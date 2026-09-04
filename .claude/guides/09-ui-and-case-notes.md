# UI and case notes

Every panel in the game, where its code lives, and why none of it was built in
the Godot editor.

---

## 1. Why the UI is written, not drawn

Most Godot projects lay out UI by dragging controls around in the editor. This
project builds every panel in code, in `Main.gd`, in a `_build_*_panel()`
function per panel.

It is more typing. It is deliberate:

- **The whole game reviews as a text diff.** A UI change shows up in a pull
  request as readable lines, rather than as a re-serialized `.tscn` that nobody
  can read and everybody conflicts on.
- **Panels are built from data that only exists at runtime.** The notes panel
  has one tab per suspect *in this game*, colored to match that suspect, with a
  flag dot that appears only when their Slipups section has real content. Every
  one of those depends on the cast, which is chosen on the selection screen.
- **There is no editor state to get out of sync** with what the code expects.

The cost is that you cannot see a panel until you press Play. Accept it; the
alternative was worse for this project.

---

## 2. The panels

All fields on `Main`, all built in `_build_ui()` or from `_start_game()`.

| Panel | Built by | Opened by |
|---|---|---|
| Suspect selection | `_build_selection_screen()` | automatically, before the game |
| Dialogue (one on one) | `_build_dialogue_panel()` | E on a suspect |
| Group (Hall meetup) | `_build_group_panel()` | E in the Hall with attendees |
| Case notes | `_build_notes_panel()` | Tab |
| Map | `_build_map_panel()` | M |
| Examine | `_build_examine_panel()` | E on evidence |
| Accusation | `_build_accusation_panel()` | E on the front door |
| Win | `_build_win_panel()` | a correct accusation |
| Debug overlay | `_refresh_debug_label()` | Ctrl+1 |

Everything lives on `ui_layer`, a `CanvasLayer`, which draws on top of the 3D
world and ignores the camera entirely.

`Esc` closes them in a fixed priority order: dialogue, group, accusation,
examine, map, notes. Tab and M refuse to open while any other panel is up.

---

## 3. The suspect-selection screen

The first thing you see. It is not a menu bolted on the front; it is where the
game is configured.

- Twelve checkboxes, one per suspect in `GameManager.CHARACTERS`.
- Opens on a random legal cast of eight, so a fresh launch is already a fresh
  mystery.
- **Random N** buttons for a quick reroll.
- A **case code** box. Type `482913-171` and it re-ticks the cast for you and
  replays that exact mystery. `_on_seed_input_changed()` validates as you type
  and `selection_seed_status` tells you what it made of it.
- A **dialogue log** checkbox. This one checkbox also turns on training
  capture, deliberately: the sessions worth capturing are exactly the sessions
  worth logging, and one switch is one thing to forget rather than two.

`_update_selection_count()` enforces 2 to `MAX_ACTIVE_SUSPECTS` and disables
Start outside that range.

---

## 4. The dialogue panel

The one-on-one interview.

- `dialogue_log` is a `RichTextLabel` with BBCode on, so names are colored and
  actions are italic.
- `dialogue_input` is a `TextEdit`, not a `LineEdit`, so it can wrap. It opens
  one row high and grows a row at a time as you type, up to `INPUT_MAX_ROWS`
  (3), then scrolls. `_fit_input_height()` does that.
- Enter submits, Shift+Enter makes a new line. `_input_box_submitted()`.
- `dialogue_status_label` shows thinking and error states.
- `DIALOGUE_FONT_SIZE` is 40. Godot's default control font is 16, so this is
  that bumped substantially for readability. **The panel dimensions and the log
  and input minimum sizes were grown to match, so retune those alongside it if
  you change it.**

Two text transforms run on everything that gets printed:

- `_colorize_names()` paints every suspect's name to match their capsule color,
  using per-character compiled regular expressions built by
  `_build_name_regexes()`. It handles honorifics (`Lord`, `Dr`, `Mrs`, ...) and
  every name variant: full name, short name, first name.
- `_italicize_actions()` renders bracketed actions in italics so they read
  differently from speech.

---

## 5. The group panel

The Hall meetup. Same shape as the dialogue panel, plus a roster.

`group_roster` is an `HBoxContainer` of one entry per attendee, each with a
**Silence / Let speak** button. Those do the same thing as typing "Marcus, be
quiet", and both routes end up in `GroupChat.set_muted()`.

`_set_group_frozen()` holds attendees still while the scene is open, so nobody
wanders off mid-sentence. `group_frozen_ids` remembers who to release.

The panel listens to five `GroupChat` signals:

| Signal | `Main` handler | Effect |
|---|---|---|
| `line_added` | `_on_group_line_added` | append to the log |
| `turn_started` | `_on_group_turn_started` | highlight whose turn it is |
| `state_changed` | `_on_group_state_changed` | enable or disable input |
| `roster_changed` | `_on_group_roster_changed` | rebuild the roster row |
| `quorum_lost` | `_on_group_quorum_lost` | close the scene when too few remain |

