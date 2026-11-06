import path from "node:path";
import { spawn } from "node:child_process";
import { claudeEnv } from "./llm/claude-code.ts";

export interface AskAnswer {
  answer: string;
  /** Pass back to continue the same conversation. */
  sessionId: string;
}

export interface AskOptions {
  root: string;
  /** The meeting being looked at when the question is asked, relative to root. */
  meeting: string;
  question: string;
  sessionId?: string;
  myName: string;
  model?: string;
  /** Called with a short description of each file read or search. */
  onStep(step: string): void;
}

const system = (myName: string) =>
  [
    `You answer ${myName}'s questions about their meetings. The current directory holds one folder per meeting`,
    "(grouped into series folders), each with summary.md, transcript.md (lines like '**[mm:ss] Name:** text'),",
    `notes.md (${myName}'s own notes, when any were taken) and meeting.json. Folder names start with the date: 'YYYY-MM-DD HHMM Title'.`,
    "Start with the meeting they're looking at. Search other meetings (Grep across */*/summary.md first, then",
    "transcripts) whenever the question reaches beyond it, such as earlier discussions, people or recurring topics.",
    "Answer in concise Markdown. Cite each meeting you draw on as a Markdown link whose target is the meeting",
    "folder's path relative to the current directory, URL-encoded (spaces as %20, & as %26), with the meeting's title",
    "and short date as the link text, e.g. [Leads sync · Oct 29](...). Add transcript timestamps like [12:34] where",
    "they help. If the meetings don't answer the question, say so.",
  ].join(" ");

/** Describes a tool call in a few words, for the progress line. */
function describe(root: string, name: string, input: Record<string, unknown>): string | null {
  const rel = (p: unknown) => (typeof p === "string" ? path.relative(root, p).split(path.sep).join(" › ") : "");
  if (name === "Read") return `Reading ${rel(input.file_path)}`;
  if (name === "Grep") return `Searching for “${String(input.pattern ?? "")}”`;
  if (name === "Glob") return "Listing meetings";
  return null;
}

/**
 * Asks Claude Code a question about the meetings. It runs in the meetings folder with read-only
 * file tools (Read, Grep, Glob) allowed only inside that folder: no shell, no MCP servers, no user
 * settings or CLAUDE.md. A transcript that tries to steer it (anything said on a call ends up in one)
 * can't reach files elsewhere on the Mac.
 */
export function ask(options: AskOptions): { result: Promise<AskAnswer>; cancel(): void } {
  if (options.sessionId && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(options.sessionId)) {
    throw new Error("That conversation can't be continued. Start a new chat.");
  }
  // Said every time: the conversation carries on as they move between meetings.
  const prompt = `I'm looking at the meeting in "${options.meeting}".\n\n${options.question}`;
  const args = [
    "-p", "--output-format", "stream-json", "--verbose",
    "--system-prompt", system(options.myName),
    "--tools", "Read,Grep,Glob", "--allowedTools", "Read(./**),Grep(./**),Glob(./**)",
    "--strict-mcp-config", "--setting-sources", "",
  ];
  if (options.model) args.push("--model", options.model);
  if (options.sessionId) args.push("--resume", options.sessionId);

  const child = spawn("claude", args, { cwd: options.root, env: claudeEnv(), stdio: ["pipe", "pipe", "pipe"] });
  const result = new Promise<AskAnswer>((resolve, reject) => {
    let buffer = "";
    let err = "";
    let final: { result?: string; session_id?: string; is_error?: boolean } | null = null;
    child.stdout.on("data", (data: Buffer) => {
      buffer += data;
      const lines = buffer.split("\n");
      buffer = lines.pop()!;
      for (const line of lines) {
        if (!line.trim()) continue;
        let event;
        try {
          event = JSON.parse(line);
        } catch {
          continue;
        }
        if (event.type === "assistant") {
          for (const block of event.message?.content ?? []) {
            if (block.type !== "tool_use") continue;
            const step = describe(options.root, block.name, block.input ?? {});
            if (step) options.onStep(step);
          }
        }
        if (event.type === "result") final = event;
      }
    });
    child.stderr.on("data", (data) => (err += data));
    child.on("error", (e: NodeJS.ErrnoException) =>
      reject(e.code === "ENOENT" ? new Error("Ask needs Claude Code installed and signed in (the claude command).") : e),
    );
    child.on("close", (code, signal) => {
      if (signal) return reject(new Error("Stopped."));
      if (final && !final.is_error && final.session_id) {
        return resolve({ answer: (final.result ?? "").trim(), sessionId: final.session_id });
      }
      reject(new Error(final?.result || err.trim() || `claude exited ${code}`));
    });
    child.stdin.end(prompt);
  });
  return { result, cancel: () => child.kill("SIGTERM") };
}
