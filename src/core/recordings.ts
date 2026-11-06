import fs from "node:fs";
import path from "node:path";
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { RECORDINGS_DIR } from "./config.ts";
import { writeAtomic } from "./files.ts";

/** One call's working folder: audio, meta.json, analysis.json, clips/, saved.json. */
export interface Recording {
  id: string;
  dir: string;
  title: string;
  /** Meetings folder (relative path) picked when the recording started; "" is the top level. */
  folder?: string;
  /** The calendar event it was started from, if any. */
  eventId?: string;
  startedAt: string;
  /** When recording stopped (from the recorder's meta.json). */
  endedAt?: string;
  state: "recording" | "recorded" | "processed" | "saved";
}

export interface RecorderStatus {
  state: "starting" | "recording" | "stopped" | "error";
  error?: string;
  elapsed?: number;
  micLevel?: number;
  systemLevel?: number;
  /** The input being recorded right now; null when there's none. */
  micDevice?: { uid: string; name: string } | null;
}

export interface InputDevice {
  uid: string;
  name: string;
  isDefault: boolean;
}

/** The Mac's input devices, read by the recorder (listing them needs no permission). */
export async function listInputs(recorderApp: string): Promise<InputDevice[]> {
  const binary = path.join(recorderApp, "Contents", "MacOS", "oatcake-recorder");
  const { stdout } = await promisify(execFile)(binary, ["--list-inputs"]);
  return JSON.parse(stdout);
}

/** The recorder re-reads mic.json every second, so this switches input mid-call. */
export function setRecordingMic(dir: string, uid: string | null): void {
  writeAtomic(path.join(dir, "mic.json"), JSON.stringify({ uid }));
}

const readJson = <T>(file: string): T | undefined =>
  fs.existsSync(file) ? (JSON.parse(fs.readFileSync(file, "utf8")) as T) : undefined;

export interface StartOptions {
  /** The calendar event this call was started from. */
  eventId?: string;
  /** Prep notes written before the call; they open the call's notes. */
  prep?: string[];
}

export function startRecording(
  title: string,
  folder: string,
  recorderApp: string,
  micUid: string | null,
  options: StartOptions = {},
): Recording {
  if (!fs.existsSync(recorderApp)) {
    throw new Error("The recorder isn't built yet. Run: npm run build:recorder");
  }
  const startedAt = new Date();
  const id = startedAt.toISOString().replace(/[:.]/g, "-");
  const dir = path.join(RECORDINGS_DIR, id);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(
    path.join(dir, "call.json"),
    JSON.stringify({ title, folder, startedAt: startedAt.toISOString(), eventId: options.eventId }),
  );
  const prep = (options.prep ?? []).map((text) => text.trim()).filter(Boolean);
  if (prep.length) saveNotes(id, prep.map((text) => ({ at: null, text })));
  setRecordingMic(dir, micUid);
  // Launched through LaunchServices so macOS treats the recorder as its own app for permissions.
  execFileSync("/usr/bin/open", ["-n", "-g", recorderApp, "--args", "--out", dir]);
  return { id, dir, title, folder, eventId: options.eventId, startedAt: startedAt.toISOString(), state: "recording" };
}

export function recorderStatus(rec: Recording): RecorderStatus {
  try {
    return readJson<RecorderStatus>(path.join(rec.dir, "status.json")) ?? { state: "starting" };
  } catch {
    return { state: "starting" }; // mid-write
  }
}

