import { useEffect, useState } from "react";
import { api, type CalendarEvent, type Config, type Recording, type TreeNode } from "./api.ts";
import { baseName, cleanError, folderPath, hhmm, loose, ownerLabel, shortDate } from "./format.ts";
import { CalendarIcon, VideoIcon } from "./icons.tsx";
import { meetingDate, meetingsIn } from "./MeetingList.tsx";
import { micHint, MicSelect, useInputs } from "./MicSelect.tsx";
import { parseTodos, toggleTodo, type Todo } from "./parse.ts";
import { findNode, linkName } from "./Sidebar.tsx";
import { Avatar, Checkbox, Select } from "./ui.tsx";

const NEW_FOLDER = "\u0000new";
const TOP = "\u0000top";

/** Every folder, as "Parent › Child". */
function allFolders(node: TreeNode | null, out: string[] = []): string[] {
  for (const c of node?.children ?? []) {
    if (c.kind !== "folder") continue;
    out.push(c.path);
    allFolders(c, out);
  }
  return out;
}

/**
 * Where a calendar event's recording goes: the folder named like the event (punctuation
 * ignored). A recurring event with no such folder gets a new one named after it; a one-off
 * uses the folder selected in the sidebar.
 */
function folderFor(event: CalendarEvent | undefined, tree: TreeNode | null, fallback: string) {
  if (!event) return { folder: fallback, newName: "" };
  // A one-off event isn't part of any series, so it doesn't borrow the sidebar's folder.
  fallback = TOP;
  // The folder's own name, or its whole path ("Team 51/Leads sync" for "Team 51 – Leads sync").
  // A title that is all punctuation matches nothing.
  const folders = allFolders(tree);
  const key = loose(event.title);
  const match = key ? (folders.find((f) => loose(baseName(f)) === key) ?? folders.find((f) => loose(f) === key)) : undefined;
  if (match) return { folder: match, newName: "" };
  // Folder names can't contain "/" or ":" ("Sam & Alex 1:1" becomes "Sam & Alex 1-1").
  return event.seriesId ? { folder: NEW_FOLDER, newName: event.title.replace(/[/:]/g, "-") } : { folder: fallback, newName: "" };
}

/** "Alex Kim" from an attendee, or from "alex.kim@…" when the invite has no name. */
const attendeeName = (a: { name?: string; email: string }) =>
  a.name ||
  a.email
    .split("@")[0]
    .split(/[._-]+/)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");

function eventWhen(e: CalendarEvent): string {
  const start = new Date(e.start);
  const today = new Date();
  const tomorrow = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 1);
  const day = start.toDateString() === today.toDateString() ? "Today" : start.toDateString() === tomorrow.toDateString() ? "Tomorrow" : start.toLocaleDateString("en-GB", { weekday: "long" });
  return [`${day} · ${hhmm(start)}–${hhmm(new Date(e.end))}`, e.meetUrl && linkName(e.meetUrl)].filter(Boolean).join(" · ");
}

