#!/usr/bin/env python3
"""Scores a dialogue export against the ground truth it already carries.

    python Training/check_dialogue_log.py DialogueLogs/dialogue_2026-09-03_140417.md
    python Training/check_dialogue_log.py --all
    python Training/check_dialogue_log.py <log> --out report.md --strict

Every log DialogueLog.gd writes contains the case's ground truth, the movement
grid, and the exact account each suspect was given. That is everything needed to
check the transcript mechanically, so the audit that took an afternoon by hand
becomes a number you can watch across builds.

Two kinds of finding come out of this:

  * per-reply defects  - a room the suspect was never in, a time outside the
    evening, an invented person, a weapon that is not in this case, last night
    described as this morning, a reply that blows the length rule.
  * case-level failures - the murderer never stated their cover story, no
    witness ever contradicted it, the expert never gave a time of death. These
    are the ones that decide whether the case was winnable at all, and they are
    invisible when you read a transcript looking for hallucinations.

--strict exits 1 when the case was not solvable from the transcript, so this can
gate a build.
"""

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

# The nine rooms, from CaseGenerator.GRID. Kept in the same reading order so a
# report lists them predictably.
ROOMS = [
    "Kitchen", "Ballroom", "Conservatory",
    "Lounge", "Dining Room", "Study",
    "Billiard Room", "Hall", "Library",
]

# 8:00pm to midnight, in minutes past 8pm, matching CaseGenerator's eight slots.
EVENING_START_MIN = 8 * 60
EVENING_END_MIN = 24 * 60

NUMBER_WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
}

# Weapon nouns a suspect might reach for. Anything here that is not part of this
# case's weapon is an invention: the gun in the 2026-09-03 log is the example
# that started this file.
WEAPON_WORDS = [
    "gun", "pistol", "revolver", "rifle", "firearm", "shotgun", "bullet", "shot",
    "knife", "blade", "dagger", "letter opener", "poison", "poisoned", "arsenic",
    "rope", "cord", "wire", "candlestick", "poker", "hammer", "axe", "cane",
    "statue", "bookend", "scissors", "sword", "syringe",
]

# People who do not exist. The prompt already says the cast list is complete, so
# any of these is a person invented to fill a gap, and every one of them becomes
# a witness or an alibi the moment it is said out loud.
INVENTED_PEOPLE = [
    "housekeeper", "maid", "footman", "valet", "cook", "servant", "butler",
    "groundskeeper", "stable", "coachman", "villager", "constable", "sergeant",
    "her father", "his father", "my father", "her mother", "his mother",
    "her husband", "his wife", "her wife", "his husband",
    "her brother", "his brother", "her sister", "his sister",
    "my niece", "my nephew", "her son", "his son", "her daughter", "his daughter",
]

# Claiming somebody else is standing here. Interviews are one to one, and a
# suspect who puts another guest in the room has invented a witness to the
# conversation the player is currently having.
PRESENCE_CLAIMS = [
    "at your back", "behind you", "standing there", "over your shoulder",
    "in this room with us", "sitting right there", "just there beside",
]

# Last night described as this morning. The prompt says plainly that it is the
# morning after and the schedule block is headed LAST NIGHT, so this is the
# model losing the frame, not a missing rule.
MORNING_FRAMING = [
    "this morning i was", "this morning, i was", "since breakfast",
    "before breakfast", "at breakfast this morning", "a morning in the",
    "the morning's observations", "this morning in the",
]

# A second body, a second death. There is one victim.
INVENTED_EVENTS = [
    "both are dead", "both of them are dead", "another body", "second body",
    "the other body", "also died", "also dead",
]

STAGE_RE = re.compile(r"\(([^)]*)\)")
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+")
ABBREV_RE = re.compile(
    r"\b(?:Mr|Mrs|Ms|Dr|St|Lt|Sgt|Capt|Rev|Prof|Jr|Sr|Hon|Col|Maj)\.", re.I)
