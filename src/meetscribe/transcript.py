"""Turn words + speaker turns into a readable, speaker-labelled transcript."""

import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np

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
    settled = 0  # where the previous change ended up: words before it aren't moved again
    for n, i in enumerate(changes):
        nxt = changes[n + 1] if n + 1 < len(changes) else len(words)
        j = i
        runs_on = (not _ends_sentence(words[i - 1]) and words[i].text.strip()[:1].islower()
                   and words[i].start - words[i - 1].end <= 1.5)
        if runs_on:
            lo, hi = max(settled, i - SNAP_WORDS), min(nxt, i + SNAP_WORDS)
            # Each side keeps at least one word — except the end of a sentence that came apart on
            # its own ("…personne | ne la met à jour." then someone else): it goes back to its start.
            ends = [k for k in range(lo + 1, hi) if _ends_sentence(words[k - 1])]
            if not ends and nxt - i <= 6 and _ends_sentence(words[nxt - 1]):
                ends = [nxt]
            if ends:
                j = min(ends, key=lambda k: abs(k - i))  # the change goes between words j-1 and j
                if j < i:
                    labels[j:i] = [labels[i]] * (i - j)  # the start of the next speaker's sentence
                elif j > i:
                    labels[i:j] = [labels[i - 1]] * (j - i)  # the end of the previous speaker's sentence
        settled = j
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


def drop_faint(words: list[Word], audio: np.ndarray, below: float = 16.0, sr: int = 16_000) -> list[Word]:
    """The mic also catches the room: people talking nearby, the call from the speakers, a car.
    Whisper makes fragments of it ("I have a good I have a good", "they're out of dog") that the
    echo check can't match. They are far quieter than your own voice: drop the stretches of words
    more than `below` dB under your usual level."""
    runs: list[list[Word]] = []
    for w in words:
        if runs and w.start - runs[-1][-1].end < 1.0:
            runs[-1].append(w)
        else:
            runs.append([w])
    if len(runs) < 5:
        return words

    def level(run: list[Word]) -> float:
        seg = audio[int(run[0].start * sr): int(max(run[-1].end, run[0].start + 0.3) * sr)]
        frames = seg[: len(seg) // 480 * 480].reshape(-1, 480)  # 30 ms
        if not len(frames):
            return -99.0
        return float(20 * np.log10(np.percentile(np.sqrt((frames ** 2).mean(1)), 90) + 1e-9))

    levels = [level(r) for r in runs]
    usual = np.percentile(np.repeat(levels, [len(r) for r in runs]), 90)  # your voice, by word
    return [w for r, lv in zip(runs, levels) if lv >= usual - below for w in r]


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
