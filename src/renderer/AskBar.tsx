import { useEffect, useReducer, useRef, useState } from "react";
import { api } from "./api.ts";
import { cleanError } from "./format.ts";
import { SendIcon, StopIcon } from "./icons.tsx";
import { toHtml } from "./markdown.ts";
import { meetingLink } from "./MeetingView.tsx";
import { Spinner } from "./ui.tsx";

interface Turn {
  id: string;
  question: string;
  answer?: string;
  error?: string;
  stopped?: boolean;
  step?: string;
  startedAt: number;
}

// One conversation for as long as the app is open. It carries on as you move between meetings,
// so following a link in an answer doesn't lose it. Each question says which meeting is open.
const chat: { sessionId?: string; turns: Turn[]; open: boolean } = { turns: [], open: false };
const listeners = new Set<() => void>();
const changed = () => listeners.forEach((listener) => listener());

api.onAskStep((askId, step) => {
  const turn = chat.turns.find((t) => t.id === askId);
  if (turn) {
    turn.step = step;
    changed();
  }
});

const SHORT_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const escapeHtml = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

/** "Team 51 – Leads sync · Oct 29" for a link to the folder "…/2026-10-29 1630 Team 51 – Leads sync". */
function meetingLinkText(href: string): string | null {
  let rel: string;
  try {
    rel = decodeURIComponent(href.replace(/&amp;/g, "&").split("#")[0]);
  } catch {
    return null;
  }
  rel = rel.replace(/^\.\//, "").replace(/\/+$/, "");
  if (/\.(md|json)$/i.test(rel)) rel = rel.split("/").slice(0, -1).join("/");
  const m = rel.split("/").pop()?.match(/^\d{4}-(\d\d)-(\d\d)(?: \d{4})? (.+)$/);
  return m ? `${escapeHtml(m[3])} · ${SHORT_MONTHS[+m[1] - 1]} ${+m[2]}` : null;
}

/**
 * Ask's answers come from a model that has read whatever was said on your calls, so a web link in
 * one is shown as plain text rather than made clickable. Links to meetings open in Oatcake and read
 * "Leads sync · Oct 29", like dates elsewhere, whatever the model wrote.
 */
const answerHtml = (markdown: string) =>
  toHtml(markdown).replace(/<a href="([^"]*)"([^>]*)>([\s\S]*?)<\/a>/gi, (whole, href: string, rest: string, text: string) => {
    if (/^[a-z][a-z0-9+.-]*:/i.test(href)) return text === href ? text : `${text} <span class="muted">(${href})</span>`;
    const label = meetingLinkText(href);
    return label ? `<a href="${href}"${rest}>${label}</a>` : whole;
  });

const SUGGESTIONS = ["What did we decide in this call?", "What’s still open from earlier meetings like this one?", "Who said they’d follow up, and on what?"];

async function send(meeting: string, question: string) {
  const turn: Turn = { id: crypto.randomUUID(), question, startedAt: Date.now() };
  chat.turns.push(turn);
  chat.open = true;
  changed();
  try {
    const { answer, sessionId } = await api.ask(turn.id, meeting, question, chat.sessionId);
    turn.answer = answer;
    chat.sessionId = sessionId;
  } catch (e) {
    const message = cleanError(e);
    if (message === "Stopped.") turn.stopped = true;
    else turn.error = message;
  }
  changed();
}

