#!/usr/bin/env python3
"""Merges Claude's verdicts back onto the harvest rows.

    python Training/apply_judge.py

Reads JudgePackets/verdicts_*.json and writes a `recommendation` field onto every
matching row of the harvest file it came from. The reviewer then shows that
recommendation with a one-key accept, so your pass becomes confirm-or-override
rather than judging three hundred replies cold.

Nothing here decides anything. A recommendation is advisory and is only turned
into training data once you have accepted it in the reviewer. That separation is
deliberate: a judge model has its own opinions about what a suspect should say
under pressure, and yours is the one that matters.
"""

import argparse
import glob
import json
import sys
from collections import Counter
from pathlib import Path

VALID = {"keep", "reject"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verdicts", default="JudgePackets/verdicts_*.json")
    ap.add_argument("--harvest", nargs="*", default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    vfiles = sorted(glob.glob(args.verdicts))
    if not vfiles:
        sys.exit(f"No verdict files matching {args.verdicts}\n"
                 "Run make_judge_packet.py, then ask Claude to judge the packets.")

    verdicts, malformed = {}, 0
    for f in vfiles:
        try:
            data = json.loads(Path(f).read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            print(f"  ! {Path(f).name} is not readable JSON: {exc}")
            continue
        for v in data:
            if not isinstance(v, dict) or "id" not in v:
                malformed += 1
                continue
            if v.get("verdict") not in VALID:
                malformed += 1
                continue
            if v["verdict"] == "reject" and not (v.get("suggested") or "").strip():
                # A rejection with no replacement is still useful (it tells the
                # reviewer to look), but it cannot become a preference pair.
                v["suggested"] = ""
            verdicts[v["id"]] = v
        print(f"  {Path(f).name}: {len(data)} verdicts")
    print(f"  {len(verdicts)} unique" + (f", {malformed} malformed and skipped" if malformed else ""))

    paths = args.harvest or sorted(glob.glob("TrainingData/harvest_*.jsonl"))
    if not paths:
        sys.exit("No harvest files found.")

    tally, touched, unmatched = Counter(), 0, set(verdicts)
    for p in paths:
        rows = [json.loads(l) for l in Path(p).open(encoding="utf-8") if l.strip()]
        hit = 0
        for r in rows:
            v = verdicts.get(r["id"])
            if not v:
                continue
            unmatched.discard(r["id"])
            r["recommendation"] = {
                "verdict": v["verdict"],
                "reason": v.get("reason", ""),
                "suggested": v.get("suggested", ""),
                "confidence": v.get("confidence", "high"),
            }
            tally[v["verdict"]] += 1
            if v.get("confidence") == "low":
                tally["flagged for a closer look"] += 1
            if v["verdict"] == "reject" and v.get("suggested"):
                tally["rejections with a suggested rewrite"] += 1
            hit += 1
        if hit and not args.dry_run:
            with Path(p).open("w", encoding="utf-8") as f:
                for r in rows:
                    f.write(json.dumps(r, ensure_ascii=False) + "\n")
        touched += hit
        print(f"  {Path(p).name}: {hit} rows updated")

    print("\n" + "=" * 56)
    for k, v in tally.most_common():
        print(f"  {v:5d}  {k}")
    if unmatched:
        print(f"  {len(unmatched):5d}  verdicts with no matching harvest row")
    print("=" * 56)

    if tally["keep"] + tally["reject"]:
        pct = 100.0 * tally["keep"] / (tally["keep"] + tally["reject"])
        print(f"\n  keep rate: {pct:.0f}%")
        if pct > 75:
            print("  That is a generous judge. Read a sample of the keeps before trusting it.")
        elif pct < 25:
            print("  That is a harsh judge. Read a sample of the rejects before trusting it.")

    if args.dry_run:
        print("\n  dry run, nothing written.")
    else:
        print("\n  Next: open the reviewer and press A to accept a recommendation,")
        print("  or J / K to overrule it. Your verdict always wins.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
