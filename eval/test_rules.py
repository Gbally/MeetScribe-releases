"""Regression checks for the rules around the models (no model needed, a few seconds):
to-do and decision checks, merging, dates, speaker names, sentence boundaries, note parsing,
transcript import.   .venv/bin/python eval/test_rules.py"""

import json
import sys
import tempfile
import zipfile
from datetime import date, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import meetscribe.summarize as sm  # noqa: E402
from meetscribe import names  # noqa: E402
from meetscribe.dates import parse_due  # noqa: E402
from meetscribe.imports import read_transcript  # noqa: E402
from meetscribe.notes import parse_notes  # noqa: E402
from meetscribe.transcribe import Word  # noqa: E402
from meetscribe.transcript import Utterance, snap_to_sentences  # noqa: E402

D = date(2026, 10, 23)  # a Friday


def A(owner, task, at, due="", line=None):
    return dict(owner=owner, task=task, at=at, due=due, quote="", line=line)


def U(speaker, text, t):
    return Utterance(t, t + 2, speaker, text)


def W(text):
    out, t = [], 0.0
    for x in text.split():
        out.append(Word(t, t + 0.3, " " + x))
        t += 0.35
    return out


def snap(text, labels):
    ws = W(text)
    return [label for label in snap_to_sentences(ws, labels)]


# ---------------------------------------------------------------- dates

def test_dates():
    for text in ("today", "this afternoon", "this morning", "ce matin", "cet après-midi", "cet après midi", "ce soir"):
        assert parse_due(text, D) == D, text
    assert str(parse_due("next Wednesday", D)) == "2026-10-28"
    assert str(parse_due("Friday", D)) == "2026-10-30"
    assert str(parse_due("le 6 novembre", D)) == "2026-11-06"


# ---------------------------------------------------------------- to-dos

def test_check_actions_owners():
    tr = """[00:01:54] Guillaume: We can do a remote training in November. Nadia, could you propose two dates to Julia?
[00:02:03] Nadia: Of course, I'll send two dates by Friday.
[00:03:00] Fiona: Chloe, I'll send you the job description by Wednesday.
[00:03:10] Lisa: Emma, can you send us the list of the forty pilot users?
[00:03:15] Emma: Yes, I'll send the list on Monday.
[00:03:30] Guillaume: I'll ask Sarah to prepare the deck for Monday.
[00:03:50] Marc: Julie will document the network code before she leaves.
[00:05:43] Chloe: And about the two roles Peter mentioned: we're hiring. I'll publish both job ads next week. Please refer people.
[00:06:00] Peter: Sure."""
    raw = "\n".join(json.dumps(x) for x in [
        {"owner": "Julia", "task": "send two training dates", "due": "Friday", "at": "00:02:03", "quote": "I'll send two dates by Friday"},
        {"owner": "Chloe", "task": "send the job description", "due": "Wednesday", "at": "00:03:00",
         "quote": "I'll send you the job description by Wednesday"},
        {"owner": "Lisa", "task": "send the pilot list", "due": "", "at": "00:03:10",
         "quote": "can you send us the list of the forty pilot users"},
        {"owner": "Sarah", "task": "prepare the deck", "due": "Monday", "at": "00:03:30", "quote": "I'll ask Sarah to prepare the deck"},
        {"owner": "Julie", "task": "document the network code", "due": "", "at": "00:03:50", "quote": "Julie will document the network code"},
        {"owner": "Chloe", "task": "publish job ads", "due": "next week", "at": "00:05:43", "quote": "I'll publish both job ads next week"},
        {"owner": "Marc", "task": "invented", "due": "", "at": "00:09:00", "quote": "I will rewrite everything from scratch"},
    ])
    got = [(a["owner"], a["task"]) for a in sm.check_actions(raw, tr, D)]
    assert got == [("Nadia", "send two training dates"), ("Fiona", "send the job description"), ("Emma", "send the pilot list"),
                   ("Sarah", "prepare the deck"), ("Julie", "document the network code"), ("Chloe", "publish job ads")], got


