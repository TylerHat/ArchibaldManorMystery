#!/usr/bin/env python3
"""Reads sft.jsonl and dpo.jsonl and tells you whether they are worth training on.

Run this before you spend an hour of GPU time, not after. Every check here
exists because the failure it catches is invisible in a loss curve: the loss
goes down beautifully while the model learns the wrong lesson, and you only find
out when you play it.

    python Training/audit.py

Exit code is 1 if anything looks likely to ruin a run, so it can gate a script.
"""

import json
import statistics
import sys
from collections import Counter
from pathlib import Path

# Same list the game's guard uses. A reply carrying one of these should never
# have been kept as a good example.
OUT_OF_CHARACTER = [
    "as an ai", "an ai assistant", "language model", "i am an ai", "i'm an ai",
    "murder mystery game", "this game", "the game is over", "the game is now over",
    "start a new game", "play again", "would you like to start", "would you like to play",
    "previous instructions", "system prompt", "developer mode", "as the administrator",
    "the player", "well done, detective", "you have solved", "case is solved",
]

# The shapes a model refuses in, as opposed to the shapes a suspect refuses in.
# A butler telling a detective to go to hell is good drama. "I don't feel
# comfortable" is a model stepping out from behind the butler.
REFUSAL_TELLS = [
    "i cannot", "i can't help", "i won't be able", "i'm not able to",
    "i must decline", "not appropriate", "inappropriate", "i apologize, but",
    "i'm sorry, but i", "as a reminder", "it's important to note",
    "i don't feel comfortable", "let's keep things", "respectful",
]

CHARS_PER_TOKEN = 3.6  # matches GameManager.CHARS_PER_TOKEN

problems = []
notes = []


def bar(n, scale):
    return "#" * max(1, int(n / scale)) if n else ""


def read(path):
    p = Path(path)
    if not p.exists():
        return []
    return [json.loads(l) for l in p.open(encoding="utf-8") if l.strip()]


def reply_of(row):
    msgs = row.get("messages", [])
    return msgs[-1].get("content", "") if msgs and msgs[-1].get("role") == "assistant" else ""


def scan(text):
    low = text.lower()
    return ([p for p in OUT_OF_CHARACTER if p in low],
            [p for p in REFUSAL_TELLS if p in low])


def section(title):
    print("\n" + title)
    print("-" * len(title))


