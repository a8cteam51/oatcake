import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import { app, BrowserWindow, dialog, ipcMain, Menu, Notification, session, shell, utilityProcess, type IpcMainInvokeEvent } from "electron";
import { ask } from "../core/ask.ts";
import {
  CALENDAR_PATH,
  calendarIsStale,
  fetchCalendar,
  loadCalendar,
  saveCalendar,
  type CalendarCache,
  type CalendarEvent,
} from "../core/calendar.ts";
import { DATA_DIR, loadConfig, RECORDINGS_DIR, saveConfig, type Config } from "../core/config.ts";
import { createFolder, folderForEvent, listTodos, listTree, moveItem, readMeeting, renameItem, resolveInside, writeMeetingFile } from "../core/meetings.ts";
import {
  discardRecording,
  finishInterrupted,
  getRecording,
  listInputs,
  listRecordings,
  loadNotes,
  recorderRunning,
  recorderStatus,
  saveNotes,
  setRecordingMic,
  startRecording,
  stopRecording,
  type Recording,
  type StartOptions,
} from "../core/recordings.ts";
import { saveMeeting } from "../core/save.ts";
import { createLlm } from "../core/llm/index.ts";
import { knownPeople } from "../core/speakers.ts";
import type { ItemAction } from "../shared/api.ts";
import { callApp } from "../shared/calls.ts";
import { applySecrets, describeSecret, getSecret, setSecret, type SecretName } from "./secrets.ts";

// Apps opened from Finder get a bare PATH; borrow the login shell's so `claude` is found.
// Markers, because interactive shells can print terminal escape codes before the value.
try {
  const out = execFileSync(process.env.SHELL || "/bin/zsh", ["-ilc", 'printf "<<PATH>>%s<<PATH>>" "$PATH"'], {
    encoding: "utf8",
    timeout: 5000,
    stdio: ["ignore", "pipe", "ignore"],
  });
  const shellPath = out.split("<<PATH>>")[1];
  if (shellPath) process.env.PATH = shellPath;
} catch {
  // Keep the inherited PATH.
}

// Chromium's caches get their own subfolder, apart from the app's data (config, models, recordings).
app.setPath("userData", path.join(DATA_DIR, "Chromium"));

let win: BrowserWindow | null = null;
let settingsWin: BrowserWindow | null = null;
const active = new Map<string, Recording>();
const analysing = new Set<string>();
const asking = new Map<string, () => void>();

const recorderApp = () =>
  app.isPackaged
    ? path.join(process.resourcesPath, "OatcakeRecorder.app")
    : path.join(app.getAppPath(), "recorder", "build", "OatcakeRecorder.app");

/** Messages go to every window: the main one and Settings both show calendar and config state. */
const send = (channel: string, ...args: unknown[]) =>
  BrowserWindow.getAllWindows().forEach((w) => w.webContents.send(channel, ...args));
const meetingsRoot = () => loadConfig().outputDir;
/** The calendar's private iCal address, kept encrypted with the API keys. "" = no calendar. */
const calendarUrl = () => getSecret("calendar").trim();
const RENDERER_PAGE = path.join(__dirname, "..", "renderer", "index.html");

function createWindow() {
  win = new BrowserWindow({
    width: 1440,
    height: 880,
    minWidth: 1000,
    minHeight: 560,
    title: "Oatcake",
    titleBarStyle: "hiddenInset",
    vibrancy: "sidebar",
    visualEffectState: "followWindow",
    webPreferences: { preload: path.join(__dirname, "preload.cjs"), contextIsolation: true, sandbox: true },
  });
  win.loadFile(RENDERER_PAGE);
  win.on("closed", () => (win = null));
  keepLinksOutside(win);
}

/** Links in summaries and answers open in the browser; nothing replaces the app's own page. */
function keepLinksOutside(w: BrowserWindow) {
  const external = (url: string) => /^https?:/i.test(url) && shell.openExternal(url);
  w.webContents.on("will-navigate", (event, url) => {
    event.preventDefault();
    external(url);
  });
  w.webContents.setWindowOpenHandler(({ url }) => {
    external(url);
    return { action: "deny" };
  });
}

/** Settings is its own window, like a Mac app's Settings. Changes apply as they're made. */
function openSettings() {
  if (settingsWin) return settingsWin.focus();
  settingsWin = new BrowserWindow({
    width: 620,
    height: 700,
    minWidth: 520,
    minHeight: 420,
    title: "Settings",
    titleBarStyle: "hiddenInset",
    minimizable: false,
    fullscreenable: false,
    webPreferences: { preload: path.join(__dirname, "preload.cjs"), contextIsolation: true, sandbox: true },
  });
  settingsWin.loadFile(RENDERER_PAGE, { hash: "settings" });
  settingsWin.on("closed", () => (settingsWin = null));
  keepLinksOutside(settingsWin);
}