def test_translated_quote():
    tr = ("[00:01:10] Camille: Je vais regarder ça avec l'équipe.\n"
          "[00:01:20] Camille: Je t'envoie les 3 contrats pour le 15 novembre.")
    raw = ('{"owner":"Camille","task":"send the 3 contracts","due":"","at":"00:01:10","quote":"I will send the 3 contracts by the 15th"}\n'
           '{"owner":"Camille","task":"send the 3 contracts","due":"","at":"00:01:20","quote":"I will send the 3 contracts by the 15th"}\n'
           '{"owner":"Speaker 2","task":"x","due":"","at":"00:01:10","quote":"I will do it"}')
    assert [a["at"] for a in sm.check_actions(raw, tr, D)] == ["00:01:20"]


def test_not_tasks():
    raw = ('{"owner":"Camille","task":"je vais faire attention","due":"","at":"00:01:00","quote":"Je vais faire attention"}\n'
           '{"owner":"Lisa","task":"be in touch","due":"","at":"00:01:00","quote":"Je vais faire attention"}')
    assert sm.check_actions(raw, "[00:01:00] Camille: Oui. Je vais faire attention.", D) == []


def test_merge():
    cases = [
        ([A("Camille", "prendre le pilotage du projet analytique", "00:02:13", "", 15),
          A("Camille", "envoyer la proposition pour le projet analytique", "00:02:38", "", 18)], 2),
        ([A("Tom", "order the new demo server", "00:01:43", "this week", 20), A("Tom", "have the new server running", "00:01:50", "Thursday", 21)], 1),
        ([A("Guillaume", "talk to sales director", "00:01:35", "November 15th", 11),
          A("Guillaume", "talk to sales director about price proposal", "00:02:27", "Monday", 17)], 2),
        ([A("Nadia", "check why PDF fix wasn't released earlier", "00:02:37", "Thursday"),
          A("Nadia", "make a point about PDF fix delay on Thursday", "00:02:37", "Thursday")], 1),
        ([A("Ana", "write the release notes", "00:01:17", "", 7), A("Ana", "deploy the build to staging", "00:01:17", "Monday", 7)], 2),
        ([A("Ben", "send the plan", "00:03:13", "November 6th", 9), A("Ben", "send the plan and the agency quote", "00:03:28", "November 6", 10)], 1),
        ([A("Guillaume", "ask HR whether we can offer a relocation package", "00:10:28"), A("Guillaume", "check with HR by Wednesday", "00:10:28", "Wednesday")], 1),
        ([A("Tom", "review pull request 482", "00:00:44"), A("Tom", "do it", "00:00:50", "before noon")], 1),
        ([A("Sarah", "contact W4 Games for a quote", "00:05:00"), A("Sarah", "ask W4 Games about C# on consoles", "00:05:30")], 2),
        ([A("Ana", "deploy the build to staging", "00:01:17", "after Tom's review"), A("Ana", "deploy the staging build", "00:05:00", "once the review is done")], 1),
        ([A("Marc", "build both prototypes", "00:10:00", "14 Nov"), A("Marc", "build the two prototypes with Julie", "00:28:24", "14 novembre")], 1),
    ]
    for items, want in cases:
        got = sm.merge_actions(items)
        assert len(got) == want, [g["task"] for g in got]


def test_second_look_candidates():
    tr = """[00:00:02] Emily: Hello.
[00:00:05] Guillaume: The build will be ready, and Emily runs the next retro.
[00:01:17] Ana: Today I'm writing the release notes, and I'll deploy the build to staging on Monday morning.
[00:01:20] Peter: Chloe will say more about that."""
    found = [c["sentence"] for c in sm.unclaimed(tr, [], D)]
    assert any("Emily runs" in s for s in found) and any(s.startswith("I'll deploy") for s in found), found
    assert not any("say more" in s for s in found), found


# ---------------------------------------------------------------- decisions

def test_check_decisions():
    tr = """[00:01:00] Guillaume: Okay, let's decide it now: the German version is the priority for November, and the offline mode moves to January.
[00:03:00] Guillaume: No, it stays the same: two days a week in the office, the rest remote."""
    raw = "\n".join(json.dumps(x) for x in [
        {"decision": "German version is the priority for November", "at": "00:01:00", "quote": "the German version is the priority for November"},
        {"decision": "Offline mode moves to January", "at": "00:01:00", "quote": "the offline mode moves to January"},
        {"decision": "Invented", "at": "00:09:00", "quote": "we will open an office in Tokyo"},
        {"decision": "Remote policy unchanged", "at": "00:03:00", "quote": "Remote stays the same 2 days"},
    ])
    assert [d["decision"] for d in sm.check_decisions(raw, tr)] == [
        "German version is the priority for November", "Offline mode moves to January", "Remote policy unchanged"]


