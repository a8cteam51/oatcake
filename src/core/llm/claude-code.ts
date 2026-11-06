import os from "node:os";
import { spawn } from "node:child_process";
import { ANTHROPIC_KEY_ENV, OPENAI_KEY_ENV, type Effort } from "../config.ts";
import type { Llm } from "./index.ts";

/**
 * The environment for a `claude` process: Oatcake's own API keys removed, so Claude Code always uses
 * its own sign-in (and billing), whichever provider is chosen in Settings.
 */
export function claudeEnv(): NodeJS.ProcessEnv {
  const env = { ...process.env };
  delete env[ANTHROPIC_KEY_ENV];
  delete env[OPENAI_KEY_ENV];
  return env;
}

/**
 * Runs `claude -p`, reusing the user's Claude Code login. No tools, no MCP, no saved
 * session, and no user/project settings, so personal CLAUDE.md rules don't leak into replies.
 */
export function claudeCode(config: { model: string; effort: Effort }): Llm {
  return {
    label: `Claude Code${config.model ? ` (${config.model})` : ""}`,
    complete(system, prompt) {
      const args = ["-p", "--output-format", "text", "--system-prompt", system, "--tools", "",
        "--strict-mcp-config", "--no-session-persistence", "--setting-sources", ""];
      if (config.model) args.push("--model", config.model);
      args.push("--effort", config.effort);
      return new Promise((resolve, reject) => {
        const child = spawn("claude", args, { cwd: os.tmpdir(), env: claudeEnv(), stdio: ["pipe", "pipe", "pipe"] });
        let out = "";
        let err = "";
        child.stdout.on("data", (d) => (out += d));
        child.stderr.on("data", (d) => (err += d));
        child.on("error", reject);
        child.on("close", (code) =>
          code === 0 ? resolve(out.trim()) : reject(new Error(`claude exited ${code}: ${err.trim() || out.trim()}`)),
        );
        child.stdin.end(prompt);
      });
    },
  };
}
