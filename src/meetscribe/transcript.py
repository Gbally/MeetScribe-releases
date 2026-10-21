"""Turn words + speaker turns into a readable, speaker-labelled transcript."""

import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path

from .diarize import Turn
from .transcribe import Word

PAUSE_SPLIT = 2.0  # start a new paragraph after this many seconds of silence


@dataclass
class Utterance:
    start: float
    end: float
    speaker: str
    text: str
    lang: str = ""


def speaker_for(word: Word, turns: list[Turn]) -> int:
    """Turn with the most overlap with the word; else the nearest turn."""
    best, best_overlap = None, 0.0
    for t in turns:
        overlap = min(word.end, t.end) - max(word.start, t.start)
        if overlap > best_overlap:
            best, best_overlap = t.speaker, overlap
    if best is not None:
        return best
    mid = (word.start + word.end) / 2
    return min(turns, key=lambda t: min(abs(mid - t.start), abs(mid - t.end))).speaker


def group_words(words: list[Word], label_of) -> list[Utterance]:
    """Group consecutive words of the same speaker into utterances."""
    out: list[Utterance] = []
    for w in words:
        label = label_of(w)
        last = out[-1] if out else None
        if last and last.speaker == label and w.start - last.end < PAUSE_SPLIT and last.lang == w.lang:
            last.text += w.text
            last.end = w.end
        else:
            out.append(Utterance(w.start, w.end, label, w.text, w.lang))
    for u in out:
        u.text = u.text.strip()
    return [u for u in out if u.text]


def _norm(text: str) -> str:
    return re.sub(r"[^\w]", "", text.lower())


def drop_echo(mic: list[Word], system: list[Word], window: float = 1.0) -> list[Word]:
    """Without headphones the mic also hears the remote people. Drop mic words that the
    system track heard at (about) the same time, plus short leftover fragments of echo."""
    by_text: dict[str, list[float]] = {}
    for w in system:
        by_text.setdefault(_norm(w.text), []).append(w.start)
    echo = [any(abs(t - w.start) < window for t in by_text.get(_norm(w.text), ())) for w in mic]

    # A short run of "own" words squeezed between echo words is misrecognized echo.
    kept, i = [], 0
    while i < len(mic):
        j = i
        while j < len(mic) and echo[j] == echo[i]:
            j += 1
        run = mic[i:j]
        if not echo[i]:
            between_echo = i > 0 and j < len(mic)
            if not (between_echo and len(run) <= 3 and run[-1].end - run[0].start < 2):
                kept.extend(run)
        i = j
    return kept


def merge(*tracks: list[Utterance]) -> list[Utterance]:
    return sorted((u for t in tracks for u in t), key=lambda u: u.start)


def fmt_time(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def main_language(utterances: list[Utterance]) -> str:
    counts: dict[str, int] = {}
    for u in utterances:
        if u.lang:
            counts[u.lang] = counts.get(u.lang, 0) + len(u.text.split())
    return max(counts, key=counts.get) if counts else ""


def _lang_tag(u: Utterance, main: str) -> str:
    """Marks passages in another language than the meeting's main one, e.g. ' (FR)'."""
    return f" ({u.lang.upper()})" if u.lang and main and u.lang != main else ""


def to_markdown(utterances: list[Utterance], title: str) -> str:
    main = main_language(utterances)
    lines = [f"# Transcript — {title}", ""]
    for u in utterances:
        lines.append(f"**[{fmt_time(u.start)}] {u.speaker}{_lang_tag(u, main)}:** {u.text}")
        lines.append("")
    return "\n".join(lines)


def to_plain(utterances: list[Utterance]) -> str:
    """Compact form fed to the LLM."""
    main = main_language(utterances)
    return "\n".join(f"[{fmt_time(u.start)}] {u.speaker}{_lang_tag(u, main)}: {u.text}" for u in utterances)


def save_json(utterances: list[Utterance], path: Path, meta: dict) -> None:
    path.write_text(json.dumps({**meta, "utterances": [asdict(u) for u in utterances]}, indent=1, ensure_ascii=False))


def load_json(path: Path) -> tuple[list[Utterance], dict]:
    data = json.loads(path.read_text())
    utterances = [Utterance(**u) for u in data.pop("utterances")]
    return utterances, data
