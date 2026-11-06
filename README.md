# Oatcake

A Mac app that records a call, transcribes it on this Mac, tells the other voices apart,
lets you check who said what, and writes a summary built around the notes you took
during the call.

## How it works

```mermaid
flowchart TD
    subgraph record["1 · Record: OatcakeRecorder helper app"]
        mic["Your microphone<br/>mic.pcm"]
        sys["Everything the Mac plays<br/>system.pcm"]
        notes["Your notes<br/>notes.json"]
    end

    subgraph process["2 · Process: speech models on this Mac (sherpa-onnx)"]
        asr["Silero VAD finds speech,<br/>Parakeet turns it into text"]
        voices["pyannote finds speaker turns,<br/>CAM++ fingerprints each voice<br/>→ speakers A, B, C…"]
        combine["Who said what<br/>call-audio text split by speaker turns;<br/>mic lines that echo the call dropped"]
        match["Voiceprint match against<br/>people you've confirmed before"]
        prints[("voiceprints.json")]
    end

    guess["Claude: guesses names for voices<br/>with no match, from the transcript"]
    review["3 · Review (you)<br/>listen to clips, confirm names,<br/>merge or mark mixed"]
    summary["Claude: writes the summary and to-dos<br/>from the transcript, focused by your notes"]
    folder["4 · Meeting folder<br/>summary.md · todo.md · transcript.md · notes.md · meeting.json"]

    mic --> asr
    sys --> asr
    sys --> voices
    asr --> combine
    voices --> combine
    voices --> match
    prints --> match
    combine --> guess
    match --> guess
    guess --> review
    review -.->|"saves voices with 30 s+ of speech"| prints
    review --> summary
    notes --> summary
    summary --> folder
    notes --> folder

    classDef llm fill:#f6e7d8,stroke:#c26a2e,color:#000
    class guess,summary llm
```

Everything runs on this Mac except the two orange steps. Silero, Parakeet, pyannote and
CAM++ are small speech models (Parakeet is 0.6B parameters): they turn audio into text
and voices into fingerprints, take no prompts, and can't write anything else. Claude is
the only language model, and it only ever sees text (the transcript and your notes),
never audio.

The window has three columns: the sidebar (a recording in progress, Upcoming from your
calendar, Needs review, and your folders), the meetings in the selected folder, and the
meeting itself. Settings (⌘,) is its own window; changes apply as you make them.

1. **Record.** New recording, or click an event under Upcoming. Pick the folder (a calendar
   event picks the folder named like it, or offers a new one for a recurring event); leave
   the title blank to use the folder's name. The screen shows the event's attendees, the
   open to-dos from the last meeting in that folder (ticking one updates its `todo.md`),
   and takes prep notes, which open the call's notes. Your microphone is recorded as you;
   everything the Mac plays (Zoom, Meet, Slack, anything) is recorded as the other people.
   During the call, write one point per line: each is stamped with the time you started
   typing it, and every line stays editable. The recorder is a small helper app
   (`recorder/`), so macOS asks for microphone and system-audio permission for
   "OatcakeRecorder" once; if it hasn't started after a few seconds, the live screen says
   to look for that prompt. Pick the microphone on the record screen, from the mic button
   during the call, or in Settings: "Same as Mac" follows System Settings › Sound; a chosen
   mic is used until it's unplugged, then the Mac's input until it's back. Changing mic
   mid-call carries on recording, with the switch filled with silence so your track stays
   lined up with the call. You're warned after 30 seconds of a silent mic or no call audio.
   Stop asks first.
2. **Process (on this Mac, in the background).** Parakeet transcribes both tracks. The call
   audio is split into voices by sherpa-onnx (pyannote segmentation + CAM++ fingerprints,
   merged by voice similarity). Mic lines that repeat the call audio (speaker echo) are
   dropped. Known voices are recognised from saved voiceprints; other names are suggested
   from the conversation by the summary model, quoting the words that gave it away. The
   recording waits under Needs review with its step (1–5); a failure shows the reason, with
   Try again and Discard.
