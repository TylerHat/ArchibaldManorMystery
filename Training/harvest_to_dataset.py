#!/usr/bin/env python3
"""Turns harvest files plus reviewer decisions into training rows.

    python Training/harvest_to_dataset.py decisions.json [decisions2.json ...]

Writes TrainingData/sft_harvest_<stamp>.jsonl and dpo_harvest_<stamp>.jsonl in
exactly the shape TrainingCapture.gd writes, so build_dataset.py and audit.py
pick them up with no changes and they merge with anything you captured by
playing.

What each verdict becomes:

    good           an imitation example. The reply you approved, with the full
                   conversation that produced it.
    rewrite        you accepted Claude's suggested replacement: a preference pair
                   with the harvested reply as rejected and the suggestion as
                   chosen, plus an imitation example of the suggestion. No rerun
                   needed, which is what makes the judging pass worth having.
    picked (n)     a preference pair: the reply you rejected in pass 1 is the
                   rejected half, the candidate you chose is the chosen half.
                   Also an imitation example, because you approved it.
    bad            nothing yet. It is waiting for a pass 2 rerun. If you never
                   rerun it, it contributes nothing, which is correct: a bad
                   reply with no better alternative teaches nothing on its own.
    all bad / skip nothing, deliberately.
"""

import argparse
import glob
import json
import sys
import time
from collections import Counter
from pathlib import Path

OUT_DIR = Path("TrainingData")


