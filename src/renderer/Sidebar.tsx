import { useEffect, useRef, useState } from "react";
import { callApp } from "../shared/calls.ts";
import { api, type Calendar, type CalendarEvent, type TreeNode } from "./api.ts";
import { clock, hhmm } from "./format.ts";
import { ChevronIcon, DotIcon, FolderIcon, NewFolderIcon, RefreshIcon, SettingsIcon, TodosIcon, WarningIcon } from "./icons.tsx";
import { RecDot, Spinner, toast } from "./ui.tsx";

export interface Job {
  id: string;
  title: string;
  status: "processing" | "review" | "failed";
  step: number;
  startedAt: string;
}

/** "21:10" today, otherwise "Nov 4, 21:10": tells two recordings of the same call apart. */
function jobWhen(iso: string): string {
  const d = new Date(iso);
  const time = hhmm(d);
  return d.toDateString() === new Date().toDateString() ? time : `${d.toLocaleDateString("en-US", { month: "short", day: "numeric" })}, ${time}`;
}

interface Props {
  tree: TreeNode | null;
  calendar: Calendar | null;
  jobs: Job[];
  /** starting: the recorder hasn't sent audio yet. */
  live: { title: string; elapsed: number; eventId?: string; starting: boolean } | null;
  /** What the detail pane shows, for highlighting. */
  selected: { kind: "live" } | { kind: "todos" } | { kind: "job"; id: string } | { kind: "folder"; path: string } | null;
  /** Open and overdue to-dos across every meeting. */
  todos: { open: number; overdue: number };
  onTodos(): void;
  onNewRecording(): void;
  onLive(): void;
  onEvent(event: CalendarEvent): void;
  onRefreshCalendar(): void;
  onJob(id: string): void;
  onFolder(path: string): void;
  onSettings(): void;
  /** A folder or meeting now lives at `to` (renamed or moved). */
  onMoved(from: string, to: string): void;
}

export const DRAG_TYPE = "application/x-oatcake-item";
const WIDTH_KEY = "sidebarWidth";
const OPEN_KEY = "openFolders";
const clampWidth = (w: number) => Math.min(520, Math.max(180, Math.round(w)));
const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/** Folders only; meetings are listed in the middle column. */
const subfolders = (node: TreeNode) => (node.children ?? []).filter((c) => c.kind === "folder");
const meetingCount = (node: TreeNode) => (node.children ?? []).filter((c) => c.kind === "meeting").length;