/** The recorder's process ID, while that process is still running and is our recorder. */
function recorderPid(rec: Recording): number | null {
  let pid: number;
  try {
    pid = Number(fs.readFileSync(path.join(rec.dir, "recorder.pid"), "utf8"));
  } catch {
    return null;
  }
  if (!Number.isInteger(pid) || pid <= 1) return null;
  try {
    // A crashed recorder leaves its pid file behind, and macOS reuses process IDs.
    const command = execFileSync("/bin/ps", ["-p", String(pid), "-o", "comm="], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    return command.endsWith("/oatcake-recorder") || command === "oatcake-recorder" ? pid : null;
  } catch {
    return null; // no such process
  }
}

export const recorderRunning = (rec: Recording) => recorderPid(rec) !== null;

/** Asks the recorder to finish (it writes meta.json as it exits). Does nothing if it already stopped. */
export function stopRecording(rec: Recording): void {
  const pid = recorderPid(rec);
  if (pid === null) return;
  try {
    process.kill(pid, "SIGTERM");
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ESRCH") throw e;
  }
}

/**
 * A recording whose recorder stopped without writing meta.json: it crashed, was killed, or never got
 * past the permission prompt. Writes a meta.json from what's on disk, so the audio it did capture is
 * processed like any other recording (and can be discarded from Needs review if there's nothing).
 */
export function finishInterrupted(rec: Recording): void {
  if (fs.existsSync(path.join(rec.dir, "meta.json")) || recorderRunning(rec)) return;
  const modified = ["mic.pcm", "system.pcm", "status.json"]
    .map((f) => {
      try {
        return fs.statSync(path.join(rec.dir, f)).mtimeMs;
      } catch {
        return 0;
      }
    })
    .reduce((a, b) => Math.max(a, b), 0);
  const meta = {
    startedAt: rec.startedAt,
    endedAt: new Date(modified || Date.parse(rec.startedAt)).toISOString(),
    sampleRate: 16_000,
    // Unknown: the tracks are taken as starting together.
    micOffset: 0,
    systemOffset: 0,
    micDevices: [],
    interrupted: true,
  };
  writeAtomic(path.join(rec.dir, "meta.json"), JSON.stringify(meta, null, 2));
  fs.rmSync(path.join(rec.dir, "recorder.pid"), { force: true });
}

export function listRecordings(): Recording[] {
  if (!fs.existsSync(RECORDINGS_DIR)) return [];
  return fs
    .readdirSync(RECORDINGS_DIR)
    .sort()
    .reverse()
    .flatMap((id) => {
      const dir = path.join(RECORDINGS_DIR, id);
      // One damaged file shouldn't hide every other recording.
      const tryJson = <T,>(file: string): T | null => {
        try {
          return readJson<T>(path.join(dir, file)) ?? null;
        } catch {
          return null;
        }
      };
      const call = tryJson<{ title: string; folder?: string; eventId?: string; startedAt: string }>("call.json");
      if (!call) return [];
      const has = (f: string) => fs.existsSync(path.join(dir, f));
      const state = has("saved.json") ? "saved" : has("analysis.json") ? "processed" : has("meta.json") ? "recorded" : "recording";
      const endedAt = has("meta.json") ? tryJson<{ endedAt?: string }>("meta.json")?.endedAt : undefined;
      return [{ id, dir, title: call.title, folder: call.folder, eventId: call.eventId, startedAt: call.startedAt, endedAt, state }];
    });
}

export interface Note {
  /** Seconds into the recording when the line was started; null for a prep note written beforehand. */
  at: number | null;
  text: string;
}

/** Recording IDs are their start time, e.g. 2026-11-05T22-35-10-123Z. Anything else is refused. */
export function recordingDir(id: string): string {
  if (!/^\d{4}-\d\d-\d\dT[\dZ-]+$/.test(id)) throw new Error("Recording not found");
  return path.join(RECORDINGS_DIR, id);
}

export function saveNotes(id: string, notes: Note[]): void {
  fs.writeFileSync(path.join(recordingDir(id), "notes.json"), JSON.stringify(notes, null, 2));
}

export function loadNotes(id: string): Note[] {
  return readJson<Note[]>(path.join(recordingDir(id), "notes.json")) ?? [];
}

export function getRecording(id: string): Recording | undefined {
  return listRecordings().find((r) => r.id === id);
}

export function discardRecording(id: string): void {
  fs.rmSync(recordingDir(id), { recursive: true, force: true });
}

export function deleteAudio(rec: Recording): void {
  for (const f of ["mic.pcm", "system.pcm"]) fs.rmSync(path.join(rec.dir, f), { force: true });
  fs.rmSync(path.join(rec.dir, "clips"), { recursive: true, force: true });
}
