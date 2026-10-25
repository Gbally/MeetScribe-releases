"""Scores a notes.json against a test meeting's truth → dict of metrics (the 30-min "engine"
meeting has its own truth in engine_score.py)."""
import json, re, sys, unicodedata
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from scenarios import SCENARIOS

def plain(t):
    t = re.sub(r"[‐-―−]", "-", t)  # en/em dashes: "6–8 weeks" must stay "6-8"
    return unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode().lower()
def has(text, kws): return any(re.search(k, plain(text)) for k in kws)

def score(scenario, notes_path, transcript_path=None):
    t = SCENARIOS[scenario]["truth"]; n = json.load(open(notes_path)); acts = n.get("actions", [])
    # A task counts by its content (the right task, whoever it's labelled for) and, separately,
    # whether it carries the right person's name — the first measures the notes model, the
    # second the naming of the voices too.
    content, named, used, wrong_due, right_due = set(), set(), set(), 0, 0
    optional = {k for k, x in enumerate(t["tasks"]) if x[3].startswith("~")}  # fine to list, fine to miss
    for k, (owners, kws, due, _) in enumerate(t["tasks"]):
        cand = [i for i, a in enumerate(acts) if i not in used and has(a["task"], kws)]
        if not cand:
            continue
        own = [i for i in cand if plain(acts[i].get("owner", "")).split()[:1]
               and plain(acts[i]["owner"]).split()[0] in {plain(o) for o in owners}]
        unnamed = [i for i in cand if re.match(r"speaker \d+", plain(acts[i].get("owner", "")))]
        pick = (own or unnamed or [None])[0]
        if pick is None:
            continue  # only rows given to someone else: not this task
        used.add(pick)
        if k in optional:
            continue
        content.add(k)
        if own:
            named.add(k)
        d = acts[pick].get("due_date")
        if due and d == due:
            right_due += 1
        elif due and d and d != due:
            wrong_due += 1  # a deadline where none was said is not counted against the notes
    dec = n.get("decisions", [])
    secs = {s["title"].lower(): s["items"] for s in n.get("sections", [])}
    sec = lambda *names: [i for k, v in secs.items() if any(x in k for x in names) for i in v]
    everything = n.get("summary", []) + dec + n.get("questions", []) + [i for v in secs.values() for i in v]
    figs_src = sec("figure") or everything
    out = dict(
        tasks_found=len(content), tasks_named=len(named), tasks_total=len(t["tasks"]) - len(optional),
        rows=len(acts) - (len(used) - len(content)),  # optional tasks listed: neither credit nor noise
        noise=len(acts) - len(used), wrong_due=wrong_due, right_due=right_due,
        dues_total=sum(1 for k, x in enumerate(t["tasks"]) if x[2] and k not in optional),
        decisions=sum(1 for _, kws in t["decisions"] if any(has(x, kws) for x in dec)), decisions_total=len(t["decisions"]),
        dec_rows=len(dec), dec_matched=sum(1 for x in dec if any(has(x, kws) for _, kws in t["decisions"])),
        topics=sum(1 for _, kws in t["topics"] if any(has(x, kws) for x in n.get("summary", []))), topics_total=len(t["topics"]),
        figures=sum(1 for _, kws in t["figures"] if any(has(x, kws) for x in figs_src)), figures_total=len(t["figures"]),
        risks=sum(1 for _, kws in t["risks"] if any(has(x, kws) for x in (sec("risk", "concern", "blocker") or everything) + n.get("questions", []))),
        risks_total=len(t["risks"]),
        missing=[x[3] for k, x in enumerate(t["tasks"]) if k not in content and k not in optional],
    )
    if "ideas" in t:
        src = sec("idea") + sec("option") or everything  # the general notes have no Ideas section
        out.update(ideas=sum(1 for _, kws in t["ideas"] if any(has(x, kws) for x in src)), ideas_total=len(t["ideas"]))
    if "strengths" in t:
        src = sec("strength") or everything
        out.update(strengths=sum(1 for _, kws in t["strengths"] if any(has(x, kws) for x in src)), strengths_total=len(t["strengths"]))
    if transcript_path and Path(transcript_path).exists():
        tr = json.load(open(transcript_path)); labels = {u["speaker"] for u in tr["utterances"]} - {SCENARIOS[scenario]["me"]}
        names = {plain(x.split()[0]) for x in SCENARIOS[scenario]["calendar"]}
        out.update(speakers_found=len(labels), speakers_total=t["speakers"], named=sum(1 for l in labels if plain(l) in names))
    return out

if __name__ == "__main__":
    print(json.dumps(score(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None), ensure_ascii=False))


def score_engine(notes_path) -> dict:
    """The 30-min meeting, in the same metrics (its scorer counts a task only with the right owner)."""
    import engine_score

    e = engine_score.score(notes_path)
    n = json.load(open(notes_path))
    dec = n.get("decisions", [])
    m = dict(tasks_found=e["tasks_found"], tasks_named=e["tasks_found"], tasks_total=len(engine_score.TASKS), rows=e["rows"],
             wrong_due=e["wrong_due"], right_due=0, dues_total=0, decisions=e["decisions"], decisions_total=len(engine_score.DECISIONS),
             dec_rows=len(dec), dec_matched=sum(1 for x in dec if any(engine_score.has(x, *kws) for _, kws in engine_score.DECISIONS)),
             topics=e["topics"], topics_total=len(engine_score.TOPICS), figures=e["figures"], figures_total=len(engine_score.FIGURES),
             risks=e["risks"], risks_total=len(engine_score.RISKS), missing=e["missing"])
    if n.get("template") == "workshop":
        m.update(ideas=min(e["ideas"], 6), ideas_total=6)
    return m
