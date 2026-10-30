# AMI benchmark: to-dos on real recorded meetings

The notes benchmark (`eval/notes_bench`) uses invented meetings read by macOS voices. This one
uses the **AMI Meeting Corpus**: about 100 hours of real recorded meetings in English, most of them
scenario meetings where a team of four designs a remote control over four sessions. Annotators
wrote a summary of each meeting with its **actions** and **decisions**. These meetings are long,
dense and messy, the way real calls are, and they show what the invented ones don't: ideas thrown
around in a discussion taken for tasks.

The transcript used is the corpus' manual one, not Whisper's. So this benchmark scores the notes
step alone.

## Use

```sh
python3 eval/ami_bench/fetch.py      # once: corpus annotations (23 MB) + the 30 meetings
"$HOME/Library/Application Support/MeetScribe/venv/bin/python" eval/ami_bench/run.py NAME [--set dev|test|all] [--rounds 2]
python3 eval/ami_bench/score.py NAME [--set …] [--show]
```

- `run.py` runs the app's to-do steps: the extraction passes, the checks, the second look and the
  merge. It skips the notes text.
- Every model answer is cached in `data/cache`. The first run takes about 4 minutes per meeting
  and round. After that, a change to the rules takes minutes, since only the prompts it changes
  go to the model again.
- `--src DIR` scores another copy of the engine.

**Dev and test sets.** The 20 `dev` meetings are the ones to look at while changing the rules. The
10 `test` meetings are only scored, to check that a change helps beyond the meetings it was made
on. The split is fixed in `convert.py`.

**Score.** `found` counts the annotated actions that a to-do matches, by the words that say what
the task is. `owner` counts those matched with the right person. `unmatched` counts the to-dos
that match no annotated action.
- The annotators only wrote down the main tasks, so some unmatched to-dos are real small ones
  ("send the minutes").
- Compare runs on the same meetings, and check by hand with `--show`.
- A change should also hold on `eval/notes_bench` and on real meetings.

## Credit and licence

AMI Meeting Corpus, © University of Edinburgh, <https://groups.inf.ed.ac.uk/ami/corpus/>,
licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The corpus isn't in this
repository: `fetch.py` downloads it into `data/`, which is gitignored. A model or adapter trained on it
should credit it the same way.

> J. Carletta et al., *The AMI Meeting Corpus: A Pre-Announcement*, MLMI 2005.