export function NewRecording(props: {
  tree: TreeNode | null;
  event?: CalendarEvent;
  folder: string;
  config: Config;
  onStarted(rec: Recording): void;
  onCancel(): void;
}) {
  const { event, tree } = props;
  const initial = folderFor(event, tree, props.folder || TOP);
  const [folder, setFolder] = useState(initial.folder);
  const [newName, setNewName] = useState(initial.newName);
  const [title, setTitle] = useState(event?.title ?? "");
  const [prep, setPrep] = useState<string[]>([]);
  const [prepDraft, setPrepDraft] = useState("");
  const [error, setError] = useState("");
  const [starting, setStarting] = useState(false);
  const { devices, refresh } = useInputs();
  const [mic, setMic] = useState(props.config.mic);
  useEffect(() => setMic(props.config.mic), [props.config.mic]);

  // Open to-dos from the latest earlier meeting in this folder that had any.
  const [previous, setPrevious] = useState<{ path: string; date: Date | null; todo: string } | null>(null);
  const [ticked, setTicked] = useState<Set<number>>(new Set());
  // The top level isn't a series, so there's nothing to carry over from "last time".
  const candidates = folder === NEW_FOLDER || folder === TOP ? [] : meetingsIn(findNode(tree, folder)).slice(0, 8);
  // Re-read only when the folder or its meetings change: ticking a to-do rewrites todo.md, which
  // refreshes the tree, and that mustn't reset the list (a mis-tick stays visible to undo).
  const candidateKey = candidates.map((m) => m.path).join("\n");
  useEffect(() => {
    setPrevious(null);
    setTicked(new Set());
    let cancelled = false;
    (async () => {
      for (const m of candidates) {
        const { todo } = await api.readMeeting(m.path);
        if (cancelled) return;
        if (parseTodos(todo).length) return setPrevious({ path: m.path, date: meetingDate(m), todo });
      }
    })();
    return () => void (cancelled = true);
  }, [folder, candidateKey]);

  const tick = async (t: Todo) => {
    if (!previous) return;
    const todo = toggleTodo(previous.todo, t.line);
    setPrevious({ ...previous, todo });
    setTicked((s) => new Set([...s, t.line]));
    await api.writeMeetingFile(previous.path, "todo.md", todo);
  };
  const openTodos = previous ? parseTodos(previous.todo).filter((t) => !t.done || ticked.has(t.line)) : [];

  const folderName = folder === NEW_FOLDER ? newName.trim() : folder === TOP ? "" : baseName(folder);
  // Everyone invited except you, each in a distinct colour.
  const me = props.config.myName.toLowerCase();
  const others = (event?.attendees ?? []).filter((a) => {
    const name = attendeeName(a).toLowerCase();
    return name !== me && name !== me.split(" ")[0];
  });
  const hint = devices ? micHint(mic, devices) : { text: "", tone: "" as const };

  const start = async () => {
    if (starting) return; // a held or repeated Return
    if (folder === NEW_FOLDER && !newName.trim()) return setError("Give the new folder a name first.");
    setError("");
    setStarting(true);
    try {
      let target = folder === TOP ? "" : folder;
      if (folder === NEW_FOLDER) {
        // A top-level folder with this name already exists: use it.
        const existing = (tree?.children ?? []).find((c) => c.kind === "folder" && loose(c.name) === loose(newName));
        target = existing ? existing.path : await api.createFolder("", newName.trim());
      }
      const pending = prepDraft.trim() ? [...prep, prepDraft.trim()] : prep;
      const rec = await api.startRecording(title.trim() || folderName || "Untitled meeting", target, { eventId: event?.id, prep: pending });
      props.onStarted(rec);
    } catch (e) {
      setError(cleanError(e));
      setStarting(false);
    }
  };

  return (
    <>
      <div className="toolbar">
        <span style={{ fontWeight: 600 }}>New recording</span>
        {event && (
          <span className="muted" style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", minWidth: 0 }}>
            · {event.title}
          </span>
        )}
      </div>
      <div className="scroll form-scroll">
        <div className="form">
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            {event && (
              <div className="event-when">
                <CalendarIcon size={13} />
                {eventWhen(event)}
              </div>
            )}
            <div className="page-title">New recording</div>
          </div>

          <div className="form-grid">
            <span className="label">Folder</span>
            <Select
              value={folder}
              onChange={setFolder}
              options={[
                { value: TOP, label: "Meetings (top level)" },
                ...allFolders(tree).map((f) => ({ value: f, label: folderPath(f) })),
                { value: NEW_FOLDER, label: "New folder…" },
              ]}
            />
            {folder === NEW_FOLDER && (
              <>
                <span className="label">New folder</span>
                <div className="stack" style={{ gap: 4 }}>
                  <input className="field" autoFocus placeholder="Folder name" value={newName} onChange={(e) => setNewName(e.target.value)} />
                  <span className="hint">Created at the top level of your Meetings folder.</span>
                </div>
              </>
            )}
            <span className="label">Title</span>
            <input
              className="field"
              autoFocus={folder !== NEW_FOLDER}
              value={title}
              placeholder={`Leave blank to use “${folderName || (folder === NEW_FOLDER ? "the new folder’s name" : "Untitled meeting")}”`}
              onChange={(e) => setTitle(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && start()}
            />
            <span className="label">Microphone</span>
            <div className="stack" onMouseDown={refresh}>
              <MicSelect
                value={mic}
                devices={devices ?? []}
                onChange={(m) => {
                  setMic(m);
                  api.setMic(m);
                }}
              />
              <span className={`hint ${hint.tone}`}>{hint.text}</span>
            </div>
            {event && others.length > 0 && (
              <>
                <span className="label">Attendees</span>
                <div className="people">
                  {others.map((a) => (
                    <span key={a.email} className="person-chip" title={a.email}>
                      <Avatar name={attendeeName(a)} size={20} />
                      {attendeeName(a)}
                    </span>
                  ))}
                </div>
              </>
            )}
          </div>

          {openTodos.length > 0 && (
            <div>
              <div className="list-head">
                <div className="section-label">Open to-dos from {previous?.date ? shortDate(previous.date) : "last time"}</div>
                <span>Ticking one updates that meeting’s todo.md</span>
              </div>
              {openTodos.map((t) => (
                <div key={t.line} className={`open-todo ${t.done ? "done" : ""}`} onClick={() => tick(t)}>
                  <Checkbox checked={t.done} />
                  <span className="text">{t.text}</span>
                  <span className="owner">{ownerLabel(t.owner, props.config.myName)}</span>
                </div>
              ))}
            </div>
          )}

          <div>
            <div className="list-head" style={{ marginBottom: 6 }}>
              <div className="section-label">Prep notes</div>
              <span>Carried into the call’s notes</span>
            </div>
            {prep.map((p, i) => (
              <div key={i} className="note-row">
                <span className="chip prep">Prep</span>
                <span>{p}</span>
              </div>
            ))}
            <div className="note-row">
              <span className="chip outline">Prep</span>
              <input
                value={prepDraft}
                placeholder="An agenda point or question, then Return"
                onChange={(e) => setPrepDraft(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && prepDraft.trim()) {
                    e.preventDefault();
                    setPrep([...prep, prepDraft.trim()]);
                    setPrepDraft("");
                  }
                }}
              />
            </div>
          </div>

          {error && <div className="notice red">{error}</div>}
          <div className="buttons">
            <button className="btn large start" disabled={starting} onClick={start}>
              <span className="white-dot" />
              {starting ? "Starting…" : "Start recording"}
            </button>
            {event?.meetUrl && (
              <button className="btn large" title={`Opens ${linkName(event.meetUrl)}`} style={{ padding: "0 14px" }} onClick={() => window.open(event.meetUrl)}>
                <VideoIcon />
                Join the call
              </button>
            )}
            <button className="btn large ghost" onClick={props.onCancel}>
              Cancel
            </button>
          </div>
        </div>
      </div>
    </>
  );
}

export { TOP };
