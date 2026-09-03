#!/usr/bin/env python3
"""Walks you through the rejected replies one at a time and asks for a better one.

This exists so you never have to hand-edit JSON. Editing a .jsonl file by hand
means getting quotes, backslashes and newlines exactly right on every line, and
one wrong character makes the whole row unreadable to the trainer. This script
does the escaping for you.

    python Training/fill_chosen.py

For each rejected reply you get the question that produced it, what the suspect
actually said, and why it was flagged. Type what they should have said instead.

    (just press Enter)   skip it for now, ask me again next time
    s                    same as Enter
    d                    delete it, this one is not worth fixing
    q                    save and quit

Work is saved after every single answer, so quitting halfway costs nothing.
Run build_dataset.py afterwards to fold your answers into dpo.jsonl.
"""

import json
import sys
from pathlib import Path

TODO = Path("dpo_needs_chosen.jsonl")
OUT_DIR = Path("TrainingData")


def wrap(text, width=76, indent="    "):
    words, line, out = text.split(), "", []
    for w in words:
        if len(line) + len(w) + 1 > width:
            out.append(indent + line)
            line = w
        else:
            line = (line + " " + w).strip()
    if line:
        out.append(indent + line)
    return "\n".join(out) if out else indent + "(empty)"


def question_of(row):
    msgs = row.get("messages", [])
    for m in reversed(msgs):
        if m.get("role") == "user":
            return m.get("content", "")
    return "(no question found)"


def main():
    if not TODO.exists():
        sys.exit(f"No {TODO} here.\n"
                 "Run 'python Training/build_dataset.py' first, from the project folder.")

    rows = [json.loads(l) for l in TODO.open(encoding="utf-8") if l.strip()]
    if not rows:
        print(f"{TODO} is empty. Nothing to fill in. You are done with this step.")
        return 0

    OUT_DIR.mkdir(exist_ok=True)
    out_path = OUT_DIR / "dpo_filled.jsonl"
    done_keys = set()
    if out_path.exists():
        for l in out_path.open(encoding="utf-8"):
            if l.strip():
                done_keys.add(json.loads(l).get("rejected", ""))

    pending = [r for r in rows if r.get("rejected", "") not in done_keys]
    if not pending:
        print("Every row already has an answer in TrainingData/dpo_filled.jsonl.")
        print("Run build_dataset.py to fold them in.")
        return 0

    print("=" * 72)
    print(f"  {len(pending)} replies to fix. Enter skips, 'd' deletes, 'q' saves and quits.")
    print("  Write what the suspect SHOULD have said. One or two sentences, in voice.")
    print("=" * 72)

    filled = deleted = skipped = 0
    out = out_path.open("a", encoding="utf-8")

    for i, row in enumerate(pending, 1):
        cid = row.get("character_id", "?")
        scene = row.get("scene", "?")
        reason = row.get("reason", "you flagged it by hand")

        print(f"\n\n[{i} of {len(pending)}]  {cid}  ({scene})")
        print(f"  flagged because: {reason}")
        print("\n  The detective said:")
        print(wrap(question_of(row)))
        print("\n  They replied (this is the BAD one):")
        print(wrap(row.get("rejected", "")))
        print()

        try:
            answer = input("  Should have said > ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n  stopping here.")
            break

        if answer.lower() == "q":
            print("  saving and quitting.")
            break
        if answer.lower() == "d":
            deleted += 1
            print("  deleted.")
            continue
        if answer == "" or answer.lower() == "s":
            skipped += 1
            print("  skipped, you will see it again next time.")
            continue

        # Length is the trap here, not correctness. If every good reply you write
        # is much shorter than the bad one it replaces, DPO learns "shorter is
        # better" rather than "in character is better", and you get a model that
        # answers in fragments. Worth a nudge at the moment it is happening.
        bad_len = len(row.get("rejected", ""))
        if bad_len > 60 and len(answer) < bad_len * 0.4:
            print(f"  note: that is a lot shorter than the reply it replaces "
                  f"({len(answer)} vs {bad_len} characters).")
            print("  A few of these is fine. Many of them teaches the model that short wins.")

        row["chosen"] = answer
        row["source"] = "manual"
        out.write(json.dumps(row, ensure_ascii=False) + "\n")
        out.flush()
        filled += 1

    out.close()
    print("\n" + "=" * 72)
    print(f"  filled {filled}   deleted {deleted}   skipped {skipped}")
    print(f"  saved to {out_path}")
    print("\n  Next: python Training/build_dataset.py")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
