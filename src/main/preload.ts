import { contextBridge, ipcRenderer } from "electron";
import type { Api } from "../shared/api.ts";

const invoke =
  (channel: string) =>
  (...args: unknown[]) =>
    ipcRenderer.invoke(channel, ...args);

function on(channel: string, callback: (...args: any[]) => void) {
  const listener = (_event: unknown, ...args: any[]) => callback(...args);
  ipcRenderer.on(channel, listener);
  return () => void ipcRenderer.off(channel, listener);
}

const api: Api = {
  getConfig: invoke("config:get"),
  setConfig: invoke("config:set"),
  onConfigChanged: (callback) => on("config:changed", callback),
  openSettings: invoke("settings:open"),
  testLlm: invoke("llm:test"),
  getSecret: invoke("secret:get"),
  setSecret: invoke("secret:set"),
  chooseFolder: invoke("config:chooseFolder"),
  listInputs: invoke("mic:list"),
  setMic: invoke("mic:set"),
  getCalendar: invoke("calendar:get"),
  refreshCalendar: invoke("calendar:refresh"),
  onCalendarChanged: (callback) => on("calendar:changed", callback),
  takePendingEvent: invoke("event:take"),
  onEventOpen: (callback) => on("event:open", callback),
  onRecordingStarted: (callback) => on("rec:started", callback),
  testReminder: invoke("reminder:test"),
  getTree: invoke("tree:get"),
  allTodos: invoke("todos:all"),
  setBadge: invoke("badge:set"),
  readMeeting: invoke("meeting:read"),
  writeMeetingFile: invoke("meeting:write"),
  renameItem: invoke("item:rename"),
  moveItem: invoke("item:move"),
  createFolder: invoke("folder:create"),
  trashItem: invoke("item:trash"),
  revealItem: invoke("item:reveal"),
  itemMenu: invoke("item:menu"),
  popupMenu: invoke("menu:popup"),
  onTreeChanged: (callback) => on("tree:changed", callback),
  ask: invoke("ask:start"),
  cancelAsk: invoke("ask:cancel"),
  onAskStep: (callback) => on("ask:step", callback),
  startRecording: invoke("rec:start"),
  activeRecordings: invoke("rec:active"),
  recorderStatus: invoke("rec:status"),
  stopRecording: invoke("rec:stop"),
  saveNotes: invoke("rec:notes"),
  getNotes: invoke("rec:notes:get"),
  pendingRecordings: invoke("rec:pending"),
  analyse: invoke("rec:analyse"),
  onAnalyseProgress: (callback) => on("analyse:progress", callback),
  getAnalysis: invoke("rec:analysis"),
  clip: invoke("rec:clip"),
  saveRecording: invoke("rec:save"),
  onSaveProgress: (callback) => on("save:progress", callback),
  discardRecording: invoke("rec:discard"),
} as Api;

contextBridge.exposeInMainWorld("api", api);
