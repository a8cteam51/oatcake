import { useEffect, useState } from "react";
import { api } from "./api.ts";
import { baseName, folderPath, isMe, parentOf, shortDate } from "./format.ts";
import { addTodo, parseTodos, toggleTodo, typedTodo, type Todo } from "./parse.ts";
import { Avatar, Checkbox, Segmented, Select, toast } from "./ui.tsx";

export interface MeetingTodos {
  path: string;
  title: string;
  startedAt?: string;
  todo: string;
}

export interface Item extends Todo {
  meeting: MeetingTodos;
  dueDate: Date | null;
}

const DAY = 86_400_000;
const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate());

/**
 * "Fri, Oct 30" → a date. To-dos give no year, so it's the meeting's year, or the next one when
 * that would put it well before the meeting (a December call agreeing something for January).
 */
export function dueDate(due: string, meetingDate?: string): Date | null {
  if (!due) return null;
  const met = meetingDate ? new Date(meetingDate) : new Date();
  const text = due.replace(/^[A-Za-z]+,\s*/, "").trim();
  const withYear = new Date(`${text} ${met.getFullYear()}`);
  const d = !isNaN(+withYear) ? withYear : new Date(text);
  if (isNaN(+d)) return null;
  if (!/\d{4}/.test(text) && +d < +met - 60 * DAY) d.setFullYear(d.getFullYear() + 1);
  return startOfDay(d);
}

/** Every to-do from every meeting. */
export function allItems(meetings: MeetingTodos[]): Item[] {
  return meetings.flatMap((m) => parseTodos(m.todo).map((t) => ({ ...t, meeting: m, dueDate: dueDate(t.due, m.startedAt) })));
}

export const isOverdue = (t: Item, today = startOfDay(new Date())) => !t.done && !!t.dueDate && +t.dueDate < +today;


type Status = "open" | "done" | "all";
type Group = "due" | "folder" | "owner";

