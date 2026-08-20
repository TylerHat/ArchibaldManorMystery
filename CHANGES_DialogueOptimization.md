# What changed — dialogue memory optimization

Applied in the recommended order. Every change is in `GameManager.gd`,
`GroupChat.gd` or `Main.gd`, plus one new test scene.

Verified with a headless Godot parse of all 11 scripts and a 23-check
regression run (`Scenes/DialogueOptTest.tscn`, F6). All pass.

---

## 0. The Ollama restart loop — `Fix_Ollama.ps1`

**Root cause, from `app.log`:** two Ollama app instances. The second one's
single-instance check failed with `"failed to send focus message to existing
instance" error="Access is denied."` — which is what Windows returns when one
process is elevated and the other isn't. Believing it was alone, instance #2
started its own server; that server couldn't bind port 11434, exited, and the
tray app respawned it.

**15,532 restarts at a steady 1.1-second interval over 27 hours.** Still running
when I looked.

The script stops everything, sets the environment variables below, and starts a
single instance. It refuses to run elevated, since that's the cause.

Your app.log also shows 0.32.11 and 0.32.12 downloaded but never installed —
probably blocked by the two instances fighting. You're on 0.32.9.

## 1. Ollama environment (set by the script)

```
OLLAMA_NUM_PARALLEL    = 4      four KV-cache slots instead of one
OLLAMA_FLASH_ATTENTION = 1      required for q8_0 below
OLLAMA_KV_CACHE_TYPE   = q8_0   halves cache memory so 4 slots fit in ~5 GB
OLLAMA_KEEP_ALIVE      = -1     never unload (cold reload measured at 60 s)
```

---

## 5. Trivial latency fixes — `GameManager.gd`

| Change | Was | Now |
|---|---|---|
| `MAX_RESPONSE_TOKENS` | 300 | **140** |
| `GROUP_MAX_TOKENS` | 90 | **70** |
| `STOP_SEQUENCES` | none | `\n\n`, `Detective:`, … |
| `keep_alive` in request body | absent | **`"30m"`** |

Measured replies ran 13–154 tokens, so 300 was only reachable by a model that
had started rambling — and at 29 ms/token, letting it finish cost 8.8 seconds.

Stop sequences are **not** applied to summary requests: a summary is a
four-section document and a blank line between sections is plausible output, so
`\n\n` would truncate it after `##TIMELINE##`. Correctness beats the second it
would save there.

---

## 2. Shared system-prompt prefix — `GameManager.gd`

`_build_system_prompt()` split into `_shared_case_preamble()` +
`_build_character_tail()`.

The preamble is now **byte-identical for all eight suspects** — verified at
**3,522 characters (~978 tokens)** by the test. It was diverging at roughly
token 6, because the old opening line was `"You are role-playing as <name>…"`.

The one substantive edit: the cast list used to read `- You.` followed by the
others, which made it unique per character. It now names all eight uniformly,
and the tail opens with `WHO YOU ARE:` plus an explicit *"You are X and nobody
else"*. The completeness guarantee the block exists for is unchanged.

The preamble is built once per game and cached in `_cached_preamble` (cleared in
`start_new_game()`, since it bakes in the murder room and cast).

Same treatment applied to `request_summary()`'s prompt — format spec first,
suspect name last, right before the transcript it describes.

**The schedule block is still last.** Your comment about a 3B model weighting
the end of context most heavily is correct and nothing moved past it.

---

## 3. Ephemeral group-scene memory — `GroupChat.gd` (the structural one)

**Before:** every line spoken in the Hall was written permanently into every
other attendee's `_histories` via `note_to_character()`. Storage was O(N²) per
round, it landed in the *middle* of each history where compaction can't reach it,
and repeat meetups stacked priming blocks and scene-enders forever.

**Now:** the room is rendered from `scene_log` on demand, per turn, and never
stored. What survives a scene is **one digest per attendee**.

| Removed | Replaced by |
|---|---|
| `_heard_buffer`, `_broadcast()`, `_flush_heard()` | `_render_scene_for()` reading `scene_log` |
| `_prime_attendees()` (permanent write) | `_group_role_instruction()` (rendered per turn) |
| `_own_recent_lines()` | `YOU:` lines inside the scene render |
| per-line `_histories` append in `_on_request_completed` | the scene-end digest |

Three details worth knowing:

**Compact tags.** Lines are tagged `DETECTIVE:` / `GUEST <name>:` / `YOU:`, with
the convention explained once in the block header. The long form
(`"(another guest in the room - NOT the detective) said out loud:"`) cost ~14
tokens of framing *per line*, re-read on every attendee's turn.

**The transcript stops before the current round.** `_round_log_start` marks where
the detective's latest line begins; everything from there is presented at the end
of the prompt where it has to be. Without this, every turn sent the current round
twice.

