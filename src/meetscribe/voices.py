"""Voice library: remembers what named colleagues sound like, so later meetings label them
automatically instead of "Speaker 2".

A voiceprint is a TitaNet speaker embedding (the same model diarization uses). When you name
a speaker, their voiceprint from that meeting is added to voices.json under the name; future
speakers are matched by cosine similarity.
"""

import json
import os
from pathlib import Path

import numpy as np

from .config import HOME
from .diarize import EMBEDDING_MODEL, Turn

VOICES_FILE = HOME / "voices.json"
MATCH_THRESHOLD = 0.70    # cosine similarity needed to recognise a known voice
MATCH_MARGIN = 0.08       # …and this much better than the next-best person (a wrong name is
                          # worse than "Speaker 2"); calibrated: same voice 0.9+, others ≤ 0.61
MAX_SAMPLES = 12          # voiceprints kept per person (most recent)
SR = 16_000

_extractor = None


def _get_extractor():
    global _extractor
    if _extractor is None:
        import sherpa_onnx

        _extractor = sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(EMBEDDING_MODEL), num_threads=max(1, (os.cpu_count() or 4) // 2)))
    return _extractor


def embed(audio: np.ndarray) -> np.ndarray:
    ex = _get_extractor()
    stream = ex.create_stream()
    stream.accept_waveform(SR, audio)
    stream.input_finished()
    v = np.array(ex.compute(stream), dtype=np.float32)
    return v / (np.linalg.norm(v) or 1)


def speaker_prints(audio: np.ndarray, turns: list[Turn], max_seconds: float = 60) -> dict[int, np.ndarray]:
    """One voiceprint per diarized speaker, from up to a minute of their clearest turns."""
    prints = {}
    for spk in sorted({t.speaker for t in turns}):
        mine = sorted((t for t in turns if t.speaker == spk), key=lambda t: t.end - t.start, reverse=True)
        chunks, total = [], 0.0
        for t in mine:
            if t.end - t.start < 1.0 and total > 3:
                continue
            chunks.append(audio[int(t.start * SR): int(t.end * SR)])
            total += t.end - t.start
            if total >= max_seconds:
                break
        if total >= 2:  # too little speech gives an unreliable print
            prints[spk] = embed(np.concatenate(chunks))
    return prints


def load_library() -> dict[str, list[list[float]]]:
    try:
        return json.loads(VOICES_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_library(lib: dict) -> None:
    VOICES_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = VOICES_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(lib))
    tmp.replace(VOICES_FILE)


def identify(prints: dict[int, np.ndarray], exclude: set[str] = frozenset()) -> dict[int, tuple[str, float]]:
    """Match speakers to known voices: {speaker: (name, similarity)}. Each name used once."""
    lib = {n: np.array(v, dtype=np.float32) for n, v in load_library().items() if v and n not in exclude}
    candidates = []
    for spk, p in prints.items():
        scores = sorted(((float(np.max(samples @ p)), name) for name, samples in lib.items()), reverse=True)
        if not scores:
            continue
        best, name = scores[0]
        runner_up = scores[1][0] if len(scores) > 1 else 0.0
        if best >= MATCH_THRESHOLD and best - runner_up >= MATCH_MARGIN:
            candidates.append((best, spk, name))
    out, used = {}, set()
    for sim, spk, name in sorted(candidates, reverse=True):
        if spk not in out and name not in used:
            out[spk] = (name, sim)
            used.add(name)
    return out


def enroll(name: str, prints: list[np.ndarray]) -> None:
    lib = load_library()
    samples = lib.get(name, []) + [p.round(5).tolist() for p in prints]
    lib[name] = samples[-MAX_SAMPLES:]
    save_library(lib)


def save_session_prints(session: Path, prints: dict[str, np.ndarray]) -> None:
    (session / "speakers.json").write_text(json.dumps({k: v.round(5).tolist() for k, v in prints.items()}))


def load_session_prints(session: Path) -> dict[str, np.ndarray]:
    try:
        data = json.loads((session / "speakers.json").read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    return {k: np.array(v, dtype=np.float32) for k, v in data.items()}
