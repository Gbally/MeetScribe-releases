"""Turn a to-do's free-text due ("Friday", "next week", "30 Oct", "fin du mois") into a date,
relative to the meeting's date. Returns None when it can't be pinned down."""

import re
from datetime import date, timedelta

WEEKDAYS = {
    "monday": 0, "mon": 0, "lundi": 0, "tuesday": 1, "tue": 1, "tues": 1, "mardi": 1,
    "wednesday": 2, "wed": 2, "mercredi": 2, "thursday": 3, "thu": 3, "thur": 3, "thurs": 3, "jeudi": 3,
    "friday": 4, "fri": 4, "vendredi": 4, "saturday": 5, "sat": 5, "samedi": 5, "sunday": 6, "sun": 6, "dimanche": 6,
}
MONTHS = {
    "january": 1, "jan": 1, "janvier": 1, "february": 2, "feb": 2, "fevrier": 2, "février": 2, "march": 3, "mar": 3,
    "mars": 3, "april": 4, "apr": 4, "avril": 4, "may": 5, "mai": 5, "june": 6, "jun": 6, "juin": 6, "july": 7,
    "jul": 7, "juillet": 7, "august": 8, "aug": 8, "aout": 8, "août": 8, "september": 9, "sep": 9, "sept": 9,
    "septembre": 9, "october": 10, "oct": 10, "octobre": 10, "november": 11, "nov": 11, "novembre": 11,
    "december": 12, "dec": 12, "decembre": 12, "décembre": 12,
}


def _month_end(d: date) -> date:
    nxt = date(d.year + (d.month == 12), d.month % 12 + 1, 1)
    return nxt - timedelta(days=1)


def _next_weekday(base: date, wd: int, skip_week: bool = False) -> date:
    days = (wd - base.weekday()) % 7 or 7  # "Wednesday" said on a Wednesday = next week's
    # "next Friday" said on a Monday is the Friday after this one; but "next Wednesday" said on a
    # Friday is simply the coming Wednesday (this week's is already over).
    if skip_week and wd > base.weekday():
        days += 7
    return base + timedelta(days=days)


def parse_due(text: str, meeting: date) -> date | None:
    t = text.lower().strip()
    if not t or t in {"—", "-", "n/a", "none"}:
        return None
    t = re.sub(r"[*_()]", " ", t)

    m = re.search(r"(\d{4})-(\d{2})-(\d{2})", t)
    if m:
        return date(int(m[1]), int(m[2]), int(m[3]))
    if re.search(r"\b(today|tonight|eod|end of (the )?day|aujourd'?hui|ce soir|asap|immediately)\b", t):
        return meeting
    if re.search(r"\b(tomorrow|demain)\b", t):
        return meeting + timedelta(days=1)
    m = re.search(r"\bin (\d+) (day|week|month)s?\b|\bdans (\d+) (jour|semaine|mois)", t)
    if m:
        n = int(m[1] or m[3])
        unit = (m[2] or m[4])[0]
        return meeting + timedelta(days=n * (1 if unit in "dj" else 7 if unit in "ws" else 30))
    if re.search(r"\b(end of (the )?week|eow|fin de (la )?semaine|this week|cette semaine)\b", t):
        return _next_weekday(meeting, 4)
    if re.search(r"\b(end of (the )?month|eom|fin du mois|this month|ce mois)\b", t):
        return _month_end(meeting)
    if re.search(r"\b(next week|la semaine prochaine|semaine prochaine)\b", t):
        return meeting + timedelta(days=7 - meeting.weekday())  # next Monday
    if re.search(r"\b(next month|le mois prochain|mois prochain)\b", t):
        return _month_end(meeting) + timedelta(days=1)

    # "30 Oct", "October 30th", "30 octobre", "le 3 novembre"
    m = re.search(r"\b(\d{1,2})(?:st|nd|rd|th|er)?\s+(?:of\s+)?([a-zéû]+)", t) or None
    m2 = re.search(r"\b([a-zéû]+)\s+(\d{1,2})(?:st|nd|rd|th)?\b", t)
    for day_s, mon_s in ([(m[1], m[2])] if m else []) + ([(m2[2], m2[1])] if m2 else []):
        if mon_s in MONTHS:
            d = date(meeting.year, MONTHS[mon_s], min(int(day_s), 28 if MONTHS[mon_s] == 2 else 30 if MONTHS[mon_s] in (4, 6, 9, 11) else 31))
            return d if d >= meeting - timedelta(days=30) else d.replace(year=d.year + 1)
    # 30/10 or 30.10 (day first, European)
    m = re.search(r"\b(\d{1,2})[/.](\d{1,2})(?:[/.](\d{2,4}))?\b", t)
    if m:
        dd, mm = int(m[1]), int(m[2])
        if mm > 12 and dd <= 12:
            dd, mm = mm, dd
        if 1 <= mm <= 12 and 1 <= dd <= 31:
            year = int(m[3]) + (2000 if m[3] and len(m[3]) == 2 else 0) if m[3] else meeting.year
            try:
                d = date(year, mm, dd)
            except ValueError:
                return None
            return d if m[3] or d >= meeting - timedelta(days=30) else d.replace(year=d.year + 1)

    # "Friday", "next Friday", "by Thursday", "vendredi prochain"
    for word, wd in WEEKDAYS.items():
        if re.search(rf"\b{word}\b", t):
            nxt = bool(re.search(rf"\bnext {word}\b|\b{word} prochain\b", t))
            return _next_weekday(meeting, wd, skip_week=nxt)
    # "in October" → end of that month
    for word, mon in MONTHS.items():
        if len(word) > 3 and re.search(rf"\b{word}\b", t):
            d = _month_end(date(meeting.year, mon, 1))
            return d if d >= meeting else _month_end(date(meeting.year + 1, mon, 1))
    return None
