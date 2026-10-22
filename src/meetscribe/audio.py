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


def condense(audio: np.ndarray, pieces: list[tuple[float, float]], gap: float = 0.6):
    """Keeps only `pieces` ([(start, end)] seconds), joined with `gap` seconds of silence.
    Returns the shorter audio and a function mapping its times back to the original."""
    silence = np.zeros(int(gap * SAMPLE_RATE), dtype=audio.dtype)
    chunks, starts, at = [], [], 0.0
    for s, e in pieces:
        chunk = audio[int(s * SAMPLE_RATE): int(e * SAMPLE_RATE)]
        chunks += [chunk, silence]
        starts.append((at, s, len(chunk) / SAMPLE_RATE))
        at += len(chunk) / SAMPLE_RATE + gap

    def piece(t: float) -> int:
        """Index of the stretch a time belongs to; in the silence between two, the nearer one."""
        for i in range(len(starts) - 1, -1, -1):
            c, _, length = starts[i]
            if t >= c:
                return i + 1 if i + 1 < len(starts) and t > c + length + gap / 2 else i
        return 0

    def original(start: float, end: float) -> tuple[float, float]:
        """A (start, end) span in the shorter audio → the original timeline, mapped within the
        stretch holding its middle (Whisper often starts or ends a word a little into the
        silence around it). Spans across several stretches (diarization turns) keep both ends."""
        a, b = piece(start), piece(end)
        k = piece((start + end) / 2) if b - a <= 1 else None
        def one(t: float, i: int) -> float:
            c, o, length = starts[i]
            return o + max(0.0, min(t - c, length))
        if not starts:
            return start, end
        if k is not None:
            return one(start, k), max(one(end, k), one(start, k))
        return one(start, a), one(end, b)

    return (np.concatenate(chunks) if chunks else audio[:0]), original
