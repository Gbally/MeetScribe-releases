"""Speaker diarization ("who spoke when") with sherpa-onnx: pyannote segmentation +
TitaNet speaker embeddings + clustering. CPU-only, no account/token needed."""

import os
from dataclasses import dataclass

import numpy as np

from .config import MODELS_DIR

SEGMENTATION_MODEL = MODELS_DIR / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx"
EMBEDDING_MODEL = MODELS_DIR / "nemo_en_titanet_small.onnx"


@dataclass
class Turn:
    start: float
    end: float
    speaker: int  # 0-based, ordered by first appearance


def diarize(audio: np.ndarray, num_speakers: int = 0, threshold: float = 0.5) -> list[Turn]:
    import sherpa_onnx

    for model in (SEGMENTATION_MODEL, EMBEDDING_MODEL):
        if not model.exists():
            raise SystemExit(f"Missing model {model} — run ./setup.sh")

    threads = max(1, (os.cpu_count() or 4) // 2)
    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(SEGMENTATION_MODEL)),
            num_threads=threads,
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(EMBEDDING_MODEL), num_threads=threads),
        clustering=sherpa_onnx.FastClusteringConfig(
            num_clusters=num_speakers if num_speakers > 0 else -1, threshold=threshold
        ),
        min_duration_on=0.3,
        min_duration_off=0.5,
    )
    if not config.validate():
        raise SystemExit("Invalid diarization config (check the model files)")
    sd = sherpa_onnx.OfflineSpeakerDiarization(config)
    segments = sd.process(audio).sort_by_start_time()

    # Renumber speakers by order of first appearance → "Speaker 1" talks first.
    order: dict[int, int] = {}
    turns = []
    for s in segments:
        spk = order.setdefault(s.speaker, len(order))
        turns.append(Turn(float(s.start), float(s.end), spk))
    return turns


def consolidate(turns: list[Turn], prints: dict, max_speakers: int = 0, same: float = 0.7) -> list[Turn]:
    """Clean up over-split diarization: one person often comes out as several "speakers" (a
    change of tone, a noisy stretch, VoIP compression). Speakers whose voiceprints match
    (cosine ≥ `same`; the same voice scores 0.9+, different people ≤ ~0.6) are merged, and
    so are the closest ones while there are more than `max_speakers` (e.g. the calendar's
    attendees). Speakers with too little speech for a voiceprint join the nearest turn's."""
    sizes: dict[int, float] = {}
    for t in turns:
        sizes[t.speaker] = sizes.get(t.speaker, 0.0) + t.end - t.start
    groups = {spk: [spk] for spk in prints}
    centre = {spk: prints[spk] / (np.linalg.norm(prints[spk]) or 1) for spk in prints}
    weight = {spk: sizes.get(spk, 0.0) for spk in prints}
    while len(groups) > 1:
        keys = sorted(groups)
        sim, a, b = max((float(centre[a] @ centre[b]), a, b) for i, a in enumerate(keys) for b in keys[i + 1:])
        if sim < same and not (max_speakers and len(groups) > max_speakers):
            break
        v = centre[a] * weight[a] + centre[b] * weight[b]
        centre[a], weight[a] = v / (np.linalg.norm(v) or 1), weight[a] + weight[b]
        groups[a] += groups.pop(b)
        del centre[b], weight[b]
    owner = {spk: g for g, members in groups.items() for spk in members}

    merged = [Turn(t.start, t.end, owner[t.speaker]) for t in turns if t.speaker in owner]
    if merged:  # speakers without a voiceprint: whoever talks closest in time
        for t in turns:
            if t.speaker not in owner:
                mid = (t.start + t.end) / 2
                near = min(merged, key=lambda m: abs((m.start + m.end) / 2 - mid))
                merged.append(Turn(t.start, t.end, near.speaker))
    else:
        merged = list(turns)
    merged.sort(key=lambda t: t.start)

    order: dict[int, int] = {}
    return [Turn(t.start, t.end, order.setdefault(t.speaker, len(order))) for t in merged]


def speakers(audio: np.ndarray, n: int, threshold: float, cap: int = 0) -> tuple[list[Turn], dict]:
    """Who spoke when, cleaned up, with one voiceprint per speaker. Run in its own process
    (see cli): sherpa-onnx holds Python's lock while it works, which would stall Whisper."""
    from .audio import condense
    from .transcribe import speech_pieces
    from .voices import speaker_prints

    # Like transcription: only the stretches with speech (often half the track or less).
    short, original = condense(audio, speech_pieces(audio))
    turns = [Turn(*original(t.start, t.end), t.speaker) for t in diarize(short, n, threshold)]
    turns = [t for t in turns if t.end > t.start]
    if n <= 0 and len({t.speaker for t in turns}) > 1:
        turns = consolidate(turns, speaker_prints(audio, turns), max_speakers=cap)
    return turns, speaker_prints(audio, turns)
