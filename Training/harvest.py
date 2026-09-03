#!/usr/bin/env python3
"""Runs the prompt bank against Ollama, unattended, and writes every reply.

    ollama serve                                  # in another window
    python Training/harvest.py                    # pass 1, one reply each
    python Training/harvest.py --rerun decisions.json --k 3   # pass 2

Pass 1 asks all 601 questions once and writes the answers. Pass 2 takes the ones
you marked bad in the reviewer and asks each three more times, so you can pick a
better reply rather than typing one. Both write to TrainingData/.

Two design choices worth knowing about:

CONVERSATIONS, NOT ONE-SHOTS. Each character's six groups run as six accumulating
conversations rather than fifty independent questions. Real captured play reaches
3 to 37 messages deep with a median of 16; fifty separate one-shots would all be
depth 3, and a model trained on that gets good at the first question of an
interview and stays exactly as bad at the twelfth. Accumulating lands at depth 3
to 21, which is close to the real distribution and costs nothing, because the
growing prompt stays in Ollama's cache.

FRAMING IS A VERIFIED PORT. Lines go through framing.frame_player_line(), which
produces byte-identical output to GameManager.frame_player_line() across the
whole prompt bank. Skipping that would mean training on prompts shaped
differently from the ones the game actually sends.
"""

import argparse
import glob
import json
import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from framing import frame_player_line                      # noqa: E402

try:
    import requests
except ImportError:
    sys.exit("pip install requests")

OLLAMA = "http://127.0.0.1:11434/api/chat"

# Same list the game's guard uses. Kept here as an advisory flag, not a verdict:
# the reviewer shows it and you still decide.
OUT_OF_CHARACTER = [
    "as an ai", "an ai assistant", "language model", "i am an ai", "i'm an ai",
    "murder mystery game", "this game", "the game is over", "the game is now over",
    "start a new game", "play again", "would you like to start", "would you like to play",
    "previous instructions", "system prompt", "developer mode", "as the administrator",
    "the player", "well done, detective", "you have solved", "case is solved",
]

# Not in the game's guard, because a suspect refusing a detective is good drama.
# These are the shapes a MODEL refuses in, which is a different thing.
REFUSAL_TELLS = [
    "i cannot", "i can't help", "i won't be able", "i'm not able to",
    "i must decline", "not appropriate", "inappropriate", "i apologize, but",
    "i'm sorry, but i", "as a reminder", "it's important to note",
    "i don't feel comfortable", "let's keep things", "respectful",
]

MODERN_TELLS = [
    "i hear you", "that must be", "reach out", "circle back", "unpack",
    "take all the time", "at this difficult time", "thoughts are with",
    "let me be clear", "great question", "happy to help", "no worries",
]

CHARS_PER_TOKEN = 3.6


# ------------------------------------------------------------------ input ---
def load_exports(patterns):
    """Merge one or more prompts_export_*.json. Later files win per character."""
    chars, meta = {}, {}
    files = sorted(sum([glob.glob(p) for p in patterns], []))
    if not files:
        sys.exit("No export files found.\n"
                 "In game, press Ctrl+3 to write one, then run this again.\n"
                 "Eight suspects go in a house, so two games cover the roster.")
    for path in files:
        d = json.loads(Path(path).read_text(encoding="utf-8"))
        for cid, c in d.get("characters", {}).items():
            c["case_code"] = d.get("case_code", "?")
            chars[cid] = c
        meta.setdefault("stop", d.get("stop"))
        meta.setdefault("num_ctx", d.get("num_ctx", 8192))
        meta.setdefault("max_response_tokens", d.get("max_response_tokens", 140))
        meta.setdefault("model", d.get("model"))
        meta.setdefault("murderer_id", d.get("murderer_id"))
        print(f"  {Path(path).name}: {len(d.get('characters', {}))} characters, "
              f"case {d.get('case_code','?')}")
    return chars, meta


def load_prompts(path):
    """prompts.txt -> {character_id: [(group, line), ...]} in file order."""
    out, cur = {}, None
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s.startswith("### "):
            cur = s[4:].strip()
            out.setdefault(cur, [])
        elif cur and s and not s.startswith("#") and "|" in s:
            g, t = s.split("|", 1)
            out[cur].append((g.strip(), t.strip()))
    return out


