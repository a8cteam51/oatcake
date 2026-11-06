// Copies a Granola export (<series>/<YYYY-MM-DD HHMM>/{summary.md,transcript.md}) into the
// Meetings folder as <series>/<YYYY-MM-DD HHMM> <title>/ with a meeting.json, so the app
// lists them. The export itself is left untouched; meetings that already exist are skipped.
//
// Usage: node scripts/import-granola-export.mjs <export dir> [meetings dir] [--dry-run]
// Dates in folder names are read as local time.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const args = process.argv.slice(2).filter((a) => a !== "--dry-run");
const dryRun = process.argv.includes("--dry-run");
const [exportDir, meetingsDir = path.join(os.homedir(), "Documents", "Meetings")] = args;
if (!exportDir) {
  console.error("Usage: node scripts/import-granola-export.mjs <export dir> [meetings dir] [--dry-run]");
  process.exit(2);
}

// Same rule as the app's meeting folder names (src/core/save.ts): no / or : in names.
const safe = (name) => name.replace(/[/:\\]/g, "-").trim();
const read = (file) => (fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "");

/** "Sam Lee (note creator) from Acme (sam@x), Alex Kim (alex@x)" → ["Sam Lee", "Alex Kim"] */
function participants(summary) {
  const line = summary.match(/^- \*\*Participants:\*\* (.+)$/m)?.[1];
  if (!line) return [];
  return line
    .split(/,\s*(?![^()]*\))/)
    .map((p) => p.replace(/\([^)]*\)/g, "").replace(/\s+from\s+.+$/, "").trim())
    .filter(Boolean);
}

let imported = 0;
let skipped = 0;
for (const series of fs.readdirSync(exportDir, { withFileTypes: true })) {
  if (!series.isDirectory() || series.name.startsWith(".")) continue;
  const seriesDir = path.join(exportDir, series.name);
  for (const when of fs.readdirSync(seriesDir).sort()) {
    const m = when.match(/^(\d{4})-(\d{2})-(\d{2}) (\d{2})(\d{2})$/);
    if (!m) continue;
    const src = path.join(seriesDir, when);
    const summary = read(path.join(src, "summary.md"));
    const transcript = read(path.join(src, "transcript.md"));
    const title = summary.match(/^# (.+)$/m)?.[1]?.trim() || series.name;
    const startedAt = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]).toISOString();
    const dest = path.join(meetingsDir, safe(series.name), `${when} ${safe(title)}`);

    if (fs.existsSync(dest)) {
      skipped++;
      continue;
    }
    imported++;
    if (dryRun) {
      console.log(`${path.relative(meetingsDir, dest)}  ← ${series.name}/${when}`);
      continue;
    }
    fs.mkdirSync(dest, { recursive: true });
    for (const file of ["summary.md", "transcript.md"]) {
      if (fs.existsSync(path.join(src, file))) fs.copyFileSync(path.join(src, file), path.join(dest, file));
    }
    const meta = {
      title,
      startedAt,
      participants: participants(summary),
      source: "granola",
      granolaNote: (summary || transcript).match(/https:\/\/notes\.granola\.ai\/d\/[0-9a-f-]+/)?.[0],
    };
    fs.writeFileSync(path.join(dest, "meeting.json"), JSON.stringify(meta, null, 2) + "\n");
  }
}
console.log(`${dryRun ? "Would import" : "Imported"} ${imported} meetings into ${meetingsDir}; ${skipped} already there.`);
