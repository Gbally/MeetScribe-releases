"""Builds mic.caf / system.caf / meeting.json (+ truth_turns.json: who really spoke when) for one
test meeting, with the macOS voices.   make_audio.py <meeting> <folder>   ("engine" = the 30-min one)

A voice missing on this Mac is replaced by the system's default voice for that language (said
once): the meeting still works, but its speakers are then harder to tell apart than in the
measurements made with all the voices."""

import json
import random
import re
import subprocess
import sys
import tempfile
from functools import lru_cache
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).parent))
from scenarios import SCENARIOS  # noqa: E402

SR = 16000
FALLBACK = {"en": "Samantha", "fr": "Thomas"}


@lru_cache(maxsize=None)
def installed() -> set[str]:
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    # "Eddy (English (US))   en_US    # Hello!…" — long names leave a single space before the locale
    return {m[1].strip() for m in (re.match(r"^(.*?)\s+[a-z]{2,3}[_-][A-Za-z0-9]+\s+#", line) for line in out.splitlines()) if m}


def voice_for(voice: str, lang: str) -> str:
    if any(v == voice or v.startswith(voice + " (") for v in installed()):  # "Amélie" = "Amélie (French (Canada))"
        return voice
    fallback = FALLBACK.get(lang, "Samantha")
    print(f"   voice '{voice}' isn't installed — using '{fallback}' (Settings → Accessibility → Spoken Content adds voices)")
    return fallback


def tts(voice: str, text: str, rate: int) -> np.ndarray:
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "x.wav"
        subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", str(f), "--file-format=WAVE", "--data-format=LEF32@16000", text],
                       check=True)
        a, _ = sf.read(f, dtype="float32")
    return a


def shift(a: np.ndarray, factor) -> np.ndarray:
    """A bit higher/faster (>1) or lower/slower (<1): makes similar voices distinct."""
    if not factor or factor == 1:
        return a
    n = int(len(a) / factor)
    return np.interp(np.linspace(0, len(a) - 1, n), np.arange(len(a)), a).astype(np.float32)


def band(a: np.ndarray, k: int) -> np.ndarray:
    return np.convolve(a, np.ones(k) / k, mode="same")


def write(out: Path, mic: np.ndarray, system: np.ndarray, meeting: dict, spoken: list[dict]):
    for name, a in (("mic", mic), ("system", system)):
        w = out / f"{name}.wav"
        sf.write(w, np.clip(a, -1, 1), SR, subtype="PCM_16")
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16@16000", str(w), str(out / f"{name}.caf")], check=True)
        w.unlink()
    (out / "meeting.json").write_text(json.dumps(meeting, ensure_ascii=False))
    (out / "truth_turns.json").write_text(json.dumps(spoken, ensure_ascii=False))


def make(name: str, out: Path):
    sc = SCENARIOS[name]
    random.seed(sum(map(ord, name)))
    np.random.seed(7)
    clips = [(spk, shift(tts(voice_for(sc["people"][spk]["voice"][lang], lang), text, 155), sc["people"][spk].get("pitch")))
             for spk, lang, text in sc["turns"]]
    total = int((sc["lead"] + sum(len(a) for _, a in clips) / SR + len(clips) * 1.4 + 6) * SR)
    mic, system = np.zeros(total, np.float32), np.zeros(total, np.float32)
    pos, spoken = int(sc["lead"] * SR), []
    for spk, a in clips:
        p = sc["people"][spk]
        spoken.append(dict(person=p["name"], start=round(pos / SR, 2), end=round((pos + len(a)) / SR, 2)))
        if p["track"] == "mic":
            v = band(a, 2) * 0.7
            mic[pos:pos + len(v)] += v
        else:
            v = band(a, 3) * p.get("gain", 0.7)
            system[pos:pos + len(v)] += v
            if sc.get("echo"):  # laptop speakers heard by the mic (no headphones)
                mic[pos:pos + len(v)] += v * sc["echo"]
        pos += len(a) + int(random.uniform(0.4, 2.0) * SR)
    mic += np.random.randn(total).astype(np.float32) * 0.003
    system += np.random.randn(total).astype(np.float32) * 0.0015
    write(out, mic, system, {"title": sc["title"], "started": "2026-10-23T10:00:00", "template": sc["template"],
                             "calendar": {"title": "", "organizer": sc["me"],
                                          "attendees": [{"name": n, "email": ""} for n in sc["calendar"]]}}, spoken)
    print(f"{name}: {len(clips)} turns, {pos / SR / 60:.1f} min")


def make_engine(out: Path):
    """The 30-minute bilingual meeting about a game engine (Guillaume on the mic, Sarah and Marc remote)."""
    from engine_script import SCRIPT

    random.seed(11)
    np.random.seed(11)
    target = 30 * 60
    voices = {("G", "en"): "Eddy (English (US))", ("G", "fr"): "Eddy (French (France))", ("S", "en"): "Flo (English (US))",
              ("S", "fr"): "Flo (French (France))", ("M", "en"): "Rocko (English (US))", ("M", "fr"): "Rocko (French (France))"}
    clips = [(spk, tts(voice_for(voices[(spk, lang)], lang), text, 150)) for spk, lang, text in SCRIPT]
    speech = sum(len(a) for _, a in clips) / SR
    lead = 20.0  # people joining
    mean_gap = max(0.6, (target - lead - 10 - speech) / len(clips))
    total = int(target * SR)
    mic, system = np.zeros(total, np.float32), np.zeros(total, np.float32)
    pos, spoken = int(lead * SR), []
    names = {"G": "Guillaume", "S": "Sarah", "M": "Marc"}
    for spk, a in clips:
        spoken.append(dict(person=names[spk], start=round(pos / SR, 2), end=round((pos + len(a)) / SR, 2)))
        if spk == "G":
            v = band(a, 2) * 0.7  # Bluetooth earbuds mic
            mic[pos:pos + len(v)] += v[: total - pos]
        else:
            v = band(a, 3) * (0.75 if spk == "S" else 0.55)  # VoIP, Marc a bit quieter
            system[pos:pos + len(v)] += v[: total - pos]
        pos += len(a) + int(random.uniform(0.3, 2 * mean_gap - 0.3) * SR)
    mic += np.random.randn(total).astype(np.float32) * 0.003  # room noise
    system += np.random.randn(total).astype(np.float32) * 0.0015
    write(out, mic, system, {"title": "", "started": "2026-10-23T10:00:00", "calendar": {
        "title": "Skyward Tales 2 — engine choice", "organizer": "Guillaume", "isOnlineMeeting": True,
        "start": "2026-10-23T08:00:00Z", "end": "2026-10-23T08:30:00Z",
        "attendees": [{"name": "Sarah Martin", "email": "sarah@studio.example"}, {"name": "Marc Dubois", "email": "marc@studio.example"}]}},
        spoken)
    print(f"engine: {len(clips)} turns, {speech / 60:.1f} min of speech, {target / 60:.0f} min")


if __name__ == "__main__":
    name, folder = sys.argv[1], Path(sys.argv[2])
    folder.mkdir(parents=True, exist_ok=True)
    make_engine(folder) if name == "engine" else make(name, folder)
