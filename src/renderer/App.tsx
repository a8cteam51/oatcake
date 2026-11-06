import { useCallback, useEffect, useRef, useState } from "react";
import { api, type Calendar, type CalendarEvent, type Config, type Recording, type RecorderStatus, type TreeNode } from "./api.ts";
import { AskBar } from "./AskBar.tsx";
import { cleanError, folderPath, parentOf } from "./format.ts";
import { LiveView, saveLiveNotes } from "./LiveView.tsx";
import { listedIn, MeetingList } from "./MeetingList.tsx";
import { MeetingView } from "./MeetingView.tsx";
import { NewRecording } from "./NewRecording.tsx";
import { ProcessingView, stepNumber, type JobProgress } from "./ProcessingView.tsx";
import { ReviewView } from "./ReviewView.tsx";
import { findNode, Sidebar, type Job } from "./Sidebar.tsx";
import { allItems, isOverdue, TodosView, type MeetingTodos } from "./TodosView.tsx";
import { ConfirmSheet, ToastHost, toast, type Confirmation } from "./ui.tsx";

/** What the detail pane shows. */
export type Selection =
  | { kind: "meeting"; path: string; initial?: { tab: "summary" | "transcript"; stamp?: string; nonce: number } }
  | { kind: "todos" }
  | { kind: "folder"; path: string }
  | { kind: "new"; event?: CalendarEvent; key: number }
  | { kind: "live" }
  | { kind: "job"; id: string }
  | null;

const LAST_MEETING = "lastMeeting";
const allMeetings = (node: TreeNode): TreeNode[] =>
  node.kind === "meeting" ? [node] : (node.children ?? []).flatMap(allMeetings);

