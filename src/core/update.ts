// Updates. Each GitHub release carries latest.json: a manifest naming the version and its zip
// (address, SHA-256, size), signed with Oatcake's Ed25519 release key. Oatcake reads it, downloads
// the zip, checks it's exactly the file that was signed, checks the app inside carries the same
// code-signing identity as the running copy, and swaps itself for it once it has quit.
//
// Oatcake isn't notarised. Files it downloads itself (like files curl downloads) get no
// quarantine flag, so Gatekeeper never looks at them; these checks stand in for it.
// install.sh reads the same manifest for first installs.

import { execFile, spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { promisify } from "node:util";
import { DATA_DIR } from "./config.ts";
import { UPDATE_PUBLIC_KEYS } from "./update-keys.ts";

const run = promisify(execFile);

export const FEED_URL = "https://github.com/a8cteam51/oatcake/releases/latest/download/latest.json";
export const INSTALL_COMMAND = "curl -fsSL https://raw.githubusercontent.com/a8cteam51/oatcake/trunk/install.sh | sh";
export const BUNDLE_ID = "local.oatcake";
const APP_NAME = "Oatcake.app";

export interface Manifest {
  bundleID: string;
  version: string;
  minimumSystemVersion: string;
  published: string;
  /** Plain text, one change per line. */
  notes: string;
  zip: { name: string; url: string; sha256: string; size: number };
}

/** Compares dotted version numbers part by part: 1 when a is newer, -1 when older, 0 when equal. */
export function compareVersions(a: string, b: string): number {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return Math.sign(d);
  }
  return 0;
}

// DER header that turns a raw 32-byte Ed25519 key into the SPKI form Node reads.
const SPKI_ED25519 = Buffer.from("302a300506032b6570032100", "hex");

/** Checks latest.json's signature against the keys Oatcake ships with, then reads what it signed. */
export function readManifest(envelope: unknown, keys: string[] = UPDATE_PUBLIC_KEYS): Manifest {
  const { payload, signature } = (envelope ?? {}) as { payload?: unknown; signature?: unknown };
  if (typeof payload !== "string" || typeof signature !== "string") throw new Error("The update information isn't in the expected format.");
  const bytes = Buffer.from(payload, "base64");
  const sig = Buffer.from(signature, "base64");
  const signed = keys.some((key) => {
    const publicKey = crypto.createPublicKey({ key: Buffer.concat([SPKI_ED25519, Buffer.from(key, "base64")]), format: "der", type: "spki" });
    return crypto.verify(null, bytes, publicKey, sig);
  });
  if (!signed) throw new Error("The update information isn't signed with Oatcake's release key.");
  const m = JSON.parse(bytes.toString("utf8")) as Manifest;
  const valid =
    m.bundleID === BUNDLE_ID &&
    /^\d+\.\d+\.\d+$/.test(m.version) &&
    /^\d+(\.\d+){0,2}$/.test(m.minimumSystemVersion) &&
    /^[\w.-]+\.zip$/.test(m.zip?.name) &&
    /^https:\/\//.test(m.zip?.url) &&
    /^[0-9a-f]{64}$/.test(m.zip?.sha256) &&
    Number.isSafeInteger(m.zip?.size) &&
    m.zip.size > 0;
  if (!valid) throw new Error("The update information is incomplete.");
  return m;
}

/** Fetches and checks the manifest. A feed other than the real one (for testing) serves its zip beside it. */
export async function fetchManifest(feed: string): Promise<Manifest> {
  const res = await fetch(feed, { signal: AbortSignal.timeout(30_000) }).catch(() => {
    throw new Error("Couldn't reach GitHub to check for updates.");
  });
  if (res.status === 404) throw new Error("No release of Oatcake is published yet.");
  if (!res.ok) throw new Error(`Couldn't check for updates (HTTP ${res.status}).`);
  const envelope = await res.json().catch(() => null);
  const manifest = readManifest(envelope);
  if (feed !== FEED_URL) manifest.zip.url = new URL(manifest.zip.name, feed).href;
  return manifest;
}