CLOCK_RE = re.compile(r"\b(\d{1,2}):(\d{2})\b")
WORD_TIME_RE = re.compile(
    r"\b(?:(half past|quarter past|quarter to|a quarter past|a quarter to)\s+)?"
    r"(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b"
    r"(?:\s+o'?clock)?",
    re.I,
)
TIME_CONTEXT_RE = re.compile(
    r"\b(at|from|until|till|to|by|about|around|past|since|after|before)\s+$", re.I
)


# --------------------------------------------------------------- time words --

def _minutes(hour, minute):
    """Clock time to minutes, read as an evening. 8 to 11 stay in the evening,
    12 is midnight, and 1 to 7 are left where they are so they fall outside the
    window and get flagged."""
    if hour == 12:
        hour = 24
    return hour * 60 + minute


def parse_times(text):
    """Every clock time in a string, as (label, minutes).

    Catches both '10:30' and 'half past eight'. Bare number words only count
    when a preposition puts them in a time position, so 'the two of us' and
    'one of them' do not become nine o'clock.

    Returns (label, minutes, position). The position matters: a time has to be
    matched to the room it sits beside, and re-finding a label by text puts
    'eleven' inside an earlier 'half past eleven'."""
    out = []
    for m in CLOCK_RE.finditer(text):
        hour, minute = int(m.group(1)), int(m.group(2))
        if hour <= 12 and minute < 60:
            out.append((m.group(0), _minutes(hour, minute), m.start()))

    for m in WORD_TIME_RE.finditer(text):
        qualifier = (m.group(1) or "").lower()
        hour = NUMBER_WORDS[m.group(2).lower()]
        before = text[: m.start()]
        # A bare "eight" needs a preposition in front of it to be a time. A
        # qualified one ("half past eight") is unambiguous on its own.
        if not qualifier and not TIME_CONTEXT_RE.search(before):
            continue
        minute = 0
        if "half past" in qualifier:
            minute = 30
        elif "quarter past" in qualifier:
            minute = 15
        elif "quarter to" in qualifier:
            minute = 45
            hour -= 1
            if hour == 0:
                hour = 12
        out.append((m.group(0), _minutes(hour, minute), m.start()))

    for m in re.finditer(r"\bmidnight\b", text, re.I):
        out.append(("midnight", 24 * 60, m.start()))
    return sorted(out, key=lambda t: t[2])


def in_evening(minutes):
    return EVENING_START_MIN <= minutes <= EVENING_END_MIN


# ------------------------------------------------------------------ parsing --

class Case:
    """Everything the log's own header states about the case."""

    def __init__(self):
        self.path = ""
        self.model = ""
        self.code = ""
        self.victim = ""
        self.murder_room = ""
        self.murderer_full = ""
        self.weapon = ""
        self.suspects = []          # full names, in play order
        self.claimed_room = ""      # the room the murderer lies about
        self.lie_from = None        # minutes
        self.lie_to = None
        self.true_room = ""         # where they really were
        self.witnesses = []         # short names, from "Disproved by"
        self.accounts = {}          # full name -> [block dicts]
        self.grid = {}              # short name -> {slot minutes -> room}
        self.short_of = {}          # full name -> short name
        self.full_of = {}           # short name -> full name


def _strip_md(text):
    return text.replace("**", "").replace("_", "").strip()


def parse_header(text, case):
    def grab(label):
        m = re.search(r"^- \*\*%s:?\*\*:?\s*(.+)$" % re.escape(label), text, re.M)
        return m.group(1).strip() if m else ""

    case.model = grab("Model").strip("`")
    case.murderer_full = grab("Murderer (ground truth)")
    case.suspects = [s.strip() for s in grab("Suspects in play").split(",") if s.strip()]

    m = re.search(r"^- \*\*Case code:\*\*\s*`([^`]+)`", text, re.M)
    if m:
        case.code = m.group(1)

    victim = grab("Victim")
    m = re.search(r"^(.*?),\s+in (?:the )?(.+)$", victim)
    if m:
        case.victim = m.group(1).strip()
        case.murder_room = m.group(2).strip()

    m = re.search(r"^- \*\*Killed:\*\* in the (.+?) at ([\d:]+), with (.+)$", text, re.M)
    if m:
        case.murder_room = m.group(1).strip()
        case.weapon = m.group(3).strip()

    m = re.search(
        r"^- \*\*The lie:\*\* (.+?) claims the (.+?) for ([\d:]+) to ([\d:]+) \(really the (.+?)\)$",
        text, re.M,
    )
    if m:
        case.claimed_room = m.group(2).strip()
        case.lie_from = _minutes(*(int(x) for x in m.group(3).split(":")))
        case.lie_to = _minutes(*(int(x) for x in m.group(4).split(":")))
        case.true_room = m.group(5).strip()

    m = re.search(r"^- \*\*Disproved by:\*\*\s*(.+)$", text, re.M)
    if m:
        case.witnesses = [w.strip() for w in m.group(1).split(",") if w.strip()]


