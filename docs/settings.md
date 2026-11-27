# Settings

Open Settings with ⌘, or choose **Settings** from Oatcake's menu bar icon. It opens in its own
window, with a pane for each part of Oatcake; changes apply as you make them. They're stored in
`~/Library/Application Support/Oatcake/config.json`, apart from connected calendars' names, colours
and private addresses (see [Calendars](#calendars)). If `config.json` can't be read, Oatcake starts
on its defaults, says so when it opens, and keeps the file beside it as `config.unreadable.json`. A
switch that works by notification says so when notifications are turned off for Oatcake in System
Settings, with **Open notification settings**.

## General

- **Your name:** labels your microphone track in every transcript, and is who "Mine" means on the
  To-dos page.
- **Run in the background** (on to start with): closing the last window takes Oatcake out of the
  Dock and keeps it in the menu bar so it can still check for calls and send reminders. Turn it
  off to quit when the last window closes, once any recording or work has finished.
- **Microphone:** "Same as Mac" follows System Settings › Sound; a chosen mic is used until it's
  unplugged, then the Mac's input until it's back. It can also be changed on the record screen
  and during the call (see [Record](how-it-works.md#1-record)).
- **Live transcript** (on to start with): shows what's being said beside your notes during the
  call (see [Live transcript](how-it-works.md#live-transcript)).
- **Name voices during the call** (on to start with): names the people Oatcake knows by voice in
  the live transcript, and lets you click a line to say who said it. Turned off, the live
  transcript doesn't load the voice models: about 180 MB less memory during a call, and a little
  less CPU.
- **After a call:** wait for you to check who's who (the default), or save each call once it's
  transcribed, with a summary or with the transcript only (see
  [Saving without Who's who](how-it-works.md#saving-without-whos-who)).
- **Offer to record when a call starts** and **Stop recording when the call ends** (both on to
  start with): see [Calls are noticed](how-it-works.md#calls-are-noticed).
- **Collect to-dos** (on to start with). Turned off, no to-dos are asked for when a summary is
  written, and the To-dos page, the sidebar's counts, each meeting's checklist, Regenerate to-dos
  and the to-do settings are hidden; Copy, Share, search and Ask leave to-dos out. Each meeting's
  `todo.md` is left as it is, so turning it back on brings them back. The summary still doesn't
  list action items (Summary instructions say so), so with this off they aren't kept anywhere
  unless you change those instructions.

## Calendars

- **Add calendar…** connects a calendar. Give it a name and paste its private iCal address (Google
  Calendar › Settings › your calendar › Integrate calendar › “Secret address in iCal format”).
  Any other calendar that gives you an iCal (`.ics`) address starting `https://` or `webcal://`
  works the same way.
  In the Add or Edit dialog, click the colour dot to open the same swatch picker as in People.
  Repeat for each calendar. **Edit…** changes the name or colour, replaces the
  address if you paste a new one, or removes the calendar. Oatcake keeps any previously connected
  calendar. Private addresses are stored in `private.json`, readable only by your user account,
  and aren't shown again in Settings.

  Oatcake refreshes each calendar once an hour, or when you press ↻ next to Upcoming (⌘R). If one
  feed fails, it keeps that feed’s last fetched events and reports the problem beside that calendar
  in Settings (not connected to the internet, server not found, no secure connection, too slow to
  answer), and tries again a minute later, then after waits that double, up to the hour. The other
  feeds continue to update.

  Home and the sidebar show one chronological list of timed events in progress or starting today
  or tomorrow, leaving out events you declined, in the same rows ("No more calls today or
  tomorrow." when there are none). The sidebar shows up to six. The coloured dots
  identify the source calendars; hover over the event to see their names. When the same invitation
  and start time appear on more than one feed, it gets one row with all its dots and one reminder.
  With no calendars connected, Home offers **Connect calendar** and the sidebar hides Upcoming.

  **Record a call** shows the matching calendars’ names and dots above Attendees. When you save
  the meeting, the dots appear in the meeting list. The meeting file keeps only
  local calendar IDs, not names or addresses. The dots reflect your current colours and disappear
  if you remove a calendar. Older meetings without calendar information don’t get a dot.

  On Home, **Join the call** opens the call link without recording. Clicking an event, on Home or in
  the sidebar, opens Record a call for it, named after it, in the folder with the same name
  or path ("John & Jane 1:1" finds "John & Jane 1-1", "Product – Weekly sync" finds "Product ›
  Weekly sync"), or offering a new folder for a recurring event with none. **Join the call** opens
  its Meet, Zoom or Teams link (only links on those services' own domains count, so a look-alike
  address is never opened).
- **Add from this Mac…** adds calendars that are already in this Mac's Calendar app (from iCloud,
  Google, Exchange or any other account set up there) instead of by address. The first time,
  macOS asks whether Oatcake may have full access to your calendars; then tick the ones you want
  and choose **Add**. Each is named after the calendar and given a badge colour, which **Edit…**
  changes, and is removed there like any other. Their events are read from this Mac whenever its
  calendars change, as well as once an hour, and not kept in a file of their own. If access is
  turned off, Settings says so, with **Open Privacy & Security** to turn it back on (System
  Settings › Privacy & Security › Calendars). The same invitation on a private address and on
  this Mac's calendar shows once, with both dots. Oatcake never changes your calendars.
### Reminders

- **Remind me before calls** (on to start with): before each timed event, a notification with
  **Join and start recording**. The button opens the call link when the event has one,
  starts recording it (in the folder named like the event; a new folder for a recurring event
  without one, ":" and "/" becoming "-"), and brings Oatcake forward on the live notes. If the
  event has gone from your calendars since, the button says so and starts nothing. Clicking the
  notification itself opens Record a call for the event. macOS asks once whether Oatcake may send
  notifications; the packaged app asks for Alerts, so reminders stay up until dealt with.
- **Reminder** (while reminders are on): how long before each call it comes, 5 minutes to start
  with. **Add reminder** adds another (5 minutes and 1 minute before, say), and − removes one.
  Each call is reminded once for each; if Oatcake opens when more than one of them has come, one
  reminder covers them. Which reminders have gone out is kept in `reminders.json` in Oatcake's
  data folder, so opening Oatcake again (an update does) doesn't remind again. A call you're
  already recording isn't reminded of: its sound would go into the recording.
- **Show my next call in the menu bar** (on to start with, with a calendar connected): Oatcake's
  oatcake with the time until it starts, and what's coming up in its menu (see
  [The menu bar](how-it-works.md#the-menu-bar)). Turning this off hides calendar details, not the
  icon while **Run in the background** is on. That setting controls whether reminders and call
  notices still work with the window closed.
### Events that aren’t calls

- **Events that aren't calls:** events whose titles start with one of these names, as whole words
  ("Focus time", "Out of office", "Working location" and "Task" to begin with; "Task" doesn't leave
  out "Taskforce sync"), or that have "Oatcake ignore" anywhere in the title, are left out of
  Upcoming, the menu bar and reminders. Separate them with commas; capitals don't matter. iCal
  doesn't say which events are Google's focus-time or out-of-office blocks, so a block renamed to
  something else still appears, and a call whose title starts with one of those names doesn't.
- **Ignored events:** a call you can't rename (someone else's recurring meeting) can be ignored on
  its own: right-click it in Upcoming for **Ignore This Event**, or for a recurring one **Ignore
  This One** or **Ignore This and Following Events**. That's kept in `config.json`, nothing changes
  in your calendar, and **Stop ignoring** here brings one back (the list shows once there are
  some). An occurrence its organiser moves shows again (its ID includes its start), and so does the
  rest of a series changed with Google's "this and following events" (that gives it a new UID).

## People

The voices Oatcake recognises. **Rename…** one ("John" to "John Smith") to change the name it
suggests from now on. **Merge into** (once there are two or more) makes two people one, under the
name you pick from its menu: both sets of fingerprints are kept, up to the 10 newest, and it asks
first; renaming to a name that's already there does the same. **Forget…** stops it recognising
them. Meetings already saved keep the names they were saved with (to change
one meeting's, use [Rename People](how-it-works.md#rename-people)).

Click someone's avatar to choose their colour from the palette's twelve: it's theirs everywhere,
in avatars and in names in transcripts. Oatcake otherwise gives each first name a colour the first
time it sees it, so a colour you choose is kept for the full name, and two people called Jane can
have different ones. **Use the colour Oatcake gave them** goes back to that. Renaming someone takes
their chosen colour with them, and so does merging them into someone who hasn't one.

## Models

- **Speech to text:** Parakeet English; Bark English, which leaves out "um", false starts and
  repeated words; Parakeet for 25 European languages; or SenseVoice for Chinese, Cantonese,
  Japanese, Korean and English (`SpeechModels.asr`). A model you haven't used yet downloads
  before the next call is transcribed. See [Speech models](models.md#speech-models).
- **Language model:** what writes summaries, to-dos and drafts for sharing, suggests names and answers questions.
  Qwen3.6 35B-A3B or Qwen3.5 4B, which Oatcake downloads and runs on this Mac (the one that suits
  its memory is chosen to start with, and marked "recommended for this Mac"; one this Mac has too
  little memory for says so), Google's Gemma 4 26B-A4B or 12B, to choose instead, Qwen3 8B or 4B
  (marked "older model": kept for those who chose them), or a model server of your own: Ollama, LM Studio or another with the same
  chat API (`http://localhost:11434/v1` for Ollama). Its address has to be this Mac, a machine on
  your network or a private IP address, and no key is sent to it. **Context**, for a server of your
  own, is how many tokens it's set to hold (Ollama's `num_ctx`, llama.cpp's `-c`): Oatcake sends no
  more than that at once, splitting a long call into parts if it has to. It doesn't change the
  server's setting, so match it to the server. Empty means 32,768, and Oatcake needs at least
  16,384. Under the list of models, whether the chosen one is on this Mac (or a server's details),
  and **Check it works**: **Download now** fetches the
  chosen model straight away rather than at your first call, **Stop** stops a download, **Remove…**
  deletes it (or **Remove partial download…**), each asking first, and **Test** asks it for one word. A model on a
  server of your own that reasons first can still be reasoning when the test's room for that word
  runs out: it answered, so that's a pass too. Choosing one of Oatcake's models sets the
  reasoning switches in Settings › Summaries to what suits it, and a note under the list says
  which changed; choosing a server of your own leaves them as they are. See
  [Language model](models.md#language-model).

(Earlier versions had speech to text in a pane of its own, Transcription.)

## Summaries

One section for each thing the model writes, each with its instructions and its reasoning switch
side by side. Instructions show as Oatcake's own or yours; **Edit…** opens them below (saved as
you type), and **Restore default…** there brings Oatcake's own back. **Reasoning** is whether the
model thinks a task through before it replies: slower, and not always better. Choosing one of
Oatcake's models in Settings › Models sets the switches to what suited it in Oatcake's tests:
all off for Qwen3.5, Qwen3.6 and Gemma 4, which Oatcake chooses from to start with (they took
minutes longer and wrote no better summaries with it on), and on for Qwen3 except for to-dos (see
the notes on each task below, and [Language model](models.md#language-model)). Choosing a server
of your own keeps the switches as they were. With a server of yours they're shown but can't be
changed, as it decides for itself, until you choose the **Reasoning switch** it takes in Settings
› Models: **Ollama** (its `reasoning_effort`: `medium` to reason, `none` not to) or **llama.cpp**
(the `enable_thinking` that Qwen's and Gemma 4's chat templates read, as Oatcake's own server
uses). Then each switch is sent with its task's requests. A model that can't turn reasoning off
(GPT-OSS on Ollama) keeps its lowest level; one on Ollama that can't reason at all is asked again
without the switch.
**Leave it to the server**, the default, sends nothing about reasoning.

- **Jargon:** names, products and acronyms, separated by commas. The model is told to spell them
  as written, in summaries, to-dos, drafts, name suggestions and Ask's answers. Transcripts keep
  what the speech model heard.
- **Summary:** what the model is told to write once it has read the transcript. Change the
  headings, the level of detail or the language to suit you. To-dos are collected separately and
  aren't affected. With Qwen3, reasoning starts on: decisions went to the right person more
  reliably with it.
- **Summary templates:** other summary instructions, each with a name, for the meetings that need a
  different summary (a one-to-one you lead, one with your own lead, a team meeting). **Add
  Template** starts one as a copy of the summary instructions; change its name and instructions in
  place, or **Delete…** it. Pick one on [Record a call](how-it-works.md#1-record) or change it from
  [Regenerate Summary](how-it-works.md#regenerate-and-summary-templates). The meeting
  keeps the choice without changing your standard summary instructions.
  A meeting keeps its template by name: once that template is renamed or deleted, the meeting is
  back on the summary instructions, until a template is given that name again. A new name is saved
  when you press Return, leave the field, switch pane or close Settings. A template with no
  instructions means the summary instructions. The summary starts at the model's
  first `## ` heading: anything written before it is left out.
- **To-dos** (while to-dos are collected): what the model is told counts as a to-do. Oatcake's
  own keep it to what somebody said they'd do after the call, and leave out what was only
  discussed, what was asked and not taken on, what was done during the call, and small talk. Make
  it stricter or looser, or keep it to your own action items. The shape of each to-do (task,
  owner, due date, time) isn't part of it. Reasoning starts off with every model: with Qwen3,
  to-dos lost detail with it.
- **Draft for sharing:** what the model is told when it writes a meeting's
  [draft for sharing](how-it-works.md#draft-for-sharing) from its summary and to-dos. Oatcake's
  own ask for an update for people who weren't there: decisions and next steps first, short
  bullet points, nothing the notes don't say. Reasoning starts as it does for summaries (not
  measured for drafts).
- **Reasoning for name suggestions and Ask:** with Qwen3 both start on: names were made up less
  often, and answers kept to the question. With Qwen3.5 4B and reasoning off, voices are left for
  you to name rather than given a suggested name.

## Storage

- **Meetings folder:** where meetings are saved; **Choose…** picks another. Choosing another folder
  doesn't move anything: meetings already in the old one stay where they are.
- **Keep call audio after saving** (off to start with): audio is deleted once a meeting is saved.
  When on, the call's audio (both sides, mixed) is saved in the meeting's folder as `audio.m4a`.
  If it can't be written there, Oatcake says why and tries again after the next save or launch. A
  meeting deleted before its audio was written sends that audio to the Trash.
- **Import from Granola** and **Import from Quill:** **Import…** picks an export (see
  [Importing](importing.md)).

### Other apps (local MCP server)

Turn on **Let other apps read my meetings** to let an app that supports the Model Context Protocol
(MCP), such as Claude Code or Claude Desktop, browse and search the current Meetings folder, read
saved meetings' summaries, transcripts, notes and to-dos, and list open and completed to-dos. It's
off to start with, and it only reads: drafts for sharing, recordings and settings aren't offered.

While it's on, Settings shows what to add to the app's MCP settings: a server named `oatcake`
whose command is Oatcake's own program (`/Applications/Oatcake.app/Contents/MacOS/Oatcake` for an
installed copy) with the argument `--mcp`. An app that asks for the command and its arguments
separately takes those two. The app starts that server itself and talks to it over its standard
input and output, so it works whether or not Oatcake is open, and nothing listens on the network:
there's no port or password. The server checks this switch before every request, so turning it
off stops apps reading at once.

Anything an app reads this way is in that app's hands: one that uses an online model may send it
to that service.

If the Meetings folder is moved or replaced outside Oatcake, apps can't read it until it's
approved again: check the folder in Storage and turn the switch off and on again, or choose the
intended folder there.

## Updates

- **Check now**, and what's new in a release that's waiting, with **Install and relaunch…**, which asks first as the sidebar's **Update…** does (or the
  install line to copy, for a copy that can't update itself).
- **Check for updates automatically** (on to start with): once a day. Nothing is installed until
  you choose to. See [Updates](updates.md).