/** The floating "ask about your meetings" lozenge; the conversation opens above it. */
export function AskBar({ path, onOpen }: { path: string; onOpen(path: string): void }) {
  const [, rerender] = useReducer((n: number) => n + 1, 0);
  const [draft, setDraft] = useState("");
  const input = useRef<HTMLInputElement>(null);
  const turns = useRef<HTMLDivElement>(null);

  useEffect(() => {
    listeners.add(rerender);
    return () => void listeners.delete(rerender);
  }, []);

  const running = chat.turns.find((t) => t.answer === undefined && !t.error && !t.stopped);
  // The elapsed-time counter while an answer is on its way.
  useEffect(() => {
    if (!running) return;
    const timer = setInterval(rerender, 1000);
    return () => clearInterval(timer);
  }, [running?.id]);

  // Show the newest question at the top, so a long answer is read from its start.
  const last = chat.turns[chat.turns.length - 1];
  useEffect(() => {
    const box = turns.current;
    const turn = box?.lastElementChild as HTMLElement | null;
    if (box && turn) box.scrollTop = turn.offsetTop - box.offsetTop - 16;
  }, [chat.turns.length, last?.answer, last?.error, chat.open]);

  // Esc hides the conversation.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && chat.open) {
        chat.open = false;
        changed();
        input.current?.blur();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const submit = (text = draft) => {
    const question = text.trim();
    if (!question || running) return;
    setDraft("");
    send(path, question);
  };
  const setOpen = (open: boolean) => {
    chat.open = open;
    changed();
  };

  return (
    <>
      {/* The meeting fades out behind the lozenge, and dims behind an open conversation. */}
      <div className="ask-fade" />
      {chat.open && <div className="ask-scrim" onClick={() => setOpen(false)} />}
      {chat.open && (
        <div className="ask-panel-wrap">
          <div className="ask-panel">
            <div className="ask-head">
              <span>Ask about your meetings</span>
              <button
                className="btn ghost"
                disabled={!!running}
                onClick={() => {
                  chat.turns = [];
                  chat.sessionId = undefined;
                  setOpen(true);
                  input.current?.focus();
                }}
              >
                New chat
              </button>
              <button className="btn ghost" title="Hide (Esc)" onClick={() => setOpen(false)}>
                Hide
              </button>
            </div>
            <div className="ask-turns" ref={turns} onClick={(e) => meetingLink(e, onOpen)}>
              {chat.turns.map((turn) => (
                <div key={turn.id} className="ask-turn">
                  <div className="ask-question">{turn.question}</div>
                  {turn.answer !== undefined ? (
                    <article className="markdown small" dangerouslySetInnerHTML={{ __html: answerHtml(turn.answer) }} />
                  ) : turn.error ? (
                    <div className="ask-error">{turn.error}</div>
                  ) : turn.stopped ? (
                    <div className="muted">Stopped.</div>
                  ) : (
                    <div className="ask-wait">
                      <Spinner />
                      <span>{turn.step ?? "Thinking"}…</span>
                      <span>{Math.floor((Date.now() - turn.startedAt) / 1000)} s</span>
                    </div>
                  )}
                </div>
              ))}
              {!chat.turns.length && (
                <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
                  <div className="muted" style={{ lineHeight: 1.5 }}>
                    Ask anything across your meetings. Answers link to the meetings they draw on.
                  </div>
                  <div className="suggestions">
                    {SUGGESTIONS.map((q) => (
                      <span key={q} onClick={() => submit(q)}>
                        {q}
                      </span>
                    ))}
                  </div>
                </div>
              )}
            </div>
          </div>
        </div>
      )}
      <div className="ask-bar-wrap">
        <div className="ask-bar">
          <input
            ref={input}
            value={draft}
            placeholder={chat.turns.length ? "Ask a follow-up…" : "Ask about this call, or any other…"}
            onChange={(e) => setDraft(e.target.value)}
            onFocus={() => chat.turns.length > 0 && !chat.open && setOpen(true)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                submit();
              }
            }}
          />
          {running ? (
            <button className="round stop" title="Stop" onClick={() => api.cancelAsk(running.id)}>
              <StopIcon size={11} />
            </button>
          ) : (
            <button className={`round ${draft.trim() ? "ready" : ""}`} title="Send (Return)" onClick={() => submit()}>
              <SendIcon size={15} />
            </button>
          )}
        </div>
      </div>
    </>
  );
}
