import type { LlmConfig } from "../config.ts";
import { anthropic } from "./anthropic.ts";
import { claudeCode } from "./claude-code.ts";
import { openaiCompatible } from "./openai-compatible.ts";

/** Anything that can answer one prompt. To add a model, add a provider and a case below. */
export interface Llm {
  label: string;
  complete(system: string, prompt: string): Promise<string>;
}

export function createLlm(config: LlmConfig): Llm {
  switch (config.provider) {
    case "claude-code":
      return claudeCode(config.claudeCode);
    case "anthropic":
      return anthropic(config.anthropic);
    case "openai-compatible":
      return openaiCompatible(config.openai);
  }
}

/** Pulls the first JSON object out of a model reply (tolerates code fences and prose). */
export function parseJsonObject<T>(text: string): T {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end < start) throw new Error(`No JSON in model reply: ${text.slice(0, 200)}`);
  return JSON.parse(text.slice(start, end + 1)) as T;
}