def load_jsonl(path):
    return [json.loads(l) for l in Path(path).open(encoding="utf-8") if l.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("decisions", nargs="+", help="decisions.json files from review.html")
    ap.add_argument("--harvest", nargs="*", default=None,
                    help="harvest files (default: whatever the decisions name, "
                         "falling back to every TrainingData/harvest_*.jsonl)")
    ap.add_argument("--no-sft-from-picks", action="store_true",
                    help="do not also treat a picked reply as an imitation example")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    # --- gather every harvest row we might be referred to ------------------
    paths = args.harvest or []
    if not paths:
        named = []
        for d in args.decisions:
            src = json.loads(Path(d).read_text(encoding="utf-8")).get("source")
            if src and Path(src).exists():
                named.append(src)
        paths = named or sorted(glob.glob(str(OUT_DIR / "harvest_*.jsonl")))
    if not paths:
        sys.exit("No harvest files found. Pass --harvest, or run harvest.py first.")

    rows = {}
    for p in paths:
        n = 0
        for r in load_jsonl(p):
            # A later file wins, which is what makes a rerun override pass 1.
            rows[r["id"]] = r
            n += 1
        print(f"  {Path(p).name}: {n} rows")
    print(f"  {len(rows)} unique questions\n")

    # --- merge the decisions ----------------------------------------------
    verdicts, picks, rewrites = {}, {}, {}
    agreed = overruled = 0
    for d in args.decisions:
        j = json.loads(Path(d).read_text(encoding="utf-8"))
        verdicts.update(j.get("verdicts", {}))
        picks.update(j.get("picks", {}))
        rewrites.update(j.get("rewrites", {}))
        jd = j.get("judge", {})
        agreed += jd.get("agreed", 0)
        overruled += jd.get("overruled", 0)
        print(f"  {Path(d).name}: {len(j.get('verdicts', {}))} verdicts, "
              f"{len(j.get('picks', {}))} picks, {len(j.get('rewrites', {}))} rewrites")
    if agreed + overruled:
        print(f"  you agreed with Claude on {100.0*agreed/(agreed+overruled):.0f}% "
              f"of the rows it judged")

    sft, dpo, tally, missing = [], [], Counter(), 0
    for rid, v in verdicts.items():
        r = rows.get(rid)
        if r is None:
            missing += 1
            continue
        meta = {"source": "harvest", "character_id": r["character_id"],
                "scene": "private", "group": r["group"], "case_code": r.get("case_code", "?")}

        if v == "good":
            tally["good"] += 1
            sft.append({"messages": r["messages"] + [
                {"role": "assistant", "content": r["candidates"][0]["text"]}], **meta})

        elif v == "picked":
            n = picks.get(rid)
            if n is None or n >= len(r["candidates"]):
                tally["picked but no candidate"] += 1
                continue
            chosen = r["candidates"][n]["text"]
            rejected = r.get("rejected_original")
            if not rejected:
                tally["picked but nothing to reject"] += 1
                continue
            if chosen.strip() == rejected.strip():
                tally["chosen equals rejected, dropped"] += 1
                continue
            tally["picked"] += 1
            dpo.append({"messages": r["messages"], "chosen": chosen, "rejected": rejected,
                        "reason": "you rejected the first reply and chose this one",
                        "chosen_source": "model", **meta})
            if not args.no_sft_from_picks:
                sft.append({"messages": r["messages"] + [
                    {"role": "assistant", "content": chosen}], **meta})

        elif v == "rewrite":
            chosen = rewrites.get(rid, "")
            rejected = r["candidates"][0]["text"]
            if not chosen.strip():
                tally["rewrite accepted but no text found"] += 1
                continue
            if chosen.strip() == rejected.strip():
                tally["rewrite identical to the reply, dropped"] += 1
                continue
            tally["accepted rewrite"] += 1
            dpo.append({"messages": r["messages"], "chosen": chosen, "rejected": rejected,
                        "reason": "you accepted Claude's suggested replacement",
                        "chosen_source": "judge", **meta})
            if not args.no_sft_from_picks:
                sft.append({"messages": r["messages"] + [
                    {"role": "assistant", "content": chosen}], **meta})

        elif v == "bad":
            tally["bad, awaiting a rerun"] += 1
        else:
            tally[v] += 1

    # --- the check worth running before writing ---------------------------
    if dpo:
        src = Counter(r.get("chosen_source", "?") for r in dpo)
        if src.get("judge"):
            j, m = src.get("judge", 0), src.get("model", 0)
            print(f"\n  chosen replies: {m} written by your own model, {j} suggested by Claude")
            if m == 0 and j > 40:
                print("    Every winner is off-policy. That is usually fine, and on an")
                print("    untuned base it often beats on-policy data outright, but keep")
                print("    the suggestions in a register your 3B can actually reach:")
                print("    short and plain, not literary. A target it cannot imitate")
                print("    teaches less than one it can.")

        shorter = sum(1 for r in dpo if len(r["chosen"]) < len(r["rejected"]))
        pct = 100.0 * shorter / len(dpo)
        if pct > 72:
            print(f"\n  ! In {pct:.0f}% of pairs the chosen reply is the shorter one.")
            print("    DPO does not know WHY you preferred it. It finds any consistent")
            print("    difference and pushes toward it, so a lopsided length signal")
            print("    teaches 'shorter is better' and you get clipped fragments.")
            print("    audit.py flags this too. Worth picking some longer winners.")

    stamp = time.strftime("%Y-%m-%d_%H%M%S")
    sft_path = OUT_DIR / f"sft_harvest_{stamp}.jsonl"
    dpo_path = OUT_DIR / f"dpo_harvest_{stamp}.jsonl"

    print("\n" + "=" * 58)
    for k, v in tally.most_common():
        print(f"  {v:5d}  {k}")
    if missing:
        print(f"  {missing:5d}  decisions with no matching harvest row (skipped)")
    print("=" * 58)
    print(f"  {len(sft):5d}  imitation examples -> {sft_path.name}")
    print(f"  {len(dpo):5d}  preference pairs   -> {dpo_path.name}")

    if args.dry_run:
        print("\n  dry run, nothing written.")
        return 0

    OUT_DIR.mkdir(exist_ok=True)
    for path, data in ((sft_path, sft), (dpo_path, dpo)):
        if not data:
            continue
        with path.open("w", encoding="utf-8") as f:
            for r in data:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    print("\n  Next:")
    print("    python Training/build_dataset.py     merge with anything you captured by playing")
    print("    python Training/audit.py             check it is worth training on")
    return 0


if __name__ == "__main__":
    sys.exit(main())
