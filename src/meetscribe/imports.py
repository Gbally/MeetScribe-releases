"""Transcripts made elsewhere (Teams, Zoom, Google Meet, Granola, Otter…) turned into MeetScribe
utterances, so they get the same notes as a recording. Reads WebVTT (.vtt), SubRip (.srt), YouTube
(.sbv), Word (.docx, Teams' download) and plain text or Markdown (.txt, .md: "Name: text" lines,
or a "Name 0:03" / "Name - 00:01" / "Speaker 1 (00:01):" / "[Name] 10:00:01" header line before
what they said, with or without times). Who said what is kept when the file says it; times too, else they're estimated
from the length of what was said."""

import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree

from .transcript import Utterance

SUFFIXES = {".vtt", ".srt", ".sbv", ".docx", ".txt", ".md"}

TIME = r"(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?"  # 1:02:03.456, 02:03, 0:03
WPM = 150  # speaking pace used when the file has no times


def _seconds(h, m, s, ms=None) -> float:
    return int(h or 0) * 3600 + int(m) * 60 + int(s) + (int(ms.ljust(3, "0")) / 1000 if ms else 0)


def read_transcript(path: Path, me: str = "") -> list[Utterance]:
    """The file's utterances, in order. `me`: your name — "Me"/"You" labels (Granola, Otter)
    become it."""
    suffix = path.suffix.lower()
    if suffix == ".docx":
        text = _docx_text(path)
    else:
        raw = path.read_bytes()
        text = raw.decode("utf-16") if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else raw.decode("utf-8-sig", errors="replace")
    if suffix in (".vtt", ".srt", ".sbv") or re.search(rf"^{TIME}\s*(-->|,)\s*{TIME}\s*$", text, re.M):
        utts = _cues(text)
    else:
        utts = _lines(text)
    while (utts and not utts[0].speaker and len(utts[0].text.split()) <= 5 and not utts[0].text.endswith((".", "!", "?"))
           and re.search(r"transcri|meeting|r[ée]union|call|appel|sync|notes|recording|enregistrement|\d", utts[0].text, re.I)):
        utts.pop(0)  # a title line ("Meeting transcript", "Weekly sync – 23 Oct"), not "Hi all"
    utts = _join(utts)
    if not utts:
        raise ValueError("No transcript text found in this file.")
    _fill_times(utts)
    if utts[0].start >= 3600:  # times of day ("[Sarah] 10:00:01"), not from the start of the meeting
        offset = utts[0].start
        for u in utts:
            u.start, u.end = u.start - offset, u.end - offset
    lang = guess_language(" ".join(u.text for u in utts))
    for u in utts:
        if me and u.speaker.lower() in {"me", "moi", "you", "vous", "toi", "yo", "eu"}:
            u.speaker = me  # Granola, Otter: your own side
        elif u.speaker.lower() in {"them", "eux", "other", "others"}:
            u.speaker = "Speaker 1"  # Granola's other side: named like any unknown voice
        u.lang, u.track = lang, "file"
    return utts


def _docx_text(path: Path) -> str:
    """The paragraphs of a Word document, one per line (no python-docx needed)."""
    ns = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
    with zipfile.ZipFile(path) as z:
        root = ElementTree.fromstring(z.read("word/document.xml"))
    paras = []
    for p in root.iter(f"{ns}p"):
        parts = [t.text or "" for t in p.iter() if t.tag in (f"{ns}t", f"{ns}tab")]
        paras.append("".join(x if x else "\t" for x in parts).strip())
    return "\n".join(paras)


def _speaker_text(text: str) -> tuple[str, str]:
    """ "<v Sarah Martin>Hello</v>" or "Sarah Martin: Hello" → ("Sarah Martin", "Hello")."""
    m = re.match(r"^<v(?:\.[^ >]*)?\s+([^>]+)>(.*?)(?:</v>)?$", text, re.S)
    if m:
        return m[1].strip(), re.sub(r"<[^>]+>", "", m[2]).strip()
    text = re.sub(r"<[^>]+>", "", text).strip()
    m = re.match(r"^([^:\n]{1,40}?):\s+(.+)$", text, re.S)
    if m and _looks_like_name(m[1]):
        return m[1].strip(), m[2].strip()
    return "", text


# Capitalised labels that come before a colon in notes, not names ("Note: …", "Update: …").
NOT_NAMES = set("""note notes update updates action actions summary agenda question questions answer important todo
next steps decision decisions info fyi reminder remarque attention résumé resume ordre du jour sujet point
ok okay yes no thanks merci oui non""".split()) | {"next steps", "ordre du jour", "to do"}


def _looks_like_name(label: str) -> bool:
    """ "Sarah Martin", "Speaker 2", "Me", "Dr. Ana Lima" — not "Note", a time or a sentence."""
    label = label.strip().strip("*").strip()
    words = label.split()
    return (0 < len(words) <= 4 and not re.search(r"https?|www\.", label) and re.search(r"[^\W\d_]", label) is not None
            and label.lower() not in NOT_NAMES and not re.fullmatch(r"Q[1-4]", label)
            and all(w[:1].isupper() or w[:1].isdigit() or w.lower() in {"de", "van", "von", "da", "le", "la"} for w in words))


