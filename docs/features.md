# Features

Everything Oatcake does today, with a link to where each is described. Planned work is in
[What's next](whats-next.md).

## Recording

- Records your microphone as you and everything the Mac plays (Zoom, Meet, Slack, a browser) as
  the other people, through a small helper app that only records for Oatcake.
  [Record](how-it-works.md#1-record)
- Notes during the call, one point per line, each stamped with the time you started typing it and
  editable afterwards. [Record](how-it-works.md#1-record)
- Prep notes typed or pasted before the call, carried into its notes.
  [Record](how-it-works.md#1-record)
- The open to-dos from the latest earlier meeting in the same folder on the record screen, to tick
  off.
  [Record](how-it-works.md#1-record)
- Live transcript beside your notes, transcribed on the Mac as the call goes.
  [Live transcript](how-it-works.md#live-transcript)
- Voices named in the live transcript: people Oatcake knows by voice, and anyone you name by
  clicking a line, followed for the rest of the call and carried into Who's who.
  [Live transcript](how-it-works.md#live-transcript)
- Microphone choice, following the Mac's or a chosen mic, changeable mid-call without a gap in the
  recording. [Record](how-it-works.md#1-record)
- Warnings for a silent microphone, no call audio, or a recorder that stopped or never started, on
  screen and as notifications; what was recorded is kept, and a recording stops by itself before
  the disk is full. [Record](how-it-works.md#1-record)
- Your microphone and the call audio stay lined up through a change of microphone, the Mac
  sleeping, or headphones connecting. [Record](how-it-works.md#1-record)
- An offer to record when a calling app starts using the microphone, and an automatic stop when
  the call ends, with **Keep recording**. [Calls are noticed](how-it-works.md#calls-are-noticed)
- An option to keep call notices working after you close the window. Reopen or quit Oatcake from
  its menu bar icon. [The menu bar](how-it-works.md#the-menu-bar)
- The running time and **Stop Recording…** in the menu bar, including over full-screen apps.
  [The menu bar](how-it-works.md#the-menu-bar)
- A recording carries on if Oatcake crashes, and is picked up if it opens again within ten minutes.
  [Security](security.md)

## Calendar

- Upcoming calls from private iCal feeds and this Mac's own calendars, in one list on Home and in
  the sidebar, with a coloured dot for each source calendar. The names and dots are shown in Record
  a call, and the dots carry over to saved meetings. [Calendar settings](settings.md#calendars)
- Clicking a call under Upcoming, on Home or in the sidebar, opens Record a call for it, in the
  folder named like it or a new one for a recurring meeting. [Calendar settings](settings.md#calendars)
- **Join the call** on Home opens a Meet, Zoom or Teams call without recording it.
  [Calendar settings](settings.md#calendars)
- Reminders before each call (5 minutes before, or as many as you like at the times you choose),
  whose button opens the call and starts recording.
  [Calendar settings](settings.md#calendars)
- Your next call in the menu bar, with what's coming up in its menu.
  [The menu bar](how-it-works.md#the-menu-bar)
- Events that aren't calls left out by their title ("Focus time", "Out of office"…) or by "Oatcake
  ignore" in the title. [Calendar settings](settings.md#calendars)
- One event, one occurrence, or a series from then on ignored from the sidebar's Upcoming
  right-click menu, and brought back from Settings. [Calendar settings](settings.md#calendars)
- Private calendar addresses kept in a file only your account can read.
  [Security](security.md)

## Transcription and voices

- Transcription on the Mac's Neural Engine, in English, 25 European languages, or Chinese,
  Cantonese, Japanese and Korean, and an English model that leaves out "um", false starts and
  repeated words. [Process](how-it-works.md#2-process), [Speech models](models.md#speech-models)
- The call side split into voices, with your microphone's echo of the call dropped.
  [Process](how-it-works.md#2-process)
- Voices recognised from earlier calls by their fingerprints, and names suggested from the
  conversation for the rest. [Process](how-it-works.md#2-process)
- Who's who: play each voice's clips, name it (or pick someone from the invite), merge voices,
  mark one as several people, or leave out one that isn't part of the call.
  [Review](how-it-works.md#3-review-whos-who)
- Saving straight after processing instead, with a summary or the transcript only, and naming the
  voices later. [Saving without Who's who](how-it-works.md#saving-without-whos-who)
- **Rename People** for a saved meeting: put a wrong name right, name a "Voice 2", swap two
  names or make two speakers one. [Rename People](how-it-works.md#rename-people)
- People Oatcake recognises listed in Settings, to rename, merge or forget, or to choose their
  colour. [People](settings.md#people)

## Summaries and to-dos

- A summary and to-dos written by a language model on this Mac, steered by your notes, in the
  background after the meeting is saved. [Save](how-it-works.md#4-save),
  [Language model](models.md#language-model)
- Your own summary instructions, to-do instructions and jargon. [Summaries](settings.md#summaries)
- Reasoning on or off for each task, for Oatcake's own models and for a server of your own once
  you've said which switch it takes (Ollama or llama.cpp). [Summaries](settings.md#summaries)
- Summary templates for different kinds of meeting, picked before recording or when regenerating.
  For calendar calls, Oatcake suggests the choice from the latest saved meeting with that title.
  [Regenerate and summary templates](how-it-works.md#regenerate-and-summary-templates)
- Regenerate the summary or the to-dos alone. [Regenerate and summary
  templates](how-it-works.md#regenerate-and-summary-templates)
- A draft for sharing: the summary and to-dos written again for other people, with its own
  instructions and an editable draft of its own. [Draft for sharing](how-it-works.md#draft-for-sharing)
- **Write summary** to try again when one couldn't be written. [Save](how-it-works.md#4-save)
- They/them for everyone in summaries, to-dos, drafts and answers, rather than a he or she the
  model guessed from a name. [Save](how-it-works.md#4-save)
- To-dos with owners and due dates, ticked off in the meeting; a to-do's time opens the transcript
  there. [To-dos](how-it-works.md#to-dos)
- A To-dos page gathering every meeting's, by due date, folder or owner, with your own list
  besides, whose to-dos can be edited or deleted there. ⌘Z undoes a tick.
  [To-dos](how-it-works.md#to-dos)
- To-dos can be turned off altogether. [General](settings.md#general)
- Qwen3.6 35B-A3B or Qwen3.5 4B, by this Mac's memory (or Google's Gemma 4 26B-A4B or 12B
  instead; Qwen3 8B and 4B are still there for those who chose them), downloaded and run by
  Oatcake, or a model server of your own on your Mac or network, sent as much at once as its
  context holds. Choosing a model sets the reasoning switches that suited it, and says which
  changed. [Language model](models.md#language-model)

## Meetings

- Home: upcoming calls with **Join the call**, your next open to-dos to tick off or add to, and
  Ask across every meeting. [The window](how-it-works.md#the-window)
- A window laid out as Mail's: the sidebar, a folder's meetings and the meeting, or the sidebar
  and one screen for Home, To-dos, recording and Who's who. It narrows to about half a laptop's
  screen, the sidebar making way for the meeting. [The window](how-it-works.md#the-window)
- Each meeting a folder of Markdown (`summary.md`, `todo.md`, `transcript.md`, `notes.md`) and
  `meeting.json` in a Meetings folder you choose, kept in step with Finder.
  [Save](how-it-works.md#4-save)
- Summary, Transcript and My notes tabs (and Draft where there's a draft for sharing), each to read
  laid out or to edit as Markdown. An edit never saves over a file that changed meanwhile (a
  summary arriving, another app): yours is kept beside it. Quitting asks first when work is under
  way or something you typed couldn't be saved.
  [Reading and editing](how-it-works.md#reading-and-editing)
- Play and pause a saved call recording, and jump to a time from the slider or the transcript.
  [Listening to the recording](how-it-works.md#listening-to-the-recording)
- **Copy** and **Share**, formatted for documents and mail and as Markdown.
  [Reading and editing](how-it-works.md#reading-and-editing)
- Folders within folders, meetings dragged or moved between them, several at a time; rename, Show
  in Finder, Move to Trash and Undo to put back. A meeting dragged out of Oatcake is its folder, or
  its summary as text. [Organising meetings](how-it-works.md#organising-meetings)
- Search across every meeting, with its words and results kept for the next look, and find on the
  tab you're reading. [The window](how-it-works.md#the-window)
- Bigger and smaller text, and dates and times written the way your Mac's region writes them.
  [The window](how-it-works.md#the-window)
- Every command in the menu bar, with keys for what's done on every call, and Back and Forward
  after following a link. [Keyboard shortcuts](keyboard-shortcuts.md)
- Oatcake opens on the folder, meeting and tab it was on when it was last closed.
  [The window](how-it-works.md#the-window)
- The call's audio kept with the meeting, if you choose. [Storage](settings.md#storage)

## Ask

- Ask across your saved meetings from Home, or start with the meeting you have open. Answers link to the
  meetings and times they draw on. [Ask](how-it-works.md#5-ask)
- Follow-ups in the same conversation as you move between Home and meetings. [Ask](how-it-works.md#5-ask)

## Accessibility

- VoiceOver: headings, a name for every button and note line, the notes at the bottom of the
  window and Ask's answers read out, and the menu bar item's countdown.
  [The window](how-it-works.md#the-window)
- Reduce motion and Increase contrast followed, errors told from warnings by their symbol as well
  as their colour, and Bigger Text for lists, to-dos and transcripts as well as what you read.
  [The window](how-it-works.md#the-window)
- Fields and cards edged at 3:1 or more against the window, light and dark, and buttons at least
  24 points to click.

## Local MCP server

[Turn it on in Settings](settings.md#other-apps-local-mcp-server) to let an MCP app on the same Mac browse
and search your Meetings folder, read summaries, transcripts, notes and to-dos, and list both open
and completed to-dos. It only reads, and the app runs it itself, over its own input and output:
nothing listens on the network.

## Getting started and staying up to date

- Install with one Terminal line, or by hand. [Install](install.md)
- Import from Granola's export and Quill's backup. [Importing](importing.md)
- Updates from signed releases, checked daily and installed when you choose.
  [Updates](updates.md)
- Moving from the Electron version (0.3 and earlier) in place.
  [Moving from Electron](moving-from-electron.md)
