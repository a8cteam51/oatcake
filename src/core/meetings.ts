// The Meetings folder on disk is the source of truth: a folder holding meeting.json
// is a meeting, any other folder is a folder you organise meetings into. Renames
// and moves here are plain filesystem renames, so Finder and the app stay in step.

import fs from "node:fs";
import path from "node:path";
import { previewOf } from "../shared/markdown.ts";
import { writeAtomic } from "./files.ts";

export interface TreeNode {
  name: string;
  /** Path relative to the Meetings folder ("" for the root). */
  path: string;
  kind: "folder" | "meeting";
  children?: TreeNode[];
  /** Meetings only, from meeting.json. */
  title?: string;
  startedAt?: string;
  endedAt?: string;
  /** Imported from a Granola export. */
  granola?: boolean;
  /** The summary's first line of prose. */
  preview?: string;
}

// Previews are re-read only when summary.md changes, since the tree is rebuilt on every edit.
const previews = new Map<string, { mtime: number; text: string }>();
function preview(file: string): string {
  try {
    const mtime = fs.statSync(file).mtimeMs;
    const cached = previews.get(file);
    if (cached?.mtime === mtime) return cached.text;
    const text = previewOf(fs.readFileSync(file, "utf8")).slice(0, 240);
    previews.set(file, { mtime, text });
    return text;
  } catch {
    return "";
  }
}

/** Resolves a path relative to `root`, refusing anything that escapes it. */
export function resolveInside(root: string, rel: string): string {
  const full = path.resolve(root, rel);
  if (full !== path.resolve(root) && !full.startsWith(path.resolve(root) + path.sep)) {
    throw new Error(`Path is outside the Meetings folder: ${rel}`);
  }
  return full;
}

