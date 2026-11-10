import fs from "node:fs";
import path from "node:path";
import type { Config } from "./config.ts";
import { createLlm } from "./llm/index.ts";
import { ME, type Analysis, type Line } from "./process.ts";
import { deleteAudio, loadNotes, recordingDir, type Note, type Recording } from "./recordings.ts";
import { addVoiceprints } from "./speakers.ts";
import { meetingFolderName, resolveInside } from "./meetings.ts";

/** What the user decided for one speaker in review. */
export type Decision =
  | { kind: "name"; name: string }
  | { kind: "merge"; into: string }
  | { kind: "mixed" }
  | { kind: "ignore" };

/** A voiceprint needs this much of one person's speech to be worth keeping. */
const MIN_VOICEPRINT_SECONDS = 30;

export interface MeetingMeta {
  title: string;
  startedAt: string;
  endedAt: string;
  participants: string[];
}

/** "Voice 1", "Voice 2"… in the order review lists them (most talking first). */
export const voiceLabel = (analysis: Analysis, id: string) => `Voice ${analysis.speakers.findIndex((s) => s.id === id) + 1}`;

/**
 * Writes the meeting folder (summary.md, transcript.md, notes.md, todo.md, meeting.json) into
 * `folder` (relative to the Meetings folder), saves confirmed voiceprints, and
 * returns the meeting's path relative to the Meetings folder.
 */
export async function saveMeeting(
  config: Config,
  rec: Recording,
  decisions: Record<string, Decision>,
  folder: string,
  onStep: (step: string) => void,
): Promise<string> {
  const analysis: Analysis = JSON.parse(fs.readFileSync(path.join(rec.dir, "analysis.json"), "utf8"));
  const notes = loadNotes(rec.id);

  /** The decision a voice ends up with once merges are followed (null for your microphone). */
  const settled = (id: string, seen = new Set<string>()): { id: string; decision?: Decision } | null => {
    if (id === ME) return null;
    const d = decisions[id];
    if (d?.kind !== "merge" || seen.has(id)) return { id, decision: d };
    seen.add(id);
    return settled(d.into, seen);
  };
  const nameOf = (id: string): string | null => {
    const s = settled(id);
    if (!s) return config.myName;
    const d = s.decision;
    if (d?.kind === "ignore") return null;
    if (d?.kind === "mixed") return "Several people";
    if (d?.kind === "name" && d.name.trim()) return d.name.trim();
    // Unnamed, or (shouldn't happen) no decision at all: keep the lines under a neutral label.
    return analysis.speakers.some((sp) => sp.id === s.id) ? voiceLabel(analysis, s.id) : "Call audio";
  };
  /** Only a name typed or accepted in review is worth remembering: not "Voice 2", "Several people" or you. */
  const rememberedName = (id: string): string | null => {
    const d = settled(id)?.decision;
    return d?.kind === "name" && d.name.trim() ? d.name.trim() : null;
  };

  const named = analysis.lines
    .map((l) => ({ ...l, speaker: nameOf(l.speaker) }))
    .filter((l): l is Line => l.speaker !== null);
  const paragraphs = mergeRuns(named);
  const participants = [...new Set([config.myName, ...paragraphs.map((p) => p.speaker)])].filter(
    (n) => n !== "Several people",
  );

  const meta: MeetingMeta = {
    title: analysis.title,
    startedAt: analysis.startedAt,
    endedAt: analysis.endedAt,
    participants,
  };
  const transcript = transcriptMarkdown(paragraphs);

  onStep("Writing the summary");
  const { summary, todo } = await summarise(config, meta, notes, transcript);

  const outRel = path.join(folder, meetingFolderName(meta));
  const out = resolveInside(config.outputDir, outRel);
  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, "transcript.md"), transcript);
  fs.writeFileSync(path.join(out, "summary.md"), summary);
  if (todo) fs.writeFileSync(path.join(out, "todo.md"), todo);
  if (notes.length) fs.writeFileSync(path.join(out, "notes.md"), notesMarkdown(notes));
  fs.writeFileSync(path.join(out, "meeting.json"), JSON.stringify({ ...meta, recording: rec.id }, null, 2) + "\n");

  // Only now the meeting is written, so a failed summary that's retried doesn't add the same voices twice.
  onStep("Saving voiceprints");
  addVoiceprints(
    analysis.speakers.flatMap((s) => {
      const name = rememberedName(s.id);
      return name && s.embedding && s.seconds >= MIN_VOICEPRINT_SECONDS ? [{ name, embedding: s.embedding }] : [];
    }),
    rec.id,
  );

  fs.writeFileSync(path.join(recordingDir(rec.id), "saved.json"), JSON.stringify({ meeting: outRel }) + "\n");
  if (!config.keepAudio) deleteAudio(rec);
  return outRel;
}