def parse_grid(text, case):
    """The 'Where everyone was' table: short name -> slot start minutes -> room.

    The murderer's row is the truth and the '...claims' row beneath it is the
    account they give, so the claims row wins where both exist."""
    block = re.search(r"### Where everyone was\n\n(.*?)\n\n", text, re.S)
    if not block:
        return
    lines = [l for l in block.group(1).splitlines() if l.startswith("|")]
    if len(lines) < 2:
        return
    slots = [_minutes(*(int(x) for x in c.split(":")))
             for c in [c.strip() for c in lines[0].split("|")[1:-1]] if ":" in c]

    last_short = ""
    for line in lines[2:]:
        cells = [c.strip() for c in line.split("|")[1:-1]]
        if not cells:
            continue
        label = _strip_md(cells[0])
        rooms = [_strip_md(c) for c in cells[1:]]
        if label.startswith("...claims"):
            if last_short:
                case.grid[last_short] = dict(zip(slots, rooms))
            continue
        if "(victim)" in label:
            continue
        short = label.replace("(murderer)", "").strip()
        if not short:
            continue
        case.grid[short] = dict(zip(slots, rooms))
        last_short = short


def parse_accounts(text, case):
    """The fenced block under each suspect name in 'The account each suspect was
    given'. This is the exact wording they were handed, and for the murderer it
    is already the lying version, so it is the right thing to check against."""
    section = re.search(r"### The account each suspect was given\n(.*?)\n---\n", text, re.S)
    if not section:
        return
    body = section.group(1)
    for m in re.finditer(r"\*\*(.+?)\*\*\n\n```\n(.*?)\n```", body, re.S):
        name = m.group(1).strip()
        blocks = []
        for line in m.group(2).splitlines():
            line = line.strip()
            b = re.match(
                r"^- ([\d:]+) to ([\d:]+): the (.+?), (.+?)\.?$", line)
            if b:
                who = b.group(4)
                companions = []
                if who.startswith("with "):
                    companions = [w.strip() for w in
                                  re.split(r",| and ", who[5:]) if w.strip()]
                blocks.append({
                    "from": _minutes(*(int(x) for x in b.group(1).split(":"))),
                    "to": _minutes(*(int(x) for x in b.group(2).split(":"))),
                    "room": b.group(3).strip(),
                    "companions": companions,
                    "dinner": "at dinner" in who,
                })
        if blocks:
            case.accounts[name] = blocks


def parse_transcript(text, case):
    """The Full timeline section, which is the only place every line carries the
    name of who said it. Returns [{n, scene, speaker, question, reply}]."""
    section = text.split("# Full timeline", 1)
    if len(section) < 2:
        return []
    body = section[1]
    entries = []
    heads = list(re.finditer(r"^\*\*(\d+) - (\w+)(?: - (.+?))?\*\*\s*$", body, re.M))
    for i, h in enumerate(heads):
        chunk = body[h.end(): heads[i + 1].start() if i + 1 < len(heads) else len(body)]
        question, reply, speaker = "", "", (h.group(3) or "").strip()
        current = None
        for raw in chunk.splitlines():
            line = raw.lstrip("> ").rstrip()
            m = re.match(r"^\*\*(.+?):\*\*\s*(.*)$", line)
            if m:
                who, rest = m.group(1).strip(), m.group(2)
                if who.lower() == "detective":
                    current, question = "q", rest
                else:
                    current, reply = "a", rest
                continue
            if line and current == "q":
                question += " " + line
            elif line and current == "a":
                reply += " " + line
        if reply:
            entries.append({
                "n": int(h.group(1)), "scene": h.group(2),
                "speaker": speaker, "question": question.strip(), "reply": reply.strip(),
            })
    return entries