function buildMenu() {
  Menu.setApplicationMenu(
    Menu.buildFromTemplate([
      {
        role: "appMenu",
        submenu: [
          { role: "about" },
          { type: "separator" },
          { label: "Settings…", accelerator: "CommandOrControl+,", click: openSettings },
          { type: "separator" },
          { role: "services" },
          { type: "separator" },
          { role: "hide" },
          { role: "hideOthers" },
          { role: "unhide" },
          { type: "separator" },
          { role: "quit" },
        ],
      },
      { role: "fileMenu" },
      { role: "editMenu" },
      { role: "viewMenu" },
      { role: "windowMenu" },
    ]),
  );
}

// Keep the sidebar in step with Finder.
let watcher: fs.FSWatcher | null = null;
function watchMeetings() {
  watcher?.close();
  const root = meetingsRoot();
  fs.mkdirSync(root, { recursive: true });
  let timer: NodeJS.Timeout | undefined;
  watcher = fs.watch(root, { recursive: true }, () => {
    clearTimeout(timer);
    timer = setTimeout(() => send("tree:changed"), 250);
  });
}

// The calendar is fetched at most once an hour (checked every 5 minutes, so a Mac that slept
// catches up), straight away when its address changes, and whenever the refresh button is pressed.
let calendarFetch: { url: string; promise: Promise<CalendarCache> } | null = null;
let calendarUrlFetched = "";
function refreshCalendar(force = false): Promise<CalendarCache> {
  const url = calendarUrl();
  if (!url) return Promise.resolve({ events: [] });
  // Joins a fetch already running for this address. One for an older address is left to finish
  // and its result thrown away below.
  if (calendarFetch?.url === url) return calendarFetch.promise;
  if (!force && url === calendarUrlFetched && !calendarIsStale(loadCalendar())) return Promise.resolve(loadCalendar());
  send("calendar:changed", { ...loadCalendar(), fetching: true });
  const fetch: { url: string; promise: Promise<CalendarCache> } = {
    url,
    promise: fetchCalendar(url).then((cache) => {
      if (calendarFetch !== fetch) return cache; // the address changed meanwhile
      calendarFetch = null;
      calendarUrlFetched = url;
      saveCalendar(cache);
      send("calendar:changed", cache);
      return cache;
    }),
  };
  calendarFetch = fetch;
  return fetch.promise;
}

/** A new (or no) calendar address: forget the old one's events and fetch the new one. */
function calendarChanged() {
  calendarFetch = null;
  calendarUrlFetched = "";
  fs.rmSync(CALENDAR_PATH, { force: true });
  if (calendarUrl()) refreshCalendar(true);
  else send("calendar:changed", null);
}

// Call reminders: 5 minutes before each call, a notification whose button opens the call and
// starts recording it. Clicking the notification itself opens New recording for the event.
const REMINDER_LEAD = 5 * 60 * 1000;
const reminded = new Set<string>();
/** Notifications are kept referenced, or their button and click events never arrive. */
const reminders = new Map<string, Notification>();
/** An event to open in New recording, collected by the window when it's ready. */
let pendingEvent: CalendarEvent | null = null;

/** The event's call link, if it's a real Meet, Zoom or Teams address (checked again: the cache may predate the check). */
const callLink = (event: CalendarEvent) => (event.meetUrl && callApp(event.meetUrl) ? event.meetUrl : undefined);
const clockTime = (iso: string) => new Date(iso).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

function checkReminders() {
  const config = loadConfig();
  if (!config.callReminders || !calendarUrl()) return;
  const now = Date.now();
  for (const event of loadCalendar().events) {
    const until = +new Date(event.start) - now;
    // In the five minutes before it starts (or the first minute after, if the Mac was asleep).
    if (event.allDay || reminded.has(event.id) || until > REMINDER_LEAD || until < -60_000) continue;
    reminded.add(event.id);
    remind(event);
  }
}

