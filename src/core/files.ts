import crypto from "node:crypto";
import fs from "node:fs";

/**
 * Replaces a file in one step: readers never see it half-written, and a crash mid-write leaves the
 * old file. The temporary file gets a random name and must not already exist, so a symlink planted
 * next to the target (say, in a synced Meetings folder) can't redirect the write elsewhere.
 */
export function writeAtomic(file: string, content: string, mode?: number): void {
  const tmp = `${file}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  fs.writeFileSync(tmp, content, { flag: "wx", mode });
  try {
    fs.renameSync(tmp, file);
  } catch (e) {
    fs.rmSync(tmp, { force: true });
    throw e;
  }
}
