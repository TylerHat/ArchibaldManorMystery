#!/usr/bin/env python3
"""Verify that the documentation in .claude/ is still correct.

Run from the project root:

    python Tools/check_docs.py

Exits 0 and prints ALL CHECKS PASSED when the documentation is consistent with
the code, non-zero otherwise. No third-party dependencies.

This exists because of the rule in
.claude/rules/00-documentation-is-part-of-every-change.md: a change is not
finished until the documentation is correct. The checker cannot tell whether a
paragraph still DESCRIBES the behaviour correctly - that is on you - but it
does catch every mechanical way documentation goes stale: a moved file, a
renamed folder, a document that fell out of the index, a res:// path that no
longer resolves, and a constant whose value a document still quotes wrongly.

Add a new pairing to DOCUMENTED_CONSTANTS whenever a document starts quoting a
constant's value.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# --------------------------------------------------------------------------
# Constants whose value is quoted in the documentation.
#
#   (source file, constant name): [documents that state its value]
#
# The checker reads the real value out of the source and fails if a listed
# document does not contain it. This is the check that catches the drift
# nobody notices: someone raises a cap in code and eight documents keep
# quoting the old number.
# --------------------------------------------------------------------------
DOCUMENTED_CONSTANTS: dict[tuple[str, str], list[str]] = {
    ("Scripts/GameManager.gd", "MAX_ACTIVE_SUSPECTS"): [
        ".claude/guides/07-adding-a-character.md",
    ],
    ("Scripts/GameManager.gd", "MAX_RESPONSE_TOKENS"): [
        ".claude/guides/05-the-dialogue-system.md",
        ".claude/guides/08-ai-training-and-tuning.md",
    ],
    ("Scripts/GameManager.gd", "GROUP_MAX_TOKENS"): [
        ".claude/guides/05-the-dialogue-system.md",
        ".claude/guides/08-ai-training-and-tuning.md",
    ],
    ("Scripts/GameManager.gd", "OLLAMA_NUM_CTX"): [
        ".claude/guides/05-the-dialogue-system.md",
    ],
    ("Scripts/GameManager.gd", "HISTORY_TOKEN_BUDGET"): [
        ".claude/guides/05-the-dialogue-system.md",
    ],
    ("Scripts/GameManager.gd", "HISTORY_KEEP_RECENT"): [
        ".claude/guides/05-the-dialogue-system.md",
    ],
    ("Scripts/GameManager.gd", "CHARS_PER_TOKEN"): [
        ".claude/guides/05-the-dialogue-system.md",
    ],
    ("Scripts/GameManager.gd", "SUMMARY_MAX_TOKENS"): [
        ".claude/guides/05-the-dialogue-system.md",
    ],
    ("Scripts/GameManager.gd", "NEXT_FREE_SLOT"): [
        ".claude/guides/07-adding-a-character.md",
    ],
    ("Scripts/GameManager.gd", "MAX_SEED"): [
        ".claude/guides/06-the-case-generator.md",
    ],
    ("Scripts/Main.gd", "MAX_HALL_ATTENDEES"): [
        ".claude/guides/04-the-manor-and-world.md",
    ],
    ("Scripts/Main.gd", "CELL"): [
        ".claude/guides/04-the-manor-and-world.md",
    ],
    ("Scripts/Main.gd", "PITCH"): [
        ".claude/guides/04-the-manor-and-world.md",
    ],
    ("Scripts/Main.gd", "DIALOGUE_FONT_SIZE"): [
        ".claude/guides/09-ui-and-case-notes.md",
    ],
    ("Scripts/Main.gd", "INPUT_MAX_ROWS"): [
        ".claude/guides/09-ui-and-case-notes.md",
    ],
    ("Scripts/CaseGenerator.gd", "SLOT_COUNT"): [
        ".claude/guides/06-the-case-generator.md",
    ],
    ("Scripts/CaseGenerator.gd", "MURDER_SLOT_MIN"): [
        ".claude/guides/06-the-case-generator.md",
    ],
    ("Scripts/CaseGenerator.gd", "MURDER_SLOT_MAX"): [
        ".claude/guides/06-the-case-generator.md",
    ],
    ("Scripts/CaseGenerator.gd", "INERTIA"): [
        ".claude/guides/06-the-case-generator.md",
    ],
    ("Scripts/CaseGenerator.gd", "MAX_PER_ROOM"): [
        ".claude/guides/06-the-case-generator.md",
    ],
    ("Scripts/CaseGenerator.gd", "MAX_ATTEMPTS"): [
        ".claude/guides/06-the-case-generator.md",
    ],
    ("Scripts/NPCCharacter.gd", "WANDER_MARGIN"): [
        ".claude/guides/04-the-manor-and-world.md",
        ".claude/guides/10-data-and-file-formats.md",
    ],
    ("Scripts/GroupChat.gd", "SCENE_RENDER_MAX_LINES"): [
        ".claude/guides/05-the-dialogue-system.md",
    ],
}

# Documents that must name every script, so a new one cannot be added without
# appearing in the architecture guide.
SCRIPT_INVENTORY_DOC = ".claude/guides/01-architecture.md"

# Markdown files whose relative links are checked.
LINK_ROOTS = ["CLAUDE.md", "README.md", ".claude", "Tools"]

failures: list[str] = []
notes: list[str] = []


def fail(check: str, message: str) -> None:
    failures.append(f"[{check}] {message}")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def markdown_files() -> list[Path]:
    out: list[Path] = []
    for entry in LINK_ROOTS:
        p = ROOT / entry
        if p.is_file() and p.suffix == ".md":
            out.append(p)
        elif p.is_dir():
            out.extend(sorted(p.rglob("*.md")))
    return out


# --------------------------------------------------------------------------
# 1. Every relative markdown link resolves.
# --------------------------------------------------------------------------
def check_links() -> int:
    checked = 0
    link_re = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
    for md in markdown_files():
        for m in link_re.finditer(read(md)):
            target = m.group(1).strip()
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target = target.split("#", 1)[0]
            if not target:
                continue
            checked += 1
            if not (md.parent / target).resolve().exists():
                fail("links", f"{md.relative_to(ROOT)} -> {target}")
    return checked


# --------------------------------------------------------------------------
# 2. .claude/README.md indexes every file in .claude/, and nothing else.
# --------------------------------------------------------------------------
def check_index() -> int:
    index = ROOT / ".claude" / "README.md"
    if not index.exists():
        fail("index", ".claude/README.md is missing")
        return 0
    text = read(index)
    on_disk = sorted(
        p for p in (ROOT / ".claude").rglob("*.md") if p.name != "README.md"
    )
    for p in on_disk:
        rel = p.relative_to(ROOT / ".claude").as_posix()
        # rules/README.md indexes the rules; the top index links the folder.
        if rel == "rules/README.md":
            continue
        if rel not in text and p.name not in text:
            fail("index", f"{p.relative_to(ROOT)} is not listed in .claude/README.md")
    return len(on_disk)


# --------------------------------------------------------------------------
# 3. Every .claude/... path named in a code comment exists.
# --------------------------------------------------------------------------
def check_doc_paths_in_code() -> int:
    checked = 0
    path_re = re.compile(r"\.claude/[A-Za-z0-9_./-]+\.md")
    sources = sorted((ROOT / "Scripts").rglob("*.gd")) + sorted(
        (ROOT / "Training").glob("*.py")
    )
    sources.append(ROOT / "Tools" / "check_docs.py")
    for src in sources:
        if not src.exists():
            continue
        for m in path_re.finditer(read(src)):
            checked += 1
            if not (ROOT / m.group(0)).exists():
                fail("doc-paths", f"{src.relative_to(ROOT)} names missing {m.group(0)}")
    return checked


# --------------------------------------------------------------------------
# 4. Every res:// path resolves.
# --------------------------------------------------------------------------
def check_resource_paths() -> int:
    checked = 0
    res_re = re.compile(r"res://([A-Za-z0-9_./-]+)")
    targets = (
        sorted((ROOT / "Scripts").rglob("*.gd"))
        + sorted((ROOT / "Scenes").rglob("*.tscn"))
        + [ROOT / "project.godot"]
    )
    for f in targets:
        if not f.exists():
            continue
        for m in res_re.finditer(read(f)):
            checked += 1
            if not (ROOT / m.group(1)).exists():
                fail("res-paths", f"{f.relative_to(ROOT)} -> res://{m.group(1)}")
    return checked


# --------------------------------------------------------------------------
# 5. A constant's documented value matches the source.
# --------------------------------------------------------------------------
def gd_constant(source: Path, name: str) -> str | None:
    pattern = re.compile(
        r"^\s*const\s+" + re.escape(name) + r"\s*(?::\s*\w+\s*)?:?=\s*(.+?)\s*(?:#.*)?$",
        re.M,
    )
    m = pattern.search(read(source))
    if not m:
        return None
    return m.group(1).strip()


def check_documented_constants() -> int:
    checked = 0
    for (src_rel, const_name), docs in DOCUMENTED_CONSTANTS.items():
        src = ROOT / src_rel
        if not src.exists():
            fail("constants", f"source {src_rel} does not exist")
            continue
        raw = gd_constant(src, const_name)
        if raw is None:
            fail(
                "constants",
                f"{const_name} no longer exists in {src_rel}; "
                f"remove it from DOCUMENTED_CONSTANTS or restore it",
            )
            continue
        # Only scalar values are comparable as text. Arrays and dictionaries
        # are skipped rather than guessed at.
        if raw.startswith(("[", "{")) or raw.endswith(","):
            continue
        value = raw.strip('"')
        for doc_rel in docs:
            doc = ROOT / doc_rel
            checked += 1
            if not doc.exists():
                fail("constants", f"{doc_rel} does not exist")
                continue
            windows = mention_windows(read(doc), const_name)
            if not windows:
                fail(
                    "constants",
                    f"{doc_rel} does not mention {const_name} at all; "
                    f"remove the pairing from DOCUMENTED_CONSTANTS or "
                    f"document the constant",
                )
                continue
            if not any(value_present(w, value) for w in windows):
                fail(
                    "constants",
                    f"{src_rel} {const_name} = {value}, but {doc_rel} "
                    f"states a different value beside it",
                )
    return checked


def mention_windows(text: str, const_name: str) -> list[str]:
    """The stretches of a document that talk about this constant.

    A value has to appear NEXT TO the constant it belongs to, not merely
    somewhere in the same file, or a document containing the digit 6 anywhere
    would vouch for every constant equal to 6. The window is the line naming
    the constant plus one line either side, which covers a table row, a code
    block line, and a wrapped sentence.
    """
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines):
        if const_name in line:
            out.append("\n".join(lines[max(0, i - 1):i + 3]))
    return out


def value_present(text: str, value: str) -> bool:
    """Whether a document states this value.

    Accepts the spellings prose actually uses: 12.0 written as 12, 1000000
    written as 1,000,000, and a number followed by a unit or a full stop
    ("3.5m", "is 40."). Rejects a value that is only part of a longer number,
    so 40 does not match inside 140 or 40.5.
    """
    candidates = {value}
    numeric = True
    try:
        number = float(value)
        if number.is_integer():
            candidates.add(str(int(number)))
            candidates.add(f"{int(number)}.0")
            candidates.add(f"{int(number):,}")
        else:
            candidates.add(str(number))
    except ValueError:
        numeric = False

    for c in candidates:
        if numeric:
            pattern = rf"(?<![\d.]){re.escape(c)}(?!\d)(?!\.\d)"
        else:
            pattern = rf"\b{re.escape(c)}\b"
        if re.search(pattern, text):
            return True
    return False


# --------------------------------------------------------------------------
# 6. Every script is named in the architecture guide.
# --------------------------------------------------------------------------
def check_script_coverage() -> int:
    doc = ROOT / SCRIPT_INVENTORY_DOC
    if not doc.exists():
        fail("scripts", f"{SCRIPT_INVENTORY_DOC} is missing")
        return 0
    text = read(doc)
    scripts = sorted((ROOT / "Scripts").glob("*.gd"))
    for s in scripts:
        if s.name not in text:
            fail(
                "scripts",
                f"{s.name} is not named in {SCRIPT_INVENTORY_DOC}; "
                f"add it to the file table",
            )
    return len(scripts)


# --------------------------------------------------------------------------

def main() -> int:
    print("Checking documentation against the code...\n")

    results = [
        ("relative markdown links", check_links()),
        ("documents in .claude/", check_index()),
        (".claude paths in code comments", check_doc_paths_in_code()),
        ("res:// resource paths", check_resource_paths()),
        ("documented constant values", check_documented_constants()),
        ("scripts covered by the architecture guide", check_script_coverage()),
    ]
    for label, count in results:
        print(f"  {count:5d}  {label}")

    for note in notes:
        print(f"\n  note: {note}")

    if failures:
        print(f"\n{len(failures)} PROBLEM(S):\n")
        for f in failures:
            print(f"  {f}")
        print(
            "\nDocumentation is part of every change. See\n"
            ".claude/rules/00-documentation-is-part-of-every-change.md\n"
        )
        return 1

    print("\nALL CHECKS PASSED\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
