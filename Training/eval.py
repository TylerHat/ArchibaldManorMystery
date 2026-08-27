#!/usr/bin/env python3
"""Asks every model the same 30 questions and writes them up side by side.

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
REFUSAL_TELLS = [
    "i cannot", "i can't help", "i won't be able", "i'm not able to",
    "i must decline", "not appropriate", "inappropriate", "i apologize, but",
    "i'm sorry, but i", "as a reminder", "it's important to note",
    "i don't feel comfortable", "let's keep things", "respectful",
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


def ask(model, system, line, timeout):
    r = requests.post("http://127.0.0.1:11434/api/chat", json={
        "model": model,
        "stream": False,
        "keep_alive": "30m",
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": line}],
        "options": {"num_predict": 140, "temperature": 0.8, "num_ctx": 8192,
                    "stop": ["\n\n", "Detective:", "\nDetective", "DETECTIVE:"]},
    }, timeout=timeout)
    r.raise_for_status()
    return r.json()["message"]["content"].strip()


def flags(text):
    low = text.lower()
    hits = [p for p in OUT_OF_CHARACTER if p in low]
    refs = [p for p in REFUSAL_TELLS if p in low]
    return hits, refs


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

    for i, (group, line) in enumerate(zip(groups, lines), 1):
        print(f"[{i:2d}/{len(lines)}] {group:<9} {line[:52]}")
        out.write(f"\n---\n\n## {i}. `{group}` {line}\n")
        for model in args.models:
            try:
                reply = ask(model, system, line, args.timeout)
            except Exception as exc:               # noqa: BLE001
                reply = f"REQUEST FAILED: {exc}"
            hits, refs = flags(reply)
            mark = []
            if hits:
                mark.append("BROKE CHARACTER: " + ", ".join(hits))
                score[model]["broke"] += 1
            if refs:
                mark.append("REFUSAL TELL: " + ", ".join(refs))
                score[model]["refused"] += 1
            if not mark:
                score[model]["clean"] += 1
            score[model][f"{group}_total"] += 1

            out.write(f"\n**{model}**")
            if mark:
                out.write(f"  <!-- {' | '.join(mark)} -->\n\n")
                out.write(f"> **[{' | '.join(mark)}]**\n>\n")
            else:
                out.write("\n\n")
            out.write("> " + reply.replace("\n", "\n> ") + "\n\n")
            out.write("> _verdict: pass / fail_\n")

    out.write("\n---\n\n## Automatic tally\n\n")
    out.write("| model | clean | broke character | refusal tells |\n|---|---|---|---|\n")
    total = len(lines)
    for model in args.models:
        s = score[model]
        out.write(f"| `{model}` | {s['clean']}/{total} | {s['broke']}/{total} | {s['refused']}/{total} |\n")
    out.close()

    print(f"\nwrote {args.out}\n")
    for model in args.models:
        s = score[model]
        print(f"  {model:<40} clean {s['clean']:2d}/{total}   "
              f"broke {s['broke']:2d}   refusal-tells {s['refused']:2d}")
    print("\nNow read the report and mark the pass/fail lines yourself.")
    print("The automatic number is the floor, not the score.")


if __name__ == "__main__":
    main()