def test_final_decisions():
    sm.DECISIONS_MODE = "union"
    acts = [{"owner": "Oliver", "task": "send two references"}, {"owner": "Guillaume", "task": "come back with a decision"},
            {"owner": "Guillaume", "task": "demander aux RH de financer la formation"}, {"owner": "Emma", "task": "send list of 40 pilot users"},
            {"owner": "Guillaume", "task": "move Orbis to next quarter"}]
    checked = ["References are requested by Monday", "The decision will be communicated by November 6th",
               "Guillaume demandera aux RH de financer la formation avant la fin du mois.", "The final choice is made on 20 November",
               "Unreal stays as a fallback", "Not decided yet", "Move Orbis deal to Q1", "Emma will send the list of 40 pilot users on Monday"]
    own = ["The final choice is made on November 20th.", "Partners are welcome at the party."]
    got = sm.final_decisions(checked, own, acts)  # the same decision from both lists: kept once, in either wording
    assert len(got) == 4 and "final choice" in got[0] and got[1:] == [
        "Unreal stays as a fallback", "Move Orbis deal to Q1", "Partners are welcome at the party."], got


def test_merge_decisions():
    merged = lambda xs: [d["decision"] for d in sm.merge_decisions([{"decision": x, "line": i} for i, x in enumerate(xs)])]
    assert len(merged(["Phase 1 goes live on December 1st without single sign-on.", "Single sign-on added in Phase 2 during January."])) == 2
    assert len(merged(["The final choice is made on 20 November", "The final choice is made on November 20th."])) == 1
    assert len(merged(["A February start is accepted", "A February start is agreed upon"])) == 1
    sm.DECISIONS_MODE = "union"
    tom = [{"owner": "Tom", "task": "order the new demo server"}]
    assert sm.final_decisions(["Approval granted to order a new server for €300/month."], [], tom) == ["Approval granted to order a new server for €300/month."]
    assert sm.final_decisions(["References are requested", "The reference deadline is set", "Not decided yet"], [], []) == []


def test_with_decisions():
    sm.DECISIONS_MODE = "union"
    body = "## Summary\n- a\n\n## Decisions taken\n- Keep Unity\n\n## Open questions\nNone."
    out = sm._with_decisions(body, [{"decision": "Unreal stays as a fallback", "line": 3}], [])
    assert parse_notes(out)["decisions"] == ["Unreal stays as a fallback", "Keep Unity"]
    out = sm._with_decisions("## Summary\n- a\n\n## Open questions\nNone.", [{"decision": "X stays", "line": 1}], [])
    assert parse_notes(out)["decisions"] == ["X stays"]


# ---------------------------------------------------------------- speaker names

def test_names():
    u = [U("Speaker 2", "For the flaky tests, each pipeline should create its own test data.", 0),
         U("Guillaume", "Okay, Karim, take it in the next sprint.", 4), U("Speaker 4", "Another idea: group work on Friday afternoons.", 8)]
    assert "Speaker 4" not in names.guess_names(u, ["Karim Haddad", "Lucas Martin"], "Guillaume")
    u = [U("Guillaume", "Okay, let's move on to the next point.", 0), U("Speaker 1", "Right, and Karim, take the testing part this sprint.", 3),
         U("Speaker 2", "Sure, I will prepare the test plan by Monday.", 7)]
    assert names.guess_names(u, ["Karim Haddad", "Lucas Martin"], "Guillaume").get("Speaker 2") == "Karim"
    assert not names._hands_over("Ana, can you check the bananas tomorrow", "ana")
    assert names._hands_over("Thanks. Fiona, support.", "fiona") and names._hands_over("Zoe, marketing?", "zoe")


# ---------------------------------------------------------------- sentence boundaries

def test_snap():
    assert snap("are the bonuses planned for December? Yes. If we reach the fourth quarter target, they will be paid.",
                ["A"] * 12 + ["B"] * 7)[7] == "B"  # "If…" goes to the next speaker
    assert snap("Et la documentation, personne ne la met à jour. Oui, on n'a pas de solution.",
                ["K"] * 4 + ["E"] * 5 + ["G"] * 6).count("K") == 9  # a stray end of sentence rejoins its start
    assert snap("so we keep going. Yes that's right. Okay then.", ["A"] * 4 + ["B"] * 3 + ["C"] * 2).count("B") == 3
    assert snap("one two three. four five six seven eight. nine ten", ["A"] * 3 + ["B"] * 2 + ["C"] * 3 + ["D"] * 2)[:3] == ["A"] * 3


