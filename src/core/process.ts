// Turns a recording into analysis.json: transcribed lines from both tracks, the
// call audio split into speakers A, B, C…, voice matches and suggested names, and
// short clips per speaker for review. The native models block the event loop, so
// the app runs this in a utility process (src/main/analyse-worker.ts).

import fs from "node:fs";
import path from "node:path";
import { readPcm, slice, writeWav } from "./audio.ts";
import { sherpaTranscriber, type Utterance, type Word } from "./asr.ts";
import { loadConfig } from "./config.ts";
import { createLlm, parseJsonObject } from "./llm/index.ts";
import { ensureModels } from "./models.ts";
import { diarize, embed, knownPeople, match, type Turn } from "./speakers.ts";

export const ME = "me";

export interface Line {
  /** ME, or a speaker letter for the call audio. */
  speaker: string;
  /** Seconds from the start of the recording. */
  start: number;
  end: number;
  text: string;
}

export interface SpeakerInfo {
  id: string;
  seconds: number;
  embedding: number[] | null;
  suggestion?: { name: string; how: "voice" | "transcript"; detail: string };
  quotes: { text: string; start: number; end: number; clip: string }[];
}

export interface Analysis {
  title: string;
  startedAt: string;
  endedAt: string;
  lines: Line[];
  speakers: SpeakerInfo[];
  echoLinesRemoved: number;
  /** Your microphone: talking time and a few clips (missing from analyses made before Nov 2026). */
  me?: { seconds: number; quotes: SpeakerInfo["quotes"] };
  /** Steps that were skipped, shown on the review screen. */
  warnings: string[];
}

export type Progress = { step?: string; fraction?: number; warning?: string };

export async function analyse(dir: string, report: (p: Progress) => void): Promise<void> {
  const config = loadConfig();
  const call = JSON.parse(fs.readFileSync(path.join(dir, "call.json"), "utf8"));
  const meta = JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8"));

  ensureModels(config.asrModel, (message) => report({ step: message }));

  report({ step: "Loading speech model" });
  const asr = sherpaTranscriber(config.asrModel);

  report({ step: "Transcribing your microphone", fraction: 0 });
  const mic = readPcm(path.join(dir, "mic.pcm"));
  const micLines = asr
    .transcribe(mic, (fraction) => report({ step: "Transcribing your microphone", fraction }))
    .map((u) => shift({ speaker: ME, start: u.start, end: u.end, text: u.text }, meta.micOffset));

  report({ step: "Transcribing the call audio", fraction: 0 });
  const system = readPcm(path.join(dir, "system.pcm"));
  const systemUtterances = asr.transcribe(system, (fraction) =>
    report({ step: "Transcribing the call audio", fraction }),
  );

  report({ step: "Telling voices apart" });
  const turns = systemUtterances.length ? diarize(system) : [];
  const letters = speakerLetters(turns);
  const systemLines = systemUtterances
    .flatMap((u) => splitBySpeaker(u, turns, letters))
    .map((l) => shift(l, meta.systemOffset));

  // On speakers, the mic also hears the other side. Drop mic lines that repeat call audio.
  const keptMic = micLines.filter((m) => !isEcho(m, systemLines));
  const lines = [...keptMic, ...systemLines].sort((a, b) => a.start - b.start);

  report({ step: "Matching voices" });
  fs.mkdirSync(path.join(dir, "clips"), { recursive: true });
  // From the lines rather than the turns: when diarisation finds nothing, the call audio is all
  // speaker "A", and it still needs a card in review (or its lines would be dropped on save).
  const speakers: SpeakerInfo[] = [...new Set(systemLines.map((l) => l.speaker))].map((id) => {
    const own = turns.filter((t) => letters.get(t.speaker) === id);
    const embedding = own.length ? embed(system, own) : null;
    const voice = embedding ? match(embedding) : null;
    const quotes = systemLines
      .filter((l) => l.speaker === id && l.end - l.start >= 1.5)
      .sort((a, b) => b.text.length - a.text.length)
      .slice(0, 3)
      .sort((a, b) => a.start - b.start)
      .map((l, i) => {
        const clip = path.join(dir, "clips", `${id}-${i + 1}.wav`);
        const from = l.start - meta.systemOffset;
        writeWav(clip, slice(system, from, Math.min(from + 10, l.end - meta.systemOffset)));
        return { text: l.text, start: l.start, end: l.end, clip };
      });
    return {
      id,
      seconds: own.length
        ? own.reduce((n, t) => n + t.end - t.start, 0)
        : systemLines.filter((l) => l.speaker === id).reduce((n, l) => n + l.end - l.start, 0),
      embedding,
      quotes,
      ...(voice && { suggestion: { name: voice.name, how: "voice" as const, detail: `voice match ${voice.score.toFixed(2)}` } }),
    };
  });

  // A few clips of your own voice, for review.
  const me = {
    seconds: keptMic.reduce((n, l) => n + l.end - l.start, 0),
    quotes: keptMic
      .filter((l) => l.end - l.start >= 1.5)
      .sort((a, b) => b.text.length - a.text.length)
      .slice(0, 3)
      .sort((a, b) => a.start - b.start)
      .map((l, i) => {
        const clip = path.join(dir, "clips", `me-${i + 1}.wav`);
        const from = l.start - meta.micOffset;
        writeWav(clip, slice(mic, from, Math.min(from + 10, l.end - meta.micOffset)));
        return { text: l.text, start: l.start, end: l.end, clip };
      }),
  };

  const warnings: string[] = [];
  const unknown = speakers.filter((s) => !s.suggestion);
  if (unknown.length) {
    report({ step: "Suggesting names from the conversation" });
    try {
      await suggestFromTranscript(config, call.title, lines, speakers, unknown);
    } catch (error) {
      warnings.push(`Name suggestions skipped: ${(error as Error).message}`);
    }
  }

  const analysis: Analysis = {
    title: call.title,
    startedAt: meta.startedAt,
    endedAt: meta.endedAt,
    lines,
    speakers: speakers.sort((a, b) => b.seconds - a.seconds),
    echoLinesRemoved: micLines.length - keptMic.length,
    me,
    warnings,
  };
  fs.writeFileSync(path.join(dir, "analysis.json"), JSON.stringify(analysis, null, 2));
}