# ------------------------------------------------------------------ flags ---
def flags_for(text):
    low = text.lower()
    f = []
    f += [f"broke character: {p}" for p in OUT_OF_CHARACTER if p in low]
    f += [f"refusal tell: {p}" for p in REFUSAL_TELLS if p in low]
    f += [f"modern voice: {p}" for p in MODERN_TELLS if p in low]
    toks = int(len(text) / CHARS_PER_TOKEN)
    if toks > 110:
        f.append(f"long: ~{toks} tokens")
    if text.strip() == "":
        f.append("empty")
    return f


# ------------------------------------------------------------------- call ---
def ask(model, messages, seed, meta, timeout, retries=2):
    body = {
        "model": model, "stream": False, "keep_alive": "30m", "messages": messages,
        "options": {
            "num_predict": meta.get("max_response_tokens", 140),
            "temperature": 0.8,
            "num_ctx": meta.get("num_ctx", 8192),
            "seed": seed,
        },
    }
    if meta.get("stop"):
        body["options"]["stop"] = meta["stop"]
    last = None
    for attempt in range(retries + 1):
        try:
            r = requests.post(OLLAMA, json=body, timeout=timeout)
            r.raise_for_status()
            return r.json()["message"]["content"].strip()
        except Exception as exc:                            # noqa: BLE001
            last = exc
            if attempt < retries:
                time.sleep(2 + attempt * 3)
    return f"__REQUEST_FAILED__ {last}"


