"""Audio loading: any format macOS can decode → 16 kHz mono float32."""

import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

SAMPLE_RATE = 16_000


def load_audio(path: Path) -> np.ndarray:
    """Decode with macOS's built-in `afconvert` (wav, caf, m4a, mp3, aac, …)."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "audio.wav"
        result = subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEF32@{SAMPLE_RATE}", "-c", "1", str(path), str(out)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise SystemExit(
                f"Could not decode {path.name}: {result.stderr.strip() or 'afconvert failed'}\n"
                "Tip: for video files (.mp4/.mov) export the audio first, e.g. QuickTime → File → Export As → Audio Only."
            )
        audio, _ = sf.read(out, dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    return np.ascontiguousarray(audio)


def is_silent(audio: np.ndarray, threshold: float = 0.003) -> bool:
    """True if the track has essentially no signal (e.g. system audio with nothing playing)."""
    return audio.size == 0 or float(np.percentile(np.abs(audio), 99.5)) < threshold