function shift(line: Line, offset: number): Line {
  return { ...line, start: line.start + offset, end: line.end + offset };
}

/** Letters by order of first appearance: A speaks first. */
function speakerLetters(turns: Turn[]): Map<number, string> {
  const letters = new Map<number, string>();
  for (const t of [...turns].sort((a, b) => a.start - b.start)) {
    if (!letters.has(t.speaker)) letters.set(t.speaker, String.fromCharCode(65 + letters.size));
  }
  return letters;
}

/** Gives each word the speaker whose turn covers (or is nearest) its midpoint, then groups runs. */
function splitBySpeaker(u: Utterance, turns: Turn[], letters: Map<number, string>): Line[] {
  if (!turns.length) return [{ speaker: "A", start: u.start, end: u.end, text: u.text }];
  const speakerAt = (w: Word) => {
    const mid = (w.start + w.end) / 2;
    let best = turns[0];
    let bestGap = Infinity;
    for (const t of turns) {
      const gap = mid < t.start ? t.start - mid : mid > t.end ? mid - t.end : 0;
      if (gap < bestGap) [best, bestGap] = [t, gap];
    }
    return letters.get(best.speaker)!;
  };
  const words = u.words.length ? u.words : [{ text: u.text, start: u.start, end: u.end }];
  const lines: Line[] = [];
  for (const w of words) {
    const speaker = speakerAt(w);
    const last = lines.at(-1);
    if (last?.speaker === speaker) {
      last.text += " " + w.text;
      last.end = w.end;
    } else {
      lines.push({ speaker, start: w.start, end: w.end, text: w.text });
    }
  }
  // Parakeet's own punctuation survives on the word text; tidy the spacing.
  return lines.map((l) => ({ ...l, text: l.text.replace(/\s+([,.!?;:])/g, "$1").trim() }));
}

const ECHO_WINDOW = 6;
const words = (text: string) => text.toLowerCase().match(/[\p{L}\p{N}']+/gu) ?? [];
const pairs = (w: string[]) => w.slice(1).map((x, i) => `${w[i]} ${x}`);

/**
 * A mic line is echo when most of its word pairs were said, in that order, on the call audio within
 * a few seconds. Pairs rather than single words, so a short reply made of the same common words
 * ("yes, I agree that's fine" after "I think that's fine, do you agree?") isn't mistaken for echo.
 */
function isEcho(mic: Line, systemLines: Line[]): boolean {
  const own = pairs(words(mic.text));
  if (!own.length) return false;
  const nearby = new Set(
    systemLines
      .filter((s) => s.end >= mic.start - ECHO_WINDOW && s.start <= mic.end + ECHO_WINDOW)
      .flatMap((s) => pairs(words(s.text))),
  );
  return own.filter((p) => nearby.has(p)).length / own.length >= 0.5;
}

async function suggestFromTranscript(
  config: ReturnType<typeof loadConfig>,
  title: string,
  lines: Line[],
  speakers: SpeakerInfo[],
  unknown: SpeakerInfo[],
) {
  const label = (id: string) =>
    id === ME ? `${config.myName} (recorder)` : (speakers.find((s) => s.id === id)?.suggestion?.name ?? `Speaker ${id}`);
  const transcript = lines.map((l) => `${label(l.speaker)}: ${l.text}`).join("\n");
  const reply = await createLlm(config.llm).complete(
    "You identify speakers in meeting transcripts. Reply with JSON only.",
    [
      `Meeting title: ${title}`,
      `People the user has met before: ${knownPeople().join(", ") || "none yet"}`,
      `Unidentified speakers: ${unknown.map((s) => `Speaker ${s.id}`).join(", ")}`,
      "",
      "For each unidentified speaker, use evidence in the transcript (being addressed by name,",
      "introducing themselves, the meeting title) to name them. Use null when there is no real evidence.",
      "Quote the few words that show it, exactly as in the transcript.",
      'Reply as {"A": {"name": "Full Name" or null, "quote": "the words that show it"}, ...}',
      "",
      "Transcript:",
      transcript,
    ].join("\n"),
  );
  const guesses = parseJsonObject<Record<string, { name: string | null; quote?: string; evidence?: string }>>(reply);
  for (const s of unknown) {
    const guess = guesses[s.id];
    if (guess?.name) s.suggestion = { name: guess.name, how: "transcript", detail: guess.quote ?? guess.evidence ?? "" };
  }
}

