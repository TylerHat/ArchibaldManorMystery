#!/usr/bin/env python3
"""Swaps in better `suggested` lines without disturbing the verdicts.

    python Training/apply_rewrites.py

Reads RewritePackets/results/rewrite_<character>.json and replaces the
`recommendation.suggested` text on every matching harvest row. The verdict,
reason and confidence are left exactly as they were.

Why this exists: the first judging pass wrote replacement lines that came out
40% shorter than the replies they replaced and carried a stage direction less
than half the time. Both are wrong for the game, and the length one is a
training hazard - when the preferred reply is reliably the shorter one, DPO has
no way to know that length was not the point, so it learns "shorter is better"
and the model starts answering in fragments. audit.py flags it above 72%.

Rewriting the line is much cheaper than re-judging the row, and the keep/reject
calls were sound, so they are carried through untouched.
"""

import argparse
import glob
import json
import statistics
import sys
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rewrites", default="RewritePackets/results/rewrite_*.json")
    ap.add_argument("--harvest", nargs="*", default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    files = sorted(glob.glob(args.rewrites))
    if not files:
        sys.exit(f"No rewrite files matching {args.rewrites}")

    new = {}
    for f in files:
        d = json.loads(Path(f).read_text(encoding="utf-8"))
        for x in d:
            if x.get("id") and (x.get("suggested") or "").strip():
                new[x["id"]] = x["suggested"]
        print(f"  {Path(f).name}: {len(d)} lines")
    print(f"  {len(new)} unique\n")

    paths = args.harvest or sorted(glob.glob("TrainingData/harvest_*.jsonl"))
    swapped = skipped = 0
    before, after, shorter = [], [], 0

    for p in paths:
        rows = [json.loads(l) for l in Path(p).open(encoding="utf-8") if l.strip()]
        hit = 0
        for r in rows:
            rec = r.get("recommendation")
            if not rec or r["id"] not in new:
                continue
            if rec.get("verdict") != "reject":
                # A keep has no replacement to improve. Leave it alone.
                skipped += 1
                continue
            before.append(len(rec.get("suggested", "")))
            rec["suggested"] = new[r["id"]]
            after.append(len(rec["suggested"]))
            if len(rec["suggested"]) < len(r["candidates"][0]["text"]):
                shorter += 1
            hit += 1
        if hit and not args.dry_run:
            with Path(p).open("w", encoding="utf-8") as f:
                for r in rows:
                    f.write(json.dumps(r, ensure_ascii=False) + "\n")
        swapped += hit
        print(f"  {Path(p).name}: {hit} lines replaced")

    if after:
        print("\n" + "=" * 56)
        print(f"  {swapped:5d}  lines replaced")
        print(f"  median length {int(statistics.median(before))} -> {int(statistics.median(after))}")
        pct = 100.0 * shorter / len(after)
        print(f"  shorter than the reply they replace: {pct:.0f}%")
        if pct > 72:
            print("  ! Still above the threshold audit.py warns at. DPO will read")
            print("    that as 'shorter is better'. Lengthen some winners.")
        else:
            print("  Below the 72% threshold, so length is no longer a confound.")
        print("=" * 56)

    if args.dry_run:
        print("\n  dry run, nothing written.")
    else:
        print("\n  Next: open the reviewer and press A to accept, J / K to overrule.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