/** Downloads the release zip into dir, checking its size and SHA-256 against the manifest. */
export async function downloadZip(manifest: Manifest, dir: string, onProgress: (fraction: number) => void): Promise<string> {
  const { url, name, size, sha256 } = manifest.zip;
  const file = path.join(dir, name);
  const res = await fetch(url, { signal: AbortSignal.timeout(30 * 60_000) }).catch(() => {
    throw new Error("Couldn't download the update. Check your connection and try again.");
  });
  if (!res.ok || !res.body) throw new Error(`The download failed (HTTP ${res.status}).`);
  const hash = crypto.createHash("sha256");
  let received = 0;
  const count = new Transform({
    transform(chunk: Buffer, _encoding, done) {
      received += chunk.length;
      if (received > size) return done(new Error("The download is bigger than the release said it would be."));
      hash.update(chunk);
      onProgress(received / size);
      done(null, chunk);
    },
  });
  await pipeline(Readable.fromWeb(res.body as import("node:stream/web").ReadableStream), count, fs.createWriteStream(file, { mode: 0o600 }));
  if (received !== size) throw new Error(`The download stopped early (${received} of ${size} bytes).`);
  if (hash.digest("hex") !== sha256) throw new Error("The download doesn't match the release's checksum.");
  return file;
}

const plistValue = async (app: string, key: string) =>
  (await run("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", path.join(app, "Contents", "Info.plist")])).stdout.trim();

/** Unpacks the zip (ditto keeps code signatures intact) and checks it holds just Oatcake.app, of the manifest's version. */
export async function unpack(zip: string, dir: string, manifest: Manifest): Promise<string> {
  const out = path.join(dir, "unpacked");
  await run("/usr/bin/ditto", ["-x", "-k", zip, out]);
  const entries = fs.readdirSync(out).filter((name) => name !== "__MACOSX");
  if (entries.length !== 1 || entries[0] !== APP_NAME) throw new Error("The download doesn't contain just Oatcake.app.");
  const app = path.join(out, APP_NAME);
  if ((await plistValue(app, "CFBundleIdentifier")) !== BUNDLE_ID) throw new Error("The download isn't Oatcake.");
  if ((await plistValue(app, "CFBundleShortVersionString")) !== manifest.version) throw new Error(`The download isn't Oatcake ${manifest.version}.`);
  return app;
}

/**
 * The code-signing requirement a bundle's signature names for itself, e.g.
 * `identifier "local.oatcake" and certificate leaf = H"…"`. An ad-hoc signature's is `cdhash H"…"`,
 * which no other build can meet.
 */
export async function designatedRequirement(bundle: string): Promise<string> {
  const { stdout } = await run("/usr/bin/codesign", ["-d", "-r", "-", bundle]);
  const req = stdout.match(/designated => (.+)/)?.[1]?.trim();
  if (!req) throw new Error("Couldn't read Oatcake's code signature.");
  return req;
}

export const isAdHoc = (requirement: string) => /^cdhash\b/.test(requirement);

/** Whether a bundle is validly signed, unmodified, and meets the requirement (the same identity as this copy). */
export async function satisfies(bundle: string, requirement: string): Promise<boolean> {
  try {
    await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", `=${requirement}`, bundle]);
    return true;
  } catch {
    return false;
  }
}

/** Copies the new app beside the installed one (same volume, so the swap is a rename) and checks the copy. */
export async function stage(app: string, installed: string, requirement: string): Promise<string> {
  const staged = path.join(path.dirname(installed), ".Oatcake-update.app");
  fs.rmSync(staged, { recursive: true, force: true });
  await run("/usr/bin/ditto", [app, staged]);
  if (!(await satisfies(staged, requirement))) {
    fs.rmSync(staged, { recursive: true, force: true });
    throw new Error("The copied update failed its signature check.");
  }
  return staged;
}

// Waits for Oatcake to quit, swaps the bundles, and opens whichever is in place: the new one, or
// the old one put back if the swap failed. Runs detached, so it outlives the app.
const SWAP_SCRIPT = `
pid=$1 dest=$2 staged=$3
old="$(dirname "$dest")/.Oatcake-old-$pid.app"
echo "$(date): updating $dest"
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -gt 600 ]; then echo "Oatcake didn't quit; update abandoned"; rm -rf "$staged"; exit 1; fi
  sleep 0.2
done
if mv "$dest" "$old"; then
  if mv "$staged" "$dest"; then
    rm -rf "$old"
    echo "updated"
  else
    mv "$old" "$dest"
    rm -rf "$staged"
    echo "couldn't move the update into place; kept the old copy"
  fi
else
  rm -rf "$staged"
  echo "couldn't move the old copy aside; kept it"
fi
touch "$dest"
/usr/bin/open "$dest"
`;

/** Starts the swap; the caller quits straight after. Its output goes to update.log in Oatcake's data folder. */
export function swapAfterExit(installed: string, staged: string): void {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const log = fs.openSync(path.join(DATA_DIR, "update.log"), "a");
  spawn("/bin/sh", ["-c", SWAP_SCRIPT, "oatcake-update", String(process.pid), installed, staged], {
    detached: true,
    stdio: ["ignore", log, log],
  }).unref();
  fs.closeSync(log);
}