def link_names(case):
    """Short names come off the movement grid, full names off the header. Join
    them so an account block and a transcript line can be matched up."""
    for full in case.suspects:
        for short in case.grid:
            if short and re.search(r"\b%s\b" % re.escape(short), full):
                case.short_of[full] = short
                case.full_of[short] = full
                break
        case.short_of.setdefault(full, full)


# ------------------------------------------------------------------- checks --

def spoken_only(reply):
    """The reply with stage directions removed, so a bracketed action never
    counts towards the length rule or trips a lexical check."""
    return STAGE_RE.sub(" ", reply)


def rooms_in(text):
    found = []
    for room in ROOMS:
        if re.search(r"\b%s\b" % re.escape(room), text, re.I):
            found.append(room)
    return found


def split_sentences(text):
    """Sentences, with runs of dots flattened first.

    Every suspect in this model's output trails off mid-thought, and an
    unflattened "too deep, too precise, and too... calculated" counts as two
    sentences and inflates every length figure in the report."""
    flat = re.sub(r"\.{2,}", " ", text)
    # "Dr. Blackwood" and "Mr. Reeves" are not sentence ends. Left alone they
    # chop a recited alibi into fragments, which both inflates every sentence
    # count and separates a room from the time that belongs to it.
    flat = ABBREV_RE.sub(lambda m: m.group(0)[:-1] + "\x00", flat)
    parts = SENTENCE_SPLIT_RE.split(flat.strip())
    return [p.replace("\x00", ".") for p in parts if p.strip()]


ALIBI_MARKER_RE = re.compile(
    r"\bI\b|\bmy\b|\bme\b|\bthen\b|\bback to\b|\balone\b|\bon my own\b"
    r"|\bwith (?:the |[A-Z])", re.I)
BODY_TALK_RE = re.compile(r"\bbody\b|\bcorpse\b|\bhe (?:was|lay|died)\b", re.I)


def reads_as_own_account(sentence):
    """Whether a sentence is the speaker describing their own evening.

    A recited alibi often has no pronoun in it ("The Dining Room, from half past
    eight until half past eleven, with Tom Reeves"), so a first-person test
    alone throws away the very lines this check exists for. A sentence that
    opens with a room or a time is a continuation of a recital and counts too.
    Talk about the body is excluded: naming the room the victim was found in is
    not a claim about where the speaker was."""
    if BODY_TALK_RE.search(sentence):
        return False
    if ALIBI_MARKER_RE.search(sentence):
        return True
    head = sentence.strip()[:24]
    if any(re.match(r"(?:the )?%s\b" % re.escape(r), head, re.I) for r in ROOMS):
        return True
    return bool(parse_times(head))


def room_time_pairs(sentence):
    """Each room in a sentence paired with the times that belong to it.

    "the Ballroom until half past eleven, then the Conservatory until ten" is
    two separate claims. Testing the sentence as one bag of rooms and one bag of
    times lets a single true clause excuse every false one next to it, which is
    exactly how a schedule recited backwards reads as fine.

    A room takes the times that follow it and come before the next room. If
    nothing follows it, it takes the times immediately in front of it instead,
    which is the "Half past eight to eleven, the Hall" shape."""
    marks = []
    for room in ROOMS:
        for m in re.finditer(r"\b%s\b" % re.escape(room), sentence, re.I):
            marks.append((m.start(), room))
    if not marks:
        return []
    marks.sort()

    times = [(at, label, mins) for label, mins, at in parse_times(sentence)]
    if not times:
        return []

    out = []
    for i, (pos, room) in enumerate(marks):
        nxt = marks[i + 1][0] if i + 1 < len(marks) else len(sentence)
        after = [(l, m) for (at, l, m) in times if pos < at < nxt]
        if not after:
            prev = marks[i - 1][0] if i > 0 else -1
            after = [(l, m) for (at, l, m) in times if prev < at < pos]
        for label, mins in after:
            out.append((room, label, mins))
    return out


