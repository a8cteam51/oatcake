// Shared by the main process (calendar parsing, reminders) and the window (labels).

/** Video-call services, by the exact host (or parent domain) their links use. */
const CALL_HOSTS: { name: string; host: RegExp }[] = [
  { name: "Google Meet", host: /^meet\.google\.com$/ },
  { name: "Zoom", host: /^(?:[a-z0-9-]+\.)*zoom\.us$/ },
  { name: "Microsoft Teams", host: /^teams\.microsoft\.com$/ },
];

/** "Google Meet", "Zoom" or "Microsoft Teams" for a call link; null for anything else. */
export function callApp(url: string): string | null {
  try {
    const { protocol, hostname } = new URL(url);
    if (protocol !== "https:") return null;
    return CALL_HOSTS.find((c) => c.host.test(hostname.toLowerCase()))?.name ?? null;
  } catch {
    return null;
  }
}
