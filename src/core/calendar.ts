import fs from "node:fs";
import path from "node:path";
import ICAL from "ical.js";
import { DATA_DIR } from "./config.ts";
import { writeAtomic } from "./files.ts";
import { callApp } from "../shared/calls.ts";

export interface CalendarEvent {
  /** Unique per occurrence. */
  id: string;
  /** Shared by every occurrence of a recurring event. */
  seriesId?: string;
  title: string;
  start: string;
  end: string;
  allDay: boolean;
  attendees: { name?: string; email: string }[];
  meetUrl?: string;
}

export interface CalendarCache {
  /** Last fetch attempt, successful or not. */
  checkedAt?: string;
  /** Last successful fetch. */
  updatedAt?: string;
  error?: string;
  events: CalendarEvent[];
}

export const CALENDAR_PATH = path.join(DATA_DIR, "calendar.json");
/** How long a fetch stays fresh. The refresh button fetches regardless. */
export const CALENDAR_MAX_AGE = 60 * 60 * 1000;
const DAY = 24 * 60 * 60 * 1000;

export function loadCalendar(): CalendarCache {
  try {
    return JSON.parse(fs.readFileSync(CALENDAR_PATH, "utf8"));
  } catch {
    return { events: [] };
  }
}

export function saveCalendar(cache: CalendarCache) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  writeAtomic(CALENDAR_PATH, JSON.stringify(cache, null, 2));
}

export const calendarIsStale = (cache: CalendarCache, now = Date.now()) =>
  !cache.checkedAt || now - Date.parse(cache.checkedAt) >= CALENDAR_MAX_AGE;

/**
 * Downloads the calendar's private iCal address and keeps the events from a day ago to two weeks
 * ahead. A failed fetch keeps the previous events and records the error. The address is a secret,
 * so it never appears in errors. The caller saves the result (unless the address changed meanwhile).
 */
export async function fetchCalendar(url: string): Promise<CalendarCache> {
  const previous = loadCalendar();
  const checkedAt = new Date().toISOString();
  let cache: CalendarCache;
  try {
    const response = await fetch(url.trim().replace(/^webcal:/i, "https:"), { signal: AbortSignal.timeout(30_000) });
    if (!response.ok) throw new Error(`the calendar address returned ${response.status} ${response.statusText}`.trim());
    const now = Date.now();
    const events = parseCalendar(await response.text(), new Date(now - DAY), new Date(now + 14 * DAY));
    cache = { checkedAt, updatedAt: checkedAt, events };
  } catch (e) {
    const message = (e as Error).name === "TimeoutError" ? "the calendar took too long to answer" : (e as Error).message;
    cache = { ...previous, checkedAt, error: `Couldn't update the calendar: ${message}` };
  }
  return cache;
}

/**
 * The first video-call link in an event's text. Hosts are checked whole, so a look-alike such as
 * "meet.google.com.example.net" or "evilzoom.us" is never offered as the call.
 */
export function findCallLink(text: string): string | undefined {
  for (const [candidate] of text.matchAll(/https:\/\/[^\s<>"']+/gi)) {
    const url = candidate.replace(/[),.;\]]+$/, "");
    if (callApp(url)) return url;
  }
}

/** Expands an iCalendar feed into the occurrences that overlap [from, to). */
export function parseCalendar(text: string, from: Date, to: Date): CalendarEvent[] {
  const root = new ICAL.Component(ICAL.parse(text));
  for (const zone of root.getAllSubcomponents("vtimezone")) ICAL.TimezoneService.register(zone);
  // A Google calendar named after its owner's address: used to drop events they declined.
  const owner = String(root.getFirstPropertyValue("x-wr-calname") ?? "").toLowerCase();

  const masters = new Map<string, ICAL.Event>();
  // Moved, edited or cancelled occurrences of a recurring event come as separate entries with the
  // same UID, keyed here by the instant they replace (matching by instant works whatever time zone
  // either entry is written in).
  const replaced = new Map<string, Map<number, ICAL.Component>>();
  const orphans: ICAL.Component[] = [];
  for (const component of root.getAllSubcomponents("vevent")) {
    const uid = String(component.getFirstPropertyValue("uid"));
    const recurrenceId = component.getFirstPropertyValue("recurrence-id") as ICAL.Time | null;
    if (!recurrenceId) masters.set(uid, new ICAL.Event(component));
    else {
      if (!replaced.has(uid)) replaced.set(uid, new Map());
      replaced.get(uid)!.set(recurrenceId.toJSDate().getTime(), component);
    }
  }
  for (const [uid, byInstant] of replaced) if (!masters.has(uid)) orphans.push(...byInstant.values());

  const events: CalendarEvent[] = [];
  const add = (event: ICAL.Event, start: ICAL.Time, end: ICAL.Time, seriesId?: string) => {
    const startDate = start.toJSDate();
    const endDate = end.toJSDate();
    if (endDate <= from || startDate >= to) return;
    const component = event.component;
    if (String(component.getFirstPropertyValue("status") ?? "").toUpperCase() === "CANCELLED") return;
    const attendees = event.attendees.map((p) => ({
      email: String(p.getFirstValue()).replace(/^mailto:/i, "").toLowerCase(),
      name: (p.getParameter("cn") as string | undefined) || undefined,
      declined: String(p.getParameter("partstat") ?? "").toUpperCase() === "DECLINED",
    }));
    if (owner && attendees.some((a) => a.email === owner && a.declined)) return;
    // Google's own conference field first, then wherever else a link was pasted.
    const links = [component.getFirstPropertyValue("x-google-conference"), event.location, event.description]
      .map((v) => (v ? String(v) : ""))
      .join(" ");
    events.push({
      id: `${event.uid}@${startDate.toISOString()}`,
      seriesId,
      title: event.summary || "Untitled event",
      start: startDate.toISOString(),
      end: endDate.toISOString(),
      allDay: start.isDate,
      attendees: attendees.map(({ email, name }) => ({ email, ...(name && name !== email ? { name } : {}) })),
      meetUrl: findCallLink(links),
    });
  };

  for (const event of masters.values()) {
    if (!event.isRecurring()) {
      add(event, event.startDate, event.endDate);
      continue;
    }
    const changes = replaced.get(event.uid);
    const occurrences = event.iterator();
    // Weekly meetings that began years ago are a few hundred steps; the cap guards against odd rules.
    for (let i = 0, next = occurrences.next(); next && i < 20_000; i++, next = occurrences.next()) {
      const original = next.toJSDate();
      if (original >= to) break;
      const change = changes?.get(original.getTime());
      if (change) {
        const changed = new ICAL.Event(change);
        add(changed, changed.startDate, changed.endDate, event.uid);
        continue;
      }
      const end = next.clone();
      end.addDuration(event.duration);
      add(event, next, end, event.uid);
    }
  }
  for (const orphan of orphans) {
    const event = new ICAL.Event(orphan);
    add(event, event.startDate, event.endDate);
  }
  return events.sort((a, b) => a.start.localeCompare(b.start));
}