def _cues(text: str) -> list[Utterance]:
    """WebVTT / SubRip / YouTube: blocks of "start --> end" (or "start,end") then text."""
    out = []
    for block in re.split(r"\n\s*\n", text.replace("\r", "")):
        m = re.search(rf"{TIME}\s*(?:-->|,)\s*{TIME}", block)
        if not m:
            continue
        body = block[m.end():].split("\n", 1)[1] if "\n" in block[m.end():] else ""
        body = " ".join(line.strip() for line in body.splitlines() if line.strip())
        speaker, said = _speaker_text(body)
        if said:
            out.append(Utterance(_seconds(*m.groups()[:4]), _seconds(*m.groups()[4:]), speaker, said))
    return out


def _lines(text: str) -> list[Utterance]:
    """Plain text / Markdown / Word: "Name: text", "[00:01:02] Name: text", "**Name:** text", or
    a name (and time) on its own line followed by what they said (Teams, Otter, Meet)."""
    out: list[Utterance] = []
    pending = ""  # a "Name   0:03" header waiting for its text
    pending_t = None
    for line in text.replace("\r", "").splitlines():
        line = re.sub(r"\*\*|__", "", line).strip()
        if not line or re.match(r"^(#|---|===|WEBVTT|transcript\b)", line, re.I):
            continue
        t = None
        m = re.match(rf"^\[?\(?{TIME}\)?\]?\s*[-–—]?\s*", line)
        if m and m.end() == len(line):  # a time alone on its line (after the speaker's name, or before)
            pending_t = _seconds(*m.groups())
            continue
        if m:
            t, line = _seconds(*m.groups()), line[m.end():].strip()
        # A header alone on its line: "Sarah Martin  0:03" (Otter), "Sarah Martin - 00:01" (Fireflies),
        # "Speaker 1 (00:01):" (Rev), "[Sarah Martin] 10:00:01" (chat-like exports)
        h = re.match(rf"^\[?(.{{1,40}}?)\]?\s*[-–—|]?\s*[\(\[]?{TIME}[\)\]]?\s*:?$", line)
        if h and _looks_like_name(h[1].strip(" -–—|")):
            pending, pending_t = h[1].strip(" -–—|"), _seconds(*h.groups()[1:])
            continue
        if not line:
            pending_t = t if t is not None else pending_t
            continue
        if _looks_like_name(line) and len(line.split()) <= 3 and not line.endswith((".", "!", "?")):
            pending, pending_t = line, t if t is not None else pending_t  # a name alone on its line
            continue
        speaker, said = _speaker_text(line)
        if not speaker and pending:
            speaker = pending
        start = t if t is not None else pending_t
        pending_t = None
        if said:
            out.append(Utterance(start if start is not None else -1.0, -1.0, speaker, said))
    return out


def _join(utts: list[Utterance]) -> list[Utterance]:
    """Consecutive pieces of the same speaker (subtitle cues cut mid-sentence) become one line;
    a speaker never named keeps the previous one's, or "Speaker 1"."""
    out: list[Utterance] = []
    for u in utts:
        if not u.speaker:
            u.speaker = out[-1].speaker if out else "Speaker 1"
        if out and out[-1].speaker == u.speaker and (u.start < 0 or out[-1].end < 0 or u.start - out[-1].end < 2.0):
            out[-1].text += " " + u.text
            out[-1].end = u.end if u.end >= 0 else out[-1].end
        else:
            out.append(u)
    return out


def _fill_times(utts: list[Utterance]) -> None:
    """Times the file didn't give: from the previous line plus the time it takes to say it."""
    clock = 0.0
    for i, u in enumerate(utts):
        said = len(u.text.split()) / WPM * 60
        if u.start < 0:
            u.start = clock
        if u.end < u.start:
            nxt = next((x.start for x in utts[i + 1:] if x.start >= 0), None)
            u.end = min(u.start + said, nxt) if nxt is not None and nxt > u.start else u.start + said
        clock = max(clock, u.end + 0.5)


# A few very common words per language: enough to tell which one a line is in.
# Words that are common in one language and rare in the others.
_COMMON = {
    "en": "the and to of is that it you we for this are with have will i".split(),
    "fr": "le les et des est que une pour pas vous nous je dans ce qui sur avec".split(),
    "es": "el los y que es una para por con las del pero muy".split(),
    "de": "der die das und ist nicht ich wir sie mit den ein eine auf für".split(),
    "it": "il di che è per non sono con della mi io gli".split(),
    "pt": "os que é um uma para não em do da com você".split(),
    "nl": "het een van dat niet ik wij jij op voor zijn".split(),
}


def guess_language(text: str) -> str:
    """The language of the whole transcript (Whisper's codes), or "" when unsure."""
    words = re.findall(r"[a-zà-ÿ']+", text.lower())
    scores = {lang: sum(w in common for w in words) for lang, common in _COMMON.items()}
    best = max(scores, key=scores.get)
    return best if scores[best] >= 3 else ""