# ---------------------------------------------------------------- notes

def test_parse_notes():
    n = parse_notes("## Summary\n- Budget approved\nDecision pending on the venue\n- Launch in March\n## Decisions\n- Keep Unity")
    assert n["summary"] == ["Budget approved", "Decision pending on the venue", "Launch in March"] and n["decisions"] == ["Keep Unity"]
    assert parse_notes("## Summary\n- a\n## \n- b")["summary"] == ["a"]  # an empty heading: no crash
    n = parse_notes("**Résumé**\n- point A\n\n**Décisions :**\n- choix B\n\n**Questions ouvertes**\n- Q ?")
    assert (n["summary"], n["decisions"], n["questions"]) == (["point A"], ["choix B"], ["Q ?"])


# ---------------------------------------------------------------- import

def test_import():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "teams.vtt").write_text("WEBVTT\n\n1\n00:00:01.200 --> 00:00:04.800\n<v Sarah Martin>Hi everyone.</v>\n\n"
                                       "2\n00:00:08.500 --> 00:00:12.000\n<v Marc Dubois>I'll send the quote by Friday.</v>\n")
        (tmp / "lines.txt").write_text("Sarah Martin\n00:00:05\nHello everyone, let us start.\nMarc Dubois\n00:00:12\nI will send it.\n")
        (tmp / "labels.txt").write_text("Sarah: Are we ready?\nNote: the budget is approved.\nMarc: Yes.\n")
        (tmp / "granola.txt").write_text("Me: Okay so the plan is to finish the migration.\nThem: Sounds good, I'll check the backups.\n")
        (tmp / "be.txt").write_bytes(b"\xfe\xff" + "Sarah: Hello there everyone.\n".encode("utf-16-be"))
        doc = ('<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
               + "".join(f"<w:p><w:r><w:t>{t}</w:t></w:r></w:p>" for t in ["Meeting transcript", "Ana Lima   0:02", "I deployed the build."])
               + "</w:body></w:document>")
        with zipfile.ZipFile(tmp / "teams.docx", "w") as z:
            z.writestr("word/document.xml", doc)
        (tmp / "youtube.sbv").write_text("0:00:01.000,0:00:04.000\nHello everyone, welcome.\n\n0:00:04.500,0:00:07.000\nToday the budget.\n")
        (tmp / "rev.txt").write_text("Speaker 1 (00:01):\nOkay, let's start.\n\nSpeaker 2 (00:15):\nSure, the timeline first.\n")
        (tmp / "fireflies.txt").write_text("Sarah Martin - 00:01\nGood morning, team.\nMarc Dubois - 00:08\nMorning.\n")
        (tmp / "chat.txt").write_text("[Sarah Martin] 10:00:01\nHi all\n[Marc Dubois] 10:00:05\nHello, can you hear me?\n")
        speakers = lambda f, me="": [u.speaker for u in read_transcript(tmp / f, me)]
        assert speakers("youtube.sbv") == ["Speaker 1"] and read_transcript(tmp / "youtube.sbv")[0].text.endswith("budget.")
        assert speakers("rev.txt") == ["Speaker 1", "Speaker 2"] and speakers("fireflies.txt") == ["Sarah Martin", "Marc Dubois"]
        chat = read_transcript(tmp / "chat.txt")
        assert [u.speaker for u in chat] == ["Sarah Martin", "Marc Dubois"] and chat[0].start == 0 and chat[1].start == 4
        assert speakers("teams.vtt") == ["Sarah Martin", "Marc Dubois"]
        assert speakers("lines.txt") == ["Sarah Martin", "Marc Dubois"]
        assert speakers("labels.txt") == ["Sarah", "Marc"]
        assert speakers("granola.txt", "Guillaume") == ["Guillaume", "Speaker 1"]
        assert speakers("be.txt") == ["Sarah"]
        assert speakers("teams.docx") == ["Ana Lima"]


