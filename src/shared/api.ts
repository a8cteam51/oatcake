// The bridge between the window and the main process (exposed as window.api by preload.ts).
import type { Config } from "../core/config.ts";
import type { TreeNode } from "../core/meetings.ts";
import type { CalendarCache, CalendarEvent } from "../core/calendar.ts";
import type { Analysis, Progress } from "../core/process.ts";
import type { InputDevice, Note, Recording, RecorderStatus, StartOptions } from "../core/recordings.ts";
import type { Decision } from "../core/save.ts";

export type Calendar = CalendarCache & { fetching?: boolean };
export type { Analysis, CalendarEvent, Config, Decision, InputDevice, Note, Progress, Recording, RecorderStatus, TreeNode };

export type ItemAction = "rename" | "newFolder" | "reveal" | "trash";
export type SecretName = "anthropic" | "openai" | "calendar";
export interface MenuItem {
  id?: string;
  label?: string;
  separator?: boolean;
  enabled?: boolean;
  submenu?: MenuItem[];
}

export interface MeetingMeta {
  title?: string;
  startedAt?: string;
  endedAt?: string;
  participants?: string[];
  source?: string;
}

export interface Api {
  getConfig(): Promise<Config>;
  setConfig(config: Config): Promise<void>;
  onConfigChanged(callback: (config: Config) => void): () => void;
  openSettings(): Promise<void>;
  /** Checks the chosen summary model replies. */
  testLlm(): Promise<{ ok: boolean; detail: string }>;
  /** Whether an API key or the calendar address is saved (encrypted), and a hint to recognise it. Never the value. */
  getSecret(name: SecretName): Promise<{ saved: boolean; hint: string }>;
  /** Saves (or, with "", removes) a secret. */
  setSecret(name: SecretName, value: string): Promise<void>;
  /** Picks and saves the Meetings folder; null if cancelled. */
  chooseFolder(): Promise<string | null>;
  listInputs(): Promise<InputDevice[]>;
  /** Saves the microphone choice and switches any running recording to it. */
  setMic(mic: Config["mic"]): Promise<void>;

  /** The cached calendar, or null when no calendar address is set. */
  getCalendar(): Promise<Calendar | null>;
  /** Fetches the calendar now. */
  refreshCalendar(): Promise<Calendar>;
  onCalendarChanged(callback: (calendar: Calendar) => void): () => void;
  /** A calendar event to open in New recording (from a clicked reminder), once. */
  takePendingEvent(): Promise<CalendarEvent | null>;
  onEventOpen(callback: () => void): () => void;
  /** A recording was started outside the window (a reminder's button). */
  onRecordingStarted(callback: () => void): () => void;
  testReminder(): Promise<string | null>;

  getTree(): Promise<TreeNode>;
  /** Every meeting's todo.md, for the combined To-dos page. */
  allTodos(): Promise<{ path: string; title: string; startedAt?: string; todo: string }[]>;
  setBadge(count: number): Promise<void>;
  readMeeting(rel: string): Promise<{ summary: string; transcript: string; notes: string; todo: string; meta: MeetingMeta }>;
  /** file is summary.md, transcript.md, notes.md or todo.md. */
  writeMeetingFile(rel: string, file: string, content: string): Promise<void>;
  renameItem(rel: string, name: string): Promise<string>;
  moveItem(rel: string, folderRel: string): Promise<string>;
  createFolder(parentRel: string, name: string): Promise<string>;
  trashItem(rel: string): Promise<void>;
  revealItem(rel: string): Promise<void>;
  itemMenu(rel: string, kind: TreeNode["kind"]): Promise<ItemAction | null>;
  /** Shows a native menu; resolves with the chosen item's id, or null. */
  popupMenu(items: MenuItem[]): Promise<string | null>;
  onTreeChanged(callback: () => void): () => void;

  /** Asks Claude Code about the meetings, starting from rel. Pass sessionId to continue a conversation. */
  ask(askId: string, rel: string, question: string, sessionId?: string): Promise<{ answer: string; sessionId: string }>;
  cancelAsk(askId: string): Promise<void>;
  /** A short description of each file Claude reads or search it runs while answering. */
  onAskStep(callback: (askId: string, step: string) => void): () => void;

  startRecording(title: string, folder: string, options?: StartOptions): Promise<Recording>;
  /** Recordings still running (e.g. after the window was closed and reopened). */
  activeRecordings(): Promise<Recording[]>;
  recorderStatus(id: string): Promise<RecorderStatus>;
  stopRecording(id: string): Promise<void>;
  saveNotes(id: string, notes: Note[]): Promise<void>;
  getNotes(id: string): Promise<Note[]>;
  pendingRecordings(): Promise<Recording[]>;
  analyse(id: string): Promise<void>;
  onAnalyseProgress(callback: (id: string, progress: Progress & { done?: boolean; error?: string }) => void): () => void;
  getAnalysis(id: string): Promise<{ analysis: Analysis; people: string[]; notes: Note[]; myName: string; folder?: string; title: string }>;
  clip(file: string): Promise<string>;
  saveRecording(id: string, decisions: Record<string, Decision>, folder: string): Promise<string>;
  onSaveProgress(callback: (id: string, step: string) => void): () => void;
  discardRecording(id: string): Promise<void>;
}
