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
    out = []
    for line in lines:
        m = re.match(r"^\s*(?:[-*•]|\d+[.)])\s+(.*)$", line)
        text = (m.group(1) if m else line).strip()
        text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
        if text and not EMPTY.match(text) and not text.startswith("|"):
            out.append(text)
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
        if EMPTY.match(task):
            continue
        out.append({"owner": "" if EMPTY.match(owner) else owner, "task": task,
                    "due": "" if EMPTY.match(due) else due})
    if not out:  # model used bullets instead of a table
        out = [{"owner": "", "task": t, "due": ""} for t in _bullets(lines)]
    return out


def parse_notes(md: str) -> dict:
    sections: dict[str, list[str]] = {}
    current = None
    for line in md.splitlines():
        m = re.match(r"^#{1,4}\s+(.*)$", line)
        if m:
            current = m.group(1).strip().lower()
            sections[current] = []
        elif current:
            sections[current].append(line)

    def get(*names):
        for key, lines in sections.items():
            if any(n in key for n in names):
                return lines
        return []

    return {
        "summary": _bullets(get("summary")),
        "decisions": _bullets(get("decision")),
        "actions": _actions(get("action", "to-do", "todo")),
        "questions": _bullets(get("question")),
    }
