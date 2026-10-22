# Privacy

MeetScribe records, transcribes and summarises your meetings **on your Mac**. Audio, transcripts,
notes, meeting titles, names and voiceprints are never sent anywhere by MeetScribe.

## What stays on your Mac

| What | Where | How long |
|---|---|---|
| Recordings (`mic.caf`, `system.caf`) and voice samples | the notes folder (default `~/Documents/MeetingNotes`) | deleted after 7 days by default (Settings → Privacy and storage) |
| Transcripts and notes | the notes folder | until you delete them |
| Known voices (`voices.json`) | `~/Library/Application Support/MeetScribe` | until you forget them (Settings → Voices) |
| Settings | the app's preferences | until you remove MeetScribe |

If you choose a OneDrive (or other synced) folder for your notes, your own sync client uploads
them to your own account — MeetScribe itself doesn't.

## What goes over the network

- **Anonymous usage statistics** (on by default, turn off in Settings → Privacy and storage →
  Usage statistics). Sent to the developer's [Zenhook](https://zenhook.dev) workspace, only to
  see how the app is used and what breaks:
  - with every event: a random install id (not linked to you), the app version, the Mac's chip and
    memory, the macOS version;
  - a new install, an update, an uninstall (with the number of meetings);
  - each recording: its length, processing time, meeting type, whether meeting audio was
    captured, the number of speakers and to-dos, the AI model used;
  - a change of AI model (the model names), and the kind of error when processing fails.

  Never audio, transcripts, notes, titles, names, email addresses or calendar data.
- **Updates and model list**: once a day the app reads `latest.json` and `models.json` from this
  GitHub repository.
- **First setup and model downloads**: the engine (Python and its packages) comes from the Python
  package index and GitHub, the AI models from [Hugging Face](https://huggingface.co).
- **Email drafts in a browser** (only if you pick Gmail or Outlook on the web in Settings): the notes
  are passed to that website to create the draft. The default mail app, Outlook and Apple Mail
  drafts stay local.

## Permissions it asks for

Microphone (your voice), Screen & System Audio Recording (the other participants' voices — sound
only, the screen is never recorded), Calendar (optional: meeting titles and attendees, read
locally), Reminders (only when you export to-dos), Notifications.

## Removing everything

Settings → Privacy and storage → **Remove MeetScribe** deletes the engine, the AI models, the
settings and learned voices, and moves the app (and, if you tick it, your notes) to the Trash.

Questions: [open an issue](https://github.com/Gbally/MeetScribe-releases/issues).

Always tell the other participants that you're recording, and follow your company's rules and the
law where you are.
