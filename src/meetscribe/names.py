"""Put names on "Speaker N" labels from the calendar invitations: when someone addresses an
invited person by name ("Sarah, can you…") and the same voice answers right after, or when a
speaker introduces themselves ("it's Marc", "c'est Marc"), that's evidence. A name is only used
with clear, repeated evidence; otherwise the label stays "Speaker N" for you to name."""

import re
import unicodedata
from collections import defaultdict

UNNAMED = re.compile(r"^Speaker \d+$")


def _plain(text: str) -> str:
    return unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()


def _close(word: str, name: str) -> bool:
    """Same name with one letter off ("Mark" for Marc, "Sara" for Sarah): Whisper's spelling."""
    if len(name) < 4 or word[:1] != name[:1] or abs(len(word) - len(name)) > 1 or word == name:
        return False
    if len(word) == len(name):
        return sum(a != b for a, b in zip(word, name)) == 1
    short, long_ = sorted((word, name), key=len)
    return any(long_[:i] + long_[i + 1:] == short for i in range(len(long_)))


def guess_names(utterances, invited: list[str], me: str) -> dict[str, str]:
    """{"Speaker 1": "Sarah", …} for the labels the transcript gives clear evidence about.
    `invited`: the calendar attendees (full names); the first name is used when it's unique."""
    first = {}
    for full in invited:
        parts = full.split()
        if not parts or _plain(parts[0]) == _plain(me.split()[0] if me else ""):
            continue
        first.setdefault(_plain(parts[0]), []).append(full)
    names = {k: (v[0].split()[0] if len(v) == 1 else v[0]) for k, v in first.items()}
    if not names:
        return {}

    def mentioned(text: str) -> list[str]:
        words = set(re.findall(r"[a-z]+", _plain(text)))
        return [k for k in names if k in words or any(_close(w, k) for w in words)]

    votes: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for i, u in enumerate(utterances):
        if not UNNAMED.match(u.speaker):
            continue
        t = _plain(u.text)
        for k in names:  # "it's Marc", "this is Marc", "c'est Marc", "ici Marc"
            if re.search(rf"\b(i'?m|i am|it'?s|this is|c'est|ici|moi c'est)\s+{re.escape(k)}\b", t):
                votes[u.speaker][k] += 3
        for k in mentioned(u.text):  # a speaker naming someone is (usually) not that person
            votes[u.speaker][k] -= 1
        if i and utterances[i - 1].speaker != u.speaker and u.start - utterances[i - 1].end < 8:
            tail = utterances[i - 1].text[-160:]  # "… Sarah, can you …?" → Sarah answers
            for k in mentioned(tail):
                votes[u.speaker][k] += 2

    out: dict[str, str] = {}
    used: set[str] = set()
    ranked = sorted(((score, label, k) for label, v in votes.items() for k, score in v.items()), reverse=True)
    for score, label, k in ranked:
        if label in out or k in used or score < 4:
            continue
        others = sorted((s for kk, s in votes[label].items() if kk != k), reverse=True)
        if others and others[0] > score / 2:  # not clearly this person
            continue
        rival = max((v.get(k, 0) for lb, v in votes.items() if lb != label), default=0)
        if rival > score / 2:  # another voice is just as likely to be them
            continue
        out[label] = names[k]
        used.add(k)
    return out
