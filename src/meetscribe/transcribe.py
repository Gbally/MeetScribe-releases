"""Speech-to-text with MLX Whisper (runs on the Apple Silicon GPU).

Whisper normally picks ONE language per file (from the first 30 s). When the meeting can mix
languages (setting `language = "en,fr"`), we detect the language every few seconds — only
choosing among the allowed languages — and transcribe each stretch in its own language.
"""

from dataclasses import dataclass

import numpy as np

SR = 16_000

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
    lang: str = ""


def parse_languages(setting: str) -> list[str]:
    return [l.strip().lower() for l in setting.split(",") if l.strip()]


def transcribe(audio: np.ndarray, model: str, language: str = "", vocabulary: str = "") -> tuple[list[Word], str]:
    """Returns the words and the main language code."""
    langs = parse_languages(language)
    if len(langs) <= 1:
        return _transcribe(audio, model, langs[0] if langs else None, vocabulary)

    from . import progress

    progress.whisper_span(0.0, 1.0)
    runs = language_runs(audio, model, langs)  # reports 0–10 % of the stage
    used = {lang for lang, _, _ in runs}
    if len(used) <= 1:  # the whole track is in one language: one plain pass
        return _transcribe(audio, model, next(iter(used), langs[0]), vocabulary)

    words: list[Word] = []
    totals: dict[str, float] = {}
    for i, lang in enumerate(sorted(used)):
        progress.whisper_span(0.1 + 0.9 * i / len(used), 0.1 + 0.9 * (i + 1) / len(used))
        spans = [(s, e) for l, s, e in runs if l == lang]
        totals[lang] = sum(e - s for s, e in spans)
        print(f"   {lang}: {totals[lang] / 60:.1f} min", flush=True)
        # Silence everything in other languages so timestamps stay aligned, then keep only
        # the words that fall inside this language's stretches.
        masked = np.zeros_like(audio)
        for s, e in spans:
            masked[int(s * SR): int(e * SR)] = audio[int(s * SR): int(e * SR)]
        w, _ = _transcribe(masked, model, lang, vocabulary)
        words += [x for x in w if any(s <= (x.start + x.end) / 2 <= e for s, e in spans)]
    words.sort(key=lambda w: w.start)
    progress.whisper_span(0.0, 1.0)
    return words, max(totals, key=totals.get)


def _transcribe(audio, model, language, vocabulary) -> tuple[list[Word], str]:
    import mlx_whisper

    result = mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=model,
        language=language,
        word_timestamps=True,
        condition_on_previous_text=False,  # avoids repetition loops on long recordings
        hallucination_silence_threshold=2.0,
        initial_prompt=f"Vocabulary: {vocabulary}." if vocabulary else None,
        verbose=False,  # False (not None) enables the progress bar that progress.py listens to
    )
    lang = result.get("language") or language or ""
    words: list[Word] = []
    for seg in result["segments"]:
        text = seg["text"].strip().lower()
        if text in HALLUCINATIONS and seg["end"] - seg["start"] < 4:
            continue
        if seg.get("no_speech_prob", 0) > 0.8 and seg.get("avg_logprob", 0) < -0.7:
            continue
        for w in seg.get("words", []):
            words.append(Word(float(w["start"]), float(w["end"]), w["word"], lang))
    return words, lang


def speech_regions(audio: np.ndarray, min_gap: float = 0.4) -> list[tuple[float, float]]:
    """Simple energy-based voice activity detection → [(start, end)] in seconds."""
    hop = int(0.03 * SR)
    n = len(audio) // hop
    if n == 0:
        return []
    rms = np.sqrt(np.mean(audio[: n * hop].reshape(n, hop) ** 2, axis=1))
    threshold = max(0.004, 0.08 * float(np.percentile(rms, 95)))
    speech = rms > threshold
    regions, start, last = [], None, -1e9
    for i, s in enumerate(speech):
        t = i * hop / SR
        if s:
            if start is None or t - last > min_gap:
                if start is not None:
                    regions.append((start, last))
                start = t
            last = t + hop / SR
    if start is not None:
        regions.append((start, last))
    return [(s, e) for s, e in regions if e - s > 0.25]


def language_runs(audio: np.ndarray, model_path: str, allowed: list[str]) -> list[tuple[str, float, float]]:
    """Split the audio into stretches of one language: [(lang, start, end)]."""
    import mlx.core as mx
    from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim
    from mlx_whisper.transcribe import ModelHolder

    model = ModelHolder.get_model(model_path, mx.float16)

    # Group speech into windows of ~4–20 s (short bits are too short to identify reliably).
    windows: list[list[float]] = []
    for s, e in speech_regions(audio):
        while e - s > 20:
            windows.append([s, s + 20])
            s += 20
        if windows and s - windows[-1][1] < 0.6 and windows[-1][1] - windows[-1][0] < 3 and e - windows[-1][0] <= 20:
            windows[-1][1] = e
        else:
            windows.append([s, e])

    from . import progress

    runs: list[list] = []
    previous = None
    for k, (s, e) in enumerate(windows):
        progress.update(0.1 * k / max(len(windows), 1))
        clip = audio[int(s * SR): int(e * SR)]
        mel = log_mel_spectrogram(clip, n_mels=model.dims.n_mels, padding=N_SAMPLES)
        _, probs = model.detect_language(pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16))
        scores = {l: float(probs.get(l, 0)) for l in allowed}
        total = sum(scores.values()) or 1
        lang = max(scores, key=scores.get)
        # Hysteresis: only switch language on a confident, long-enough window.
        if previous and lang != previous and (scores[lang] / total < 0.75 or e - s < 2):
            lang = previous
        previous = lang
        if runs and runs[-1][0] == lang:
            runs[-1][2] = e
        else:
            runs.append([lang, s, e])

    # Pad each run a little so word edges aren't cut, without overlapping the next.
    out = []
    for i, (lang, s, e) in enumerate(runs):
        s = max(0.0, s - 0.3 if i == 0 else (runs[i - 1][2] + s) / 2)
        e = e + 0.3 if i == len(runs) - 1 else (e + runs[i + 1][1]) / 2
        out.append((lang, round(s, 2), round(min(e, len(audio) / SR), 2)))
    return out
