#!/usr/bin/env python3
"""Builds packets for re-writing the SUGGESTED lines, keeping the verdicts.

    python Training/make_rewrite_packet.py --harvest TrainingData/harvest_*.jsonl

The first judging pass decided keep-or-reject and wrote a replacement line for
every rejection. The verdicts held up; the replacements did not. They came out
40% shorter than the replies they replaced and carried a stage direction less
than half the time, which is both flatter than the game wants and a training
hazard: when the preferred reply is consistently the shorter one, DPO learns
"shorter is better" and the model starts answering in fragments.

So this rebuilds only the `suggested` text. Verdicts, reasons and confidences
are carried through untouched, which is why it is a separate script rather than
a re-judge: re-deciding 601 rows to fix 493 lines would be wasteful and would
churn calls that were already right.

Writes RewritePackets/rewrite_<character>.json, one per character so a writer
holds a single voice for a whole sitting. Feed the results back with
apply_rewrites.py.
"""

import argparse
import glob
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from make_judge_packet import load_briefs, case_facts, prev_exchange


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--harvest", nargs="*", default=None)
    ap.add_argument("--prompts", default="Training/prompts.txt")
    ap.add_argument("--out", default="RewritePackets")
    ap.add_argument("--only", nargs="*", default=None)
    args = ap.parse_args()

    paths = args.harvest or sorted(glob.glob("TrainingData/harvest_*.jsonl"))
    briefs = load_briefs(args.prompts)

    rows = {}
    for p in paths:
        for l in Path(p).open(encoding="utf-8"):
            if not l.strip():
                continue
            r = json.loads(l)
            rows[r["id"]] = r

    groups = {}
    for r in rows.values():
        rec = r.get("recommendation") or {}
        if rec.get("verdict") != "reject":
            continue
        cid = r["character_id"]
        if args.only and cid not in args.only:
            continue
        b = briefs.get(cid, {})
        room, moves = case_facts(r)
        who = b.get("who", "")
        if room:
            who = re.sub(r",?\s*found in the [^.,]+", "", who).rstrip(" .,")
            who = f"{who}, currently in the {room}"
        pq, pa = prev_exchange(r)
        item = {
            "id": r["id"],
            "character": r.get("character", cid),
            "who": who,
            "trait_to_protect": b.get("trait", ""),
            "what_failure_looks_like": b.get("fail", ""),
            "their_secret": b.get("secret", ""),
            "group": r["group"],
            "question": r["question"],
            "reply_being_replaced": r["candidates"][0]["text"],
            "why_it_failed": rec.get("reason", ""),
            "current_suggestion_too_flat": rec.get("suggested", ""),
            "reply_length": len(r["candidates"][0]["text"]),
        }
        if moves:
            item["their_movements_last_night"] = moves
        if pa:
            item["previous_exchange"] = {"question": pq, "reply": pa}
        groups.setdefault(cid, []).append(item)

    out_dir = Path(args.out)
    out_dir.mkdir(exist_ok=True)
    for cid, items in sorted(groups.items()):
        p = out_dir / f"rewrite_{cid}.json"
        p.write_text(json.dumps(items, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"  {p}  {len(items)} lines to rewrite  {p.stat().st_size:,} bytes")
    print(f"\n{len(groups)} packet(s), {sum(len(v) for v in groups.values())} lines in {out_dir}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
