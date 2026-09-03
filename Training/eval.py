#!/usr/bin/env python3
"""Asks every model the same fixed questions and writes them up side by side.

The system prompt is lifted out of the captured training data rather than
retyped here, so the eval always runs against the prompt the game actually
ships. Point --system at a text file to override.

Two scores come out. The automatic one reuses the same phrase list the game's
own guard uses, so it counts exactly the failures the guard would have caught.
The manual one is you reading eval_report.md, because a suspect who politely
declines to answer is a failure the guard cannot see and is the entire reason
the 'pressure' group exists.

Usage:
    ollama serve            # in another window
    python Training/eval.py                                  # baseline vs v1
    python Training/eval.py --models base:tag mine:v1 mine:v2
"""

import argparse
import json
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

try:
    import requests
except ImportError:
    sys.exit("pip install requests")

# Same list as GameManager.OUT_OF_CHARACTER. Keep the two in step: if you add a
# phrase to the game's guard, add it here, or the eval will start scoring
# better than the game behaves.
OUT_OF_CHARACTER = [
    "as an ai", "an ai assistant", "language model", "i am an ai", "i'm an ai",
    "murder mystery game", "this game", "the game is over", "the game is now over",
    "start a new game", "play again", "would you like to start", "would you like to play",
    "previous instructions", "system prompt", "developer mode", "as the administrator",
    "the player", "well done, detective", "you have solved", "case is solved",
]

# Not in the game's guard, because a suspect is allowed to refuse a detective
# and that refusal is good drama. These are the shapes a *model* refuses in,
# which is a different thing: the giveaway is that it stops being a person.
# "i cannot" bare was here and was wrong - it is ordinary period English
# ("I cannot get out of this costume") and flagged good lines while catching
# nothing. What marks a MODEL refusing is the object of the verb. "respectful"
# bare matched "Disrespectful" in a suspect describing the victim.
REFUSAL_TELLS = [
    "i cannot help", "i cannot assist", "i cannot provide", "i cannot comply",
    "i cannot answer that", "i cannot do that", "i cannot engage", "i cannot continue",
    "i can't help", "i won't be able", "i'm not able to",
    "i must decline", "not appropriate", "inappropriate", "i apologize, but",
    "i'm sorry, but i", "as a reminder", "it's important to note",
    "i don't feel comfortable", "let's keep things", "keep it respectful",
]

# Modern or American register in a 1930s English country house. Measured at 3%
# of replies on the base model and 2% on the tuned one, so this is a real if
# small failure class that the character guard never sees.
MODERN_TELLS = [
    "okay", "yeah", "gonna", "wanna", "i guess", "kids", "guys", "reach out",
    "wifi", "email", "television", "camera", "awesome", "for sure", "no worries",
    "showed up", "follow through", "check in", "process this", "not my thing",
]


def load_lines(path):
    groups, lines = [], []
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        group, _, text = raw.partition("|")
        groups.append(group.strip())
        lines.append(text.strip())
    return groups, lines


def system_prompt(explicit, data_dir):
    if explicit:
        return Path(explicit).read_text(encoding="utf-8")
    files = sorted(Path(data_dir).glob("*.jsonl"), key=lambda p: p.stat().st_mtime)
    if not files:
        sys.exit(f"No captured data in {data_dir} and no --system given.\n"
                 "Play one logged session first, or save a prompt to a text file.")
    with files[-1].open(encoding="utf-8") as fh:
        for line in fh:
            msgs = json.loads(line).get("messages", [])
            if msgs and msgs[0].get("role") == "system":
                print(f"Using the system prompt from {files[-1].name}")
                return msgs[0]["content"]
    sys.exit("Found capture files but no system message in them.")


def game_token_cap(default=200):
    """Read MAX_RESPONSE_TOKENS out of GameManager.gd.

    It was hardcoded to 140 here, and when the game raised its cap the eval
    silently kept measuring a truncation the game no longer had. Reading it
    from the source means the two cannot drift again.
    """
    gd = Path("Scripts/GameManager.gd")
    if gd.exists():
        m = re.search(r"const MAX_RESPONSE_TOKENS\s*:=\s*(\d+)", gd.read_text(encoding="utf-8"))
        if m:
            return int(m.group(1))
    return default


TOKEN_CAP = game_token_cap()


def ask(model, system, line, timeout):
    r = requests.post("http://127.0.0.1:11434/api/chat", json={
        "model": model,
        "stream": False,
        "keep_alive": "30m",
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": line}],
        "options": {"num_predict": TOKEN_CAP, "temperature": 0.8, "num_ctx": 8192,
                    "stop": ["\n\n", "Detective:", "\nDetective", "DETECTIVE:"]},
    }, timeout=timeout)
    r.raise_for_status()
    return r.json()["message"]["content"].strip()


