// Reading the meeting files for the rendered views. Each format Oatcake has written, plus
// Granola's imports, is understood.

import { seconds } from "./format.ts";

/** "0:20" → "00:20", so every timestamp reads the same way. */
export const padStamp = (stamp: string) => (/^\d:\d\d$/.test(stamp) ? `0${stamp}` : stamp);

export interface TranscriptLine {
  stamp: string;
  at: number;
  speaker: string;
  text: string;
}

const STAMP = String.raw`(\d{1,2}:\d\d(?::\d\d)?)`;
const FORMATS = [
  // **[12:34] Name:** text   (Oatcake)
  new RegExp(String.raw`^\*\*\[${STAMP}\]\s+(.+?):\*\*\s*(.*)$`),
  // [12:34] **Name:** text
  new RegExp(String.raw`^\[${STAMP}\]\s+\*\*(.+?):\*\*\s*(.*)$`),
  // [12:34] System audio (Name): text   /   [12:34] Microphone: text   (Granola)
  new RegExp(String.raw`^\[${STAMP}\]\s+([^:]{1,80}?):\s+(.*)$`),
];

export function parseTranscript(markdown: string): TranscriptLine[] {
  const out: TranscriptLine[] = [];
  for (const raw of markdown.split("\n")) {
    const line = raw.trim();
    for (const re of FORMATS) {
      const m = line.match(re);
      if (m) {
        out.push({ stamp: padStamp(m[1]), at: seconds(m[1]), speaker: m[2].replace(/^System audio \((.+)\)$/, "$1"), text: m[3] });
        break;
      }
    }
  }
  return out;
}

export interface NoteLine {
  /** null for a prep note written before the call. */
  stamp: string | null;
  text: string;
}

export function parseNotes(markdown: string): NoteLine[] {
  return markdown
    .split("\n")
    .map((l) => l.match(new RegExp(String.raw`^\s*[-*]\s+(?:\[${STAMP}\]\s+)?(.*)$`)))
    .filter((m): m is RegExpMatchArray => !!m && !!m[2].trim() && !/^\*\*[^*]+:\*\*/.test(m[2]))
    .map((m) => ({ stamp: m[1] ? padStamp(m[1]) : null, text: m[2].trim() }));
}

export interface Todo {
  /** Line number in todo.md, for ticking it off. */
  line: number;
  done: boolean;
  text: string;
  owner: string;
  due: string;
  stamp: string;
}

/** "- [ ] Task — Owner — due Fri, Oct 30 — [12:34]" (owner, due date and time optional). */
export function parseTodos(markdown: string): Todo[] {
  const out: Todo[] = [];
  markdown.split("\n").forEach((l, line) => {
    const m = l.match(/^\s*[-*]\s+\[( |x|X)\]\s+(.*)$/);
    if (!m) return;
    const parts = m[2].split(/\s+—\s+/);
    const todo: Todo = { line, done: m[1] !== " ", text: parts[0], owner: "", due: "", stamp: "" };
    for (const p of parts.slice(1)) {
      const stamp = p.match(new RegExp(String.raw`^\[${STAMP}\]$`));
      if (stamp) todo.stamp = padStamp(stamp[1]);
      else if (/^due\s+/i.test(p)) todo.due = p.replace(/^due\s+/i, "");
      else todo.owner = p;
    }
    out.push(todo);
  });
  return out;
}

/** todo.md with one item ticked or unticked. */
export function toggleTodo(markdown: string, line: number): string {
  const lines = markdown.split("\n");
  lines[line] = lines[line].replace(/\[( |x|X)\]/, (box) => (box === "[ ]" ? "[x]" : "[ ]"));
  return lines.join("\n");
}

/**
 * A typed to-do in todo.md's form. " - " and " -- " count as the separator (an em dash is awkward
 * to type), and `owner` fills in when none is given: "Send the deck - due Fri, Nov 6" with owner
 * "Sam" becomes "Send the deck — Sam — due Fri, Nov 6".
 */
export function typedTodo(text: string, owner?: string): string {
  const parts = text.trim().split(/\s+(?:—|--|-)\s+/);
  const isField = (p: string) => /^due\s/i.test(p) || /^\[\d{1,2}:\d\d(?::\d\d)?\]$/.test(p);
  const named = parts.slice(1).some((p) => !isField(p));
  if (owner && !named) parts.splice(1, 0, owner);
  return parts.join(" — ");
}

/** todo.md with a new open to-do at the end. */
export function addTodo(markdown: string, text: string): string {
  const base = markdown.replace(/\s*$/, "");
  return `${base ? base + "\n" : ""}- [ ] ${text.trim()}\n`;
}
