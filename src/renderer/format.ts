// Dates, times and people, formatted the way the design shows them.

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
export const ordinal = (d: number) =>
  d + (d % 100 >= 11 && d % 100 <= 13 ? "th" : ({ 1: "st", 2: "nd", 3: "rd" } as Record<number, string>)[d % 10] ?? "th");

/** "October 29th, 2026" */
export const longDate = (d: Date) => `${MONTHS[d.getMonth()]} ${ordinal(d.getDate())}, ${d.getFullYear()}`;
/** "October 29th" */
export const shortDate = (d: Date) => `${MONTHS[d.getMonth()]} ${ordinal(d.getDate())}`;
export const weekday = (d: Date) => WEEKDAYS[d.getDay()];
/** "16:30" */
export const hhmm = (d: Date) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

/** "32 min", or "under a minute". */
export const minutes = (seconds: number) => (seconds < 60 ? "under a minute" : `${Math.round(seconds / 60)} min`);

/** "03:09", or "1:02:09" past an hour. */
export function clock(seconds = 0): string {
  const s = Math.max(0, Math.floor(seconds));
  const mm = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
  const ss = String(s % 60).padStart(2, "0");
  return s >= 3600 ? `${Math.floor(s / 3600)}:${mm}:${ss}` : `${mm}:${ss}`;
}

/** "12:34" or "1:02:03" → seconds. */
export function seconds(stamp: string): number {
  const p = stamp.split(":").map(Number);
  return p.length === 3 ? p[0] * 3600 + p[1] * 60 + p[2] : p[0] * 60 + p[1];
}

/** "Sam & Alex 1:1" and a folder called "Sam & Alex 1-1" are the same name. */
export const loose = (name: string) => name.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");

const HUES = [265, 25, 160, 330, 200, 60, 295, 130, 230, 0, 95, 180];
const GREY = "light-dark(#8e8e93,#636366)";
/** Labels that aren't a person: their avatars are grey. */
const NOT_A_PERSON = /^(Voice \d+|Several people|Microphone|System audio|Call audio|Unknown)$/;

// Each person keeps one colour everywhere and for good: the first time a name is seen it takes the
// palette's least-used hue (in the order above, which spreads early picks around the wheel), and
// that choice is remembered. Keyed by first name, so "Alex" and "Alex Kim" match.
const COLORS_KEY = "personColors";
let remembered: Record<string, number> | null = null;
const colorKey = (name: string) => name.trim().split(/\s+/)[0].toLowerCase();

function hueFor(name: string, remember: boolean): number {
  remembered ??= (() => {
    try {
      return JSON.parse(localStorage.getItem(COLORS_KEY) ?? "{}");
    } catch {
      return {};
    }
  })();
  const all = remembered!;
  const key = colorKey(name);
  if (key in all) return HUES[all[key]];
  const uses = HUES.map((_, i) => Object.values(all).filter((v) => v === i).length);
  const index = uses.indexOf(Math.min(...uses));
  // A name typed but not yet saved (in review) gets a colour without claiming one.
  if (!remember) return HUES[index];
  all[key] = index;
  localStorage.setItem(COLORS_KEY, JSON.stringify(all));
  return HUES[index];
}

/** A person's avatar colour and initial: the same colour on every screen. */
export function person(name: string, remember = true): { name: string; initial: string; color: string } {
  const clean = name.replace(/^Voice /, "");
  const initial = (clean.match(/[\p{L}\p{N}]/u)?.[0] ?? "?").toUpperCase();
  if (!name.trim() || NOT_A_PERSON.test(name)) {
    return { name, initial: /^Voice/.test(name) ? clean.slice(0, 1) : initial, color: GREY };
  }
  return { name, initial, color: `oklch(0.55 0.15 ${hueFor(name, remember)})` };
}

/** Is this owner you? "Sam" counts for "Sam Lee". */
export const isMe = (owner: string | undefined, myName: string) =>
  !!owner && !!myName && [myName.toLowerCase(), myName.split(" ")[0].toLowerCase()].includes(owner.trim().toLowerCase());
/** An owner as shown: "You" for you. */
export const ownerLabel = (owner: string | undefined, myName: string) => (isMe(owner, myName) ? "You" : (owner ?? ""));

/** The meeting's folder path for display: "Team 51 › Leads sync". "" is the top level. */
export const folderPath = (rel: string) => (rel ? rel.split("/").join(" › ") : "Meetings");
export const baseName = (rel: string) => rel.split("/").pop() ?? rel;
export const parentOf = (rel: string) => rel.split("/").slice(0, -1).join("/");

/** The folder's name (or whole path) says the same as the title, e.g. "Team 51/Leads sync" for "Team 51 – Leads sync". */
export const sameAsFolder = (title: string, folder: string) =>
  !!folder && !!loose(title) && (loose(title) === loose(baseName(folder)) || loose(title) === loose(folder));
/** The path above a title, without its last part when that only repeats the title. */
export const pathAbove = (folder: string, title: string) => folderPath(sameAsFolder(title, folder) ? parentOf(folder) : folder);

export const cleanError = (e: unknown) => String((e as Error)?.message ?? e).replace(/^Error invoking remote method '[^']+': (Error: )?/, "");
