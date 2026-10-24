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
    track: str = ""  # which recording it came from: "meeting", "mic", "room" or "file"


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


SNAP_WORDS = 8  # how far a change of speaker can move to reach the end of a sentence


def _ends_sentence(w: Word) -> bool:
    return w.text.rstrip().endswith((".", "?", "!", "…"))


def snap_to_sentences(words: list[Word], labels: list[str]) -> list[str]:
    """People rarely take over in the middle of a sentence. When the voices come apart there
    ("…if we reach the fourth | quarter target…", often a reply chained on in under a second),
    the change moves to the nearest end of sentence — a few words at most, and only when the
    words around it run on (no full stop before, no capital after, no pause)."""
    labels = list(labels)
    changes = [i for i in range(1, len(words)) if labels[i] != labels[i - 1]]
    for n, i in enumerate(changes):
        if _ends_sentence(words[i - 1]) or not words[i].text.strip()[:1].islower() or words[i].start - words[i - 1].end > 1.0:
            continue
        lo = max(changes[n - 1] if n else 0, i - SNAP_WORDS)
        hi = min(changes[n + 1] if n + 1 < len(changes) else len(words), i + SNAP_WORDS)
        # Each side keeps at least one word: a short reply must not vanish into its neighbour.
        ends = [j for j in range(lo + 1, hi) if _ends_sentence(words[j - 1])]
        if not ends:
            continue
        j = min(ends, key=lambda j: abs(j - i))  # the change goes between words j-1 and j
        if j < i:
            labels[j:i] = [labels[i]] * (i - j)  # the start of the next speaker's sentence
        elif j > i:
            labels[i:j] = [labels[i - 1]] * (j - i)  # the end of the previous speaker's sentence
    return labels


def group_words(words: list[Word], label_of) -> list[Utterance]:
    """Group consecutive words of the same speaker into utterances."""
    out: list[Utterance] = []
    labels = snap_to_sentences(words, [label_of(w) for w in words])
    for w, label in zip(words, labels):
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
