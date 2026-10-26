"""Turn a to-do's free-text due ("Friday", "next week", "30 Oct", "fin du mois", "el lunes",
"bis Freitag", "até sexta", "entro mercoledì") into a date, relative to the meeting's date — in
English, French, Spanish, German, Portuguese and Italian. Returns None when it can't be pinned down."""

import re
from datetime import date, timedelta

WEEKDAYS = {
    "monday": 0, "mon": 0, "lundi": 0, "tuesday": 1, "tue": 1, "tues": 1, "mardi": 1,
    "wednesday": 2, "wed": 2, "mercredi": 2, "thursday": 3, "thu": 3, "thur": 3, "thurs": 3, "jeudi": 3,
    "friday": 4, "fri": 4, "vendredi": 4, "saturday": 5, "sat": 5, "samedi": 5, "sunday": 6, "sun": 6, "dimanche": 6,
    # es, de, pt, it (with and without accents: models drop them)
    "lunes": 0, "martes": 1, "miércoles": 2, "miercoles": 2, "jueves": 3, "viernes": 4, "sábado": 5, "sabado": 5, "domingo": 6,
    "montag": 0, "dienstag": 1, "mittwoch": 2, "donnerstag": 3, "freitag": 4, "samstag": 5, "sonntag": 6,
    "segunda": 0, "segunda-feira": 0, "terça": 1, "terca": 1, "terça-feira": 1, "terca-feira": 1, "quarta": 2,
    "quarta-feira": 2, "quinta": 3, "quinta-feira": 3, "sexta": 4, "sexta-feira": 4,
    "lunedì": 0, "lunedi": 0, "martedì": 1, "martedi": 1, "mercoledì": 2, "mercoledi": 2, "giovedì": 3, "giovedi": 3,
    "venerdì": 4, "venerdi": 4, "sabato": 5, "domenica": 6,
}
MONTHS = {
    "january": 1, "jan": 1, "janvier": 1, "february": 2, "feb": 2, "fevrier": 2, "février": 2, "march": 3, "mar": 3,
    "mars": 3, "april": 4, "apr": 4, "avril": 4, "may": 5, "mai": 5, "june": 6, "jun": 6, "juin": 6, "july": 7,
    "jul": 7, "juillet": 7, "august": 8, "aug": 8, "aout": 8, "août": 8, "september": 9, "sep": 9, "sept": 9,
    "septembre": 9, "october": 10, "oct": 10, "octobre": 10, "november": 11, "nov": 11, "novembre": 11,
    "december": 12, "dec": 12, "decembre": 12, "décembre": 12,
    "enero": 1, "febrero": 2, "marzo": 3, "abril": 4, "mayo": 5, "junio": 6, "julio": 7, "agosto": 8, "septiembre": 9,
    "setiembre": 9, "octubre": 10, "noviembre": 11, "diciembre": 12,
    "januar": 1, "februar": 2, "märz": 3, "maerz": 3, "marz": 3, "juni": 6, "juli": 7, "oktober": 10, "dezember": 12,
    "janeiro": 1, "fevereiro": 2, "março": 3, "marco": 3, "maio": 5, "junho": 6, "julho": 7, "setembro": 9, "outubro": 10,
    "novembro": 11, "dezembro": 12,
    "gennaio": 1, "febbraio": 2, "aprile": 4, "maggio": 5, "giugno": 6, "luglio": 7, "settembre": 9, "ottobre": 10,
    "dicembre": 12,
}
# Small numbers said as words ("in two weeks", "dentro de dos semanas", "in zwei Wochen").
NUMBERS = {"one": 1, "two": 2, "three": 3, "four": 4, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "uno": 1,
           "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "ein": 1, "eine": 1, "einem": 1, "einer": 1, "zwei": 2, "drei": 3,
           "vier": 4, "um": 1, "uma": 1, "dois": 2, "duas": 2, "três": 3, "quatro": 4, "due": 2, "tre": 3, "quattro": 4}
# "next Friday": the word for "next" before or after the weekday.
NEXT = r"next|prochain|próximo|proximo|próxima|proxima|que viene|que vem|nächsten|naechsten|nächste|naechste|prossimo|prossima"


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


# Chinese and Japanese: no spaces, so these are found anywhere in the text.
CJK_WEEKDAYS = {"月曜": 0, "火曜": 1, "水曜": 2, "木曜": 3, "金曜": 4, "土曜": 5, "日曜": 6,
                "周一": 0, "周二": 1, "周三": 2, "周四": 3, "周五": 4, "周六": 5, "周日": 6, "周天": 6}
CJK_WEEKDAYS |= {f"{p}{d}": n for p in ("星期", "礼拜") for d, n in zip("一二三四五六日天", (0, 1, 2, 3, 4, 5, 6, 6))}


def _chinese_japanese(t: str, meeting: date) -> date | None:
    m = re.search(r"(\d{1,2})月(\d{1,2})[日号號]", t)  # "11月12日"
    if m and 1 <= int(m[1]) <= 12 and int(m[2]) >= 1:
        first = date(meeting.year, int(m[1]), 1)
        d = min(first + timedelta(days=int(m[2]) - 1), _month_end(first))
        return d if d >= meeting - timedelta(days=30) else date(d.year + 1, d.month, d.day)
    if re.search(r"明日|明天", t):  # before "today": "明日の午後" is tomorrow afternoon
        return meeting + timedelta(days=1)
    if re.search(r"今日|今天|本日|今晚|今夜|今朝", t):
        return meeting
    if re.search(r"月末|月底", t):
        return _month_end(meeting)
    found = [(t.find(w), w, n) for w, n in CJK_WEEKDAYS.items() if w in t]
    if found:
        pos, word, wd = min(found)
        nxt = bool(re.search(r"(来週の?|下周|下星期|下个?礼拜)" + re.escape(word), t))
        return _next_weekday(meeting, wd, skip_week=nxt)
    if re.search(r"来週|下周|下星期|下个?礼拜", t):
        return meeting + timedelta(days=7 - meeting.weekday())
    if re.search(r"今週中|今週|这周|本周|週末|周末", t):
        return _next_weekday(meeting, 4)
    return None


