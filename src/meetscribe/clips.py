"""Short voice clips of each speaker (clips/*.wav + clips.json), so you can hear who is who
when naming speakers. Made while processing, so they exist even if the full audio is deleted."""

import json
import math
import shutil
from pathlib import Path

import numpy as np
import soundfile as sf

SR = 16_000
MAX_CLIP = 8.0      # seconds
PER_SPEAKER = 3


def make_clips(session: Path, utterances, audio_by_track: dict[str, np.ndarray]) -> None:
    out_dir = session / "clips"
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir()
    index: dict[str, list[dict]] = {}
    n = 0
    by_speaker: dict[str, list] = {}
    for u in utterances:
        by_speaker.setdefault(u.speaker, []).append(u)

    for speaker, utts in by_speaker.items():
        # The longest clear sentences, kept in chronological order.
        good = [u for u in utts if u.end - u.start >= 1.5 and len(u.text.split()) >= 4]
        good.sort(key=lambda u: min(u.end - u.start, MAX_CLIP), reverse=True)
        picked = sorted(good[:PER_SPEAKER], key=lambda u: u.start)
        for u in picked:
            audio = audio_by_track.get(u.track)
            if audio is None:  # older transcripts: no track recorded
                audio = next(iter(audio_by_track.values()), None)
            if audio is None:
                continue
            start, end = max(0.0, u.start - 0.2), min(u.end, u.start + MAX_CLIP) + 0.3
            seg = audio[int(start * SR): int(end * SR)].astype(np.float32)
            if seg.size < SR:
                continue
            peak = float(np.max(np.abs(seg))) or 1.0
            seg = seg * min(0.9 / peak, 20.0)  # make quiet voices audible
            n += 1
            name = f"{n}.wav"
            sf.write(out_dir / name, seg, SR, subtype="PCM_16")
            # Text of the part we actually play (the clip may stop mid-sentence).
            words = u.text.split()
            ratio = min(1.0, (end - start) / max(u.end - u.start, 0.1))
            shown = " ".join(words[: max(1, math.ceil(len(words) * ratio))])
            if ratio < 1:
                shown += " …"
            index.setdefault(speaker, []).append({"file": f"clips/{name}", "start": round(u.start, 2), "text": shown})
    (session / "clips.json").write_text(json.dumps(index, indent=1, ensure_ascii=False))


def rename_clips(session: Path, mapping: dict[str, str]) -> None:
    path = session / "clips.json"
    if not path.exists():
        return
    index = json.loads(path.read_text())
    out: dict[str, list] = {}
    for speaker, clips in index.items():
        out.setdefault(mapping.get(speaker, speaker), []).extend(clips)
    path.write_text(json.dumps(out, indent=1, ensure_ascii=False))
