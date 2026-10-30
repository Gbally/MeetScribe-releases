"""AMI scenario meetings → MeetScribe sessions (data/sessions/ID: transcript.json + truth.json).

The transcript is the corpus' manual one: each speaker's words grouped into turns (a pause of a
second or more ends one), in time order. Speakers are named by their role in the scenario
("Project Manager"…), as the annotators' summaries do. truth.json holds the annotated summary:
actions, decisions, abstract.

The split is fixed: DEV meetings are the ones looked at while changing the rules, TEST ones are
only scored, to check that a change helps beyond the meetings it was made on.
"""
import html
import json
import random
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORPUS = HERE / "data" / "ami"
OUT = HERE / "data" / "sessions"
ROLE = {"PM": "Project Manager", "ID": "Industrial Designer", "UI": "Interface Designer", "ME": "Marketing Expert"}
WORD = re.compile(r'<w [^>]*starttime="([\d.]+)" endtime="([\d.]+)"([^>]*)>([^<]*)</w>')
PAUSE = 1.0

# The 8 meetings of the first look (2026-10-29), then others picked at random (seeded).
FIRST = ["ES2006b", "ES2008b", "ES2013c", "IS1000c", "IS1008b", "TS3006a", "TS3011b", "TS3012b"]


def section(summary: str, name: str) -> list[str]:
    m = re.search(f"<{name}.*?</{name}>", summary, re.S)
    return [html.unescape(s).strip() for s in re.findall(r"<sentence[^>]*>(.*?)</sentence>", m.group(0), re.S)] if m else []


def split() -> tuple[list[str], list[str]]:
    """DEV: the first 8 and 12 more; TEST: 10 others. Scenario meetings (ES, IS, TS) with an
    annotated summary that has at least one action."""
    pool = []
    for f in sorted((CORPUS / "abstractive").glob("*.abssumm.xml")):
        mid = f.name.split(".")[0]
        if mid[:2] in ("ES", "IS", "TS") and mid not in FIRST and section(f.read_text(encoding="latin-1"), "actions"):
            pool.append(mid)
    random.Random(0).shuffle(pool)
    return FIRST + sorted(pool[:12]), sorted(pool[12:22])


def convert(mid: str) -> None:
    meetings = (CORPUS / "corpusResources" / "meetings.xml").read_text(encoding="latin-1")
    block = re.search(rf'observation="{mid}".*?</meeting>', meetings, re.S).group(0)
    roles = dict(re.findall(r'nxt_agent="(\w)"[^>]*role="(\w+)"', block))
    turns = []
    for agent, role in roles.items():
        f = CORPUS / "words" / f"{mid}.{agent}.words.xml"
        if not f.exists():
            continue
        cur = None
        for start, end, attrs, word in WORD.findall(f.read_text(encoding="latin-1")):
            start, end, word = float(start), float(end), html.unescape(word)
            punc = 'punc="true"' in attrs
            if cur and (punc or start - cur["end"] < PAUSE):
                cur["text"] += word if punc else " " + word
                cur["end"] = max(cur["end"], end)
            else:
                if cur:
                    turns.append(cur)
                cur = {"start": start, "end": end, "speaker": ROLE.get(role, role), "text": word, "lang": "en",
                       "track": "meeting"}
        if cur:
            turns.append(cur)
    turns.sort(key=lambda u: u["start"])
    utterances = []
    for u in turns:  # the same speaker twice in a row: one utterance
        if utterances and utterances[-1]["speaker"] == u["speaker"]:
            utterances[-1]["text"] += " " + u["text"]
            utterances[-1]["end"] = u["end"]
        else:
            utterances.append(u)
    summary = (CORPUS / "abstractive" / f"{mid}.abssumm.xml").read_text(encoding="latin-1")
    d = OUT / mid
    d.mkdir(parents=True, exist_ok=True)
    (d / "transcript.json").write_text(json.dumps(
        {"title": "", "languages": ["en"], "tracks": ["meeting"], "guessed_names": [],
         "duration": utterances[-1]["end"], "created": "2005-01-10T10:00:00", "utterances": utterances},
        indent=1, ensure_ascii=False))
    (d / "truth.json").write_text(json.dumps(
        {name: section(summary, name) for name in ("actions", "decisions", "abstract")}, indent=1))


if __name__ == "__main__":
    dev, test = split()
    for mid in dev + test:
        convert(mid)
    (OUT.parent / "split.json").write_text(json.dumps({"dev": dev, "test": test}, indent=1))
    print(f"{len(dev)} dev and {len(test)} test meetings in {OUT}")