def account_covers(blocks, room, minutes):
    for b in blocks:
        if b["room"].lower() == room.lower() and b["from"] <= minutes <= b["to"]:
            return True
    return False


def account_rooms(blocks):
    return {b["room"] for b in blocks}


def check_reply(entry, case, findings):
    """Everything checkable inside one reply."""
    full = entry["speaker"]
    reply = entry["reply"]
    spoken = spoken_only(reply)
    low = spoken.lower()
    blocks = case.accounts.get(full, [])
    n = entry["n"]

    def flag(kind, detail):
        findings.append({"n": n, "speaker": full, "kind": kind, "detail": detail})

    # -- length. The prompt asks for 1 to 3 sentences and under 50 words.
    words = len(re.findall(r"[A-Za-z']+", spoken))
    sentences = len(split_sentences(spoken))
    if words > 50:
        flag("too_long", "%d spoken words (rule: under 50)" % words)
    if sentences > 3:
        flag("too_many_sentences", "%d sentences (rule: 1 to 3)" % sentences)

    # -- stage directions.
    directions = STAGE_RE.findall(reply)
    if len(directions) > 2:
        flag("stage_direction_flood", "%d bracketed actions in one reply" % len(directions))
    for d in directions:
        if re.search(r"\bdetective\b|\bhe repeats\b|\byou had\b", d, re.I):
            flag("narrates_the_detective", "(%s)" % d.strip()[:60])

    # -- times outside the evening.
    for label, minutes, _ in parse_times(spoken):
        if not in_evening(minutes):
            flag("time_outside_evening", "\"%s\" is not between 8:00pm and midnight" % label)

    # -- last night described as this morning.
    for phrase in MORNING_FRAMING:
        if phrase in low:
            flag("morning_framing", "\"%s\"" % phrase)
            break

    # -- a room they were never in, stated in the first person.
    if blocks:
        mine = {r.lower() for r in account_rooms(blocks)}
        for room in rooms_in(spoken):
            if room.lower() in mine:
                continue
            m = re.search(
                r"\bI (?:was|were|had been|have been|went|stayed|sat|stood)\b([^.]{0,40}?)\b%s\b"
                % re.escape(room), spoken, re.I,
            )
            # "I was not in the Ballroom" is a denial, and denying a room you
            # were never in is the correct answer, not a defect.
            if m and not re.search(r"\b(not|never|n't)\b", m.group(1), re.I):
                flag("room_not_in_account", "claims the %s" % room)

    # -- a room paired with a time the account does not support.
    if blocks:
        for sentence in split_sentences(spoken):
            if not reads_as_own_account(sentence):
                continue
            for room, label, mins in room_time_pairs(sentence):
                if not in_evening(mins):
                    continue
                if not account_covers(blocks, room, mins):
                    flag("alibi_time_mismatch",
                         "the %s at %s does not match their account" % (room, label))

    # -- a weapon that is not this case's weapon.
    for word in WEAPON_WORDS:
        if re.search(r"\b%s\b" % re.escape(word), low) and word not in case.weapon.lower():
            flag("weapon_not_in_case", "\"%s\" (the weapon is %s)" % (word, case.weapon))

    # -- people who do not exist.
    for word in INVENTED_PEOPLE:
        if re.search(r"\b%s\b" % re.escape(word), low):
            flag("invented_person", "\"%s\"" % word)

    # -- another guest placed in the interview room.
    for phrase in PRESENCE_CLAIMS:
        if phrase in low:
            flag("presence_claim", "\"%s\"" % phrase)

    # -- a second death.
    for phrase in INVENTED_EVENTS:
        if phrase in low:
            flag("invented_event", "\"%s\"" % phrase)

    # -- the victim's name, one canonical form.
    if case.victim:
        surname = case.victim.split()[-1]
        if re.search(r"\bthe Lord %s\b" % re.escape(surname), spoken):
            flag("victim_naming", "\"the Lord %s\"" % surname)
        if re.search(r"\bMr\.? %s\b" % re.escape(surname), spoken):
            flag("victim_naming", "\"Mr. %s\" (he is Lord %s)" % (surname, surname))