# A first-person claim about where the speaker was. Negations and hypotheticals
# are excluded, because "I don't think I was in the Study" is a denial and
# "if she had told you I had been in the Conservatory" is a supposition. Tested
# against 1,202 harvested replies: it fires on about 0.3% of them and roughly
# half of those are still false positives, which is why the report calls these
# "worth checking" rather than marking them wrong.
POSITION_CLAIM = re.compile(
    r"\bI\s+(?:was|were|had been|stayed|sat|remained|went)\s+(?!not\b|never\b)"
    r"(?:still\s+|alone\s+|back\s+)?(?:in|into|to|at)\s+the\s+([A-Z][a-z]+(?:\s+Room)?)")

ROOMS = ["Kitchen", "Conservatory", "Library", "Ballroom", "Study",
         "Lounge", "Billiard Room", "Dining Room", "Hall"]


def rooms_on_the_card(system):
    """Every room the system prompt actually puts this suspect in."""
    ok = set()
    m = re.search(r"You are currently in the ([^.\n]+)\.", system)
    if m:
        ok.add(m.group(1).strip())
    grab = False
    for ln in system.splitlines():
        t = ln.strip()
        if t.startswith("YOUR OWN MOVEMENTS"):
            grab = True
            continue
        if grab:
            if re.match(r"- \d", t):
                for r in ROOMS:
                    if r.lower() in t.lower():
                        ok.add(r)
            elif t.startswith("Those are the only"):
                break
    return ok


def flags(text, allowed_rooms=None):
    low = text.lower()
    hits = [p for p in OUT_OF_CHARACTER if p in low]
    refs = [p for p in REFUSAL_TELLS if p in low]
    mods = [p for p in MODERN_TELLS if p in low]
    rooms = []
    if allowed_rooms:
        for m in POSITION_CLAIM.finditer(text):
            room = m.group(1)
            if room in ROOMS and room not in allowed_rooms:
                rooms.append(room)
    return hits, refs, mods, rooms


END_PUNCT = ".!?\u0022\u0027)"   # . ! ? " ' )