export function App() {
  const [tree, setTree] = useState<TreeNode | null>(null);
  const [calendar, setCalendar] = useState<Calendar | null>(null);
  const [config, setConfig] = useState<Config | null>(null);
  const [pending, setPending] = useState<Recording[]>([]);
  const [todoMeetings, setTodoMeetings] = useState<MeetingTodos[]>([]);
  const [progress, setProgress] = useState<Record<string, JobProgress>>({});
  const [live, setLive] = useState<Recording | null>(null);
  const [status, setStatus] = useState<RecorderStatus>({ state: "starting" });
  const [sel, setSel] = useState<Selection>(null);
  const [folder, setFolder] = useState("");
  const [confirm, setConfirm] = useState<Confirmation | null>(null);
  const started = useRef(new Set<string>());

  const refresh = useCallback(async () => {
    const [tree, pending, todos] = await Promise.all([api.getTree(), api.pendingRecordings(), api.allTodos()]);
    setTree(tree);
    setPending(pending);
    setTodoMeetings(todos);
  }, []);

  // Recordings waiting to be processed start straight away, in the background.
  useEffect(() => {
    for (const rec of pending) {
      if (rec.state === "recorded" && !started.current.has(rec.id)) {
        started.current.add(rec.id);
        api.analyse(rec.id).catch((e) => setProgress((p) => ({ ...p, [rec.id]: { step: p[rec.id]?.step ?? "Starting", error: cleanError(e) } })));
      }
    }
  }, [pending]);

  useEffect(() => {
    refresh();
    api.getConfig().then(setConfig);
    api.getCalendar().then(setCalendar);
    const offs = [
      api.onTreeChanged(refresh),
      api.onCalendarChanged(setCalendar),
      api.onConfigChanged((c) => {
        setConfig(c);
        api.getCalendar().then(setCalendar);
      }),
      api.onAnalyseProgress((id, p) => {
        if (p.done) {
          refresh();
          setProgress((all) => {
            const { [id]: _, ...rest } = all;
            return rest;
          });
        } else if (p.error) {
          setProgress((all) => ({ ...all, [id]: { step: all[id]?.step ?? "Starting", error: p.error } }));
        } else if (p.step) {
          setProgress((all) => ({ ...all, [id]: { step: p.step!, fraction: p.fraction } }));
        }
      }),
    ];
    // Reopening the window mid-call, or a reminder's button starting one, goes to the recording.
    const toLive = () =>
      api.activeRecordings().then((active) => {
        if (active[0]) {
          setLive(active[0]);
          setSel({ kind: "live" });
        }
      });
    toLive();
    // A clicked reminder opens New recording for its event, unless a call is already being recorded.
    const openEvent = async () => {
      const event = await api.takePendingEvent();
      if (!event) return;
      const [recording] = await api.activeRecordings();
      if (recording) {
        setLive(recording);
        setSel({ kind: "live" });
      } else setSel({ kind: "new", event, key: Date.now() });
    };
    openEvent();
    offs.push(api.onRecordingStarted(toLive), api.onEventOpen(openEvent));
    return () => offs.forEach((off) => off());
  }, [refresh]);

  // Open the meeting you were last reading, once the tree has loaded.
  const restored = useRef(false);
  useEffect(() => {
    if (!tree || restored.current) return;
    restored.current = true;
    if (sel) return;
    const last = localStorage.getItem(LAST_MEETING);
    if (last && findNode(tree, last)?.kind === "meeting") return openMeeting(last);
    // First run: the most recent meeting anywhere.
    const newest = allMeetings(tree).sort((a, b) => (b.startedAt ?? "").localeCompare(a.startedAt ?? ""))[0];
    if (newest) openMeeting(newest.path);
  }, [tree]);
  useEffect(() => {
    if (sel?.kind === "meeting") localStorage.setItem(LAST_MEETING, sel.path);
  }, [sel]);

  // The live recording's status, for the timer, meters and sidebar row.
  useEffect(() => {
    if (!live) return;
    const timer = setInterval(async () => setStatus(await api.recorderStatus(live.id)), 500);
    return () => clearInterval(timer);
  }, [live]);

  const openMeeting = (path: string, at?: { tab: "summary" | "transcript"; stamp?: string }) => {
    const node = findNode(tree, path);
    if (!node || node.kind !== "meeting") return;
    setFolder(parentOf(path));
    setSel({ kind: "meeting", path, ...(at && { initial: { ...at, nonce: Date.now() } }) });
  };
  const openFolder = (path: string) => {
    setFolder(path);
    const first = listedIn(findNode(tree, path))[0];
    setSel(first ? { kind: "meeting", path: first.path } : { kind: "folder", path });
  };
  const newRecording = (event?: CalendarEvent) => setSel(live ? { kind: "live" } : { kind: "new", event, key: Date.now() });

  const stop = () =>
    setConfirm({
      title: "Stop recording?",
      text: "Oatcake will transcribe the call and ask you to check who’s who. You can’t add more to this recording afterwards.",
      ok: "Stop recording",
      cancel: "Keep recording",
      onOk: async () => {
        if (!live) return;
        const id = live.id;
        await saveLiveNotes(id);
        await api.stopRecording(id);
        setLive(null);
        setStatus({ state: "starting" });
        setProgress((p) => ({ ...p, [id]: { step: "Starting" } }));
        setSel({ kind: "job", id });
        await refresh();
      },
    });

  /** Cancel before any audio arrived: stop the recorder and throw the recording away. */
  const cancelRecording = (hasNotes: boolean) => {
    const cancel = async () => {
      if (!live) return;
      const id = live.id;
      await api.stopRecording(id);
      await api.discardRecording(id);
      setLive(null);
      setStatus({ state: "starting" });
      openFolder(folder);
      toast("Recording cancelled");
      await refresh();
    };
    if (!hasNotes) return void cancel().catch((e) => toast(cleanError(e)));
    setConfirm({
      title: "Cancel this recording?",
      text: "Nothing has been recorded yet. The notes you’ve typed for it will be deleted.",
      ok: "Cancel recording",
      cancel: "Keep waiting",
      onOk: cancel,
    });
  };

  const discard = (rec: Recording) =>
    setConfirm({
      title: "Discard this recording?",
      text: "The audio, transcript and your notes will be deleted. This can’t be undone.",
      ok: "Discard",
      cancel: "Cancel",
      onOk: async () => {
        await api.discardRecording(rec.id);
        await refresh();
        openFolder(folder);
        toast("Recording discarded");
      },
    });

  const retry = (rec: Recording) => {
    setProgress((p) => ({ ...p, [rec.id]: { step: "Starting" } }));
    api.analyse(rec.id).catch((e) => setProgress((p) => ({ ...p, [rec.id]: { step: "Starting", error: cleanError(e) } })));
  };

  const moved = (from: string, to: string) => {
    const remap = (p: string) => (p === from ? to : p.startsWith(from + "/") ? to + p.slice(from.length) : p);
    setFolder(remap);
    setSel((s) => (s?.kind === "meeting" || s?.kind === "folder" ? { ...s, path: remap(s.path) } : s));
  };

  const jobs: Job[] = pending
    .slice()
    .sort((a, b) => b.startedAt.localeCompare(a.startedAt))
    .map((r) => ({
      id: r.id,
      title: r.title,
      status: progress[r.id]?.error ? "failed" : r.state === "processed" ? "review" : "processing",
      step: stepNumber(progress[r.id]?.step ?? ""),
      startedAt: r.startedAt,
    }));

  // The Dock badge counts what's waiting for you: recordings to review, or that failed.
  const waiting = jobs.filter((j) => j.status !== "processing").length;
  useEffect(() => {
    api.setBadge(waiting);
  }, [waiting]);

  const todoItems = allItems(todoMeetings);
  const todoCounts = { open: todoItems.filter((t) => !t.done).length, overdue: todoItems.filter((t) => isOverdue(t)).length };

  const job = sel?.kind === "job" ? pending.find((r) => r.id === sel.id) : undefined;
  const meeting = sel?.kind === "meeting" ? findNode(tree, sel.path) : null;
  const showList = !sel || sel.kind === "meeting" || sel.kind === "folder";
  const folderNode = findNode(tree, folder) ?? tree;

  return (
    <div className="app">
      <Sidebar
        tree={tree}
        calendar={calendar}
        jobs={jobs}
        live={live ? { title: live.title, elapsed: status.elapsed ?? 0, eventId: live.eventId, starting: status.state !== "recording" } : null}
        selected={
          sel?.kind === "live" || sel?.kind === "job" || sel?.kind === "todos" ? sel : showList ? { kind: "folder", path: folder } : null
        }
        todos={todoCounts}
        onTodos={() => setSel({ kind: "todos" })}
        onNewRecording={() => newRecording()}
        onLive={() => setSel({ kind: "live" })}
        onEvent={(e) => newRecording(e)}
        onRefreshCalendar={() => api.refreshCalendar()}
        onJob={(id) => setSel({ kind: "job", id })}
        onFolder={openFolder}
        onSettings={() => api.openSettings()}
        onMoved={moved}
      />
      {showList && (
        <MeetingList
          folder={folderNode}
          selected={sel?.kind === "meeting" ? sel.path : null}
          onOpen={openMeeting}
          onRecordHere={() => newRecording()}
          onMoved={moved}
        />
      )}
      <main className="detail">
        {meeting && config ? (
          <>
            <MeetingView
              key={meeting.path + (sel?.kind === "meeting" && sel.initial ? sel.initial.nonce : "")}
              node={meeting}
              myName={config.myName}
              onOpen={openMeeting}
              initial={sel?.kind === "meeting" ? sel.initial : undefined}
            />
            <AskBar path={meeting.path} onOpen={openMeeting} />
          </>
        ) : sel?.kind === "todos" && config ? (
          <TodosView meetings={todoMeetings} myName={config.myName} onChanged={refresh} onOpen={openMeeting} />
        ) : sel?.kind === "new" && config ? (
          <NewRecording
            key={sel.key}
            tree={tree}
            event={sel.event}
            folder={folder}
            config={config}
            onStarted={(rec) => {
              setLive(rec);
              setStatus({ state: "starting" });
              setSel({ kind: "live" });
            }}
            onCancel={() => openFolder(folder)}
          />
        ) : sel?.kind === "live" && live && config ? (
          <LiveView rec={live} status={status} config={config} onStop={stop} onCancel={cancelRecording} />
        ) : job && job.state === "processed" ? (
          <ReviewView
            key={job.id}
            rec={job}
            onSaved={async (path, savedFolder) => {
              await refresh();
              setFolder(parentOf(path));
              setSel({ kind: "meeting", path });
              toast(`Saved to ${folderPath(savedFolder)}`);
            }}
            onDiscard={() => discard(job)}
          />
        ) : job ? (
          <ProcessingView key={job.id} rec={job} progress={progress[job.id]} onRetry={() => retry(job)} onDiscard={() => discard(job)} />
        ) : (
          <>
            <div className="toolbar empty" />
            {/* An empty folder says so (with Record here) in the middle column; this pane stays blank. */}
            <div className="empty-state">{listedIn(folderNode).length ? "Select a meeting" : ""}</div>
          </>
        )}
        <ToastHost />
      </main>
      {confirm && <ConfirmSheet confirm={confirm} onClose={() => setConfirm(null)} />}
    </div>
  );
}
