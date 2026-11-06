import { useEffect, useRef, useState } from "react";
import { api, type TreeNode } from "./api.ts";
import { baseName, folderPath, hhmm, longDate, parentOf, sameAsFolder } from "./format.ts";
import { DotIcon } from "./icons.tsx";
import { DRAG_TYPE } from "./Sidebar.tsx";
import { toast } from "./ui.tsx";

const LIST_WIDTH = "listWidth";
const clampList = (w: number) => Math.min(560, Math.max(220, Math.round(w)));

/** When a meeting happened: meeting.json, or the "2026-10-02 1400 Title" folder name. */
export function meetingDate(node: TreeNode): Date | null {
  if (node.startedAt && !isNaN(+new Date(node.startedAt))) return new Date(node.startedAt);
  const m = node.name.match(/^(\d{4})-(\d{2})-(\d{2}) (\d{2})(\d{2})/);
  return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) : null;
}

/** The title to show: meeting.json's, or the folder name without its date. */
export const meetingTitle = (node: TreeNode) => node.title || node.name.replace(/^\d{4}-\d{2}-\d{2} \d{4} /, "");

const newestFirst = (a: TreeNode, b: TreeNode) =>
  (+(meetingDate(b) ?? 0) || 0) - (+(meetingDate(a) ?? 0) || 0) || b.name.localeCompare(a.name);

/** The meetings directly inside a folder, newest first. */
export function meetingsIn(folder: TreeNode | null): TreeNode[] {
  return (folder?.children ?? []).filter((c) => c.kind === "meeting").sort(newestFirst);
}

/** Every meeting under a folder, in any subfolder, newest first. */
export function allMeetingsIn(folder: TreeNode | null): TreeNode[] {
  const walk = (n: TreeNode): TreeNode[] => (n.kind === "meeting" ? [n] : (n.children ?? []).flatMap(walk));
  return folder ? walk(folder).sort(newestFirst) : [];
}

/** What the middle column lists: a folder's own meetings, or every meeting for the top level. */
export const listedIn = (folder: TreeNode | null) => (folder && !folder.path ? allMeetingsIn(folder) : meetingsIn(folder));

export function MeetingList(props: {
  folder: TreeNode | null;
  selected: string | null;
  onOpen(path: string): void;
  onRecordHere(): void;
  onMoved(from: string, to: string): void;
}) {
  const folder = props.folder;
  // The top level lists every meeting, each labelled with the folder it's in.
  const everything = !folder?.path;
  const rows = listedIn(folder);
  const [renaming, setRenaming] = useState<TreeNode | null>(null);
  // Width is draggable like the sidebar's, and remembered.
  const [width, setWidth] = useState(() => clampList(Number(localStorage.getItem(LIST_WIDTH)) || 300));
  const [resizing, setResizing] = useState<{ x: number; width: number } | null>(null);
  useEffect(() => {
    if (!resizing) localStorage.setItem(LIST_WIDTH, String(width));
  }, [resizing, width]);
  const name = everything ? "All meetings" : baseName(folder!.path);
  const parent = everything ? "" : parentOf(folder!.path) ? `${folderPath(parentOf(folder!.path))} · ` : "";

  const menu = async (node: TreeNode) => {
    const action = await api.itemMenu(node.path, "meeting");
    if (action === "reveal") api.revealItem(node.path);
    if (action === "trash") {
      await api.trashItem(node.path);
      toast(`Moved “${meetingTitle(node)}” to the Trash`);
    }
    if (action === "rename") setRenaming(node);
  };
  const rename = async (node: TreeNode, to: string) => {
    setRenaming(null);
    if (!to.trim() || to.trim() === node.name) return;
    try {
      props.onMoved(node.path, await api.renameItem(node.path, to.trim()));
    } catch (e) {
      toast((e as Error).message.replace(/^Error invoking remote method '[^']+': (Error: )?/, ""));
    }
  };

  return (
    <div className="meeting-list" style={{ width }}>
      <div className="head">
        <span>{name}</span>
        <span>
          {parent}
          {rows.length} meeting{rows.length === 1 ? "" : "s"}
        </span>
      </div>
      <div className="rows">
        {rows.map((m) => {
          const date = meetingDate(m);
          const title = meetingTitle(m);
          return (
            <div
              key={m.path}
              className={`meeting-row ${props.selected === m.path ? "on" : ""}`}
              draggable
              onDragStart={(e) => e.dataTransfer.setData(DRAG_TYPE, m.path)}
              onClick={() => props.onOpen(m.path)}
              onContextMenu={(e) => {
                e.preventDefault();
                menu(m);
              }}
            >
              {renaming?.path === m.path && <RenameRow initial={m.name} onDone={(to) => rename(m, to)} onCancel={() => setRenaming(null)} />}
              <div className="line1">
                <span className="date">{date ? longDate(date) : m.name}</span>
                {date && (
                  <>
                    <span className="dim">·</span>
                    <span className="dim">{hhmm(date)}</span>
                  </>
                )}
                {m.granola && <span className="tag grey">Granola</span>}
              </div>
              {everything ? (
                <div className="title">
                  {parentOf(m.path) ? (
                    <>
                      {folderPath(parentOf(m.path))}
                      {!sameAsFolder(title, parentOf(m.path)) && <span className="dim"> · {title}</span>}
                    </>
                  ) : (
                    title
                  )}
                </div>
              ) : (
                !sameAsFolder(title, folder?.path ?? "") && <div className="title">{title}</div>
              )}
              {m.preview && <div className="preview">{m.preview}</div>}
            </div>
          );
        })}
        {!rows.length && (
          <div className="list-empty">
            <span>{everything ? "No meetings yet." : "No meetings in this folder yet."}</span>
            <button className="btn" onClick={props.onRecordHere}>
              <DotIcon size={10} />
              Record here
            </button>
          </div>
        )}
      </div>
      <div
        className="list-resizer"
        title="Drag to resize"
        onPointerDown={(e) => {
          e.preventDefault();
          e.currentTarget.setPointerCapture(e.pointerId);
          setResizing({ x: e.clientX, width });
        }}
        onPointerMove={(e) => resizing && setWidth(clampList(resizing.width + e.clientX - resizing.x))}
        onPointerUp={() => setResizing(null)}
        onDoubleClick={() => setWidth(300)}
      />
    </div>
  );
}

/** Renames the meeting's folder ("2026-11-05 1400 Weekly sync"). */
function RenameRow(props: { initial: string; onDone(name: string): void; onCancel(): void }) {
  const [value, setValue] = useState(props.initial);
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => ref.current?.select(), []);
  return (
    <input
      ref={ref}
      className="field"
      value={value}
      onChange={(e) => setValue(e.target.value)}
      onClick={(e) => e.stopPropagation()}
      onBlur={() => props.onDone(value)}
      onKeyDown={(e) => {
        if (e.key === "Enter") props.onDone(value);
        if (e.key === "Escape") props.onCancel();
      }}
    />
  );
}