function remind(event: CalendarEvent) {
  if (!Notification.isSupported()) return;
  const minutes = Math.round((+new Date(event.start) - Date.now()) / 60_000);
  const link = callLink(event);
  const note = new Notification({
    title: event.title,
    body: [
      minutes > 0 ? `In ${minutes} min` : "Starting now",
      `${clockTime(event.start)}–${clockTime(event.end)}`,
      link && callApp(link),
    ]
      .filter(Boolean)
      .join(" · "),
    actions: [{ type: "button", text: link ? "Open call and start note taking" : "Start note taking" }],
    closeButtonText: "Dismiss",
  });
  note.on("action", () => startFromEvent(event));
  note.on("click", () => {
    pendingEvent = event;
    showWindow();
    send("event:open");
  });
  note.on("close", () => reminders.delete(event.id));
  note.on("failed", (_e, error) => console.error(`Reminder failed: ${event.title}: ${error}`));
  reminders.set(event.id, note);
  note.show();
}

function showWindow() {
  if (!win) createWindow();
  else {
    if (win.isMinimized()) win.restore();
    win.show();
  }
  app.focus({ steal: true });
}

/** Opens the call's link, starts recording it, and brings Oatcake forward on the live notes. */
function startFromEvent(event: CalendarEvent) {
  const link = callLink(event);
  if (link) shell.openExternal(link);
  // Already recording: go back to that recording rather than start a second.
  if (active.size === 0) {
    try {
      const folder = folderForEvent(meetingsRoot(), event.title, !!event.seriesId);
      const rec = startRecording(event.title, folder, recorderApp(), loadConfig().mic?.uid ?? null, { eventId: event.id });
      active.set(rec.id, rec);
    } catch (e) {
      dialog.showErrorBox("Couldn't start recording", (e as Error).message);
      return;
    }
  }
  // After the browser has opened the call, so Oatcake ends up in front for the notes.
  setTimeout(() => {
    showWindow();
    send("rec:started");
  }, 800);
}

/** Only Oatcake's own pages (the main window and Settings) may call into the main process. */
function fromOurPage(event: IpcMainInvokeEvent): boolean {
  const url = event.senderFrame?.url ?? "";
  return event.senderFrame?.parent === null && url.split("#")[0] === pathToFileURL(RENDERER_PAGE).href;
}

function handle(channel: string, fn: (...args: any[]) => unknown) {
  ipcMain.handle(channel, (event, ...args) => {
    if (!fromOurPage(event)) throw new Error(`Refused ${channel} from ${event.senderFrame?.url ?? "an unknown page"}`);
    return fn(...args);
  });
}

handle("config:get", () => loadConfig());
handle("settings:open", () => openSettings());
/** Settings › Test: asks the chosen model for a one-word reply. */
handle("llm:test", async () => {
  const started = Date.now();
  try {
    const reply = await Promise.race([
      createLlm(loadConfig().llm).complete("Reply with the single word OK and nothing else.", "Say OK."),
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("No reply after 60 seconds")), 60_000)),
    ]);
    const seconds = ((Date.now() - started) / 1000).toFixed(1);
    return { ok: true, detail: `Working: replied “${reply.trim().slice(0, 40)}” in ${seconds} s.` };
  } catch (e) {
    return { ok: false, detail: (e as Error).message.slice(0, 300) };
  }
});
// The window can save a secret, and learn whether one is saved, but never read one back.
handle("secret:get", (name: SecretName) => describeSecret(name));
handle("secret:set", (name: SecretName, value: string) => {
  const before = getSecret(name);
  setSecret(name, value);
  if (name === "calendar" && getSecret(name) !== before) calendarChanged();
});
handle("config:set", (config: Config) => {
  // The Meetings folder only changes through the folder picker below, never from the window.
  const saved: Config = { ...config, outputDir: loadConfig().outputDir };
  delete (saved as Partial<{ calendarUrl: string }>).calendarUrl;
  saveConfig(saved);
  for (const rec of active.values()) setRecordingMic(rec.dir, saved.mic?.uid ?? null);
  send("config:changed", saved);
});
handle("config:chooseFolder", async () => {
  const parent = BrowserWindow.getFocusedWindow() ?? win;
  const options: Electron.OpenDialogOptions = { properties: ["openDirectory", "createDirectory"] };
  const result = parent ? await dialog.showOpenDialog(parent, options) : await dialog.showOpenDialog(options);
  if (result.canceled || !result.filePaths[0]) return null;
  const config = { ...loadConfig(), outputDir: result.filePaths[0] };
  saveConfig(config);
  watchMeetings();
  send("config:changed", config);
  send("tree:changed");
  return config.outputDir;
});

handle("ask:start", (askId: string, rel: string, question: string, sessionId?: string) => {
  const config = loadConfig();
  const { result, cancel } = ask({
    root: meetingsRoot(),
    meeting: rel,
    question,
    sessionId,
    myName: config.myName,
    model: config.llm.provider === "claude-code" ? config.llm.claudeCode.model || undefined : undefined,
    onStep: (step) => send("ask:step", askId, step),
  });
  asking.set(askId, cancel);
  return result.finally(() => asking.delete(askId));
});
handle("ask:cancel", (askId: string) => asking.get(askId)?.());

