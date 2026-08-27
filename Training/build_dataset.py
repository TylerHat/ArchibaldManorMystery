#!/usr/bin/env python3
"""Turns a folder of captured play sessions into two files a trainer can read.

Reads every sft_*.jsonl and dpo_*.jsonl written by TrainingCapture.gd and emits:

    sft.jsonl              imitation examples, ready to train on
    dpo.jsonl              preference pairs, ready to train on
    dpo_needs_chosen.jsonl the rejected replies still missing a better answer

The third file is the only manual work in the pipeline. Every guard catch in a
hall meetup, and every F10 press, lands there with an empty "chosen". Write what
the suspect should have said, save, and re-run this script; rows move from the
third file into dpo.jsonl as they get filled in.

Usage:
    python Training/build_dataset.py                 # reads ./TrainingData
    python Training/build_dataset.py path/to/dir
"""

import json
import sys
from collections import Counter
from pathlib import Path


def load(path):
    rows = []
    with path.open(encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                print(f"  ! {path.name}:{n} unreadable, skipped ({exc})")
    return rows


def fingerprint(row):
    """Identity of a row, for dropping duplicates.

    Keyed on the last user turn plus the reply rather than the whole message
    list: asking the same suspect the same question twice in one session
    produces two rows whose histories differ by a few turns but which teach
    exactly the same thing, and keeping both quietly doubles that lesson's
    weight.
    """
    msgs = row.get("messages", [])
    last_user = next((m["content"] for m in reversed(msgs) if m.get("role") == "user"), "")
    tail = row.get("chosen", "") + "\x00" + row.get("rejected", "")
    if not row.get("chosen") and not row.get("rejected"):
        tail = msgs[-1].get("content", "") if msgs else ""
    return (row.get("character_id", ""), last_user, tail)


def system_of(row):
    msgs = row.get("messages", [])
    return msgs[0]["content"] if msgs and msgs[0].get("role") == "system" else ""


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "TrainingData")
    if not root.is_dir():
        sys.exit(f"No such folder: {root.resolve()}\n"
                 "Play a session with the dialogue log box ticked first.")

    sft_files = sorted(root.glob("sft_*.jsonl"))
    dpo_files = sorted(root.glob("dpo_*.jsonl"))
    print(f"Reading {len(sft_files)} sft file(s) and {len(dpo_files)} dpo file(s) from {root}\n")

    sft_raw, dpo_raw = [], []
    for p in sft_files:
        sft_raw += load(p)
    for p in dpo_files:
        dpo_raw += load(p)

    # --- dedupe ----------------------------------------------------------
    seen = set()
    sft = []
    for r in sft_raw:
        fp = fingerprint(r)
        if fp not in seen:
            seen.add(fp)
            sft.append(r)

    # Preference rows key on the REJECTED reply alone, not on chosen+rejected.
    # fill_chosen.py writes a completed copy of a row rather than editing the
    # original in place, so the same failure exists twice: once empty, once
    # answered. Keying on the failure and keeping whichever copy has an answer
    # is what stops the answered one being treated as a separate row and the
    # empty one reappearing in the todo file forever.
    by_failure = {}
    for r in dpo_raw:
        msgs = r.get("messages", [])
        last_user = next((m["content"] for m in reversed(msgs) if m.get("role") == "user"), "")
        key = (r.get("character_id", ""), last_user, r.get("rejected", ""))
        prev = by_failure.get(key)
        if prev is None or (not prev.get("chosen", "").strip() and r.get("chosen", "").strip()):
            by_failure[key] = r
    dpo_all = list(by_failure.values())

    ready = [r for r in dpo_all if r.get("chosen", "").strip()]
    todo = [r for r in dpo_all if not r.get("chosen", "").strip()]

    # --- the check that matters most -------------------------------------
    # Rows captured before a system-prompt rewrite teach the model to answer a
    # prompt it will never be shown again. Cheap to detect, expensive to miss.
    systems = Counter(system_of(r) for r in sft + dpo_all)
    if len(systems) > 1:
        print(f"  ! {len(systems)} different system prompts across these rows.")
        print("    That usually means the prompt was edited mid-collection.")
        for text, n in systems.most_common():
            head = text[:70].replace("\n", " ")
            print(f"      {n:4d} rows  {head}...")
        print("    Consider keeping only the rows matching the prompt you ship.\n")

    # --- write -----------------------------------------------------------
    def write(path, rows, keys):
        with Path(path).open("w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps({k: r[k] for k in keys if k in r},
                                    ensure_ascii=False) + "\n")

    write("sft.jsonl", sft, ["messages"])
    write("dpo.jsonl", ready, ["messages", "chosen", "rejected"])
    write("dpo_needs_chosen.jsonl", todo,
          ["messages", "chosen", "rejected", "reason", "character_id", "scene"])

    # --- report ----------------------------------------------------------
    auto = sum(1 for r in dpo_all if r.get("source") == "guard" and r.get("chosen", "").strip())
    print(f"sft.jsonl              {len(sft):5d} examples "
          f"({len(sft_raw) - len(sft)} duplicates dropped)")
    print(f"dpo.jsonl              {len(ready):5d} pairs "
          f"({auto} of them captured automatically by the guard)")
    if todo:
        print("\n  -> python Training/fill_chosen.py   walks you through those, "
              "one at a time")
    print(f"dpo_needs_chosen.jsonl {len(todo):5d} waiting on a better reply from you")

    if dpo_all:
        print("\nWhy the guard fired:")
        for reason, n in Counter(
            r.get("reason", "(marked by hand)") for r in dpo_all
        ).most_common(8):
            print(f"  {n:4d}  {reason}")

    if sft:
        print("\nGood examples per suspect:")
        for cid, n in Counter(r.get("character_id", "?") for r in sft).most_common():
            bar = "#" * min(n, 40)
            print(f"  {cid:<12} {n:4d}  {bar}")
        thin = [c for c, n in Counter(r.get("character_id", "?") for r in sft).items() if n < 15]
        if thin:
            print(f"\n  ! Thin on: {', '.join(thin)}. A suspect with almost no examples")
            print("    drifts toward the voice of whoever has the most. Interview them more.")

    print("\nReady to train when sft.jsonl is 300+ and dpo.jsonl is 120+.")


if __name__ == "__main__":
    main()