# Denying the murder itself. The shared preamble opens by stating flatly that
# the victim was killed, so a suspect proposing natural causes is not a theory,
# it is a character contradicting a fact they were given. The expert saying it
# is worse, because hers is the one opinion the player has no way to check.
DENIES_THE_MURDER = [
    "natural causes", "heart attack", "died of natural", "nobody killed",
    "no one killed", "was not murdered", "wasn't murdered", "not a murder",
]


def parse_roles(text, case):
    """Role and guilt for each suspect, off the per-character section headers."""
    roles = {}
    for m in re.finditer(r"^## (.+?)\n\n\*(.+?) - found in the (.+?) - \*\*(.+?)\*\*\*", text, re.M):
        roles[m.group(1).strip()] = {
            "role": m.group(2).strip(),
            "room_now": m.group(3).strip(),
            "guilt": m.group(4).strip(),
        }
    return roles


def check_self_contradiction(entries, case, findings):
    """The same clock time claimed for two different rooms by one suspect.

    This is the check that catches the failure a reader misses: Evelyn's three
    incompatible versions in log 2026-09-03 are spread over one long reply and
    over twenty turns, and both read fluently in isolation."""
    claims = defaultdict(lambda: defaultdict(set))   # speaker -> minutes -> rooms
    where = defaultdict(lambda: defaultdict(list))   # speaker -> (minutes, room) -> line numbers
    for e in entries:
        spoken = spoken_only(e["reply"])
        for sentence in split_sentences(spoken):
            srooms = rooms_in(sentence)
            stimes = parse_times(sentence)
            if len(srooms) != 1 or not stimes:
                continue
            for _, mins, _pos in stimes:
                if not in_evening(mins):
                    continue
                claims[e["speaker"]][mins].add(srooms[0])
                where[e["speaker"]][(mins, srooms[0])].append(e["n"])

    for speaker, by_time in claims.items():
        for mins, rooms in sorted(by_time.items()):
            if len(rooms) < 2:
                continue
            hour, minute = divmod(mins, 60)
            lines = sorted({n for r in rooms for n in where[speaker][(mins, r)]})
            findings.append({
                "n": lines[0], "speaker": speaker, "kind": "self_contradiction",
                "detail": "%d:%02d given as both %s (lines %s)" % (
                    hour if hour < 24 else 12, minute,
                    " and ".join(sorted(rooms)),
                    ", ".join(str(n) for n in lines)),
            })


def check_case(entries, case, roles):
    """The case-level questions: was this playthrough winnable at all?"""
    by_speaker = defaultdict(list)
    for e in entries:
        by_speaker[e["speaker"]].append(e)

    out = {}
    murderer = case.murderer_full
    murderer_lines = by_speaker.get(murderer, [])
    out["murderer_questioned"] = len(murderer_lines)

    # Did the murderer ever state their cover story? If they were never asked,
    # the lie is not a failure of the model - it is a case nobody opened.
    stated = [e["n"] for e in murderer_lines
              if case.claimed_room
              and re.search(r"\b%s\b" % re.escape(case.claimed_room),
                            spoken_only(e["reply"]), re.I)]
    out["lie_stated"] = stated

    # Did a witness ever put themselves in that room at that time, which is the
    # fact that breaks it?
    contradicted = []
    for short in case.witnesses:
        full = case.full_of.get(short, short)
        for e in by_speaker.get(full, []):
            spoken = spoken_only(e["reply"])
            if not case.claimed_room:
                continue
            if not re.search(r"\b%s\b" % re.escape(case.claimed_room), spoken, re.I):
                continue
            if any(case.lie_from <= mins <= case.lie_to for _, mins, _ in parse_times(spoken)):
                contradicted.append(e["n"])
    out["lie_contradicted"] = contradicted

    # The expert's time of death, which normally clears two or three people.
    expert = ""
    for full, info in roles.items():
        if re.search(r"patholog|coroner|medical examiner|forensic", info["role"], re.I):
            expert = full
            break
    out["expert"] = expert
    given, denied = [], []
    for e in by_speaker.get(expert, []):
        spoken = spoken_only(e["reply"])
        for sentence in split_sentences(spoken):
            if re.search(r"\bdie[ds]?\b|\bdeath\b|\bkilled\b", sentence, re.I):
                if any(in_evening(m) for _, m, _ in parse_times(sentence)):
                    given.append(e["n"])
                    break
        if any(p in spoken.lower() for p in DENIES_THE_MURDER):
            denied.append(e["n"])
    out["expert_time_given"] = given
    out["expert_denied_murder"] = denied

    out["never_questioned"] = [s for s in case.suspects if not by_speaker.get(s)]
    out["solvable"] = bool(stated and contradicted)
    return out