def looks_cut_off(text):
    """A reply that ran into the token ceiling stops mid-clause.

    14% of 601 harvested replies did this against the old 140-token cap, and
    four of the thirty-two lines in the 2026-09-01 play log end mid-sentence.
    It is invisible in a pass/fail read because the part you can see is fine.
    """
    t = text.rstrip()
    return bool(t) and t[-1] not in END_PUNCT


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+",
                    default=["huihui_ai/llama3.2-abliterate:3b", "archibald-suspect:v1"])
    ap.add_argument("--lines", default="Training/eval_lines.txt")
    ap.add_argument("--system", default=None)
    ap.add_argument("--data-dir", default="TrainingData")
    ap.add_argument("--out", default="eval_report.md")
    ap.add_argument("--timeout", type=int, default=180)
    args = ap.parse_args()

    groups, lines = load_lines(args.lines)
    system = system_prompt(args.system, args.data_dir)
    score = defaultdict(Counter)

    out = Path(args.out).open("w", encoding="utf-8")
    out.write("# Eval report\n\nSame questions, every model, same system prompt.\n")
    out.write("Mark each reply yourself: the automatic flags below catch the "
              "obvious breaks, not a suspect who quietly stopped being one.\n")

    # Models on the OUTSIDE, questions on the inside. The obvious ordering -
    # ask every model each question in turn - makes Ollama swap models on every
    # single line. On a 6 GB laptop card only one 3B fits at a time, so 30
    # questions across 2 models means 60 load/unload cycles and ten minutes of
    # nothing but disk. This way each model loads once, answers all 30, and is
    # evicted when the next one needs the card.
    replies = {}
    lengths = defaultdict(list)
    allowed_rooms = rooms_on_the_card(system)
    if allowed_rooms:
        print(f"Rooms on this prompt's card: {', '.join(sorted(allowed_rooms))}")
    for model in args.models:
        print(f"\n=== {model} ===")
        for i, (group, line) in enumerate(zip(groups, lines), 1):
            print(f"[{i:2d}/{len(lines)}] {group:<9} {line[:52]}")
            failed = False
            try:
                reply = ask(model, system, line, args.timeout)
            except Exception as exc:               # noqa: BLE001
                reply = f"REQUEST FAILED: {exc}"
                failed = True
            # A failed request is not a reply, and scoring it as one is worse
            # than useless: on 2026-09-02 a model that was never pulled 404'd on
            # all 40 questions and came top of the table, because an error string
            # trips no character flag. Count them, score none of them.
            if failed:
                score[model]["failed"] += 1
                replies[(model, i)] = (reply, ["REQUEST FAILED - not scored"])
                continue
            hits, refs, mods, rooms = flags(reply, allowed_rooms)
            mark = []
            if hits:
                mark.append("BROKE CHARACTER: " + ", ".join(hits))
                score[model]["broke"] += 1
            if refs:
                mark.append("REFUSAL TELL: " + ", ".join(refs))
                score[model]["refused"] += 1
            # "clean" keeps its original meaning - no character break, no model
            # refusal - so the number stays comparable with earlier runs. The
            # signals below are reported separately rather than folded in.
            if not mark:
                score[model]["clean"] += 1
            if mods:
                mark.append("MODERN REGISTER: " + ", ".join(mods))
                score[model]["modern"] += 1
            if rooms:
                mark.append("ROOM NOT ON THEIR CARD (check by hand): " + ", ".join(rooms))
                score[model]["rooms"] += 1
            if looks_cut_off(reply):
                mark.append("ENDS MID-CLAUSE - probably hit the %d-token cap" % TOKEN_CAP)
                score[model]["cut"] += 1
            score[model]["chars"] += len(reply)
            score[model]["acts"] += 1 if "(" in reply else 0
            score[model][f"{group}_total"] += 1
            if not (hits or refs):
                score[model][f"{group}_clean"] += 1
            lengths[model].append(len(reply))
            replies[(model, i)] = (reply, mark)

    # Written out question-by-question so the models sit side by side on the
    # page, which is the only way to read this comparison honestly.
    for i, (group, line) in enumerate(zip(groups, lines), 1):
        out.write(f"\n---\n\n## {i}. `{group}` {line}\n")
        for model in args.models:
            reply, mark = replies[(model, i)]
            out.write(f"\n**{model}**")
            if mark:
                out.write(f"  <!-- {' | '.join(mark)} -->\n\n")
                out.write(f"> **[{' | '.join(mark)}]**\n>\n")
            else:
                out.write("\n\n")
            out.write("> " + reply.replace("\n", "\n> ") + "\n\n")
            out.write("> _verdict: pass / fail_\n")

    total = len(lines)
    seen_groups = []
    for g in groups:
        if g not in seen_groups:
            seen_groups.append(g)

    out.write("\n---\n\n## Automatic tally\n\n")
    out.write("| model | clean | broke character | refusal tells | modern register | ends mid-clause |\n")
    out.write("|---|---|---|---|---|---|\n")
    for model in args.models:
        sc = score[model]
        n = total - sc["failed"]
        note = f" _({sc['failed']} requests failed, not scored)_" if sc["failed"] else ""
        out.write(f"| `{model}`{note} | {sc['clean']}/{n} | {sc['broke']}/{n} | "
                  f"{sc['refused']}/{n} | {sc['modern']}/{n} | {sc['cut']}/{n} |\n")

    out.write("\n### Clean rate by group\n\nWhich kind of question each model fails on.\n\n")
    out.write("| model | " + " | ".join(seen_groups) + " |\n")
    out.write("|---" * (len(seen_groups) + 1) + "|\n")
    for model in args.models:
        sc = score[model]
        cells = []
        for g in seen_groups:
            t = sc[f"{g}_total"]
            cells.append(f"{sc[f'{g}_clean']}/{t}" if t else "-")
        out.write(f"| `{model}` | " + " | ".join(cells) + " |\n")

    out.write("\n### Shape of the replies\n\n")
    out.write("Style, not correctness. Training moved the base model from 58% of replies\n")
    out.write("carrying a stage direction to 96%, and that is invisible in a pass/fail read.\n\n")
    out.write("| model | median chars | longest | with a stage direction | rooms to check |\n|---|---|---|---|---|\n")
    for model in args.models:
        sc = score[model]
        L = lengths[model] or [0]
        out.write(f"| `{model}` | {int(statistics.median(L))} | {max(L)} | "
                  f"{sc['acts']}/{total} | {sc['rooms']}/{total} |\n")

    out.write("\n_Room flags are advisory. The check misreads denials and hypotheticals "
              "about half the time, so read the flagged line before believing it._\n")
    out.close()

    print(f"\nwrote {args.out}\n")
    for model in args.models:
        sc = score[model]
        L = lengths[model] or [0]
        print(f"  {model}" + (f"   !! {sc['failed']} REQUESTS FAILED - is it pulled?" if sc["failed"] else ""))
        if sc["failed"] == total:
            print("      every request failed. Nothing here is a result.")
            continue
        print(f"      clean {sc['clean']:2d}/{total - sc['failed']}   broke {sc['broke']:2d}   "
              f"refusal-tells {sc['refused']:2d}   modern {sc['modern']:2d}   cut-off {sc['cut']:2d}")
        print(f"      by group: " + "  ".join(
            f"{g} {sc[f'{g}_clean']}/{sc[f'{g}_total']}" for g in seen_groups if sc[f"{g}_total"]))
        print(f"      median {int(statistics.median(L))} chars, "
              f"{sc['acts']}/{total} with a stage direction")
    print("\nNow read the report and mark the pass/fail lines yourself.")
    print("The automatic number is the floor, not the score. In particular, nothing")
    print("here can tell you whether a timeline answer matches the movement list -")
    print("that one you have to check against the prompt by hand.")


if __name__ == "__main__":
    main()