def parse_due(text: str, meeting: date) -> date | None:
    t = text.lower().strip()
    if not t or t in {"—", "-", "n/a", "none"}:
        return None
    t = re.sub(r"[*_()]", " ", t)

    m = re.search(r"(\d{4})-(\d{2})-(\d{2})", t)
    if m:
        return date(int(m[1]), int(m[2]), int(m[3]))
    cjk = _chinese_japanese(t, meeting)
    if cjk:
        return cjk
    if re.search(r"\b(today|tonight|eod|end of (the )?day|this (morning|afternoon|evening)|aujourd'?hui|ce soir|ce matin|"
                 r"cet apr[eè]s[- ]?midi|ce midi|asap|immediately|"
                 r"hoy|esta (mañana|manana|tarde|noche)|hoje|hoje à tarde|esta manhã|esta manha|heute|oggi|stamattina|"
                 r"stasera|stanotte|oggi pomeriggio|questo pomeriggio)\b", t):
        return meeting
    if re.search(r"\b(tomorrow|demain|amanhã|amanha|domani)\b", t) or re.search(
            r"(?<!esta )(?<!la )(?<!por la )\b(mañana|manana)\b", t) or re.search(r"(?<!heute )\bmorgen\b", t):
        return meeting + timedelta(days=1)  # Spanish "mañana" is also "morning", German "Morgen" too
    m = re.search(r"\b(?:in|dans|en|dentro de|em|daqui a|tra|fra) (\d+|[a-zêé]+) (day|week|month|jour|semaine|mois|"
                  r"d[ií]a|semana|mes|tag|woche|monat|dia|m[eê]s|giorn|settiman|mes)", t)
    if m and (m[1].isdigit() or m[1] in NUMBERS):
        n = int(m[1]) if m[1].isdigit() else NUMBERS[m[1]]
        unit = m[2]
        days = 7 if unit.startswith(("week", "semai", "seman", "woch", "settim")) else 30 if unit.startswith(("mo", "me", "mê")) else 1
        return meeting + timedelta(days=n * days)
    if re.search(r"\b(end of (the )?week|eow|fin de (la )?semaine|this week|cette semaine|finales de (la )?semana|"
                 r"final de (la )?semana|esta semana|ende der woche|diese woche|dieser woche|fim da semana|final da semana|"
                 r"fine (della )?settimana|questa settimana)\b", t):
        return _next_weekday(meeting, 4)
    if re.search(r"\b(end of (the )?month|eom|fin du mois|this month|ce mois|fin de mes|finales de mes|final de mes|este mes|"
                 r"monatsende|ende des monats|ende monat|diesen monat|fim do m[eê]s|final do m[eê]s|este m[eê]s|"
                 r"fine (del )?mese|questo mese)\b", t):
        return _month_end(meeting)
    if re.search(r"\b(next week|la semaine prochaine|semaine prochaine|la semana que viene|la pr[oó]xima semana|"
                 r"semana que vem|pr[oó]xima semana|n[aä]chste woche|naechste woche|n[aä]chster woche|"
                 r"la settimana prossima|settimana prossima|la prossima settimana|prossima settimana)\b", t):
        return meeting + timedelta(days=7 - meeting.weekday())  # next Monday
    if re.search(r"\b(next month|le mois prochain|mois prochain|el mes que viene|el pr[oó]ximo mes|n[aä]chsten monat|"
                 r"m[eê]s que vem|pr[oó]ximo m[eê]s|il mese prossimo|mese prossimo|il prossimo mese)\b", t):
        return _month_end(meeting) + timedelta(days=1)

    # "30 Oct", "October 30th", "30 octobre", "le 3 novembre", "12 de noviembre", "12. November"
    m = re.search(r"\b(\d{1,2})(?:st|nd|rd|th|er|º|\.)?\s+(?:of\s+|de\s+)?([a-zà-ü]+)", t) or None
    m2 = re.search(r"\b([a-zà-ü]+)\s+(\d{1,2})(?:st|nd|rd|th)?\b", t)
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

    # "Friday", "next Friday", "by Thursday", "vendredi prochain", "el próximo viernes", "nächsten Freitag"
    found = [(m.start(), -len(word), word, wd) for word, wd in WEEKDAYS.items() for m in re.finditer(rf"\b{word}\b", t)]
    if found:  # the first one said ("Tuesday to Thursday" → Tuesday); "segunda-feira" rather than "segunda"
        _, _, word, wd = min(found)
        nxt = bool(re.search(rf"\b({NEXT})\s+{word}\b|\b{word}\s+({NEXT})\b", t))
        return _next_weekday(meeting, wd, skip_week=nxt)
    # "in October" → end of that month
    for word, mon in MONTHS.items():
        if len(word) > 3 and re.search(rf"\b{word}\b", t):
            d = _month_end(date(meeting.year, mon, 1))
            return d if d >= meeting else _month_end(date(meeting.year + 1, mon, 1))
    return None
