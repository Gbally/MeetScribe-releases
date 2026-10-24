"""Words Whisper should spell right, learned from earlier meetings: the product, client and
project names that keep coming back in a recurring meeting ("Godot", "Northwind", "W4"), and
the colleagues you named in a small voice library. Added to the vocabulary you typed and the
calendar's names — never instead of them."""

import json
import re
from collections import Counter
from pathlib import Path

# Capitalised words that say nothing about a team's jargon.
COMMON = set("""i a an the we you he she it they this that these those our my your his her their there here
what when where who why how yes no ok okay so and but or if then also next last first second third
monday tuesday wednesday thursday friday saturday sunday january february march april may june july
august september october november december q1 q2 q3 q4 am pm eod asap tbd fyi n/a none summary
decisions decision action actions items open questions risks risk key figures dates updates blockers
feedback growth ideas options client requests commitments concerns strengths background title meeting
team notes speaker speakers je tu il elle nous vous ils elles le la les un une des et ou mais donc
lundi mardi mercredi jeudi vendredi samedi dimanche janvier février mars avril mai juin juillet août
septembre octobre novembre décembre résumé décisions tâches questions ouvertes risques réunion""".split())


# Verbs to-dos start with ("Ask W4 for a quote"): capitalised, but not names.
VERBS = set("""ask send prepare check review write update book call share contact fix test schedule finish
create publish plan organize organise confirm get make set follow draft submit discuss find meet move add
remove deploy validate start keep give take talk tell present build run look see do go use try buy pay
envoyer préparer vérifier écrire contacter faire mettre organiser planifier tester valider demander
appeler partager publier relancer trouver lancer finir terminer présenter regarder""".split())


def _terms(lines: list[str]) -> set[str]:
    """Names and jargon: capitalised ("Godot" — but not a to-do's verb: "Ask W4…") or with
    capitals/digits inside ("PS5", "iOS", "W4")."""
    found = set()
    for sentence in (s for line in lines for s in re.split(r"(?<=[.!?:;])\s+", line)):
        for i, w in enumerate(re.findall(r"\b\w[\w'.-]*\b", sentence)):
            w = w.strip(".'-")
            if len(w) < 2 or w.lower() in COMMON or w.isdigit():
                continue
            if re.search(r"[a-z][A-Z]|[A-Za-z]\d|\d[A-Za-z]", w) or (w[0].isupper() and (i or w.lower() not in VERBS)):
                found.add(w)
    return found


def _same_series(info: dict, calendar: dict) -> bool:
    """An earlier meeting of the same recurring meeting: same calendar title, or 2+ of the same people."""
    other = info.get("calendar") or {}
    if calendar.get("title") and other.get("title", "").strip().lower() == calendar["title"].strip().lower():
        return True
    people = lambda c: {(a.get("email") or a.get("name") or "").lower() for a in c.get("attendees") or []} - {""}
    return len(people(other) & people(calendar)) >= 2


def learned(notes_dir: Path, calendar: dict, known: list[str], library: list[str], me: str = "",
            limit: int = 12, history: int = 8) -> list[str]:
    """Up to `limit` words for this meeting. `known`: what Whisper is told already (left out);
    `library`: the names in the voice library (only when it's a small team's)."""
    out: list[str] = []
    told = {k.lower() for x in known for k in re.findall(r"[\w'-]+", x)}
    if 0 < len(library) <= 15:
        out += [n for n in library if n.lower() != me.lower() and n.split()[0].lower() not in told]
    if calendar and notes_dir.is_dir():
        past = []
        for folder in sorted((p for p in notes_dir.iterdir() if p.is_dir()), reverse=True):
            try:
                info = json.loads((folder / "meeting.json").read_text())
                notes = json.loads((folder / "notes.json").read_text())
            except (OSError, ValueError):
                continue
            if _same_series(info, calendar):
                past.append(_terms([notes.get("title", "")] + notes.get("summary", []) + notes.get("decisions", [])
                                   + [a.get("task", "") for a in notes.get("actions", [])]))
            if len(past) >= history:
                break
        # Said in at least two of those meetings: a real recurring name, not a one-off typo.
        seen = Counter(t for terms in past for t in terms)
        out += [t for t, n in seen.most_common() if n >= 2 and t.lower() not in told]
    unique = list(dict.fromkeys(out))
    return unique[:limit]
