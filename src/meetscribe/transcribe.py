"""Speech-to-text with MLX Whisper (runs on the Apple Silicon GPU)."""

from dataclasses import dataclass

import numpy as np

# Phrases Whisper tends to invent on silence / music.
HALLUCINATIONS = {
    "thank you.", "thank you", "thanks for watching!", "thanks for watching.", "you",
    "bye.", "bye!", "merci.", "sous-titrage st' 501", "sous-titres réalisés par la communauté d'amara.org",
    "subtitles by the amara.org community", ".", "...",
}


@dataclass
class Word:
    start: float
    end: float
    text: str  # includes its leading space, as produced by Whisper


def transcribe(audio: np.ndarray, model: str, language: str = "", vocabulary: str = "") -> tuple[list[Word], str]:
    import mlx_whisper

    result = mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=model,
        language=language or None,
        word_timestamps=True,
        condition_on_previous_text=False,  # avoids repetition loops on long recordings
        hallucination_silence_threshold=2.0,
        initial_prompt=f"Vocabulary: {vocabulary}." if vocabulary else None,
        verbose=None,
    )
    words: list[Word] = []
    for seg in result["segments"]:
        text = seg["text"].strip().lower()
        if text in HALLUCINATIONS and seg["end"] - seg["start"] < 4:
            continue
        if seg.get("no_speech_prob", 0) > 0.8 and seg.get("avg_logprob", 0) < -0.7:
            continue
        for w in seg.get("words", []):
            words.append(Word(float(w["start"]), float(w["end"]), w["word"]))
    return words, result.get("language", language)
