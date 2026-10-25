# Scores one notes.json against the stress-test scenario's ground truth.
import json, re, sys, unicodedata

def plain(t):
    return unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode().lower()

def has(text, *alts):
    t = plain(text)
    return any(re.search(a, t) for a in alts)

# (id, owners accepted, keyword regexes (any), due ISO or None, description)
TASKS = [
    ("w4quote", {"sarah"}, [r"\bw4", r"port quote", r"devis"], {"2026-10-30", "2026-10-31"}, "Sarah: W4 Games quote by Fri 31"),
    ("w4csharp", {"sarah"}, [r"c#|c sharp|csharp"], None, "Sarah: ask W4 about C# on consoles"),
    ("protos", {"marc"}, [r"prototype", r"vertical slice"], {"2026-11-14"}, "Marc: both prototypes by Nov 14"),
    ("julie", {"marc"}, [r"julie"], None, "Marc: ask Julie to help with netcode"),
    ("costs", {"guillaume"}, [r"cost", r"spreadsheet", r"tableau"], {"2026-11-10"}, "Guillaume: 3-year cost comparison by Nov 10"),
    ("invite", {"guillaume"}, [r"invit"], None, "Guillaume: send the Nov 20 invitation"),
    ("shaders", {"marc"}, [r"shader", r"asset"], None, "Marc: add asset/shader migration to the doc"),
    ("export", {"marc"}, [r"export"], None, "Marc: measure export time in both engines"),
    ("xplay", {"marc"}, [r"cross.?play", r"plugin"], None, "Marc: test the cross-play plugin"),
    ("mods", {"sarah"}, [r"\bmod"], None, "Sarah: tell publisher mods = PC, post-launch"),
    ("demo", {"sarah"}, [r"\bdemo\b(?!.*camera)"], None, "Sarah: discuss demo date with publisher after Nov 20"),
    ("artists", {"marc"}, [r"artist", r"scene"], None, "Marc: test scene for the artists"),
    ("budget", {"sarah"}, [r"budget", r"training", r"formation"], None, "Sarah: block the €5k training budget"),
    ("criteria", {"sarah"}, [r"criteri", r"grid", r"grille"], {"2026-11-17"}, "Sarah: criteria grid by Nov 17"),
    ("netdoc", {"julie", "marc", "thomas"}, [r"network|reseau|netcode", r"document"], {"2026-12-15"}, "Julie (via Marc): document network code, train Thomas by Dec 15"),
    ("switch1", {"marc"}, [r"switch 1|switch one|kit"], None, "Marc: test on the Switch 1 kit"),
    ("qa", {"sarah"}, [r"\bqa\b", r"montreal", r"vendor", r"prestataire", r"quality"], None, "Sarah: write to the QA vendor next week"),
    ("publisher", {"sarah"}, [r"publisher|editor|editeur"], None, "Sarah: tell publisher about the Nov 20 decision + estimate"),
    ("allhands", {"sarah", "marc"}, [r"team meeting", r"friday", r"all.?hands", r"camera"], None, "Friday 16:00 team meeting (Sarah process, Marc demo)"),
]
DECISIONS = [
    ("custom engine dropped", [r"custom", r"own engine", r"in.?house"]),
    ("Unreal kept as fallback", [r"unreal.*(fallback|backup|plan b)", r"(fallback|backup).*unreal"]),
    ("Unity vs Godot decided via prototypes", [r"prototype"]),
    ("final decision on Nov 20", [r"20(th)? nov|nov(ember)? 20"]),
    ("mods: PC only, after launch", [r"\bmod"]),
    ("€5k training budget blocked", [r"5[ ,.]?000|5k"]),
    ("5 evaluation criteria", [r"criteri"]),
    ("<60 fps on Switch = stay on Unity", [r"60"]),
    ("engine-independent tools after Nov 20", [r"independent|agnostic|dialogue|quest"]),
    ("demo date depends on the engine", [r"\bdemo"]),
    ("team meeting Friday 16:00", [r"friday|team meeting|16"]),
]
DECISION_ERRORS = [r"godot (4 )?(is |has been )?(selected|chosen|adopted)", r"unity (is )?(dropped|rejected)"]
TOPICS = [
    ("Unity", [r"unity"]), ("Unreal", [r"unreal"]), ("Godot", [r"godot|goated"]), ("Custom engine", [r"custom"]),
    ("Prototypes", [r"prototype|vertical slice"]), ("Team / survey / training", [r"survey|9 |training|formation|artist"]),
    ("Planning / Julie / Switch kits", [r"julie|planning|timeline|schedule|kit"]),
    ("Build pipeline, cross-play, mods, QA, demo", [r"build|cross.?play|\bmod|qa|demo"]),
]
FIGURES = [
    ("$2,200 per seat", [r"2[ ,.]?200"]), ("~$30k/year licences", [r"30[ ,.]?000|30k"]), ("$4M revenue", [r"4 ?m|4 million|4,000,000"]),
    ("~$150k Unreal royalty", [r"150[ ,.]?000|150k"]), ("5% royalty", [r"5 ?%"]), ("14 people", [r"\b14 (people|person|members)|team of 14|14-person"]),
    ("18–24 months custom engine", [r"18"]), ("survey 9/3/2", [r"\b9\b.*\b3\b|nine"]), ("€12k training budget", [r"12[ ,.]?000|12k"]),
    ("€5k training", [r"5[ ,.]?000|5k"]), ("3 weeks shaders", [r"3 weeks|three weeks"]), ("level editor 1 month (6 months originally)", [r"6 months|six months|1 month|one month"]),
    ("builds 40–60 min vs <2 min", [r"40 min|2 min|hour"]), ("40% wishlists from the demo", [r"40 ?%"]), ("release Q4 2027", [r"2027|q4|fourth quarter"]),
    ("first playable in June", [r"june|juin"]), ("Julie away from Dec 15, 2 months", [r"15 dec|dec(ember)? 15"]), ("W4 quote Oct 31", [r"31"]),
    ("Nov 10 / 14 / 17", [r"nov(ember)? (10|14|17)|(10|14|17)(th)? nov"]), ("netcode 2–3 months", [r"2.?3 months|two to three months"]),
]
RISKS = [
    ("Julie's leave", [r"julie"]), ("cross-play plugin untested", [r"cross.?play|plugin"]), ("Switch 2 kits date unknown", [r"kit"]),
    ("Switch performance / 4 players", [r"performance|4.player|four.player"]), ("QA vendor and Godot", [r"\bqa\b|vendor|montreal"]),
    ("netcode effort", [r"netcode|network"]), ("demo / wishlists timing", [r"demo|wishlist"]), ("hiring Godot developers", [r"hir|recruit"]),
]
OPTIONS = {"unity": {"open", "still", "review", "under", "evaluat", "baseline"}, "unreal": {"fallback", "backup"},
           "godot": {"open", "still", "evaluat", "under", "consider", "active"}, "custom": {"reject", "drop", "abandon", "out", "not"}}