def test_session_dirs():
    from meetscribe.cli import new_session_dir
    from meetscribe.config import Config

    with tempfile.TemporaryDirectory() as tmp:
        cfg = Config(notes_dir=tmp)
        when = datetime(2026, 10, 23, 9)
        a = new_session_dir(cfg, "Standup", when)
        (a / "transcript.json").write_text("{}")
        assert new_session_dir(cfg, "Standup", when).name == "2026-10-23_0900_Standup-2"


def test_chinese_japanese():
    """No spaces between words: their quotes are checked on pairs of characters, so the to-dos and
    decisions said are kept (they all went before) — and a made-up one still goes."""
    ja = "\n".join([
        "[00:00:30] 佐藤: では、リリースを1月に延期することに決めましょう。",
        "[00:00:40] 田中: 了解です。月曜日にプロバイダーに電話して契約をまとめます。",
        "[00:01:05] 田中: 来週確認しましょう。予算は4万ユーロのままです。"])
    raw = "\n".join([
        '{"owner": "田中", "task": "プロバイダーに電話して契約をまとめる", "due": "", "at": "00:00:40", "quote": "月曜日にプロバイダーに電話して契約をまとめます。"}',
        '{"owner": "田中", "task": "来週最終デザインを確認する", "due": "", "at": "00:01:05", "quote": "来週確認しましょう。"}',
        '{"owner": "佐藤", "task": "見積もりを送る", "due": "", "at": "00:00:50", "quote": "見積もりを今日中に送ります。"}'])
    kept = sm.merge_actions(sm.check_actions(raw, ja, D))
    assert [(a["owner"], a["at"]) for a in kept] == [("田中", "00:00:40"), ("田中", "00:01:05")], kept
    dec = sm.check_decisions('{"decision": "リリースを1月に延期", "at": "00:00:30", "quote": "リリースを1月に延期することに決めましょう"}', ja)
    assert [d["at"] for d in dec] == ["00:00:30"], dec
    zh = "[00:00:40] 李明: 好的。我周一给供应商打电话，把合同定下来。"
    raw = '{"owner": "李明", "task": "给供应商打电话并定下合同", "due": "", "at": "00:00:40", "quote": "我周一给供应商打电话，把合同定下来。"}'
    assert [a["owner"] for a in sm.check_actions(raw, zh, D)] == ["李明"]
    assert sm._norm_words("l'équipe a décidé ﬁn 5,000") == ["l", "equipe", "a", "decide", "fin", "5", "000"]


def test_out_of_memory():
    """The app is told which model ran out of memory (the speech one while transcribing, else the
    notes one), and the notes are retried in parts before giving up."""
    import contextlib
    import dataclasses
    import io
    import weakref

    from meetscribe import progress
    from meetscribe.config import Config

    def said(stage, fn=progress.out_of_memory):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            progress.plan([("mic", 1), ("notes", 1)])
            if stage:
                progress.start(stage)
            fn()
        return [line for line in out.getvalue().splitlines() if line.startswith("@@memory")]

    assert said("mic") == ["@@memory speech"] and said("notes") == ["@@memory notes"] and said("") == ["@@memory notes"]
    tried, first, real = [], [], sm._summarize

    class Model:
        pass

    def short_of_memory(transcript, cfg, *rest):
        tried.append(cfg.max_context_tokens)
        if cfg.max_context_tokens > 6000:
            model = Model()  # the first attempt's model: gone before the retry loads it again
            first.append(weakref.ref(model))
            raise MemoryError("[METAL] Insufficient Memory")
        assert first[0]() is None, "the first attempt's model is still in memory during the retry"
        return "notes"

    def never_fits(*_):
        raise MemoryError("[METAL] Insufficient Memory")

    cfg = dataclasses.replace(Config(), llm_backend="openai", max_context_tokens=20000)
    sm._summarize = short_of_memory
    try:
        assert said("notes", lambda: sm.summarize("t", cfg)) == ["@@memory notes"] and tried == [20000, 6000], tried
        sm._summarize = never_fits
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                sm.summarize("t", cfg)
            raise AssertionError("no SystemExit when even the parts don't fit")
        except SystemExit as e:
            assert "memory" in str(e).lower() and out.getvalue().count("@@memory notes") == 2, out.getvalue()
    finally:
        sm._summarize = real


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted((n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)):
        try:
            fn()
            print(f"ok    {name}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL  {name}: {e}")
    sys.exit(1 if failed else 0)
