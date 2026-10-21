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