FACT_ERRORS = [(r"2025", "wrong year (2025)"), (r"maternity", "maternity leave (paternity)"), (r"30 nov|nov(ember)? 30", "W4 quote Nov 30"),
               (r"godot (4 )?(is |has been )?(selected|chosen)", "says Godot chosen")]


def section(notes, *names):
    return [i for s in notes.get("sections", []) if any(n in s["title"].lower() for n in names) for i in s["items"]]


def score(path):
    n = json.load(open(path))
    acts = n.get("actions", [])
    found, wrong_owner, wrong_due, matched_rows = set(), 0, 0, set()
    for tid, owners, kws, due, _ in TASKS:
        for i, a in enumerate(acts):
            if i in matched_rows or not has(a["task"], *kws):
                continue
            owner = plain(a.get("owner", "")).split()[0] if a.get("owner") else ""
            if owner in owners:
                found.add(tid); matched_rows.add(i)
                if due and a.get("due_date") and a["due_date"] not in due:
                    wrong_due += 1
                if not due and a.get("due_date"):
                    pass
                break
        else:
            for i, a in enumerate(acts):  # right task, wrong person?
                if i not in matched_rows and has(a["task"], *kws):
                    wrong_owner += 1; matched_rows.add(i); break
    noise = len(acts) - len(matched_rows)
    precision = len(found) / max(1, len(acts))
    everything = (n.get("summary", []) + n.get("decisions", []) + n.get("questions", [])
                  + [i for s in n.get("sections", []) for i in s["items"]])
    text_all = " ".join(everything)
    dec = n.get("decisions", [])
    dec_found = [d for d, kws in DECISIONS if any(has(x, *kws) for x in dec)]
    dec_err = sum(1 for x in dec for e in DECISION_ERRORS if has(x, e))
    topics = [t for t, kws in TOPICS if any(has(x, *kws) for x in n.get("summary", []))]
    figs_src = section(n, "figure") or n.get("summary", [])
    figs = [f for f, kws in FIGURES if any(has(x, *kws) for x in figs_src)]
    risks_src = (section(n, "risk") or everything) + n.get("questions", [])  # templates without a Risks section
    risks = [r for r, kws in RISKS if any(has(x, *kws) for x in risks_src)]
    opts = section(n, "option")
    opt_ok = sum(1 for k, words in OPTIONS.items() for x in opts
                 if plain(x).startswith(k) or (k in plain(x)[:25] and "status" in plain(x)) if any(w in plain(x).split("status")[-1] for w in words))
    ideas = section(n, "idea")
    facts = [label for rx, label in FACT_ERRORS if has(text_all, rx)]
    return dict(tasks_found=len(found), tasks_total=len(TASKS), rows=len(acts), noise=noise, wrong_owner=wrong_owner,
                wrong_due=wrong_due, precision=round(precision, 2), missing=[t[4] for t in TASKS if t[0] not in found],
                decisions=len(dec_found), decisions_total=len(DECISIONS), decision_errors=dec_err,
                missing_decisions=[d for d, _ in DECISIONS if d not in dec_found],
                topics=len(topics), topics_total=len(TOPICS), summary_bullets=len(n.get("summary", [])),
                figures=len(figs), figures_total=len(FIGURES), risks=len(risks), risks_total=len(RISKS),
                options_ok=opt_ok, options_rows=len(opts), ideas=len(ideas), fact_errors=facts,
                sections=[s["title"] for s in n.get("sections", [])])


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(p.split("/")[-2], json.dumps(score(p), ensure_ascii=False))