**Departures are honoured.** `_left_at[id]` freezes what a dismissed suspect
heard at the moment they walked out, so they don't remember being talked about
after leaving.

Group replies are also no longer appended to `_histories`. Besides duplicating
the digest, they landed as `assistant` messages with no `user` message before
them (the turn prompt is ephemeral), leaving orphaned assistant turns. The
`transcript` still gets them — that's the detective's record, and it feeds the
case notes and dialogue log.

**`MAX_HALL_ATTENDEES` raised 2 → 4** in `Main.gd`.

---

## 4. History compaction — `GameManager.gd`

The runner reports `n_keep = 4`. When a history outgrew 8,192 tokens, Ollama
truncated from the front and took the system prompt with it — including
`YOUR OWN MOVEMENTS LAST NIGHT`, which every alibi answer is read off. No error;
suspects would just start improvising again.

```gdscript
const HISTORY_TOKEN_BUDGET := 4500
const HISTORY_KEEP_RECENT  := 8
const CHARS_PER_TOKEN      := 3.6
```

`_compact_history_if_needed()` folds everything older than the last 8 messages
into one `[EARLIER IN THIS INVESTIGATION…]` block containing their own condensed
answers. Message 0 is never touched.

Called at the *top* of `ask_character()` and `ask_group_member()` — before the
request is built, so no over-budget prompt ever reaches Ollama — and after
`note_to_character()`.

Compaction is deliberately chunky (122 messages → 10 in the test). Rewriting any
part of a history invalidates that character's cached prefix, so this trades one
slow turn occasionally against a slightly slow turn every time.

---

## The new test — `Scenes/DialogueOptTest.tscn`

Press **F6**. No network calls, runs in about a second, doesn't need Ollama.
Follows the same pattern as your `CaseGeneratorTest.tscn`.

23 checks across six areas. The one worth keeping is #1: put a
character-specific detail into `_shared_case_preamble()` and it fails
immediately. That failure is otherwise completely invisible — it just quietly
makes every Hall meetup slower again.

---

## Honest revision to my earlier estimate

**My report projected ~3.1 s per line at 4 attendees. That was too optimistic
and I should correct it.**

I assumed the whole prompt would be cached. It isn't: the *turn prompt* is
rebuilt every turn by design, so it's re-read every time. Measured at **~1,008
tokens**, that's ~0.85 s of prefill per turn that no amount of cache slots
removes.

Realistic per-turn cost with everything above in place:

| | |
|---|---|
| System prompt + history | cached — **~0 ms** |
| Turn prompt (~1,000 tokens) | **~0.85 s** |
| Generation (~35 tokens @ 34/s) | **~1.0 s** |
| **Per turn** | **~1.85 s** |
| **Per line, 4 attendees** | **~7.4 s** |

Against ~10.1 s before, that's about **1.4×** — not the 3× I claimed.

**What genuinely improved beyond the raw number:**

- **It's flat now.** Before, cost grew every round (10.1 s at round 5, 12.4 s at
  round 10) because histories grew. Now a round-10 meetup costs the same as a
  round-2 one.
- Two-attendee meetups: ~4.2 s → **~3.7 s**.
- Repeat meetups no longer accumulate anything.
- The silent-truncation correctness bug is gone.

**The remaining lever is Fix #7 (parallel first round), and it's the big one.**
The 7.4 s is four × 1.85 s *in sequence*. With `NUM_PARALLEL=4` your GPU can
serve them simultaneously, which makes a round cost `max` rather than `sum` —
about **2 s instead of 7.4 s**. That needs multiple `HTTPRequest` nodes and a
change to what a round means (everyone reacts to you, then a sequential rebuild
round for whoever contradicts someone).

I did not do it unprompted because it changes the drama, not just the speed.

**One optimization I considered and deliberately rejected:** moving the turn
prompt's static instruction block (~400 tokens) into each attendee's history at
scene start so it caches. It would save ~1.4 s per line. But your comments
document being burned by exactly this — instructions drifting away from the
generation point and stopping being obeyed — and I can't verify compliance
without running the model against real play. Worth trying, worth measuring,
not worth me doing silently.

---

## What to do next

1. Run **`Fix_Ollama.ps1`** (right-click → Run with PowerShell, **not** as admin).
2. Open the project, press **F6** on `Scenes/DialogueOptTest.tscn` — expect 23 passes.
3. Play a Hall meetup with 3–4 suspects.
4. Check the slots took effect:
   ```powershell
   Select-String -Path "$env:LOCALAPPDATA\Ollama\server.log" -Pattern "n_slots|n_ctx_slot" | Select -First 3
   ```
   You want `n_slots = 4`. If `n_ctx_slot` reads 2048 rather than 8192, Ollama
   divided the context instead of multiplying it — set `NUM_PARALLEL=3` and
   re-run the script.
5. Confirm the loop is dead — `"ollama exited"` in `app.log` should stay at 0.
