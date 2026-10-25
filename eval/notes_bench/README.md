# Notes benchmark

Measures what the notes get right on meetings whose content is known exactly: 10 synthetic
meetings spoken by the macOS voices (and an optional 30-minute one), each with its truth — the
to-dos (owner, deadline), decisions, figures, risks, topics, and who spoke when.

| Meeting | Language | People | Length | Template |
|---|---|---|---|---|
| `standup` | EN | 5 | 3 min | Stand-up |
| `one_on_one` | FR | 2 | 3 min | 1:1 |
| `client` | EN, laptop echo, a quiet voice | 4 | 4 min | Client call |
| `workshop` | EN/FR mixed | 6 | 4 min | Workshop |
| `interview` | EN, debrief after the candidate leaves | 3 | 11 min | Interview |
| `allhands` | EN, 6 accents, a quiet voice | 8 | 9 min | General |
| `revue_projet` | FR | 4 | 3 min | General |
| `client_bilingue` | EN call, then a FR debrief | 4 | 3 min | Client call |
| `pipeline` | EN | 5 | 3 min | General |
| `retro` | FR/EN mixed | 5 | 3 min | Workshop |
| `engine` (`--engine`) | EN/FR, 3 people | 3 | 30 min | Workshop |

## Run

From the repository, with the app's Python (the engine must be installed and the models
downloaded):

```sh
"$HOME/Library/Application Support/MeetScribe/venv/bin/python" eval/notes_bench/run.py ~/bench-run \
    --model mlx-community/Qwen3.5-4B-4bit --rounds 3
```

- `--model` again to compare models; `--templates both` to also score the General template;
  `--meetings standup,interview` for a subset; `--engine` for the 30-min meeting.
- About 1–2 min per meeting and round on an M2 (8 GB); the audio is made once, the
  transcription once per meeting; rerunning only does what's missing.
- `python eval/notes_bench/report.py ~/bench-run` prints the report again (`report.json` too).

## Reading the report

Each rubric is 0–10; the overall is a weighted mean (decisions and summary count most). The
synthetic voices are cleaner than real calls and the scoring is by keywords, so compare runs
with each other rather than reading the numbers as absolute. A voice missing on another Mac
is replaced by a default one (it says so), which makes speakers harder to separate.

`eval/test_rules.py` (no model, seconds) checks the rules around the models; run it after
changing them, and this benchmark before changing prompts or models.
