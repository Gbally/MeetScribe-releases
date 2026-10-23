"""Parse the LLM's Markdown notes into structured data (notes.json) for the app."""

import re

EMPTY = re.compile(r"^(none( recorded)?|n/?a|—|-)\.?$", re.I)


def split_title(md: str) -> tuple[str, str]:
    """Remove the leading 'Title: …' line the model is asked to write."""
    lines = md.strip().splitlines()
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        m = re.match(r"^\W*title\W*:\s*(.+)$", line.strip(), re.I)
        if m:
            title = m.group(1).strip().strip("*#\"' ")
            return title, "\n".join(lines[i + 1:]).strip()
        break
    return "", md.strip()


def _bullets(lines: list[str]) -> list[str]:
    out, seen = [], set()
    for line in lines:
        m = re.match(r"^\s*(?:[-*•]|\d+[.)])\s+(.*)$", line)
        text = (m.group(1) if m else line).strip()
        text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
        if text and not EMPTY.match(text) and not text.startswith("|") and text.lower() not in seen:
            seen.add(text.lower())  # a line repeated (a model stuck in a loop) is kept once
            out.append(text)
    return out


def _table_rows(lines: list[str]) -> list[str]:
    """A Markdown table in a section (e.g. Options compared) → one line per row:
    "Unity — For: … — Against: … — Status: …"."""
    rows = [[c.strip() for c in l.strip().strip("|").split("|")] for l in lines
            if l.strip().startswith("|") and not set(l.strip()) <= set("|-: ")]
    if len(rows) < 2:
        return []
    header, out = rows[0], []
    for r in rows[1:]:
        cells = [f"{h}: {c}" if i and h else c for i, (h, c) in enumerate(zip(header, r)) if c and not EMPTY.match(c)]
        if cells:
            out.append(" — ".join(cells))
    return out


def _actions(lines: list[str]) -> list[dict]:
    out = []
    for line in lines:
        line = line.strip()
        if not line.startswith("|") or set(line) <= set("|-: "):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 2 or cells[0].lower() == "owner":
            continue
        owner, task = cells[0], cells[1]
        due = cells[2] if len(cells) > 2 else ""
        at = cells[3] if len(cells) > 3 and re.fullmatch(r"\d+:\d{2}(:\d{2})?", cells[3]) else ""
        if EMPTY.match(task):
            continue
        item = {"owner": "" if EMPTY.match(owner) else owner, "task": task, "due": "" if EMPTY.match(due) else due}
        if at:
            item["at"] = at  # where it was said in the transcript
        out.append(item)
    if not out:  # model used bullets instead of a table
        out = [{"owner": "", "task": t, "due": ""} for t in _bullets(lines)]
    return out


def _section_key(heading: str) -> str:
    """A section heading, lowercased, with the usual French names mapped to the English ones
    (in case a model translates the headings)."""
    import unicodedata

    key = heading.strip().lower()
    plain = unicodedata.normalize("NFKD", key).encode("ascii", "ignore").decode()
    for french, english in (("resume", "summary"), ("synthese", "summary"), ("decision", "decisions"),
                            ("taches", "action items"), ("actions a mener", "action items"),
                            ("a faire", "action items"), ("questions ouvertes", "open questions")):
        if plain.startswith(french):
            return english
    return key


def parse_notes(md: str) -> dict:
    sections: dict[str, list[str]] = {}
    current = None
    for line in md.splitlines():
        m = re.match(r"^#{1,4}\s+(.*)$", line)
        if m:
            current = _section_key(m.group(1))
            sections[current] = []
        elif current:
            sections[current].append(line)

    def get(*names):
        for key, lines in sections.items():
            if any(n in key for n in names):
                return lines
        return []

    base = ("summary", "decision", "action", "to-do", "todo", "question")
    extra = [{"title": title_case(k), "items": _table_rows(v) + _bullets(v)} for k, v in sections.items()
             if not any(n in k for n in base)]
    return {
        "summary": _bullets(get("summary")),
        "decisions": _bullets(get("decision")),
        "actions": _actions(get("action", "to-do", "todo")),
        "questions": _bullets(get("question")),
        "sections": [x for x in extra if x["items"]],
    }


def title_case(heading: str) -> str:
    return heading[:1].upper() + heading[1:]


def render_markdown(notes: dict, duration_text: str) -> str:
    """notes.md from notes.json — the single format, also after edits made in the app."""
    from datetime import datetime

    created = datetime.fromisoformat(notes["date"])
    out = [f"# {notes['title']}", "",
           f"- **Date:** {created:%Y-%m-%d %H:%M}",
           f"- **Duration:** {duration_text}",
           f"- **Participants:** {', '.join(notes.get('participants', []))}",
           "- **Full transcript:** [transcript.md](transcript.md)", ""]

    def bullets(title, items, empty="None recorded."):
        out.extend([f"## {title}", ""] + ([f"- {i}" for i in items] or [empty]) + [""])

    bullets("Summary", notes.get("summary", []))
    for sec in notes.get("sections", []):
        bullets(sec["title"], sec["items"], "None.")
    bullets("Decisions", notes.get("decisions", []))
    out += ["## Action items", ""]
    if notes.get("actions"):
        out += ["| Owner | Task | Due | Said at |", "|---|---|---|---|"]
        for a in notes["actions"]:
            due = a.get("due") or "—"
            if a.get("due_date") and a["due_date"] not in due:
                due += f" ({a['due_date']})"
            out.append(f"| {a.get('owner') or '—'} | {a['task']} | {due} | {a.get('at') or '—'} |")
    else:
        out.append("None recorded.")
    out.append("")
    bullets("Open questions", notes.get("questions", []), "None.")
    return "\n".join(out)