3. **Review (Who's who).** One card per voice: play its clips, confirm or type the name
   (with where the suggestion came from), merge it into another voice or into you, or mark
   it as mixed ("Several people"). Unnamed voices are saved as "Voice 1", "Voice 2"… The
   transcript beside it updates as you name voices. Confirmed voices with 30+ seconds of
   speech are saved, so they're recognised next time.
4. **Save.** The meeting is a folder in the folder you picked:
   `2026-11-05 1400 Weekly sync/` with `summary.md`, `todo.md` (action items, as
   `- [ ] Task — Owner — due Fri, Oct 30 — [12:34]`), `transcript.md`, `notes.md` (your own
   notes, untouched; prep notes have no time) and `meeting.json` (title, times,
   participants). Your notes steer what the summary focuses on but aren't copied into it.
   Tabs: Summary (with the meeting's to-dos at the top), Transcript and My notes (⌘1–⌘3),
   each Rendered or as editable Markdown (saved as you type; Summary shows `todo.md` and
   `summary.md`). Tick to-dos off in place; a to-do's time jumps to that moment in the
   transcript. **To-dos** at the top of the sidebar gathers every meeting's to-dos (open
   and overdue counts beside it): Open / Done / All, grouped by due date, folder or owner,
   filtered by owner ("Mine" is your name from Settings). Ticking one there updates that
   meeting's `todo.md`. Add a to-do under a meeting's Summary and it goes in that meeting's
   `todo.md`; add one on the To-dos page and it goes in the Meetings folder's own `todo.md`,
   owned by you unless you name someone. Type owner and due date after dashes:
   `Send the deck - Alex - due Fri, Nov 6`. The middle column's width drags, like the
   sidebar's. Organise meetings by dragging them onto folders, or
   right-click to rename or trash; Finder and the app stay in step.
5. **Ask.** The lozenge at the bottom of a meeting takes questions about it ("what did we
   decide about hiring?") or across meetings ("when did Alex first raise the launch date?").
   It runs Claude Code (`claude -p`) in your Meetings folder with read-only file tools
   (Read, Grep, Glob) that may only open files inside that folder: no shell, no MCP servers,
   no personal settings. Answers link to the meetings they draw on; click one to open it.
   Web links in an answer are shown as text, not made clickable. Follow-ups continue the same conversation,
   which stays open as you move between meetings, until New chat. Expect 10–60 seconds
   and some Claude usage per question; the meeting text Claude reads is sent to Anthropic.

## Importing a Granola export

```sh
node scripts/import-granola-export.mjs ~/Documents/granola-export --dry-run
node scripts/import-granola-export.mjs ~/Documents/granola-export
```

Copies `<series>/<YYYY-MM-DD HHMM>/{summary.md,transcript.md}` into the Meetings folder as
`<series>/<YYYY-MM-DD HHMM> <title>/` with a `meeting.json`. The export is left as it is,
and meetings already imported are skipped. Granola has no export in this layout: it was made
by asking Claude, with the Granola connector, to save each meeting's summary and transcript.
The script reads the title from `summary.md`'s first `# ` heading and the participants from a
`- **Participants:** Name (…), Name (…)` line; folder times are read as local time.

## Install and run

Needs an Apple Silicon Mac on macOS 14.2 or later (the recorder uses Core Audio process taps),
Node 22 or later, and Xcode's command line tools (`xcode-select --install`) to build the
recorder. Summaries use Claude Code by default: install it and sign in, or pick another
provider in Settings.

```sh
npm install
node node_modules/electron/install.js   # if installed with --ignore-scripts
npm run build:recorder                  # builds recorder/build/OatcakeRecorder.app
npm start                               # development
npm run package                         # out/Oatcake-darwin-arm64/Oatcake.app
```

The packaged app is ad-hoc signed, not notarised. Built on your own Mac it opens normally;
copied to another Mac, macOS blocks the first open until you allow it in System Settings ›
Privacy & Security › Open Anyway. The first processing run downloads ~700 MB of models to
`~/Library/Application Support/Oatcake/models`. The Dock badge counts recordings waiting
under Needs review. The icon is `assets/icon.svg`; `assets/Oatcake.icns` is built from
`assets/icon.png` with `iconutil`.

## Settings

Settings in the app (stored in `~/Library/Application Support/Oatcake/config.json`):

- **Summaries and name suggestions:** Claude through Claude Code (`claude -p`, uses your
  Claude Code sign-in; model and effort), Claude through the Anthropic API, or any
  OpenAI-compatible endpoint such as a local Ollama. Each provider keeps its own settings.
  API keys typed in Settings are stored encrypted (Electron safeStorage, whose key lives in
  your Keychain) in `secrets.json`, not in `config.json`. Settings shows only that a key is
  saved and its last four characters; it can replace or remove one but never read it back.
  Claude Code never sees these keys: it always uses its own sign-in. Add a provider in
  `src/core/llm/`.
- **Transcription model:** any model in `ASR_MODELS` (`src/core/models.ts`); sherpa-onnx
  also runs Whisper, Canary and Cohere Transcribe.
- **Keep call audio:** off by default; audio is deleted once a meeting is saved.
- **Calendar:** paste your calendar's private iCal address (Google Calendar › Settings › your
  calendar › Integrate calendar › "Secret address in iCal format"). It's stored encrypted with
  the API keys (an address from an older `config.json` is moved there). Oatcake fetches it once an
  hour, or when you press ↻ next to Upcoming, and keeps events from yesterday to two weeks
  ahead in `calendar.json`. Upcoming in the sidebar lists the rest of today and tomorrow
  (events you declined are left out). Clicking one starts a new recording named after it, in
  the folder with the same name or path ("Sam & Alex 1:1" finds "Sam & Alex 1-1", "Team 51 –
  Leads sync" finds "Team 51 › Leads sync"), or offers a new folder for a recurring event
  with none; "Join the call" opens its Meet, Zoom or Teams link (only links on those services'
  own domains count, so a look-alike address is never opened). A failed
  fetch keeps the last events and turns ↻ red; hover it for the reason.
- **Remind me before calls** (on by default): 5 minutes before each timed event, a notification
  with **Open call and start note taking** (or **Start note taking** when there's no call
  link). The button opens the call link, starts recording it (in the folder named like the
  event; a new folder for a recurring event without one, ":" and "/" becoming "-"), and
  brings Oatcake forward on the live notes. Clicking the notification itself opens New
  recording for the event. macOS asks once whether Oatcake may send notifications; the
  packaged app asks for Alerts, so reminders stay up until dealt with.

## Security

- The window can only ask the main process for things through the preload bridge, and only
  from Oatcake's own pages; every path it sends is checked to stay inside the Meetings folder
  or the recordings folder. The Meetings folder itself is only changed through the folder
  picker. The window gets no camera, microphone or other web permissions: the recorder app
  captures audio on its own.
- Summaries and answers are rendered with any HTML shown as text, under a content security
  policy that allows only the app's own scripts and no remote images.
- Downloaded speech models are checked against pinned SHA-256 checksums before use.
- The packaged app has Electron's fuses set: it can't be run as plain Node
  (`ELECTRON_RUN_AS_NODE`), ignores `NODE_OPTIONS` and `--inspect`, and loads its code only
  from its own asar, whose checksum is verified.
- Files Oatcake rewrites (meeting Markdown, config, voiceprints, calendar) are written to a
  new temporary file and renamed into place, never through an existing file or link.
- Known gap: `OatcakeRecorder.app` holds the microphone and system-audio permissions, and any
  program running as you can launch it (`open … --args --out <dir>`) to record. Closing that
  needs the recorder to check who launched it, which means rebuilding it, and a rebuilt
  recorder asks for both permissions again.
- Recording one call at a time is enforced by the main process. If Oatcake quits or crashes
  mid-call, the next launch picks the recording up again (still running) or finishes it from
  the audio on disk (recorder gone), so nothing is left recording unseen or stuck.

## Accuracy

Speaker separation was tuned against a real four-person meeting with known speakers
(AMI ES2002a, two 5-minute excerpts): 82–85% of speech went to the right voice, all four
people were found, and voiceprints from one excerpt recognised people in the other
3 times out of 5 with no wrong matches (it asked in the other 2). Expect to merge a split
voice now and then, and to mark a voice "mixed" when two people sound alike.

## Layout

- `recorder/` — Swift system-audio + mic recorder (helper app)
- `src/core/` — recording, transcription, speakers, voiceprints, summaries, meeting folders
- `src/main/` — Electron main process, preload bridge, analysis worker
- `src/renderer/` — the window (React)

## License

GPL-3.0-or-later (`LICENSE`). The recorder's audio tap and some speaker-matching values are
adapted from OpenWhispr, under its MIT license (`THIRD_PARTY_NOTICES.md`).