export function listTree(root: string): TreeNode {
  fs.mkdirSync(root, { recursive: true });
  const walk = (rel: string): TreeNode => {
    const full = resolveInside(root, rel);
    const name = rel ? path.basename(rel) : path.basename(root);
    const metaFile = path.join(full, "meeting.json");
    if (rel && fs.existsSync(metaFile)) {
      let meta: { title?: string; startedAt?: string; endedAt?: string; source?: string } = {};
      try {
        meta = JSON.parse(fs.readFileSync(metaFile, "utf8"));
      } catch {
        // A hand-edited meeting.json shouldn't hide the meeting.
      }
      return {
        name,
        path: rel,
        kind: "meeting",
        title: meta.title,
        startedAt: meta.startedAt,
        endedAt: meta.endedAt,
        granola: meta.source === "granola",
        preview: preview(path.join(full, "summary.md")),
      };
    }
    const children = fs
      .readdirSync(full, { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith("."))
      .map((e) => walk(path.join(rel, e.name)));
    // Folders first (A–Z), then meetings, newest first.
    children.sort((a, b) =>
      a.kind !== b.kind
        ? a.kind === "folder" ? -1 : 1
        : a.kind === "folder"
          ? a.name.localeCompare(b.name)
          : b.name.localeCompare(a.name),
    );
    return { name, path: rel, kind: "folder", children };
  };
  return walk("");
}

export function readMeeting(root: string, rel: string) {
  const dir = resolveInside(root, rel);
  const read = (f: string) => (fs.existsSync(path.join(dir, f)) ? fs.readFileSync(path.join(dir, f), "utf8") : "");
  return {
    summary: read("summary.md"),
    transcript: read("transcript.md"),
    notes: read("notes.md"),
    todo: read("todo.md"),
    meta: JSON.parse(read("meeting.json") || "{}"),
  };
}

export const MEETING_FILES = ["summary.md", "transcript.md", "notes.md", "todo.md"] as const;

/** Saves an edit made in the app. Only the meeting's Markdown files can be written. */
export function writeMeetingFile(root: string, rel: string, file: string, content: string): void {
  if (!(MEETING_FILES as readonly string[]).includes(file)) throw new Error(`Can't edit ${file}`);
  const target = path.join(resolveInside(root, rel), file);
  if (!content && !fs.existsSync(target)) return;
  writeAtomic(target, content);
}

/** A meeting's folder name: "2026-11-05 1400 Weekly sync", in local time. */
export function meetingFolderName(meta: { title: string; startedAt: string }): string {
  const d = new Date(meta.startedAt);
  const pad = (n: number) => String(n).padStart(2, "0");
  const stamp = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}${pad(d.getMinutes())}`;
  const title = meta.title.replace(/[/:\\]/g, "-").trim() || "Call";
  return `${stamp} ${title}`;
}

/** A folder name made from free text such as an event title: no "/" or ":". */
export const safeName = (name: string) => name.replace(/[/:]/g, "-").replace(/\s+/g, " ").trim();
/** Letters and digits only (any script), for matching names that differ only in punctuation. */
export const loose = (name: string) => name.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");

/**
 * The folder a calendar event's recording goes in: the folder named like the event (punctuation
 * ignored, so "Sam & Alex 1:1" finds "Sam & Alex 1-1"). A recurring event with no such folder
 * gets a new top-level one named after it; a one-off goes at the top level.
 */
export function folderForEvent(root: string, title: string, recurring: boolean): string {
  const folders: string[] = [];
  const walk = (node: TreeNode) =>
    node.children?.forEach((c) => {
      if (c.kind !== "folder") return;
      folders.push(c.path);
      walk(c);
    });
  walk(listTree(root));
  // The folder's own name, or its whole path ("Team 51/Leads sync" for "Team 51 – Leads sync").
  // A title that is all punctuation matches nothing.
  const key = loose(title);
  const match = key ? (folders.find((f) => loose(path.basename(f)) === key) ?? folders.find((f) => loose(f) === key)) : undefined;
  if (match) return match;
  if (!recurring) return "";
  const name = safeName(title) || "Calls";
  return fs.existsSync(resolveInside(root, name)) ? name : createFolder(root, "", name);
}

function checkName(name: string): string {
  const clean = name.trim();
  if (!clean || clean === "." || clean === ".." || /[/:]/.test(clean)) {
    throw new Error("Names can't be empty or contain / or :");
  }
  return clean;
}

/** Refuses to overwrite, unless `self` is the item already there (a capitalisation-only rename on a case-insensitive disk). */
function ensureFree(target: string, self?: string) {
  if (!fs.existsSync(target)) return;
  if (self && fs.statSync(target).ino === fs.statSync(self).ino) return;
  throw new Error(`Something called "${path.basename(target)}" is already there`);
}

/** Renames in place; returns the new relative path. */
export function renameItem(root: string, rel: string, newName: string): string {
  if (!rel) throw new Error("The Meetings folder itself can't be renamed here");
  const from = resolveInside(root, rel);
  const to = resolveInside(root, path.join(path.dirname(rel), checkName(newName)));
  if (from === to) return rel;
  ensureFree(to, from);
  fs.renameSync(from, to);
  return path.relative(root, to);
}

/** Moves into another folder; returns the new relative path. */
export function moveItem(root: string, rel: string, folderRel: string): string {
  const from = resolveInside(root, rel);
  const to = resolveInside(root, path.join(folderRel, path.basename(rel)));
  if (to === from) return rel;
  if (to.startsWith(from + path.sep)) throw new Error("A folder can't go inside itself");
  ensureFree(to);
  fs.renameSync(from, to);
  return path.relative(root, to);
}

export function createFolder(root: string, parentRel: string, name: string): string {
  const target = resolveInside(root, path.join(parentRel, checkName(name)));
  ensureFree(target);
  fs.mkdirSync(target);
  return path.relative(root, target);
}

export interface MeetingTodos {
  /** The meeting, relative to the Meetings folder. */
  path: string;
  title: string;
  startedAt?: string;
  /** todo.md's text. */
  todo: string;
}

/** Every meeting's todo.md, for the combined To-dos page. Meetings without one are left out. */
export function listTodos(root: string): MeetingTodos[] {
  const out: MeetingTodos[] = [];
  const walk = (node: TreeNode) => {
    if (node.kind === "meeting") {
      const file = path.join(resolveInside(root, node.path), "todo.md");
      if (fs.existsSync(file)) {
        out.push({ path: node.path, title: node.title ?? node.name, startedAt: node.startedAt, todo: fs.readFileSync(file, "utf8") });
      }
      return;
    }
    node.children?.forEach(walk);
  };
  walk(listTree(root));
  // To-dos added on the To-dos page itself live in the Meetings folder's own todo.md.
  const own = path.join(root, "todo.md");
  if (fs.existsSync(own)) out.unshift({ path: "", title: "To-dos", todo: fs.readFileSync(own, "utf8") });
  return out;
}