export function Sidebar(props: Props) {
  const { tree, calendar, selected } = props;
  const [width, setWidth] = useState(() => clampWidth(Number(localStorage.getItem(WIDTH_KEY)) || 260));
  const [resizing, setResizing] = useState(false);
  const [open, setOpen] = useState<Set<string>>(() => new Set(JSON.parse(localStorage.getItem(OPEN_KEY) ?? "[]")));
  const [renaming, setRenaming] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [dropTarget, setDropTarget] = useState<string | null>(null);
  const [now, setNow] = useState(() => new Date());

  useEffect(() => {
    if (!resizing) localStorage.setItem(WIDTH_KEY, String(width));
  }, [resizing, width]);
  useEffect(() => localStorage.setItem(OPEN_KEY, JSON.stringify([...open])), [open]);
  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), 30_000);
    return () => clearInterval(timer);
  }, []);
  // A selected folder's parents open, so it's visible.
  useEffect(() => {
    if (selected?.kind !== "folder" || !selected.path) return;
    const parts = selected.path.split("/");
    const parents = parts.slice(0, -1).map((_, i) => parts.slice(0, i + 1).join("/"));
    if (parents.some((p) => !open.has(p))) setOpen((o) => new Set([...o, ...parents]));
  }, [selected]);

  const toggle = (path: string) =>
    setOpen((o) => {
      const next = new Set(o);
      next.has(path) ? next.delete(path) : next.add(path);
      return next;
    });

  const newFolder = async (parent: string) => {
    const names = new Set((parent ? findNode(tree, parent) : tree)?.children?.map((c) => c.name.toLowerCase()) ?? []);
    let name = "untitled folder";
    for (let n = 2; names.has(name); n++) name = `untitled folder ${n}`;
    try {
      const path = await api.createFolder(parent, name);
      if (parent) setOpen((o) => new Set([...o, parent]));
      setDraft(name);
      setRenaming(path);
    } catch (e) {
      toast((e as Error).message);
    }
  };

  const commitRename = async () => {
    const path = renaming;
    setRenaming(null);
    if (!path || !draft.trim() || draft.trim() === path.split("/").pop()) return;
    try {
      const to = await api.renameItem(path, draft.trim());
      props.onMoved(path, to);
    } catch (e) {
      toast((e as Error).message.replace(/^Error invoking remote method '[^']+': (Error: )?/, ""));
    }
  };

  const menu = async (node: TreeNode) => {
    const action = await api.itemMenu(node.path, node.kind);
    if (action === "rename") {
      setDraft(node.name);
      setRenaming(node.path);
    } else if (action === "newFolder") newFolder(node.path);
    else if (action === "reveal") api.revealItem(node.path);
    else if (action === "trash") {
      await api.trashItem(node.path);
      toast(`Moved “${node.name}” to the Trash`);
    }
  };

  // Drag and drop: folders here and meetings from the middle column can be dropped on a folder.
  const dropProps = (target: string) => ({
    onDragOver: (e: React.DragEvent) => {
      if (!e.dataTransfer.types.includes(DRAG_TYPE)) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = "move";
      if (dropTarget !== target) setDropTarget(target);
    },
    onDragLeave: () => dropTarget === target && setDropTarget(null),
    onDrop: async (e: React.DragEvent) => {
      e.preventDefault();
      setDropTarget(null);
      const from = e.dataTransfer.getData(DRAG_TYPE);
      if (!from || from === target || target.startsWith(from + "/")) return;
      if (from.split("/").slice(0, -1).join("/") === target) return;
      try {
        const to = await api.moveItem(from, target);
        props.onMoved(from, to);
        toast(`Moved to ${target ? target.split("/").join(" › ") : "Meetings"}`);
      } catch (err) {
        toast((err as Error).message.replace(/^Error invoking remote method '[^']+': (Error: )?/, ""));
      }
    },
  });

  const renderFolder = (node: TreeNode, depth: number): React.ReactNode => {
    const kids = subfolders(node);
    const isOpen = open.has(node.path);
    const on = selected?.kind === "folder" && selected.path === node.path;
    return (
      <div key={node.path}>
        <div
          className={`folder-row ${on ? "on" : ""} ${dropTarget === node.path ? "drop" : ""}`}
          style={{ paddingLeft: 4 + depth * 14 }}
          draggable={renaming !== node.path}
          onDragStart={(e) => e.dataTransfer.setData(DRAG_TYPE, node.path)}
          onClick={() => props.onFolder(node.path)}
          onDoubleClick={() => {
            setDraft(node.name);
            setRenaming(node.path);
          }}
          onContextMenu={(e) => {
            e.preventDefault();
            menu(node);
          }}
          {...dropProps(node.path)}
        >
          <span
            className="chev"
            style={{ visibility: kids.length ? "visible" : "hidden" }}
            onClick={(e) => {
              e.stopPropagation();
              toggle(node.path);
            }}
          >
            <ChevronIcon size={9} style={{ transform: `rotate(${isOpen ? 90 : 0}deg)` }} />
          </span>
          <span className="folder-icon">
            <FolderIcon size={15} />
          </span>
          {renaming === node.path ? (
            <RenameField value={draft} onChange={setDraft} onDone={commitRename} onCancel={() => setRenaming(null)} />
          ) : (
            <>
              <span className="name">{node.name}</span>
              <span className="count">{meetingCount(node) || ""}</span>
            </>
          )}
        </div>
        {isOpen && kids.map((k) => renderFolder(k, depth + 1))}
      </div>
    );
  };

  // Upcoming: the rest of today and tomorrow, timed events only.
  const endOfTomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 2);
  const events = (calendar?.events ?? [])
    .filter((e) => !e.allDay && new Date(e.end) > now && new Date(e.start) < endOfTomorrow)
    .slice(0, 6);
  const next = events.find((e) => new Date(e.start) > now);
  const minsToNext = next ? Math.ceil((+new Date(next.start) - +now) / 60_000) : Infinity;
  const when = (e: CalendarEvent) => {
    const start = new Date(e.start);
    if (start <= now) return "Now";
    return start.toDateString() === now.toDateString() ? hhmm(start) : `${DAYS[start.getDay()]} ${hhmm(start)}`;
  };
  const calTip = calendar?.fetching
    ? "Fetching…"
    : calendar?.error
      ? calendar.error
      : calendar?.updatedAt
        ? `Updated ${hhmm(new Date(calendar.updatedAt))}`
        : "Not fetched yet";
  const calMessage = !calendar
    ? ""
    : !calendar.updatedAt
      ? calendar.error ?? "Fetching your calendar…"
      : events.length
        ? ""
        : "Nothing else today or tomorrow.";

  return (
    <aside className="sidebar" style={{ width }}>
      <div className="sidebar-head">
        <button className="new-recording" title="New recording" onClick={props.onNewRecording}>
          <DotIcon size={12} />
          {width >= 236 && <span>New recording</span>}
        </button>
      </div>
      <div className="sidebar-body">
        {props.live && (
          <div className={`recording-row ${selected?.kind === "live" ? "on" : ""} ${props.live.starting ? "starting" : ""}`} onClick={props.onLive}>
            {props.live.starting ? <span className="grey-dot" /> : <RecDot />}
            <div style={{ flex: 1, minWidth: 0 }}>
              <div className="title">{props.live.title}</div>
              <div className="time">{props.live.starting ? "Starting…" : `Recording · ${clock(props.live.elapsed)}`}</div>
            </div>
          </div>
        )}

        <div className={`todos-row ${selected?.kind === "todos" ? "on" : ""}`} title="To-dos from every meeting" onClick={props.onTodos}>
          <span className="icon">
            <TodosIcon size={15} />
          </span>
          <span className="label">To-dos</span>
          {props.todos.overdue > 0 && <span className="overdue">{props.todos.overdue} overdue</span>}
          <span className="n" title="Open to-dos">
            {props.todos.open || ""}
          </span>
        </div>

        {calendar && (
          <>
            <div className="sb-heading">
              <span>Upcoming</span>
              <button
                className={`icon-btn ${calendar.fetching ? "spinning" : ""} ${calendar.error ? "failed" : ""}`}
                title={`${calTip}. Refresh now.`}
                disabled={calendar.fetching}
                onClick={props.onRefreshCalendar}
              >
                <RefreshIcon size={12} />
              </button>
            </div>
            {events.map((e) => {
              // Status and countdown sit in the time column, so they never cut the title short.
              const recording = props.live?.eventId === e.id;
              const label = recording
                ? props.live!.starting
                  ? "Starting…"
                  : "Recording"
                : e === next && minsToNext <= 60
                  ? `in ${minsToNext}m`
                  : when(e);
              const tone = recording ? (props.live!.starting ? "starting" : "recording") : label === "Now" ? "now" : label.startsWith("in ") ? "soon" : "";
              return (
                <div
                  key={e.id}
                  className="event-row"
                  title={`${e.title} · ${hhmm(new Date(e.start))}–${hhmm(new Date(e.end))}${e.meetUrl ? ` · ${linkName(e.meetUrl)}` : ""}`}
                  onClick={() => props.onEvent(e)}
                >
                  <span className={`when ${tone}`}>{label}</span>
                  <span className="name">{e.title}</span>
                </div>
              );
            })}
            {calMessage && <div className={`sb-message ${calendar.error && !calendar.updatedAt ? "error" : ""}`}>{calMessage}</div>}
          </>
        )}

        {props.jobs.length > 0 && (
          <>
            <div className="sb-heading">
              <span>Needs review</span>
            </div>
            {props.jobs.map((j) => (
              <div key={j.id} className={`job-row ${selected?.kind === "job" && selected.id === j.id ? "on" : ""}`} onClick={() => props.onJob(j.id)}>
                <span className="mark">
                  {j.status === "processing" && <Spinner />}
                  {j.status === "review" && <span className="ready" />}
                  {j.status === "failed" && (
                    <span className="failed-mark">
                      <WarningIcon size={13} />
                    </span>
                  )}
                </span>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div className="title">{j.title}</div>
                  <div className={`status ${j.status === "failed" ? "failed" : ""}`}>
                    {j.status === "processing" ? `Processing · step ${j.step} of 5` : j.status === "review" ? "Ready to review" : "Couldn’t finish"} ·{" "}
                    {jobWhen(j.startedAt)}
                  </div>
                </div>
              </div>
            ))}
          </>
        )}

        <div
          className={`tree-root ${selected?.kind === "folder" && selected.path === "" ? "on" : ""} ${dropTarget === "" ? "drop" : ""}`}
          {...dropProps("")}
        >
          <span title="All meetings" onClick={() => props.onFolder("")}>
            Meetings
          </span>
          <button className="icon-btn" title="New folder" onClick={() => newFolder("")}>
            <NewFolderIcon size={15} />
          </button>
        </div>
        {tree && subfolders(tree).map((n) => renderFolder(n, 0))}
        {tree && !subfolders(tree).length && <div className="sb-message">No folders yet.</div>}
      </div>
      <div className="sidebar-foot" title="Settings (⌘,)" onClick={props.onSettings}>
        <SettingsIcon />
        Settings
      </div>
      <div
        className="sidebar-resizer"
        title="Drag to resize"
        onPointerDown={(e) => {
          e.preventDefault();
          e.currentTarget.setPointerCapture(e.pointerId);
          setResizing(true);
        }}
        onPointerMove={(e) => resizing && setWidth(clampWidth(e.clientX))}
        onPointerUp={() => setResizing(false)}
        onDoubleClick={() => setWidth(260)}
      />
    </aside>
  );
}

function RenameField(props: { value: string; onChange(v: string): void; onDone(): void; onCancel(): void }) {
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    ref.current?.focus();
    ref.current?.select();
  }, []);
  return (
    <input
      ref={ref}
      value={props.value}
      onChange={(e) => props.onChange(e.target.value)}
      onClick={(e) => e.stopPropagation()}
      onBlur={props.onDone}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") props.onDone();
        if (e.key === "Escape") props.onCancel();
      }}
    />
  );
}

export function findNode(tree: TreeNode | null, path: string): TreeNode | null {
  if (!tree) return null;
  if (tree.path === path) return tree;
  for (const c of tree.children ?? []) {
    if (c.kind === "folder" && (path === c.path || path.startsWith(c.path + "/"))) return findNode(c, path);
    if (c.path === path) return c;
  }
  return null;
}

/** "Google Meet", "Zoom" or "Microsoft Teams", from a call link. */
export const linkName = (url: string) => callApp(url) ?? "the call";