function mergeRuns(lines: Line[]): Line[] {
  const out: Line[] = [];
  for (const l of lines) {
    const last = out.at(-1);
    if (last && last.speaker === l.speaker && l.start - last.end < 3) {
      last.text += " " + l.text;
      last.end = l.end;
    } else {
      out.push({ ...l });
    }
  }
  return out;
}

const clock = (seconds: number) => {
  const s = Math.max(0, Math.round(seconds));
  const h = Math.floor(s / 3600);
  const mm = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
  const ss = String(s % 60).padStart(2, "0");
  return h ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
};

// The title, date and participants live in meeting.json (and the meeting view's header), so the
// Markdown files hold only their content.
function transcriptMarkdown(paragraphs: Line[]): string {
  return paragraphs.map((p) => `**[${clock(p.start)}] ${p.speaker}:** ${p.text}`).join("\n\n") + "\n";
}

/** "- [12:34] point", or "- point" for a prep note written before the call. */
function notesMarkdown(notes: Note[]): string {
  return notes.map((n) => (n.at === null ? `- ${n.text}` : `- [${clock(n.at)}] ${n.text}`)).join("\n") + "\n";
}

const TODO_MARKER = "=== TO-DOS ===";
/** "- [ ] Task — Owner — due Fri, Oct 30 — [12:34]" (owner, due date and time optional). */
const TODO_LINE = /^\s*[-*]\s+\[( |x|X)\]\s+\S/;

/** Writes summary.md's body and todo.md's to-dos in one model call. */
async function summarise(
  config: Config,
  meta: MeetingMeta,
  notes: Note[],
  transcript: string,
): Promise<{ summary: string; todo: string }> {
  // The notes stay the note-taker's own (notes.md). Here they only tell the model what mattered.
  const notesBlock = notes.length
    ? [
        `${config.myName} took these notes ([mm:ss] = time into the call; "before the call" = prep written`,
        "beforehand). They are kept separately, so don't copy them into the summary. Treat them as a signal",
        "of what mattered most to the note-taker: cover those topics fully, with the details from the",
        "transcript around each timestamp, and keep everything else brief.",
        ...notes.map((n) => `[${n.at === null ? "before the call" : clock(n.at)}] ${n.text}`),
      ].join("\n")
    : "";

  const reply = await createLlm(config.llm).complete(
    "You write concise, accurate meeting notes in Markdown. Use only facts from the transcript and notes. " +
      "Name who said or decided what. Follow the reply format exactly.",
    [
      `Meeting: ${meta.title}`,
      `Participants: ${meta.participants.join(", ")}`,
      "",
      notesBlock,
      "",
      "Reply in two parts.",
      "1. The summary: organised by topic under your own '##' headings, starting at the first '##'.",
      "   Leave action items out of it; they go in part 2. You may cite a moment as [mm:ss].",
      `2. A line reading exactly ${TODO_MARKER}, then one line per action item agreed in the call:`,
      "   - [ ] What to do — Owner — due <date, only if one was stated, e.g. Fri, Oct 30> — [mm:ss]",
      "   Owner is the person's name as in the transcript; leave out any part that isn't known, and",
      "   [mm:ss] is when it was agreed. If nothing was agreed, write nothing after the marker.",
      "",
      "Transcript:",
      transcript,
    ].join("\n"),
  );
  const [summaryPart, todoPart = ""] = reply.split(TODO_MARKER);
  const todos = todoPart.split("\n").filter((l) => TODO_LINE.test(l)).map((l) => l.trim());
  return {
    summary: summaryPart.trim() + "\n",
    todo: todos.length ? todos.join("\n") + "\n" : "",
  };
}
