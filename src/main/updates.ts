// Checking for and installing new releases; the mechanics are in core/update.ts. A check runs 20
// seconds after launch and then once a day (unless turned off in Settings), and from Settings'
// Check Now. Installing never starts while a call is being recorded, analysed or saved.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { app } from "electron";
import {
  compareVersions,
  designatedRequirement,
  downloadZip,
  FEED_URL,
  fetchManifest,
  INSTALL_COMMAND,
  isAdHoc,
  satisfies,
  stage,
  swapAfterExit,
  unpack,
  type Manifest,
} from "../core/update.ts";
import type { UpdateState } from "../shared/api.ts";

const DAY = 24 * 60 * 60 * 1000;

interface Options {
  send(state: UpdateState): void;
  /** Why installing has to wait (a call being recorded, analysed or saved), if it does. */
  busy(): string | undefined;
  /** Settings › Check for updates automatically. */
  autoCheck(): boolean;
}

export function createUpdater(options: Options) {
  // OATCAKE_UPDATE_FEED points at another latest.json, for trying a release before it's published.
  const feed = process.env.OATCAKE_UPDATE_FEED || FEED_URL;
  let state: UpdateState = { current: app.getVersion(), checking: false };
  let manifest: Manifest | null = null;
  let lastCheck = 0;
  let requirement: Promise<string> | undefined;

  const set = (patch: Partial<UpdateState>) => {
    state = { ...state, ...patch };
    options.send(state);
  };
  /** The running bundle: …/Oatcake.app/Contents/MacOS/Oatcake → …/Oatcake.app. */
  const bundle = () => path.resolve(process.execPath, "..", "..", "..");
  const ownRequirement = () => (requirement ??= designatedRequirement(bundle()));

  /** Why this copy can't replace itself with the release, if it can't, and whether the install command would. */
  async function blocked(m: Manifest): Promise<{ blocked?: string; command?: string }> {
    if (compareVersions(process.getSystemVersion(), m.minimumSystemVersion) < 0) {
      return { blocked: `Oatcake ${m.version} needs macOS ${m.minimumSystemVersion} or later.` };
    }
    if (!app.isPackaged) return { blocked: "This is a development copy of Oatcake: update it with git." };
    const where = bundle();
    if (where.includes("/AppTranslocation/")) {
      return { blocked: "Move Oatcake to your Applications folder and open it from there; then it can update itself." };
    }
    try {
      fs.accessSync(path.dirname(where), fs.constants.W_OK);
    } catch {
      return { blocked: `Oatcake can't replace itself in ${path.dirname(where)}. Install the update from Terminal instead:`, command: INSTALL_COMMAND };
    }
    try {
      if (isAdHoc(await ownRequirement())) {
        return { blocked: "This copy of Oatcake wasn't signed for updates. Install the update from Terminal instead:", command: INSTALL_COMMAND };
      }
    } catch (e) {
      return { blocked: (e as Error).message };
    }
    return {};
  }

  async function check(): Promise<UpdateState> {
    if (state.checking || state.installing) return state;
    set({ checking: true, error: undefined });
    try {
      const m = await fetchManifest(feed);
      lastCheck = Date.now();
      const checkedAt = new Date().toISOString();
      if (compareVersions(m.version, state.current) > 0) {
        manifest = m;
        const { blocked: reason, command } = await blocked(m);
        set({ checking: false, checkedAt, available: { version: m.version, notes: m.notes, size: m.zip.size }, blocked: reason, command });
      } else {
        manifest = null;
        set({ checking: false, checkedAt, available: undefined, blocked: undefined, command: undefined });
      }
    } catch (e) {
      set({ checking: false, error: (e as Error).message });
    }
    return state;
  }

  async function install(): Promise<void> {
    if (!manifest || state.installing || state.blocked) return;
    const busy = options.busy();
    if (busy) return set({ error: busy });
    const m = manifest;
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "oatcake-update-"));
    try {
      set({ installing: "Downloading…", error: undefined });
      let shown = -1;
      const zip = await downloadZip(m, tmp, (fraction) => {
        const percent = Math.floor(fraction * 100);
        if (percent !== shown) set({ installing: `Downloading… ${(shown = percent)}%` });
      });
      set({ installing: "Checking…" });
      const newApp = await unpack(zip, tmp, m);
      const req = await ownRequirement();
      if (!(await satisfies(newApp, req))) {
        throw new Error("The update isn't signed with the same certificate as this copy of Oatcake, so it wasn't installed.");
      }
      set({ installing: "Installing…" });
      const staged = await stage(newApp, bundle(), req);
      // A call may have started during the download.
      const busyNow = options.busy();
      if (busyNow) {
        fs.rmSync(staged, { recursive: true, force: true });
        throw new Error(busyNow);
      }
      swapAfterExit(bundle(), staged);
      set({ installing: "Relaunching…" });
      app.quit();
    } catch (e) {
      set({ installing: undefined, error: (e as Error).message });
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  }

  function start() {
    // Development copies check only when asked, unless pointed at a test feed.
    if (!app.isPackaged && feed === FEED_URL) return;
    const tick = () => options.autoCheck() && Date.now() - lastCheck > DAY && check();
    setTimeout(tick, 20_000);
    setInterval(tick, 60 * 60 * 1000);
  }

  return { state: () => state, check, install, start };
}
