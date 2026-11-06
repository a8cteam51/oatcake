import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { writeAtomic } from "./files.ts";

export const DATA_DIR = path.join(os.homedir(), "Library", "Application Support", "Oatcake");
export const MODELS_DIR = path.join(DATA_DIR, "models");
export const RECORDINGS_DIR = path.join(DATA_DIR, "recordings");
export const VOICEPRINTS_PATH = path.join(DATA_DIR, "voiceprints.json");
export const CONFIG_PATH = path.join(DATA_DIR, "config.json");

export type Effort = "low" | "medium" | "high";

/**
 * Which model writes summaries and suggests names. Each provider keeps its own settings, so
 * switching back and forth loses nothing. API keys are stored encrypted (see secrets.ts) and
 * reach the providers as environment variables.
 */
export interface LlmConfig {
  provider: "claude-code" | "anthropic" | "openai-compatible";
  /** model: "" for Claude Code's default, or an alias such as "sonnet", "opus", "haiku". */
  claudeCode: { model: string; effort: Effort };
  anthropic: { model: string; effort: Effort };
  openai: { baseUrl: string; model: string; effort: Effort };
}

export const ANTHROPIC_MODELS = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"];
/** Environment variables the providers read their keys from. */
export const ANTHROPIC_KEY_ENV = "ANTHROPIC_API_KEY";
export const OPENAI_KEY_ENV = "OATCAKE_OPENAI_API_KEY";

export interface Config {
  /** Your name: the microphone track is always you. */
  myName: string;
  /** The Meetings folder. Each meeting is a folder inside it (or inside any subfolder). */
  outputDir: string;
  /** Speech-to-text model, a key of ASR_MODELS in models.ts. */
  asrModel: string;
  llm: LlmConfig;
  /** Keep the raw audio after a call is saved (needed to re-run with another model). */
  keepAudio: boolean;
  /** The microphone to record. null follows the Mac's input (System Settings › Sound). */
  mic: { uid: string; name: string } | null;
  /** A notification 5 minutes before each call, with a button to open it and start recording. */
  callReminders: boolean;
}

function onPath(command: string): boolean {
  try {
    execFileSync("/usr/bin/which", [command], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function fullName(): string {
  try {
    return execFileSync("/usr/bin/id", ["-F"], { encoding: "utf8" }).trim() || os.userInfo().username;
  } catch {
    return os.userInfo().username;
  }
}

// Worked out once: loadConfig runs on nearly every request, and these each start a process.
let guessed: { myName: string; hasClaude: boolean } | undefined;

function defaults(): Config {
  guessed ??= { myName: fullName(), hasClaude: onPath("claude") };
  return {
    myName: guessed.myName,
    outputDir: path.join(os.homedir(), "Documents", "Meetings"),
    asrModel: "parakeet-unified-en",
    // Claude Code reuses an existing Claude login; otherwise use the API.
    llm: {
      provider: guessed.hasClaude ? "claude-code" : "anthropic",
      claudeCode: { model: "", effort: "medium" },
      anthropic: { model: ANTHROPIC_MODELS[0], effort: "medium" },
      openai: { baseUrl: "", model: "", effort: "medium" },
    },
    keepAudio: false,
    mic: null,
    callReminders: true,
  };
}

export function loadConfig(): Config {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const base = defaults();
  if (!fs.existsSync(CONFIG_PATH)) {
    saveConfig(base);
    return base;
  }
  const saved = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  return { ...base, ...saved, llm: upgradeLlm(saved.llm, base.llm) };
}

/** Reads both the current shape and the older one-provider-at-a-time shape. */
function upgradeLlm(saved: any, base: LlmConfig): LlmConfig {
  if (!saved) return base;
  if (saved.claudeCode) return { ...base, ...saved };
  const llm: LlmConfig = { ...base, provider: saved.provider ?? base.provider };
  if (saved.provider === "claude-code") llm.claudeCode = { ...base.claudeCode, model: saved.model ?? "" };
  if (saved.provider === "anthropic") llm.anthropic = { model: saved.model ?? base.anthropic.model, effort: saved.effort ?? "medium" };
  if (saved.provider === "openai-compatible") llm.openai = { ...base.openai, baseUrl: saved.baseUrl ?? "", model: saved.model ?? "" };
  return llm;
}

export function saveConfig(config: Config): void {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  writeAtomic(CONFIG_PATH, JSON.stringify(config, null, 2) + "\n");
}