# ------------------------------------------------------------------- main ---
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", nargs="+",
                    default=["TrainingData/prompts_export_*.json"])
    ap.add_argument("--prompts", default="Training/prompts.txt")
    ap.add_argument("--out", default=None, help="default: TrainingData/harvest_<stamp>.jsonl")
    ap.add_argument("--model", default=None, help="default: the model in the export")
    ap.add_argument("--k", type=int, default=1, help="replies per question")
    ap.add_argument("--only", nargs="*", help="limit to these character ids")
    ap.add_argument("--groups", nargs="*", help="limit to these groups")
    ap.add_argument("--rerun", help="decisions.json from the reviewer: redo only the bad ones")
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--seed", type=int, default=3407)
    args = ap.parse_args()

    print("Loading exports")
    chars, meta = load_exports(args.export)
    prompts = load_prompts(args.prompts)
    model = args.model or meta.get("model")
    if not model:
        sys.exit("No model in the export and none given. Pass --model.")

    rng = random.Random(args.seed)
    stamp = time.strftime("%Y-%m-%d_%H%M%S")
    out_path = Path(args.out or f"TrainingData/harvest_{stamp}.jsonl")
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Resume: anything already written is skipped, so a Ctrl+C costs nothing.
    # The reply that was written is kept, because skipping a question without
    # putting its answer back into the conversation would silently change the
    # history every later question in that group is asked with.
    done = {}
    if out_path.exists():
        for l in out_path.open(encoding="utf-8"):
            if l.strip():
                r = json.loads(l)
                done[r["id"]] = r["candidates"][0]["text"]
        print(f"  resuming, {len(done)} rows already present")

    todo = [c for c in prompts if c in chars]
    missing = [c for c in prompts if c not in chars]
    if args.only:
        todo = [c for c in todo if c in args.only]
    print(f"\n{len(todo)} characters ready" +
          (f", {len(missing)} still need an export ({', '.join(missing)})" if missing else ""))
    if not todo and not args.rerun:
        sys.exit("Nothing to run. Press Ctrl+3 in game to export the characters you want.")

    total = sum(1 for c in todo for g, _ in prompts[c]
                if not args.groups or g in args.groups)
    if not args.rerun:
        print(f"{total} questions, k={args.k}  ->  {total * args.k} replies\n")

    fh = out_path.open("a", encoding="utf-8")
    n = failures = 0
    t0 = time.time()

    # ---------------------------------------------------------- rerun mode --
    # Re-sampling questions you marked bad. The original harvest row already
    # stores the exact messages that produced the bad reply, so there is no
    # conversation to rebuild: read it back and ask again. That also means a
    # rerun is faithful even to a history the reviewer never saw.
    if args.rerun:
        d = json.loads(Path(args.rerun).read_text(encoding="utf-8"))
        bad = {k for k, v in d.get("verdicts", {}).items() if v == "bad"}
        src = Path(d.get("source", ""))
        if not src.exists():
            src_guess = sorted(Path("TrainingData").glob("harvest_*.jsonl"))
            if not src_guess:
                sys.exit("Cannot find the harvest file the decisions came from.")
            src = src_guess[-1]
        rows = [json.loads(l) for l in src.open(encoding="utf-8") if l.strip()]
        rows = [r for r in rows if r["id"] in bad and r["id"] not in done]
        print(f"  rerun: {len(rows)} questions from {src.name}, k={args.k}\n")

        for i, r in enumerate(rows, 1):
            cands = []
            for _ in range(args.k):
                seed = rng.randrange(1, 2**31)
                txt = ask(model, r["messages"], seed, meta, args.timeout)
                if txt.startswith("__REQUEST_FAILED__"):
                    failures += 1
                cands.append({"text": txt, "seed": seed, "flags": flags_for(txt)})
            out = dict(r)
            out["candidates"] = cands
            out["rejected_original"] = r["candidates"][0]["text"]
            out["rerun_of"] = src.name
            fh.write(json.dumps(out, ensure_ascii=False) + "\n")
            fh.flush()
            n += 1
            if n % 10 == 0 or n == len(rows):
                el = time.time() - t0
                print(f"  [{n:4d}/{len(rows)}] {r['character_id']:14} {r['group']:9} "
                      f"{el/60:5.1f} min elapsed, ~{(len(rows)-n)*(el/n)/60:4.1f} left")
        total = len(rows)

    # ------------------------------------------------------------ pass one --
    else:
        for cid in todo:
            info = chars[cid]
            by_group = {}
            for g, line in prompts[cid]:
                if args.groups and g not in args.groups:
                    continue
                by_group.setdefault(g, []).append(line)

            for group, lines in by_group.items():
                # One accumulating conversation per group. This is the whole
                # point: question 8 is asked with questions 1 to 7 still in the
                # history.
                messages = [{"role": "system", "content": info["system"]}]
                for idx, line in enumerate(lines):
                    rid = f"{cid}/{group}/{idx}"
                    framed = frame_player_line(line)
                    messages.append({"role": "user", "content": framed})

                    if rid in done:
                        messages.append({"role": "assistant", "content": done[rid]})
                        continue

                    cands = []
                    for _ in range(args.k):
                        seed = rng.randrange(1, 2**31)
                        txt = ask(model, messages, seed, meta, args.timeout)
                        if txt.startswith("__REQUEST_FAILED__"):
                            failures += 1
                        cands.append({"text": txt, "seed": seed, "flags": flags_for(txt)})

                    fh.write(json.dumps({
                        "id": rid,
                        "character_id": cid,
                        "character": info.get("short", cid),
                        "case_code": info.get("case_code", "?"),
                        "group": group,
                        "question": line,
                        "framed": framed,
                        "depth": len(messages),
                        "messages": messages.copy(),
                        "candidates": cands,
                        "model": model,
                    }, ensure_ascii=False) + "\n")
                    fh.flush()

                    messages.append({"role": "assistant", "content": cands[0]["text"]})
                    n += 1
                    if n % 10 == 0 or n == total:
                        el = time.time() - t0
                        print(f"  [{n:4d}/{total}] {cid:14} {group:9} "
                              f"{el/60:5.1f} min elapsed, ~{(total-n)*(el/n)/60:4.1f} left")

    fh.close()
    el = time.time() - t0
    print(f"\nwrote {out_path}")
    print(f"{n} questions, {n * args.k} replies, {el/60:.1f} min"
          + (f", {failures} request failures" if failures else ""))
    print(f"\nNext: open Training/review.html in your browser and drag {out_path.name} into it.")


if __name__ == "__main__":
    main()
