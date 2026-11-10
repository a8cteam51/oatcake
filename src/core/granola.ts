// Imports Granola's export: a .zip holding one or more CSV files (or one of those CSVs), one row
// per note with document_id, document_title, document_created, summary, notes and transcript.
// Each note becomes a meeting folder (summary.md, transcript.md, notes.md when Granola kept any,
// meeting.json) under a "Granola" folder, with notes that share a title grouped in a subfolder.
// A note already in the Meetings folder (same Granola note, wherever it was moved) is skipped.

import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { meetingFolderName, resolveInside, safeName } from "./meetings.ts";

const run = promisify(execFile);

export const GRANOLA_FOLDER = "Granola";
const NOTE_URL = "https://notes.granola.ai/d/";
const REQUIRED = ["document_id", "document_title", "document_created", "summary", "transcript"];

export interface GranolaImport {
  imported: number;
  /** Already in the Meetings folder (the same Granola note). */
  skipped: number;
  /** Rows without an id or a readable date. */
  unreadable: number;
  /** Where the new meetings went, relative to the Meetings folder. */
  folder: string;
}

/** RFC 4180 CSV: quoted fields may hold commas, newlines and doubled quotes. */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else quoted = false;
      } else field += c;
    } else if (c === '"' && field === "") quoted = true;
    else if (c === ",") {
      row.push(field);
      field = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else field += c;
  }
  if (field !== "" || row.length) {
    row.push(field);
    rows.push(row);
  }
  return rows.filter((r) => r.length > 1 || r[0] !== "");
}

/** The export's rows as objects, from every CSV in it. */
async function readExport(file: string): Promise<Record<string, string>[]> {
  if (/\.csv$/i.test(file)) return readCsvs([file]);
  if (!/\.zip$/i.test(file)) throw new Error("Pick the .zip (or .csv) that Granola's export gave you.");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "oatcake-granola-"));
  try {
    try {
      await run("/usr/bin/ditto", ["-x", "-k", file, tmp]);
    } catch {
      throw new Error("Couldn't open that .zip. Is it the file Granola's export gave you?");
    }
    const csvs: string[] = [];
    const walk = (dir: string) => {
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        if (e.name.startsWith(".") || e.name === "__MACOSX") continue;
        const full = path.join(dir, e.name);
        if (e.isDirectory()) walk(full);
        else if (/\.csv$/i.test(e.name)) csvs.push(full);
      }
    };
    walk(tmp);
    if (!csvs.length) throw new Error("That .zip has no CSV in it. Is it the file Granola's export gave you?");
    return readCsvs(csvs.sort());
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function readCsvs(csvs: string[]): Record<string, string>[] {
  const rows: Record<string, string>[] = [];
  for (const csv of csvs) {
    const [header, ...body] = parseCsv(fs.readFileSync(csv, "utf8").replace(/^\uFEFF/, ""));
    const missing = REQUIRED.filter((c) => !header?.includes(c));
    if (missing.length) throw new Error(`${path.basename(csv)} doesn't look like a Granola export (no ${missing.join(", ")} column).`);
    for (const cells of body) rows.push(Object.fromEntries(header.map((h, i) => [h, cells[i] ?? ""])));
  }
  if (!rows.length) throw new Error("There are no notes in that export.");
  return rows;
}

/** Granola note ids of every meeting already in the Meetings folder. */
function knownNotes(root: string): Set<string> {
  const ids = new Set<string>();
  const walk = (dir: string) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (!e.isDirectory() || e.name.startsWith(".")) continue;
      const full = path.join(dir, e.name);
      const meta = path.join(full, "meeting.json");
      if (fs.existsSync(meta)) {
        try {
          const id = String(JSON.parse(fs.readFileSync(meta, "utf8")).granolaNote ?? "").match(/[0-9a-f-]{36}/i)?.[0];
          if (id) ids.add(id.toLowerCase());
        } catch {
          // An unreadable meeting.json can't be a duplicate.
        }
      } else walk(full);
    }
  };
  if (fs.existsSync(root)) walk(root);
  return ids;
}

/** A series folder's name. No leading dots: those make hidden folders (or "." and ".."). */
const seriesFolder = (title: string) => safeName(title).replace(/^\.+/, "").trim() || "Untitled";

/** Granola's transcript is one line per utterance, with no times or names: one paragraph each. */
const transcriptMarkdown = (text: string) =>
  text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean)
    .join("\n\n") + "\n";

export async function importGranola(file: string, root: string): Promise<GranolaImport> {
  const rows = await readExport(file);
  const known = knownNotes(root);
  const titleOf = (r: Record<string, string>) => r.document_title.trim() || "Untitled";
  const titles = new Map<string, number>();
  for (const r of rows) titles.set(titleOf(r), (titles.get(titleOf(r)) ?? 0) + 1);

  const result: GranolaImport = { imported: 0, skipped: 0, unreadable: 0, folder: GRANOLA_FOLDER };
  for (const r of rows) {
    const id = r.document_id.trim().toLowerCase();
    const started = new Date(r.document_created);
    if (!/^[0-9a-f-]{36}$/.test(id) || Number.isNaN(+started)) {
      result.unreadable++;
      continue;
    }
    if (known.has(id)) {
      result.skipped++;
      continue;
    }
    const title = titleOf(r);
    // Notes that share a title (a recurring meeting) get a folder of their own.
    const series = (titles.get(title) ?? 0) > 1 ? seriesFolder(title) : "";
    const startedAt = started.toISOString();
    // Two notes with the same title in the same minute are different notes: number the second.
    const name = meetingFolderName({ title, startedAt });
    let rel = path.join(GRANOLA_FOLDER, series, name);
    for (let n = 2; fs.existsSync(resolveInside(root, rel)); n++) rel = path.join(GRANOLA_FOLDER, series, `${name} (${n})`);
    const dest = resolveInside(root, rel);
    // Written beside its final place, then renamed in, so a half-written meeting never shows.
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const tmp = fs.mkdtempSync(path.join(path.dirname(dest), ".import-"));
    try {
      fs.writeFileSync(path.join(tmp, "summary.md"), r.summary.trim() + "\n");
      fs.writeFileSync(path.join(tmp, "transcript.md"), transcriptMarkdown(r.transcript));
      if (r.notes?.trim()) fs.writeFileSync(path.join(tmp, "notes.md"), r.notes.trim() + "\n");
      const meta = { title, startedAt, source: "granola", granolaNote: NOTE_URL + id };
      fs.writeFileSync(path.join(tmp, "meeting.json"), JSON.stringify(meta, null, 2) + "\n");
      fs.renameSync(tmp, dest);
    } catch (e) {
      fs.rmSync(tmp, { recursive: true, force: true });
      throw e;
    }
    known.add(id);
    result.imported++;
  }
  return result;
}
