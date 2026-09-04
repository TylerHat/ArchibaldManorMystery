#!/usr/bin/env python3
"""Probe C: hand the model ONE row of its card, not the whole table.

    python Training/probe_c.py --models archibald-suspect:v1

Probe B restated the whole four-row account immediately before the question and
did not help: three questions improved, three got worse, and one answer came
back with every room right and every time wrong. The reading was that the model
can see the card perfectly well - it never invents a room that is not on it -
but cannot select the right row AND reformat it AND stay in voice, all at once,
at 3B.

So this removes the selection step. The game knows what hour the question is
about, looks the row up itself, and hands over that one line. Copying one line
into character is a much smaller job than querying a table.

Writes probe_c.md with the injected fact beside each reply, so you can see what
the model was given and what it did with it.
"""

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import requests
except ImportError:
    sys.exit("pip install requests")

sys.path.insert(0, str(Path(__file__).parent))
from eval import system_prompt, TOKEN_CAP          # noqa: E402


def parse_account(sysp):
    """The account block -> [(start_min, end_min, text), ...] plus the last-seen line."""
    i = sysp.find("YOUR OWN MOVEMENTS")
    j = sysp.find("Those are the only", i)
    if i < 0:
        return [], ""
    rows, last_seen = [], ""
    for ln in sysp[i:j if j > i else len(sysp)].splitlines():
        t = ln.strip()
        if not t.startswith("- "):
            continue
        if t.lower().startswith("- you last saw"):
            last_seen = t[2:]
            continue
        m = re.match(r"- (\d{1,2}):(\d{2}) to (\d{1,2}):(\d{2}): (.+)", t)
        if m:
            a = int(m.group(1)) % 24 * 60 + int(m.group(2))
            b = int(m.group(3)) % 24 * 60 + int(m.group(4))
            if b <= a:
                b += 24 * 60
            rows.append((a, b, m.group(5).rstrip(".")))
    return rows, last_seen


WORDS = {"eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "midnight": 0}


def asked_time(q):
    """The clock time a question is about, in minutes, or None for 'the whole evening'."""
    low = q.lower()
    if "midnight" in low:
        return 24 * 60
    m = re.search(r"half past (\w+)", low)
    if m and m.group(1) in WORDS:
        return WORDS[m.group(1)] * 60 + 30
    m = re.search(r"between (\w+) and (\w+)", low)
    if m and m.group(1) in WORDS:
        return WORDS[m.group(1)] * 60
    m = re.search(r"\b(\w+)\s*o'clock", low)
    if m and m.group(1) in WORDS:
        return WORDS[m.group(1)] * 60
    m = re.search(r"\bat (\w+)\b", low)
    if m and m.group(1) in WORDS:
        return WORDS[m.group(1)] * 60
    return None


# Questions that are about the shape of the whole evening rather than one hour.
# Checked BEFORE the clock lookup: "backwards, starting at midnight" names a time
# but wants the lot, and midnight falls outside a card that runs to 12:00.
WHOLE_EVENING = re.compile(
    r"whole evening|in order|backwards|every room|set foot|how long|all told|"
    r"not mentioned|take me through", re.I)


def fact_for(q, rows, last_seen):
    """The one line to hand over, or the whole card when the question needs it."""
    if re.search(r"last saw|last see", q, re.I) and last_seen:
        return f"The detective is asking when you last saw him.\nYour card says: {last_seen}"
    t = None if WHOLE_EVENING.search(q) else asked_time(q)
    if t is None:
        card = "\n".join(f"  {a//60}:{a%60:02d} to {b//60}:{b%60:02d} - {txt}" for a, b, txt in rows)
        return ("The detective is asking about the whole evening. Your card, in full:\n"
                + card + "\nGive every row. Do not merge two of them and do not leave one out.")
    for a, b, txt in rows:
        if a <= t < b:
            return (f"The detective is asking about {t//60}:{t%60:02d}.\n"
                    f"Your card for that hour reads: {txt}\n"
                    f"That block runs {a//60}:{a%60:02d} to {b//60}:{b%60:02d}.")
    return ""


def ask(model, system, content, timeout):
    r = requests.post("http://127.0.0.1:11434/api/chat", json={
        "model": model, "stream": False, "keep_alive": "30m",
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": content}],
        "options": {"num_predict": TOKEN_CAP, "temperature": 0.8, "num_ctx": 8192,
                    "stop": ["\n\n", "Detective:", "\nDetective", "DETECTIVE:"]},
    }, timeout=timeout)
    r.raise_for_status()
    return r.json()["message"]["content"].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+", default=["archibald-suspect:v1"])
    ap.add_argument("--lines", default="Training/_probe_lines.txt")
    ap.add_argument("--system", default=None)
    ap.add_argument("--data-dir", default="TrainingData")
    ap.add_argument("--out", default="Training/reports/probe_c.md")
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--dry-run", action="store_true", help="show the injections, ask nothing")
    args = ap.parse_args()

    sysp = system_prompt(args.system, args.data_dir)
    rows, last_seen = parse_account(sysp)
    if not rows:
        sys.exit("No movement rows found in that system prompt.")
    print(f"card: {len(rows)} rows" + (", plus a last-seen line" if last_seen else ""))
    for a, b, txt in rows:
        print(f"   {a//60}:{a%60:02d}-{b//60}:{b%60:02d}  {txt}")

    qs = [l.split("|", 1)[-1].strip()
          for l in Path(args.lines).read_text(encoding="utf-8").splitlines()
          if "|" in l and not l.startswith("#")]

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    out = Path(args.out).open("w", encoding="utf-8")
    out.write("# Probe C - one row, not the whole table\n\n")
    out.write("Each question shows the fact the game resolved and injected, then the reply.\n")
    out.write("Grade the reply against the injected fact, not against the whole card.\n")

    print()
    for i, q in enumerate(qs, 1):
        fact = fact_for(q, rows, last_seen)
        content = (f"[FACT SHEET FOR THIS QUESTION\n{fact}\n"
                   f"Answer in character, but the hour and the room must be exactly as written above.]\n\n"
                   f"{q}") if fact else q
        out.write(f"\n---\n\n## {i}. {q}\n\n**injected:**\n\n```\n{fact or '(nothing matched)'}\n```\n")
        print(f"[{i:2d}/{len(qs)}] {q[:52]}")
        print(f"        -> {fact.splitlines()[1] if fact and len(fact.splitlines())>1 else fact[:60]}")
        if args.dry_run:
            continue
        for model in args.models:
            try:
                reply = ask(model, sysp, content, args.timeout)
            except Exception as exc:                     # noqa: BLE001
                reply = f"REQUEST FAILED: {exc}"
            out.write(f"\n**{model}**\n\n> " + reply.replace("\n", "\n> ") + "\n\n")
            out.write("> _verdict: pass / fail_\n")
    out.close()
    print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
