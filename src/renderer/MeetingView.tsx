import { useEffect, useRef, useState } from "react";
import { api, type MeetingMeta, type TreeNode } from "./api.ts";
import { folderPath, hhmm, longDate, minutes, ownerLabel, seconds, weekday } from "./format.ts";
import { FileIcon, FinderIcon } from "./icons.tsx";
import { forReading, toHtml } from "./markdown.ts";
import { meetingDate, meetingTitle } from "./MeetingList.tsx";
import { addTodo, parseNotes, parseTodos, parseTranscript, toggleTodo, typedTodo } from "./parse.ts";
import { Avatar, Checkbox, Segmented } from "./ui.tsx";

type Tab = "summary" | "transcript" | "notes";
type Mode = "rendered" | "markdown";
/** The files: "todos" is todo.md, shown at the top of the Summary tab. */
type FileKey = Tab | "todos";
type Files = Record<FileKey, string>;

const FILE: Record<FileKey, string> = { summary: "summary.md", transcript: "transcript.md", notes: "notes.md", todos: "todo.md" };
const TABS: Tab[] = ["summary", "transcript", "notes"];

// Remembered across meetings, so you can step through meetings on the same tab and view.
let lastTab: Tab = "summary";
let lastMode: Mode = "rendered";

/** Links in answers and summaries point at meeting folders, relative to the Meetings folder. */
export function meetingLink(e: React.MouseEvent, open: (path: string) => void) {
  const link = (e.target as HTMLElement).closest("a");
  const href = link?.getAttribute("href");
  if (!href || /^[a-z][a-z0-9+.-]*:/i.test(href)) return; // web links: the main process opens them
  e.preventDefault();
  let rel = href.split("#")[0];
  try {
    rel = decodeURIComponent(rel);
  } catch {
    return;
  }
  rel = rel.replace(/^\.\//, "").replace(/\/+$/, "");
  if (/\.(md|json)$/i.test(rel)) rel = rel.split("/").slice(0, -1).join("/");
  if (rel) open(rel);
}

export function MeetingView(props: {
  node: TreeNode;
  myName: string;
  onOpen(path: string): void;
  /** Open on this tab, and jump to this transcript time once loaded. */
  initial?: { tab: Tab; stamp?: string };
}) {
  const path = props.node.path;
  if (props.initial) lastTab = props.initial.tab;
  const [files, setFiles] = useState<Files | null>(null);
  const [meta, setMeta] = useState<MeetingMeta>({});
  const [error, setError] = useState("");
  const [tab, setTabState] = useState<Tab>(lastTab);
  const [mode, setModeState] = useState<Mode>(lastMode);
  const [status, setStatus] = useState<"" | "saving" | "saved" | "failed" | "todo">("");
  const [flash, setFlash] = useState(-1);
  const [newTodo, setNewTodo] = useState("");
  const scroller = useRef<HTMLDivElement>(null);
  const setTab = (t: Tab) => setTabState((lastTab = t));
  const setMode = (m: Mode) => setModeState((lastMode = m));

  // Edits save 600 ms after the last keystroke, and straight away when leaving the meeting. One
  // waiting edit per file: Markdown mode on the Summary tab edits todo.md and summary.md side by side.
  const pending = useRef(new Map<string, { path: string; file: string; content: string }>());
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const flush = async () => {
    clearTimeout(timer.current);
    for (const edit of [...pending.current.values()]) {
      try {
        await api.writeMeetingFile(edit.path, edit.file, edit.content);
        // Typing that arrived during the save stays waiting.
        if (pending.current.get(edit.file) === edit) pending.current.delete(edit.file);
      } catch {
        setStatus("failed");
        return;
      }
    }
    if (!pending.current.size) setStatus((s) => (s === "todo" ? "todo" : "saved"));
  };

  useEffect(() => {
    setFiles(null);
    setStatus("");
    setError("");
    const load = () =>
      api.readMeeting(path).then(
        // A change on disk (Finder, another editor, our own save) only replaces the text when
        // nothing typed here is still waiting to be saved.
        (m) => {
          if (pending.current.size) return;
          setFiles({ summary: m.summary, transcript: m.transcript, notes: m.notes, todos: m.todo });
          setMeta(m.meta);
        },
        (e: Error) => setError(e.message),
      );
    load();
    const unwatch = api.onTreeChanged(load);
    return () => {
      unwatch();
      flush();
    };
  }, [path]);

  // ⌘1–⌘3 switch tabs.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const index = ["1", "2", "3"].indexOf(e.key);
      if (e.metaKey && index >= 0) {
        e.preventDefault();
        flush();
        setTab(TABS[index]);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // "Saved to todo.md" shows for a couple of seconds after ticking a to-do.
  useEffect(() => {
    if (status !== "todo") return;
    const t = setTimeout(() => setStatus(""), 2000);
    return () => clearTimeout(t);
  }, [status, files?.todos]);

  // A jump lands on its transcript line, highlighted for a moment.
  useEffect(() => {
    if (flash < 0 || tab !== "transcript") return;
    const el = scroller.current?.querySelector(`[data-i="${flash}"]`) as HTMLElement | null;
    if (el && scroller.current) scroller.current.scrollTo({ top: Math.max(0, el.offsetTop - scroller.current.clientHeight / 3), behavior: "smooth" });
    const t = setTimeout(() => setFlash(-1), 1800);
    return () => clearTimeout(t);
  }, [flash, tab]);

  function jump(stamp: string) {
    const t = seconds(stamp);
    let index = 0;
    parseTranscript(files?.transcript ?? "").forEach((l, i) => l.at <= t && (index = i));
    flush();
    setMode("rendered");
    setTab("transcript");
    setFlash(index);
  }

  // Arriving from the To-dos page with a time: jump there once the transcript has loaded.
  const arrived = useRef(false);
  useEffect(() => {
    if (!files || arrived.current || !props.initial?.stamp) return;
    arrived.current = true;
    jump(props.initial.stamp);
  }, [files]);

  if (error) return <div className="empty-state">{error}</div>;
  if (!files) return <div className="toolbar empty" />;

  const write = (t: FileKey, content: string, now = false) => {
    setFiles({ ...files, [t]: content });
    pending.current.set(FILE[t], { path, file: FILE[t], content });
    setStatus(now ? "todo" : "saving");
    clearTimeout(timer.current);
    timer.current = setTimeout(flush, now ? 0 : 600);
  };

  // Granola labels your track "Microphone"; the call side carries Granola's own guesses at names.
  const lines = parseTranscript(files.transcript).map((l) =>
    l.speaker === "Microphone" ? { ...l, speaker: props.myName } : l.speaker === "System audio" ? { ...l, speaker: "Call audio" } : l,
  );
  const notes = parseNotes(files.notes);
  const todos = parseTodos(files.todos);
  const open = todos.filter((t) => !t.done).length;
  const granola = meta.source === "granola" || !!props.node.granola;
  // Granola's CSV export has transcripts without times or names: shown as plain paragraphs.
  const plain = lines.length ? [] : files.transcript.split("\n").map((l) => l.trim()).filter(Boolean);
  const granolaNotice = [
    "Imported from Granola.",
    !files.notes.trim() && "It didn’t keep your notes.",
    // Read the raw file: parseTranscript turns "System audio (Alex)" into plain "Alex".
    /^\[[\d:]+\]\s+System audio \(/m.test(files.transcript)
      ? "The names on the call side of its transcript are Granola’s own guesses."
      : /^\[[\d:]+\]\s+System audio:/m.test(files.transcript) && "Its transcript only tells your side of the call from everyone else’s.",
    plain.length > 0 && "Its transcript doesn’t say who said what.",
  ]
    .filter(Boolean)
    .join(" ");

  const date = meta.startedAt ? new Date(meta.startedAt) : meetingDate(props.node);
  const length = meta.startedAt && meta.endedAt ? (+new Date(meta.endedAt) - +new Date(meta.startedAt)) / 1000 : null;
  const others = (meta.participants ?? []).filter((n) => n !== props.myName);
  const withWhom = others.map((n) => n.replace(/\s*\(.*\)$/, ""));
  const metaLine = [
    date && `${weekday(date)}, ${longDate(date)}`,
    date && hhmm(date),
    length !== null && minutes(length),
    !granola && withWhom.length > 0 && `with ${withWhom.join(", ")}`,
  ]
    .filter(Boolean)
    .join(" · ");


  const tabLabel: Record<Tab, string> = { summary: "Summary", transcript: "Transcript", notes: "My notes" };

  return (
    <>
      <div className="toolbar">
        <div className="grow">
          <Segmented
            value={tab}
            onChange={(t) => {
              flush();
              setTab(t);
            }}
            options={TABS.map((t, i) => ({ value: t, label: tabLabel[t], title: `⌘${i + 1}` }))}
          />
        </div>
        {status && (mode === "markdown" || status === "todo") && (
          <span className={`save-status ${status === "failed" ? "error" : ""}`}>
            {{ saving: "Saving…", saved: "Saved", failed: "Couldn’t save", todo: "Saved to todo.md" }[status]}
            {status === "failed" && <a onClick={flush}>Try again</a>}
          </span>
        )}
        <Segmented
          size="small"
          value={mode}
          onChange={(m) => {
            flush();
            setMode(m);
            setStatus("");
          }}
          options={[
            { value: "rendered", label: "Rendered" },
            { value: "markdown", label: "Markdown" },
          ]}
        />
        <button className="btn" title="Show this meeting’s folder in Finder" onClick={() => api.revealItem(path)}>
          <FinderIcon size={13} />
          Show in Finder
        </button>
      </div>
      <div className="scroll meeting-scroll" ref={scroller}>
        <div className="page">
          <div className="page-title">{meta.title || meetingTitle(props.node)}</div>
          <div className="page-meta">{metaLine}</div>
          {granola && (
            <div className="notice grey" style={{ marginTop: 14 }}>
              <FileIcon size={14} style={{ marginTop: 1 }} />
              <span>{granolaNotice}</span>
            </div>
          )}
          <div style={{ height: 22 }} />

          {mode === "markdown" ? (
            (tab === "summary" ? (["todos", "summary"] as FileKey[]) : [tab]).map((f) => (
              <div key={f} style={{ marginBottom: 18 }}>
                <div className="file-path">
                  <FileIcon size={12} />
                  <span>
                    {folderPath(path)} › {FILE[f]}
                  </span>
                </div>
                <textarea
                  className={`markdown-source ${f === "todos" ? "short" : ""}`}
                  spellCheck={f !== "transcript"}
                  placeholder={f === "todos" ? "- [ ] What to do — Owner — due Fri, Oct 30 — [12:34]" : ""}
                  value={files[f]}
                  onChange={(e) => write(f, e.target.value)}
                />
              </div>
            ))
          ) : tab === "summary" ? (
            <>
              <div className="meeting-todos">
                {/* No to-dos yet: just the field to add one. */}
                {todos.length > 0 && (
                  <div className="list-head">
                    <div className="section-label">To-dos{open ? ` · ${open} open` : ""}</div>
                  </div>
                )}
                {todos.map((t) => (
                  <div key={t.line} className={`todo-row ${t.done ? "done" : ""}`}>
                    <Checkbox checked={t.done} onClick={() => write("todos", toggleTodo(files.todos, t.line), true)} />
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div className="text">{t.text}</div>
                      {(t.owner || t.due) && <div className="meta">{[ownerLabel(t.owner, props.myName), t.due && `due ${t.due}`].filter(Boolean).join(" · ")}</div>}
                    </div>
                    {t.stamp && (
                      <span className="chip link" title="Jump to this moment in the transcript" onClick={() => jump(t.stamp)}>
                        {t.stamp}
                      </span>
                    )}
                  </div>
                ))}
                <div className="todo-add">
                  <span className="checkbox ghost" />
                  <input
                    value={newTodo}
                    placeholder="Add a to-do, then Return"
                    title="Add an owner or due date with dashes: Send the deck - Alex - due Fri, Nov 6"
                    onChange={(e) => setNewTodo(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key !== "Enter" || !newTodo.trim()) return;
                      write("todos", addTodo(files.todos, typedTodo(newTodo)), true);
                      setNewTodo("");
                    }}
                  />
                </div>
              </div>
              {forReading(files.summary).trim() ? (
                <article
                  className="markdown"
                  onClick={(e) => {
                    const stamp = (e.target as HTMLElement).closest<HTMLElement>("[data-stamp]")?.dataset.stamp;
                    if (stamp) return jump(stamp);
                    meetingLink(e, props.onOpen);
                  }}
                  dangerouslySetInnerHTML={{ __html: toHtml(forReading(files.summary)) }}
                />
              ) : (
                <div className="empty-text">No summary for this meeting.</div>
              )}
            </>
          ) : tab === "transcript" ? (
            <div className="transcript">
              {lines.map((l, i) => (
                <div key={i} data-i={i} className={`transcript-line ${i === flash ? "flash" : ""}`}>
                  <Avatar name={l.speaker} />
                  <div style={{ minWidth: 0 }}>
                    <div className="who">
                      <span>{l.speaker}</span>
                      <span>{l.stamp}</span>
                    </div>
                    <div className="said">{l.text}</div>
                  </div>
                </div>
              ))}
              {plain.map((p, i) => (
                <p key={i} className="said plain">
                  {p}
                </p>
              ))}
              {!lines.length && !plain.length && <div className="empty-text" style={{ padding: "0 10px" }}>transcript.md is empty.</div>}
            </div>
          ) : (
            <div>
              {notes.map((n, i) => (
                <div key={i} className="note-row">
                  <span className={`chip ${n.stamp ? "" : "prep"}`}>{n.stamp ?? "Prep"}</span>
                  <span>{n.text}</span>
                </div>
              ))}
              {!notes.length && (
                <div className="empty-text">
                  {granola ? "No notes. Granola didn’t keep your notes when this meeting was imported." : "You didn’t take notes in this meeting."}
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </>
  );
}