def check_denials(entries, findings):
    for e in entries:
        low = spoken_only(e["reply"]).lower()
        for phrase in DENIES_THE_MURDER:
            if phrase in low:
                findings.append({
                    "n": e["n"], "speaker": e["speaker"], "kind": "denies_the_murder",
                    "detail": "\"%s\"" % phrase,
                })
                break


# ------------------------------------------------------------------ report --

KIND_LABELS = {
    "alibi_time_mismatch": "Alibi does not match the account",
    "self_contradiction": "Contradicts their own earlier answer",
    "room_not_in_account": "Claims a room they were never in",
    "time_outside_evening": "A time outside 8pm to midnight",
    "morning_framing": "Last night described as this morning",
    "weapon_not_in_case": "A weapon that is not in this case",
    "invented_person": "A person who does not exist",
    "presence_claim": "Another guest placed in the interview",
    "invented_event": "An event that did not happen",
    "denies_the_murder": "Denies that there was a murder",
    "victim_naming": "Wrong form of the victim's name",
    "narrates_the_detective": "Stage direction writes the detective",
    "stage_direction_flood": "More than two stage directions",
    "too_long": "Over the 50 word rule",
    "too_many_sentences": "Over the 3 sentence rule",
}

# The ones that break the fiction or the case, as against the ones that are
# style. Kept apart so a run can get worse on manners and better on truth and
# the number still says so.
HARD_KINDS = [
    "alibi_time_mismatch", "self_contradiction", "room_not_in_account",
    "time_outside_evening", "weapon_not_in_case", "invented_person",
    "presence_claim", "invented_event", "denies_the_murder", "morning_framing",
]


