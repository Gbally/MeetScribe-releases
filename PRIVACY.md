# Privacy

MeetNouce records, transcribes and summarises your meetings **on your Mac**. Audio, transcripts,
notes, meeting titles, names and voiceprints are never sent anywhere by MeetNouce.

## What stays on your Mac

| What | Where | How long |
|---|---|---|
| Recordings (`mic.caf`, `system.caf`) and voice samples | the notes folder (default `~/Documents/MeetingNotes`) | deleted after 7 days by default (Settings → Privacy and storage) |
| Transcripts and notes | the notes folder | until you delete them |
| Known voices (`voices.json`) | `~/Library/Application Support/MeetScribe` | until you forget them (Settings → Voices) |
| Settings | the app's preferences | until you remove MeetNouce |

If you choose a OneDrive (or other synced) folder for your notes, your own sync client uploads
them to your own account — MeetNouce itself doesn't.

## What goes over the network

- **No analytics, no tracking.** MeetNouce has no usage statistics, crash reporting or
  identifiers of any kind. (Versions 0.3.1 to 0.5.1 sent optional anonymous usage counts; they
  were removed in 0.5.2.)
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

Settings → Privacy and storage → **Remove MeetNouce** deletes the engine, the AI models, the
settings and learned voices, and moves the app (and, if you tick it, your notes) to the Trash.

Questions: [open an issue](https://github.com/Gbally/MeetScribe-releases/issues).

Always tell the other participants that you're recording, and follow your company's rules and the
law where you are.