handle("calendar:get", () => (calendarUrl() ? { ...loadCalendar(), fetching: !!calendarFetch } : null));
handle("calendar:refresh", () => refreshCalendar(true));
handle("event:take", () => {
  const event = pendingEvent;
  pendingEvent = null;
  return event;
});
/** Shows a reminder for the next timed event straight away, for checking notifications work. */
handle("reminder:test", () => {
  const next = loadCalendar().events.find((e) => !e.allDay && +new Date(e.end) > Date.now());
  if (next) remind(next);
  return next?.title ?? null;
});

handle("tree:get", () => listTree(meetingsRoot()));
handle("todos:all", () => listTodos(meetingsRoot()));
// The Dock icon's badge: recordings waiting for you under Needs review.
handle("badge:set", (count: number) => app.dock?.setBadge(count > 0 ? String(count) : ""));
handle("meeting:read", (rel: string) => readMeeting(meetingsRoot(), rel));
handle("meeting:write", (rel: string, file: string, content: string) => writeMeetingFile(meetingsRoot(), rel, file, content));
handle("item:rename", (rel: string, name: string) => renameItem(meetingsRoot(), rel, name));
handle("item:move", (rel: string, folder: string) => moveItem(meetingsRoot(), rel, folder));
handle("folder:create", (parent: string, name: string) => createFolder(meetingsRoot(), parent, name));
handle("item:trash", (rel: string) => shell.trashItem(resolveInside(meetingsRoot(), rel)));
handle("item:reveal", (rel: string) => shell.showItemInFolder(resolveInside(meetingsRoot(), rel)));
handle(
  "item:menu",
  (rel: string, kind: "folder" | "meeting") =>
    new Promise<ItemAction | null>((resolve) => {
      let chosen: ItemAction | null = null;
      const pick = (action: ItemAction) => () => (chosen = action);
      const items: Electron.MenuItemConstructorOptions[] = [
        ...(rel ? [{ label: "Rename…", click: pick("rename") }] : []),
        ...(kind === "folder" ? [{ label: "New Folder Inside…", click: pick("newFolder") }] : []),
        { label: "Show in Finder", click: pick("reveal") },
        ...(rel ? [{ type: "separator" as const }, { label: "Move to Trash", click: pick("trash") }] : []),
      ];
      Menu.buildFromTemplate(items).popup({ window: win!, callback: () => resolve(chosen) });
    }),
);

/** A native menu built by the window (the voice "⋯" menu); resolves with the chosen item's id. */
interface MenuItem {
  id?: string;
  label?: string;
  separator?: boolean;
  enabled?: boolean;
  submenu?: MenuItem[];
}
handle(
  "menu:popup",
  (items: MenuItem[]) =>
    new Promise<string | null>((resolve) => {
      let chosen: string | null = null;
      const build = (list: MenuItem[]): Electron.MenuItemConstructorOptions[] =>
        list.map((i) =>
          i.separator
            ? { type: "separator" as const }
            : {
                label: String(i.label ?? ""),
                enabled: i.enabled !== false,
                ...(i.submenu ? { submenu: build(i.submenu) } : { click: () => (chosen = i.id ?? null) }),
              },
        );
      const focused = BrowserWindow.getFocusedWindow() ?? win;
      if (!focused) return resolve(null);
      Menu.buildFromTemplate(build(items)).popup({ window: focused, callback: () => resolve(chosen) });
    }),
);

handle("mic:list", () => listInputs(recorderApp()));
handle("mic:set", (mic: Config["mic"]) => {
  const config = { ...loadConfig(), mic };
  saveConfig(config);
  for (const rec of active.values()) setRecordingMic(rec.dir, mic?.uid ?? null);
  send("config:changed", config);
});