def build_report(path, case, roles, entries, findings, verdict):
    by_kind = defaultdict(list)
    for f in findings:
        by_kind[f["kind"]].append(f)
    hard = sum(len(by_kind[k]) for k in HARD_KINDS)
    soft = len(findings) - hard

    out = []
    out.append("# Dialogue check: %s\n" % Path(path).name)
    out.append("- **Case code:** `%s`" % case.code)
    out.append("- **Model:** `%s`" % case.model)
    out.append("- **Murderer:** %s, lying about the %s for %s" % (
        case.murderer_full, case.claimed_room, _span(case.lie_from, case.lie_to)))
    out.append("- **Exchanges:** %d across %d suspects" % (
        len(entries), len({e["speaker"] for e in entries})))
    out.append("- **Findings:** %d hard, %d style\n" % (hard, soft))

    out.append("## Was the case winnable\n")
    out.append("| Check | Result |")
    out.append("|---|---|")
    out.append("| Murderer questioned | %s |" % (
        "%d exchanges" % verdict["murderer_questioned"]
        if verdict["murderer_questioned"] else "**never questioned**"))
    out.append("| Cover story stated | %s |" % (
        "yes, line %s" % ", ".join(str(n) for n in verdict["lie_stated"])
        if verdict["lie_stated"] else "**no**"))
    out.append("| Cover story contradicted | %s |" % (
        "yes, line %s" % ", ".join(str(n) for n in verdict["lie_contradicted"])
        if verdict["lie_contradicted"] else "**no**"))
    if verdict["expert"]:
        out.append("| Expert gave a time of death | %s |" % (
            "yes, line %s" % ", ".join(str(n) for n in verdict["expert_time_given"])
            if verdict["expert_time_given"] else "**no**"))
        if verdict["expert_denied_murder"]:
            out.append("| Expert denied the murder | **yes, line %s** |" %
                       ", ".join(str(n) for n in verdict["expert_denied_murder"]))
    if verdict["never_questioned"]:
        out.append("| Never questioned | %s |" % ", ".join(verdict["never_questioned"]))
    out.append("")
    out.append("**Verdict: the case was %s from this transcript.**\n" % (
        "solvable" if verdict["solvable"] else "NOT solvable"))

    out.append("## Findings by kind\n")
    out.append("| Kind | Count |")
    out.append("|---|---|")
    for kind, items in sorted(by_kind.items(), key=lambda kv: -len(kv[1])):
        out.append("| %s | %d |" % (KIND_LABELS.get(kind, kind), len(items)))
    out.append("")

    out.append("## Findings by suspect\n")
    per = defaultdict(lambda: defaultdict(int))
    lines_per = defaultdict(int)
    for e in entries:
        lines_per[e["speaker"]] += 1
    for f in findings:
        per[f["speaker"]][f["kind"]] += 1
    out.append("| Suspect | Lines | Hard | Style |")
    out.append("|---|---|---|---|")
    for speaker in case.suspects:
        h = sum(v for k, v in per[speaker].items() if k in HARD_KINDS)
        s = sum(v for k, v in per[speaker].items() if k not in HARD_KINDS)
        out.append("| %s | %d | %d | %d |" % (speaker, lines_per[speaker], h, s))
    out.append("")

    out.append("## Every finding\n")
    for f in sorted(findings, key=lambda f: (f["n"], f["kind"])):
        mark = "**" if f["kind"] in HARD_KINDS else ""
        out.append("- line %d, %s: %s%s%s - %s" % (
            f["n"], f["speaker"], mark, KIND_LABELS.get(f["kind"], f["kind"]), mark,
            f["detail"]))
    if not findings:
        out.append("_Nothing flagged._")
    out.append("")
    return "\n".join(out)


def _span(a, b):
    if a is None or b is None:
        return "?"
    def fmt(m):
        h, mi = divmod(m, 60)
        return "%d:%02d" % (h if h < 24 else 12, mi)
    return "%s to %s" % (fmt(a), fmt(b))


def check_log(path):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    case = Case()
    case.path = str(path)
    parse_header(text, case)
    parse_grid(text, case)
    parse_accounts(text, case)
    link_names(case)
    roles = parse_roles(text, case)
    entries = parse_transcript(text, case)

    findings = []
    for e in entries:
        check_reply(e, case, findings)
    check_self_contradiction(entries, case, findings)
    check_denials(entries, findings)
    seen, unique = set(), []
    for f in findings:
        key = (f["n"], f["kind"], f["detail"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(f)
    findings = unique
    verdict = check_case(entries, case, roles)
    return case, roles, entries, findings, verdict


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logs", nargs="*", help="dialogue log(s) to check")
    ap.add_argument("--all", action="store_true", help="check every log in DialogueLogs/")
    ap.add_argument("--out", help="write the report here instead of stdout")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 if any case was not solvable from its transcript")
    args = ap.parse_args()

    paths = [Path(p) for p in args.logs]
    if args.all:
        paths += sorted(Path("DialogueLogs").glob("dialogue_*.md"))
    if not paths:
        ap.error("give a log path, or --all")

    reports, unsolved = [], 0
    for p in paths:
        if not p.exists():
            print("missing: %s" % p, file=sys.stderr)
            continue
        case, roles, entries, findings, verdict = check_log(p)
        if not entries:
            print("no transcript found in %s" % p, file=sys.stderr)
            continue
        reports.append(build_report(p, case, roles, entries, findings, verdict))
        if not verdict["solvable"]:
            unsolved += 1

    text = "\n\n---\n\n".join(reports)
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
        print("wrote %s" % args.out)
    else:
        print(text)

    if args.strict and unsolved:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