export function TodosView(props: {
  meetings: MeetingTodos[];
  myName: string;
  onChanged(): void;
  onOpen(path: string, at: { tab: "summary" | "transcript"; stamp?: string }): void;
}) {
  const [status, setStatus] = useState<Status>("open");
  const [group, setGroup] = useState<Group>("due");
  const [owner, setOwner] = useState("all");
  const [adding, setAdding] = useState(false);
  // Ticked on this page: they stay (faded) in Open until you leave, so a mis-tick can be undone.
  const [touched, setTouched] = useState<Set<string>>(new Set());
  const [draft, setDraft] = useState("");
  // Ticks not yet read back from disk, so two quick ticks in one meeting don't undo each other.
  const [local, setLocal] = useState<Record<string, string>>({});
  useEffect(() => {
    setLocal((l) => Object.fromEntries(Object.entries(l).filter(([path, todo]) => props.meetings.find((m) => m.path === path)?.todo !== todo)));
  }, [props.meetings]);

  const today = startOfDay(new Date());
  const items = allItems(props.meetings.map((m) => (local[m.path] !== undefined ? { ...m, todo: local[m.path] } : m)));
  const key = (t: Item) => `${t.meeting.path}:${t.line}`;
  const open = items.filter((t) => !t.done);
  const overdue = items.filter((t) => isOverdue(t, today));

  let list = items.filter((t) => (status === "open" ? !t.done || touched.has(key(t)) : status === "done" ? t.done : true));
  if (owner === "mine") list = list.filter((t) => isMe(t.owner, props.myName));
  else if (owner !== "all") list = list.filter((t) => t.owner === owner);
  list.sort(
    (a, b) =>
      (a.dueDate ? +a.dueDate : Infinity) - (b.dueDate ? +b.dueDate : Infinity) ||
      (b.meeting.startedAt ?? "").localeCompare(a.meeting.startedAt ?? ""),
  );

  // Calendar weeks: "This week" runs to Sunday, "Next week" the seven days after.
  const endOfWeek = +today + ((7 - today.getDay()) % 7) * DAY;
  const bucket = (t: Item): [string, string] => {
    if (!t.dueDate) return ["6", "No due date"];
    const d = +t.dueDate;
    if (d < +today) return t.done ? ["1", "Was due earlier"] : ["0", "Overdue"];
    if (d === +today) return ["2", "Today"];
    if (d <= endOfWeek) return ["3", "This week"];
    if (d <= endOfWeek + 7 * DAY) return ["4", "Next week"];
    return ["5", "Later"];
  };
  const folderOf = (t: Item) => (t.meeting.path ? parentOf(t.meeting.path) : "");
  const groupKey = (t: Item): [string, string] =>
    group === "folder"
      ? [folderPath(folderOf(t)), folderPath(folderOf(t))]
      : group === "owner"
        ? [isMe(t.owner, props.myName) ? "0" : t.owner ? `1${t.owner}` : "2", isMe(t.owner, props.myName) ? "You" : t.owner || "No owner"]
        : bucket(t);
  const groups = new Map<string, { label: string; items: Item[] }>();
  for (const t of list) {
    const [k, label] = groupKey(t);
    if (!groups.has(k)) groups.set(k, { label, items: [] });
    groups.get(k)!.items.push(t);
  }
  const ordered = [...groups.entries()].sort(([a], [b]) => a.localeCompare(b));

  const owners = [...new Set(items.map((t) => t.owner).filter((o) => o && !isMe(o, props.myName)))].sort();
  // Your own list (the Meetings folder's todo.md) isn't a meeting.
  const fromMeetings = new Set(open.filter((t) => t.meeting.path).map((t) => t.meeting.path)).size;
  const fromYourList = open.some((t) => !t.meeting.path);
  const sources = [fromMeetings && `${fromMeetings} meeting${fromMeetings === 1 ? "" : "s"}`, fromYourList && "your list"].filter(Boolean).join(" and ");

  /** To-dos added here go in the Meetings folder's own todo.md, owned by you unless you name someone. */
  const add = async () => {
    const text = draft.trim();
    if (!text) return;
    const own = props.meetings.find((m) => m.path === "");
    const current = local[""] ?? own?.todo ?? "";
    const todo = addTodo(current, typedTodo(text, props.myName));
    setLocal((l) => ({ ...l, [""]: todo }));
    setDraft("");
    await api.writeMeetingFile("", "todo.md", todo);
    toast("Added to Meetings › todo.md");
    props.onChanged();
  };

  const tick = async (t: Item) => {
    const todo = toggleTodo(t.meeting.todo, t.line);
    setLocal((l) => ({ ...l, [t.meeting.path]: todo }));
    setTouched((s) => new Set([...s, key(t)]));
    await api.writeMeetingFile(t.meeting.path, "todo.md", todo);
    toast(`Saved to ${t.meeting.path ? folderPath(t.meeting.path) : "Meetings"} › todo.md`);
    props.onChanged();
  };

  const dueLabel = (t: Item) => {
    if (!t.dueDate) return "No date";
    const d = Math.round((+t.dueDate - +today) / DAY);
    return d === 0 ? "Today" : d === 1 ? "Tomorrow" : t.due;
  };

  return (
    <>
      <div className="toolbar todos-toolbar">
        <div className="todos-toolbar-inner">
        <div className="grow">
          <Segmented
            value={status}
            onChange={(s) => {
              setStatus(s);
              setTouched(new Set());
            }}
            options={[
              { value: "open", label: `Open · ${open.length}` },
              { value: "done", label: "Done" },
              { value: "all", label: "All" },
            ]}
          />
        </div>
        <label className="inline-field">
          <span>Group by</span>
          <Select
            width={124}
            value={group}
            onChange={(g) => setGroup(g as Group)}
            options={[
              { value: "due", label: "Due date" },
              { value: "folder", label: "Folder" },
              { value: "owner", label: "Owner" },
            ]}
          />
        </label>
        <label className="inline-field">
          <span>Owner</span>
          <Select
            width={140}
            value={owner}
            onChange={setOwner}
            options={[
              { value: "all", label: "Everyone" },
              { value: "mine", label: "Mine" },
              ...owners.map((o) => ({ value: o, label: o })),
            ]}
          />
        </label>
        </div>
      </div>
      <div className="scroll" style={{ padding: "28px 32px 48px" }}>
        <div className="todos-page">
          <div className="todos-head">
            <div style={{ flex: 1, minWidth: 0 }}>
              <div className="page-title">To-dos</div>
              <div className="muted" style={{ marginTop: 6 }}>
                {open.length} open{overdue.length ? ` · ${overdue.length} overdue` : ""}
                {sources && ` · from ${sources}`}. Ticking one updates that meeting’s todo.md.
              </div>
            </div>
          </div>
          <div className="todo-add standalone">
            <span className="checkbox ghost" />
            <input
              value={draft}
              placeholder="Add a to-do, then Return"
              title="Yours unless you name someone: Send the deck - Alex - due Fri, Nov 6"
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && add()}
              onFocus={() => setAdding(true)}
              onBlur={() => setAdding(false)}
            />
          </div>
          {/* How adding works, only while adding. */}
          {adding && (
            <div className="todo-add-hint">
              Saved in your Meetings folder’s own todo.md, as yours unless you name someone: Send the deck - Alex - due Fri, Nov 6. To add one to a
              meeting, use the to-dos at the top of its summary.
            </div>
          )}
          {ordered.map(([k, g]) => (
            <div key={k}>
              <div className="todo-group">
                {group === "owner" && g.items[0].owner && <Avatar name={g.items[0].owner} size={18} />}
                <span style={{ color: k === "0" && group === "due" ? "var(--red)" : undefined }}>{g.label}</span>
                <span className="n">{g.items.length}</span>
              </div>
              {g.items.map((t) => {
                const late = isOverdue(t, today);
                const folder = folderOf(t);
                const date = t.meeting.startedAt ? shortDate(new Date(t.meeting.startedAt)) : "";
                return (
                  <div key={key(t)} className={`todo-item ${t.done ? "done" : ""}`} style={{ opacity: t.done && status === "open" ? 0.55 : 1 }}>
                    <span title={t.done ? "Mark as not done" : "Mark as done"} style={{ marginTop: 2 }}>
                      <Checkbox checked={t.done} onClick={() => tick(t)} />
                    </span>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div className="text">{t.text}</div>
                      <div className="source">
                        {t.meeting.path ? (
                          <a title="Open this meeting" onClick={() => props.onOpen(t.meeting.path, { tab: "summary" })}>
                            <i style={{ background: folder ? "light-dark(#2f7fd8,#5aa9ff)" : "var(--fg3)" }} />
                            <span>{group === "folder" ? date || "Open meeting" : `${folder ? baseName(folder) : "Meetings"}${date ? ` · ${date}` : ""}`}</span>
                          </a>
                        ) : (
                          <span className="added-here">Your list</span>
                        )}
                        {t.stamp && (
                          <span className="chip link" title="Jump to this moment in the transcript" onClick={() => props.onOpen(t.meeting.path, { tab: "transcript", stamp: t.stamp })}>
                            {t.stamp}
                          </span>
                        )}
                      </div>
                    </div>
                    {/* 19: grouped by owner, the group heading already names them. */}
                    {group !== "owner" && (
                      <div className="owner">
                        {t.owner && (
                          <>
                            <Avatar name={t.owner} size={18} />
                            <span>{isMe(t.owner, props.myName) ? "You" : t.owner}</span>
                          </>
                        )}
                      </div>
                    )}
                    <div className={`due ${late ? "late" : !t.dueDate ? "none" : ""}`}>{dueLabel(t)}</div>
                  </div>
                );
              })}
            </div>
          ))}
          {!ordered.length && (
            <div className="muted" style={{ padding: "40px 0", textAlign: "center" }}>
              {status === "done" ? "Nothing ticked off yet." : owner === "all" ? "No open to-dos." : "No open to-dos for this person."}
            </div>
          )}
        </div>
      </div>
    </>
  );
}
