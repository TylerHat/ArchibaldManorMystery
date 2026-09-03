#!/usr/bin/env python3
"""Strips a harvest down to what a judge needs, in batches small enough to read.

    python Training/make_judge_packet.py
    python Training/make_judge_packet.py --batch 60 --out JudgePackets

Produces JudgePackets/packet_001.json ... each holding the character brief, the
question, the reply, the previous exchange for context, and the mechanical flags.
Full system prompts are stripped out: they are two thousand tokens each, identical
across a character, and the judge already gets the brief they were built from.

Then ask Claude to judge a packet. It writes JudgePackets/verdicts_001.json, and
apply_judge.py merges those back onto the harvest rows.
"""

import argparse
import re
import glob
import json
import sys
from pathlib import Path


def load_briefs(path):
    """prompts.txt -> {character_id: {"who","trait","fail","secret"}}"""
    briefs, cur, key = {}, None, None
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s.startswith("### "):
            cur = s[4:].strip()
            briefs[cur] = {"who": "", "trait": "", "fail": "", "secret": ""}
            key = "who"
            continue
        if cur is None or not s.startswith("#"):
            continue
        t = s.lstrip("#").strip()
        low = t.upper()
        if low.startswith("TRAIT:"):
            key, t = "trait", t.split(":", 1)[1].strip()
        elif low.startswith("FAIL:"):
            key, t = "fail", t.split(":", 1)[1].strip()
        elif low.startswith("SECRET:"):
            key, t = "secret", t.split(":", 1)[1].strip()
        if key and t:
            briefs[cur][key] = (briefs[cur][key] + " " + t).strip()
    return briefs


def case_facts(row):
    """The character's real room and movement list, read off this row's own system prompt.

    prompts.txt carries a room in its `who` line ("found in the Ballroom"), but
    that file is static and CaseGenerator randomises rooms every game: ten of the
    twelve briefs named the wrong room for the case actually harvested. A judge
    told the wrong room marks correct answers as location drift and, worse, may
    write a replacement that relocates the character. The system prompt the reply
    was actually generated from is the only authority, so read it from there.
    """
    m = row.get("messages", [])
    if not m or m[0].get("role") != "system":
        return "", []
    sysp = m[0]["content"]
    room = ""
    mo = re.search(r"You are currently in the ([^.\n]+)\.", sysp)
    if mo:
        room = mo.group(1).strip()
    moves, grab = [], False
    for ln in sysp.splitlines():
        t = ln.strip()
        if t.startswith("YOUR OWN MOVEMENTS"):
            grab = True
            continue
        if grab:
            if re.match(r"- \d", t):
                moves.append(t[2:])
            elif t.startswith("Those are the only"):
                break
    return room, moves


def prev_exchange(row):
    """The question and answer immediately before this one, for contradiction checks."""
    m = row.get("messages", [])
    q = a = ""
    for i in range(len(m) - 2, 0, -1):
        if m[i].get("role") == "assistant":
            a = m[i]["content"]
            if i > 0 and m[i - 1].get("role") == "user":
                q = m[i - 1]["content"]
            break
    return q[:200], a[:300]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--harvest", nargs="*", default=None)
    ap.add_argument("--prompts", default="Training/prompts.txt")
    ap.add_argument("--out", default="JudgePackets")
    ap.add_argument("--batch", type=int, default=60)
    ap.add_argument("--skip-judged", action="store_true",
                    help="leave out rows that already carry a recommendation")
    ap.add_argument("--only", nargs="*", default=None,
                    help="only these character ids")
    ap.add_argument("--per-character", action="store_true",
                    help="one packet per character instead of fixed-size batches, so a "
                         "judge reads fifty replies in a single consistent voice rather "
                         "than crossing a character boundary mid-packet")
    args = ap.parse_args()

    paths = args.harvest or sorted(glob.glob("TrainingData/harvest_*.jsonl"))
    if not paths:
        sys.exit("No harvest files. Run harvest.py first.")

    briefs = load_briefs(args.prompts)
    rows = []
    for p in paths:
        for l in Path(p).open(encoding="utf-8"):
            if not l.strip():
                continue
            r = json.loads(l)
            if args.skip_judged and r.get("recommendation"):
                continue
            if args.only and r["character_id"] not in args.only:
                continue
            rows.append((p, r))
    print(f"{len(rows)} rows from {len(paths)} file(s)")

    out_dir = Path(args.out)
    out_dir.mkdir(exist_ok=True)
    for stale in out_dir.glob("packet_*.json"):
        # OneDrive and some mounted folders refuse deletes. Overwriting the ones
        # we are about to write is enough; a leftover packet from a longer run
        # would be stale, so say so rather than failing the whole build.
        try:
            stale.unlink()
        except OSError:
            print(f"  ! could not remove {stale.name}; overwriting what we can")

    if args.per_character:
        order, groups = [], {}
        for src, r in rows:
            cid = r["character_id"]
            if cid not in groups:
                groups[cid] = []
                order.append(cid)
            groups[cid].append((src, r))
        chunks = [groups[c] for c in order]
    else:
        chunks = [rows[i:i + args.batch] for i in range(0, len(rows), args.batch)]

    n = 0
    for chunk in chunks:
        n += 1
        items = []
        for src, r in chunk:
            b = briefs.get(r["character_id"], {})
            pq, pa = prev_exchange(r)
            room, moves = case_facts(r)
            who = b.get("who", "")
            if room:
                # Overwrite the stale "found in the X" the brief carries.
                who = re.sub(r",?\s*found in the [^.,]+", "", who).rstrip(" .,")
                who = f"{who}, currently in the {room}"
            item = {
                "id": r["id"],
                "character": r.get("character", r["character_id"]),
                "who": who,
                "trait_to_protect": b.get("trait", ""),
                "what_failure_looks_like": b.get("fail", ""),
                "their_secret": b.get("secret", ""),
                "group": r["group"],
                "question": r["question"],
                "reply": r["candidates"][0]["text"],
                "auto_flags": r["candidates"][0]["flags"],
                "source_file": Path(src).name,
            }
            if moves:
                item["their_movements_last_night"] = moves
            if pa:
                item["previous_exchange"] = {"question": pq, "reply": pa}
            items.append(item)
        p = out_dir / f"packet_{n:03d}.json"
        p.write_text(json.dumps(items, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"  {p}  {len(items)} rows  {p.stat().st_size:,} bytes")

    print(f"\n{n} packet(s) in {out_dir}/")
    print("Ask Claude to judge them. Then: python Training/apply_judge.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