handle("rec:start", (title: string, folder: string, options?: StartOptions) => {
  // One call at a time: a second recorder would capture the same audio, out of sight of the window.
  if (active.size > 0) throw new Error("Oatcake is already recording a call. Stop it first.");
  const rec = startRecording(title, folder, recorderApp(), loadConfig().mic?.uid ?? null, options);
  active.set(rec.id, rec);
  return rec;
});
handle("rec:active", () => [...active.values()]);
handle("rec:status", (id: string) => {
  const rec = active.get(id) ?? getRecording(id);
  return rec ? recorderStatus(rec) : { state: "error", error: "Recording not found" };
});
handle("rec:stop", async (id: string) => {
  const rec = active.get(id);
  if (!rec) return;
  try {
    stopRecording(rec);
    // The recorder writes meta.json as it exits.
    for (let i = 0; i < 50 && !fs.existsSync(path.join(rec.dir, "meta.json")); i++) {
      await new Promise((r) => setTimeout(r, 100));
    }
    // It had already stopped (crashed, or never got permission): keep whatever audio it captured.
    finishInterrupted(rec);
  } finally {
    active.delete(id);
  }
});
handle("rec:notes", (id: string, notes) => saveNotes(id, notes));
handle("rec:notes:get", (id: string) => loadNotes(id));
handle("rec:pending", () => listRecordings().filter((r) => r.state === "recorded" || r.state === "processed"));
handle("rec:analyse", (id: string) => {
  const rec = getRecording(id);
  if (!rec) throw new Error("Recording not found");
  if (analysing.has(id)) return; // already running; progress keeps arriving
  analysing.add(id);
  const worker = utilityProcess.fork(path.join(__dirname, "analyse-worker.cjs"), [rec.dir], {
    serviceName: "Meeting analysis",
    env: { ...process.env },
  });
  let reported = false;
  worker.on("message", (message) => {
    if (message?.error || message?.done) reported = true;
    send("analyse:progress", id, message);
  });
  worker.on("exit", (code) => {
    analysing.delete(id);
    if (reported) return; // its own done or error message says more than its exit code
    if (code === 0 && fs.existsSync(path.join(rec.dir, "analysis.json"))) send("analyse:progress", id, { done: true });
    else send("analyse:progress", id, { error: `Analysis stopped (code ${code})` });
  });
});
handle("rec:analysis", (id: string) => {
  const rec = getRecording(id);
  if (!rec) throw new Error("Recording not found");
  return {
    analysis: JSON.parse(fs.readFileSync(path.join(rec.dir, "analysis.json"), "utf8")),
    people: knownPeople(),
    notes: loadNotes(id),
    myName: loadConfig().myName,
    folder: rec.folder,
    title: rec.title,
  };
});
handle("rec:clip", (file: string) => {
  const full = resolveInside(RECORDINGS_DIR, path.relative(RECORDINGS_DIR, file));
  return `data:audio/wav;base64,${fs.readFileSync(full).toString("base64")}`;
});
handle("rec:save", (id: string, decisions, folder: string) => {
  const rec = getRecording(id);
  if (!rec) throw new Error("Recording not found");
  return saveMeeting(loadConfig(), rec, decisions, folder, (step) => send("save:progress", id, step));
});
handle("rec:discard", (id: string) => {
  if (active.has(id)) throw new Error("Stop the recording before discarding it.");
  if (!getRecording(id)) throw new Error("Recording not found");
  discardRecording(id);
});

/** Recordings left from an earlier run: a recorder still going is picked up again; a dead one is finished off. */
function resumeRecordings() {
  for (const rec of listRecordings()) {
    if (rec.state !== "recording") continue;
    if (recorderRunning(rec)) active.set(rec.id, rec);
    else finishInterrupted(rec);
  }
}

/** The calendar address used to sit in config.json in plain text; it now lives with the encrypted keys. */
function moveCalendarUrlToSecrets() {
  const config = loadConfig() as Config & { calendarUrl?: string };
  if (config.calendarUrl === undefined) return;
  if (config.calendarUrl.trim() && !getSecret("calendar")) setSecret("calendar", config.calendarUrl);
  delete config.calendarUrl;
  saveConfig(config);
}

app.whenReady().then(() => {
  // Nothing in Oatcake's pages needs the camera, microphone, location or the like: the recorder
  // captures audio itself, as its own app.
  session.defaultSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  session.defaultSession.setPermissionCheckHandler(() => false);
  applySecrets();
  moveCalendarUrlToSecrets();
  resumeRecordings();
  buildMenu();
  watchMeetings();
  createWindow();
  // An address set in an earlier session counts as already fetched, so this only fetches if stale.
  calendarUrlFetched = calendarUrl();
  refreshCalendar();
  setInterval(() => refreshCalendar(), 5 * 60 * 1000);
  checkReminders();
  setInterval(checkReminders, 30 * 1000);
  app.on("activate", () => !win && createWindow());
});

// Never leave the recorder running behind a closed app.
app.on("before-quit", () => {
  for (const rec of active.values()) stopRecording(rec);
});
app.on("window-all-closed", () => {
  if (active.size === 0) app.quit();
});
