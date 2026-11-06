// API keys and the calendar's private address, typed into Settings. They're encrypted with a key
// macOS keeps in your Keychain (Electron's safeStorage). The keys reach the model providers as
// environment variables, so the analysis worker and the summary step pick them up without reading
// this file. The window can save a secret but never read one back: it only learns whether one is set.

import fs from "node:fs";
import path from "node:path";
import { safeStorage } from "electron";
import { ANTHROPIC_KEY_ENV, DATA_DIR, OPENAI_KEY_ENV } from "../core/config.ts";
import { writeAtomic } from "../core/files.ts";

export type SecretName = "anthropic" | "openai" | "calendar";
export const SECRET_NAMES: SecretName[] = ["anthropic", "openai", "calendar"];
const SECRETS_PATH = path.join(DATA_DIR, "secrets.json");
const ENV: Partial<Record<SecretName, string>> = { anthropic: ANTHROPIC_KEY_ENV, openai: OPENAI_KEY_ENV };
/** A key already in the environment when Oatcake started (e.g. from your shell) is the fallback. */
const inherited: Partial<Record<SecretName, string>> = {
  anthropic: process.env[ANTHROPIC_KEY_ENV],
  openai: process.env[OPENAI_KEY_ENV],
};

function readAll(): Partial<Record<SecretName, string>> {
  try {
    return JSON.parse(fs.readFileSync(SECRETS_PATH, "utf8"));
  } catch {
    return {};
  }
}

export function getSecret(name: SecretName): string {
  const stored = readAll()[name];
  if (!stored || !safeStorage.isEncryptionAvailable()) return "";
  try {
    return safeStorage.decryptString(Buffer.from(stored, "base64"));
  } catch {
    return "";
  }
}

/** What Settings shows for a secret: whether one is saved, and enough to recognise it. */
export function describeSecret(name: SecretName): { saved: boolean; hint: string } {
  const value = getSecret(name);
  if (!value) return { saved: false, hint: inherited[name] ? "Using the key from your shell" : "" };
  if (name === "calendar") {
    try {
      return { saved: true, hint: `Saved · ${new URL(value.replace(/^webcal:/i, "https:")).host}` };
    } catch {
      return { saved: true, hint: "Saved" };
    }
  }
  return { saved: true, hint: `Saved · ends in ${value.slice(-4)}` };
}

export function setSecret(name: SecretName, value: string): void {
  if (!SECRET_NAMES.includes(name)) throw new Error(`Unknown secret ${name}`);
  const all = readAll();
  if (value.trim()) {
    if (!safeStorage.isEncryptionAvailable()) throw new Error("Can't encrypt secrets on this Mac right now");
    all[name] = safeStorage.encryptString(value.trim()).toString("base64");
  } else delete all[name];
  fs.mkdirSync(DATA_DIR, { recursive: true });
  writeAtomic(SECRETS_PATH, JSON.stringify(all, null, 2), 0o600);
  applySecrets();
}

/** Puts the saved keys (or the inherited ones) into this process's environment. */
export function applySecrets(): void {
  for (const name of SECRET_NAMES) {
    const env = ENV[name];
    if (!env) continue;
    const value = getSecret(name) || inherited[name];
    if (value) process.env[env] = value;
    else delete process.env[env];
  }
}