def main():
    sft = read("sft.jsonl")
    dpo = read("dpo.jsonl")
    todo = read("dpo_needs_chosen.jsonl")

    print("=" * 68)
    print("  TRAINING DATA AUDIT")
    print("=" * 68)
    print(f"\n  sft.jsonl               {len(sft):5d} examples   (want 300+)")
    print(f"  dpo.jsonl               {len(dpo):5d} pairs      (want 120+)")
    print(f"  dpo_needs_chosen.jsonl  {len(todo):5d} unfinished (want 0)")

    if len(sft) < 300:
        notes.append(f"Only {len(sft)} SFT examples. It will train, but the voice "
                     "will be thin. 300 is where it starts holding together.")
    if len(dpo) < 120:
        notes.append(f"Only {len(dpo)} DPO pairs. This is the pass that fixes "
                     "break-character, so it is the one worth being patient about.")
    if todo:
        notes.append(f"{len(todo)} rejected replies still have no 'chosen'. They are "
                     "not being trained on. Fill them in and re-run build_dataset.py.")

    # ---------------------------------------------------------------- SFT --
    if sft:
        section("1. Are the good examples actually good?")
        bad_ooc, bad_ref = [], []
        for i, r in enumerate(sft):
            ooc, ref = scan(reply_of(r))
            if ooc:
                bad_ooc.append((i, ooc))
            if ref:
                bad_ref.append((i, ref))

        if bad_ooc:
            problems.append(
                f"{len(bad_ooc)} SFT examples contain break-character phrases. "
                "You are teaching the exact behaviour you are trying to remove.")
            print(f"  ! {len(bad_ooc)} rows carry an OUT_OF_CHARACTER phrase:")
            for i, hits in bad_ooc[:5]:
                print(f"      row {i}: {', '.join(hits)}")
        if bad_ref:
            problems.append(
                f"{len(bad_ref)} SFT examples read like a model refusing. "
                "Fine-tuning on these puts refusals back in, which undoes the abliteration.")
            print(f"  ! {len(bad_ref)} rows read like a refusal:")
            for i, hits in bad_ref[:5]:
                print(f"      row {i}: {', '.join(hits)}")
        if not bad_ooc and not bad_ref:
            print("  ok - nothing in the good pile looks like a failure.")

        section("2. Reply length")
        lens = [len(reply_of(r)) for r in sft]
        toks = [int(l / CHARS_PER_TOKEN) for l in lens]
        print(f"  median {statistics.median(toks):.0f} tokens, "
              f"mean {statistics.mean(toks):.0f}, max {max(toks)}")
        buckets = Counter(min(int(t / 20) * 20, 140) for t in toks)
        scale = max(1, max(buckets.values()) / 30)
        for lo in sorted(buckets):
            label = f"{lo}+" if lo == 140 else f"{lo}-{lo+19}"
            print(f"    {label:>7} tok  {buckets[lo]:4d}  {bar(buckets[lo], scale)}")
        long_ones = sum(1 for t in toks if t > 110)
        if long_ones > len(sft) * 0.15:
            notes.append(
                f"{long_ones} examples run past 110 tokens, near your 140 cap. "
                "Keeping many long replies teaches the model that long is correct, "
                "and every extra token is 29ms of the player waiting.")

        section("3. Coverage")
        by_char = Counter(r.get("character_id", "?") for r in sft)
        scale = max(1, max(by_char.values()) / 34)
        for cid, n in by_char.most_common():
            print(f"    {cid:<12} {n:4d}  {bar(n, scale)}")
        if by_char:
            hi, lo = max(by_char.values()), min(by_char.values())
            if hi > lo * 4:
                notes.append(
                    f"Coverage is lopsided: {hi} examples for the best-served suspect "
                    f"against {lo} for the worst. Thin characters drift toward the "
                    "voice of whoever dominates the set.")
        by_scene = Counter(r.get("scene", "?") for r in sft)
        print(f"\n    private {by_scene.get('private', 0)}   "
              f"hall {by_scene.get('group', 0)}")
        if by_scene.get("group", 0) < len(sft) * 0.15:
            notes.append(
                "Almost everything came from private interviews. Hall meetups are a "
                "different prompt shape, and a model tuned only on interviews will not "
                "have improved there.")

        section("4. Repeats")
        rep = Counter(reply_of(r).strip() for r in sft)
        worst = [(t, n) for t, n in rep.most_common(5) if n > 2]
        if worst:
            print("  ! the same reply was kept more than twice:")
            for t, n in worst:
                print(f"      {n}x  {t[:60]}...")
            notes.append("Repeated replies get learned hardest. If the model was "
                         "looping, those rows teach it to loop.")
        else:
            print("  ok - no reply kept more than twice.")

    # ---------------------------------------------------------------- DPO --
    if dpo:
        section("5. Are the pairs teaching what you think?")
        ident = sum(1 for r in dpo if r["chosen"].strip() == r["rejected"].strip())
        if ident:
            problems.append(f"{ident} pairs have identical chosen and rejected. "
                            "They contribute nothing and add noise.")
            print(f"  ! {ident} pairs are identical on both sides.")

        c_len = [len(r["chosen"]) for r in dpo]
        r_len = [len(r["rejected"]) for r in dpo]
        shorter = sum(1 for c, j in zip(c_len, r_len) if c < j)
        pct = 100.0 * shorter / len(dpo)
        print(f"  chosen averages {statistics.mean(c_len):.0f} chars, "
              f"rejected {statistics.mean(r_len):.0f}")
        print(f"  chosen is shorter in {shorter}/{len(dpo)} pairs ({pct:.0f}%)")
        if pct > 72:
            problems.append(
                f"In {pct:.0f}% of pairs the good reply is the shorter one. DPO will "
                "happily learn 'shorter is better' instead of 'in character is better', "
                "and you get a model that answers in clipped fragments. Write some "
                "'chosen' replies that are as long as the rejected one.")
        elif pct < 28:
            notes.append(f"In {100-pct:.0f}% of pairs the good reply is the longer one. "
                         "Same trap in reverse: watch for the model padding.")

        good_ooc = sum(1 for r in dpo if scan(r["chosen"])[0])
        good_ref = sum(1 for r in dpo if scan(r["chosen"])[1])
        if good_ooc or good_ref:
            problems.append(
                f"{good_ooc + good_ref} pairs have a 'chosen' that itself breaks "
                "character or reads as a refusal. DPO will push toward it.")
            print(f"  ! {good_ooc} chosen replies break character, "
                  f"{good_ref} read as refusals.")

        bad_ooc = sum(1 for r in dpo if scan(r["rejected"])[0])
        print(f"  {bad_ooc}/{len(dpo)} rejected replies trip the guard "
              f"({100.0*bad_ooc/len(dpo):.0f}%) - the rest are subtler failures you caught by eye.")
        if bad_ooc == len(dpo):
            notes.append("Every rejected reply is one the guard already catches. The "
                         "guard is handling those at runtime anyway, so the training is "
                         "partly redundant. Press F10 more on the failures it misses: "
                         "refusals, moralising, modern voice.")

        section("6. Prompt consistency")
        sysd = Counter(
            (r["messages"][0]["content"] if r["messages"] and r["messages"][0]["role"] == "system" else "")
            for r in sft + dpo)
        if len(sysd) > 1:
            problems.append(
                f"{len(sysd)} different system prompts across the data. Rows captured "
                "before a prompt edit teach the model to answer a prompt it will never "
                "be shown. Keep only the rows matching the prompt you ship.")
            for text, n in sysd.most_common():
                print(f"    {n:4d} rows  {text[:60].replace(chr(10), ' ')}...")
        else:
            print("  ok - one system prompt throughout.")

    # ------------------------------------------------------------- budget --
    if sft:
        section("7. Rough training cost")
        total_tok = sum(
            int(sum(len(m["content"]) for m in r["messages"]) / CHARS_PER_TOKEN)
            for r in sft)
        row_toks = [
            int(sum(len(m["content"]) for m in r["messages"]) / CHARS_PER_TOKEN)
            for r in sft]
        longest = max(row_toks)
        print(f"  ~{total_tok:,} tokens per epoch across {len(sft)} examples")
        print(f"  longest single example: {longest} tokens")
        # max_seq_length is a silent truncator. Anything past it is cut off the
        # front, which is where the system prompt lives, so an under-set value
        # trains the model on examples whose instructions have been sliced away
        # and nothing anywhere reports it.
        for cap in (2048, 4096, 8192):
            if longest < cap * 0.92:
                print(f"  -> set max_seq_length = {cap} in the notebook")
                break
        else:
            print(f"  -> set max_seq_length = 8192; {sum(1 for t in row_toks if t > 7500)} "
                  "examples are close to it and may be truncated")
        print(f"  2 epochs on a free Colab T4: roughly {2*total_tok/2000/60:.0f}-"
              f"{2*total_tok/1000/60:.0f} minutes")
        print(f"  DPO on {len(dpo)} pairs: add roughly 15-30 minutes")

    # ------------------------------------------------------------ verdict --
    print("\n" + "=" * 68)
    if problems:
        print("  FIX BEFORE TRAINING")
        print("=" * 68)
        for p in problems:
            print(f"\n  x  {p}")
    if notes:
        print("\n" + "=" * 68)
        print("  WORTH KNOWING")
        print("=" * 68)
        for n in notes:
            print(f"\n  -  {n}")
    if not problems and not notes:
        print("  Nothing to flag. Go and train it.")
        print("=" * 68)
    elif not problems:
        print("\n  Nothing blocking. The notes above are judgement calls, not errors.")
    print()
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