---

## 6. The case notes

Tab. The most involved panel in the game.

### Tabs

One down the left side per suspect, plus **The Scene** at the top
(`EVIDENCE_TAB`, the constant `"__evidence__"`).

Each suspect tab is:

- colored to match their capsule
- **dimmed** if you have not talked to them yet
- marked with a small **red dot** if their Slipups section has real content,
  so you can tell at a glance who is worth pressing further without opening
  every tab. `_has_slipup_flag()` decides.

### The four sections

Generated by the AI from that suspect's transcript, parsed by
`_parse_summary_sections()`:

| Section | Contains |
|---|---|
| **Timeline** | their claimed whereabouts around the time of the murder |
| **Potential Reason to Kill** | motive: grudges, money, secrets, relationships |
| **Slipups** | anything suspicious, evasive, defensive or inconsistent |
| **Contradictions** | where their account conflicts with what somebody said in front of them in the Hall, or where their public story differs from what they told you privately |

### The Scene tab

Unlike the suspect tabs, **it is not AI-summarized**. It is what you saw
yourself, word for word, from `GameManager.evidence_found`. That is the point:
you can trust it against anything you are told.

### Timeline rendering

`_append_timeline_table()` and `_parse_timeline_rows()` try to render the
Timeline section as an actual table rather than prose, which means parsing
times out of model output. That is as fragile as it sounds, so it is defensive:

- `TIMELINE_EARLIEST_MIN` / `TIMELINE_LATEST_MIN` bound what counts as a
  plausible time (18:00 to 01:00)
- `TIMELINE_REJECT` drops rows that mention "detective", "overheard" or "the
  player", which are the model summarising the wrong thing
- `TIMELINE_NO_CLAIM` and `TIMELINE_UNKNOWN` are the placeholders when a row
  parses but says nothing

If parsing fails, it falls back to showing the prose.

### Laziness, and the fallback

Summaries are generated **per tab, on demand**. Clicking a suspect's tab only
asks Ollama for a summary if you have talked to them since the last one, which
`_summarized_at[id]` tracks. Browsing your notes therefore does not slow down
normal questioning.

`_pending_summaries` prevents a second request for a tab already waiting.

**If a summary fails, the tab shows that suspect's raw questions and answers
rather than nothing.** Never leave a panel empty on failure; this is the
pattern to copy.

---

## 7. The map

M. A 3 by 3 grid of `PanelContainer` cells, one per room.

- your current room is highlighted
- each cell lists who is in it, colored per suspect
- refreshed on a `Timer` (`map_refresh_timer`) rather than every frame

`_map_base_color()` tints a cell from `ROOM_COLORS`, and `_murder_room_name()`
marks the scene once you know where it is.

---

## 8. Examine and accusation

**Examine** is opened by `Evidence.interact()` through the `main_controller`
group. It shows a title and body, and calls `GameManager.note_evidence()`,
which deduplicates by id so walking back over the body does not fill your notes
with copies.

**Accusation** is opened by `Door.interact()`. It is a grid of suspect buttons
rather than a text field, so a typo cannot cost you a case.
`_select_accusation_suspect()` tracks the choice and `_submit_accusation()`
calls `GameManager.check_accusation()`. A wrong guess just lets you keep
investigating. The right one opens the win panel with the murderer's motive.

---

## 9. The debug overlay

Ctrl+1. `debug_label`, refreshed by `_refresh_debug_label()`.

Shows the murderer, the weapon and its home room, the lie being told, who can
disprove it, and every suspect's real movements slot by slot. Rooms are
abbreviated to two letters and `[]` marks the murder.

`_debug_path(path, mark_slot)` does the formatting. This is the single most
useful debugging tool in the project, because almost every check is "does what
the game just said match this".

It lives behind `GameManager.DEBUG_KEYS`, so with that constant false the key is
never registered and the overlay cannot be summoned at all.

---

## 10. Adding a panel

1. Add the field: `var thing_panel: Panel`.
2. Write `_build_thing_panel()` next to the existing ones and call it from
   `_build_ui()`. **Copy the shape of the nearest existing one** rather than
   inventing a new layout approach.
3. Write `open_thing()` and `close_thing()`.
4. Add it to the `Esc` chain in `_unhandled_input()`, in the right priority
   position.
5. Add it to the guard conditions on Tab and M, so it cannot open on top of
   another panel.
6. If it shows text with names in it, run that text through `_colorize_names()`.
7. If it shows anything generated by the AI, **give it a fallback for failure**.

Scaling: `_scale_rich_text_font()` exists so text sizes stay consistent. Use
it rather than setting font sizes by hand.
