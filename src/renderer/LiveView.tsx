import { useEffect, useReducer, useRef, useState } from "react";
import { api, type Config, type InputDevice, type Recording, type RecorderStatus } from "./api.ts";
import { clock, pathAbove } from "./format.ts";
import { CheckIcon, ChevronDownIcon, MicIcon, StopIcon, WarningIcon } from "./icons.tsx";
import { choose, micChoices } from "./MicSelect.tsx";
import { RecDot, Spinner } from "./ui.tsx";

interface Line {
  id: number;
  /** Seconds in when typing started; null until then, and always for prep notes. */
  at: number | null;
  prep: boolean;
  text: string;
}

// Notes live outside the component, so leaving the live view (to read another meeting) and
// coming back keeps them. They're also saved to the recording as you type.
const store = new Map<string, Line[]>();
let nextId = 1;
const blank = (): Line => ({ id: nextId++, at: null, prep: false, text: "" });

export async function saveLiveNotes(id: string) {
  const lines = store.get(id);
  if (!lines) return;
  await api.saveNotes(
    id,
    lines.filter((l) => l.text.trim()).map((l) => ({ at: l.prep ? null : l.at ?? 0, text: l.text.trim() })),
  );
}

/** 14 segments on a rough log scale (speech peaks sit around 0.05–0.5); the last two are "hot". */
function Meter({ label, level = 0 }: { label: string; level?: number }) {
  const fraction = level > 0 ? Math.min(1, Math.max(0, (100 + 25 * Math.log10(level)) / 100)) : 0;
  const lit = Math.round(fraction * 14);
  return (
    <div className="meter">
      <span>{label}</span>
      <div className="segments">
        {Array.from({ length: 14 }, (_, i) => (
          <i key={i} className={i < lit ? (i >= 12 ? "hot" : "on") : ""} />
        ))}
      </div>
    </div>
  );
}

export function LiveView(props: {
  rec: Recording;
  status: RecorderStatus;
  config: Config;
  onStop(): void;
  /** Before any audio has arrived: throw the recording away. Says whether notes were typed. */
  onCancel(hasNotes: boolean): void;
}) {
  const { rec, status, config } = props;
  const [, rerender] = useReducer((n: number) => n + 1, 0);
  const inputs = useRef(new Map<number, HTMLInputElement>());
  const [micOpen, setMicOpen] = useState(false);
  const [devices, setDevices] = useState<InputDevice[] | null>(null);
  const silentSince = useRef<{ mic: number | null; call: number | null }>({ mic: null, call: null });
  const elapsed = status.elapsed ?? 0;

  // Load what's saved (prep notes, or notes from before the window reopened), then a blank line.
  useEffect(() => {
    if (store.has(rec.id)) return;
    store.set(rec.id, [blank()]);
    api.getNotes(rec.id).then((notes) => {
      store.set(rec.id, [...notes.map((n) => ({ id: nextId++, at: n.at, prep: n.at === null, text: n.text })), blank()]);
      rerender();
      focus(store.get(rec.id)!.at(-1)!.id);
    });
  }, [rec.id]);

  const lines = store.get(rec.id) ?? [];
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const update = (next: Line[], focusId?: number) => {
    store.set(rec.id, next);
    rerender();
    if (focusId) requestAnimationFrame(() => focus(focusId));
    clearTimeout(timer.current);
    timer.current = setTimeout(() => saveLiveNotes(rec.id), 600);
  };
  const focus = (id: number) => {
    const el = inputs.current.get(id);
    if (!el) return;
    el.focus();
    el.setSelectionRange(el.value.length, el.value.length);
  };
  // (A cancelled recording is already gone by then, so a failed save is fine.)
  useEffect(() => () => void saveLiveNotes(rec.id).catch(() => {}), [rec.id]);

  // Before audio arrives the clock hasn't started, so a line begun then is stamped 00:00: it's a
  // note from the call, not prep. Only notes written on New recording are prep.
  const started = status.state === "recording";
  const onChange = (line: Line, text: string) =>
    update(
      lines.map((l) => {
        if (l.id !== line.id) return l;
        return { ...l, text, at: l.prep || !text ? null : (l.at ?? (started ? Math.floor(elapsed) : 0)) };
      }),
    );
  const onKey = (line: Line, e: React.KeyboardEvent<HTMLInputElement>) => {
    const i = lines.indexOf(line);
    if (e.key === "Enter") {
      e.preventDefault();
      if (!line.text.trim()) return;
      const next = lines[i + 1];
      if (next && !next.text) return focus(next.id);
      const added = blank();
      update([...lines.slice(0, i + 1), added, ...lines.slice(i + 1)], added.id);
    } else if (e.key === "Backspace" && !line.text && lines.length > 1) {
      e.preventDefault();
      update(lines.filter((l) => l.id !== line.id), (lines[i - 1] ?? lines[i + 1]).id);
    } else if (e.key === "ArrowUp" && i > 0) {
      e.preventDefault();
      focus(lines[i - 1].id);
    } else if (e.key === "ArrowDown" && i < lines.length - 1) {
      e.preventDefault();
      focus(lines[i + 1].id);
    }
  };

  // Silence: a working mic always picks up some room noise; true silence means nothing arrives.
  const now = Date.now();
  if (status.state === "recording") {
    const micQuiet = !!status.micDevice && (status.micLevel ?? 0) < 0.001;
    const callQuiet = (status.systemLevel ?? 0) < 0.001;
    silentSince.current.mic = micQuiet ? (silentSince.current.mic ?? now) : null;
    silentSince.current.call = callQuiet ? (silentSince.current.call ?? now) : null;
  }
  const micSilentFor = silentSince.current.mic ? Math.floor((now - silentSince.current.mic) / 1000) : 0;
  const callSilentFor = silentSince.current.call ? Math.floor((now - silentSince.current.call) / 1000) : 0;

  const device = status.micDevice;
  const mic = config.mic;
  const micStatus =
    status.state !== "recording"
      ? { text: status.state === "error" ? "Recording stopped." : "Starting…", tone: "" }
      : !device
        ? { text: "No microphone found. Connect one to record your side of the call.", tone: "red" }
        : mic && device.uid !== mic.uid
          ? { text: `${mic.name} isn’t connected, so this is recording from ${device.name}.`, tone: "amber" }
          : { text: `Recording from ${device.name}.`, tone: "" };

  const openMic = () => {
    setMicOpen(true);
    setDevices(null);
    api.listInputs().then(setDevices, () => setDevices([]));
  };

  return (
    <>
      <div className="live-head">
        {started ? (
          <>
            <RecDot />
            <span className="live-red">Recording</span>
            <span className="live-red">{clock(elapsed)}</span>
          </>
        ) : (
          <>
            <span className="grey-dot" />
            <span className="live-grey">{status.state === "error" ? "Recording stopped" : "Starting…"}</span>
          </>
        )}
        <div className="spacer" />
        {/* Nothing has been recorded until audio arrives, so until then it's Cancel, not Stop. */}
        {status.state === "starting" ? (
          <button className="btn" title="Cancel this recording" onClick={() => props.onCancel(lines.some((l) => l.text.trim()))}>
            Cancel
          </button>
        ) : (
          <button className="btn red" title="Stop recording" onClick={props.onStop}>
            <StopIcon size={10} />
            Stop
          </button>
        )}
      </div>
      <div className="scroll live-scroll">
        <div className="live-page">
          <div className="page-path">{pathAbove(rec.folder ?? "", rec.title)}</div>
          <div className="page-title" style={{ marginTop: 4 }}>
            {rec.title}
          </div>
          {status.state === "starting" && Date.now() - +new Date(rec.startedAt) > 6000 && (
            <div className="notice amber" style={{ marginTop: 16 }}>
              <WarningIcon size={15} style={{ marginTop: 1 }} />
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 600 }}>The recorder hasn’t started yet</div>
                <div style={{ color: "var(--fg)", opacity: 0.85 }}>
                  If macOS is asking whether OatcakeRecorder can use the microphone or record system audio, click Allow.
                </div>
              </div>
            </div>
          )}
          {status.state === "error" && (
            <div className="notice red" style={{ marginTop: 16 }}>
              <WarningIcon size={15} style={{ marginTop: 1, color: "var(--red)" }} />
              <div>{status.error}</div>
            </div>
          )}
          {micSilentFor >= 30 && (
            <div className="notice amber" style={{ marginTop: 16 }}>
              <WarningIcon size={15} style={{ marginTop: 1 }} />
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 600 }}>Your microphone has been silent for {micSilentFor} seconds</div>
                <div style={{ color: "var(--fg)", opacity: 0.85 }}>Check it isn’t muted, or switch to another microphone.</div>
              </div>
              <a style={{ color: "var(--amb)", fontWeight: 600, whiteSpace: "nowrap" }} onClick={openMic}>
                Change…
              </a>
            </div>
          )}
          {callSilentFor >= 30 && (
            <div className="notice amber" style={{ marginTop: 16 }}>
              <WarningIcon size={15} style={{ marginTop: 1 }} />
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 600 }}>No call audio for {callSilentFor} seconds</div>
                <div style={{ color: "var(--fg)", opacity: 0.85 }}>
                  If people are talking, allow Oatcake in System Settings › Privacy &amp; Security › Screen &amp; System Audio Recording.
                </div>
              </div>
            </div>
          )}
          <div className="live-notes">
            {lines.map((l, i) => (
              <div key={l.id} className="note-row">
                <span className={`chip ${l.prep ? "prep" : l.at === null ? "pending" : ""}`}>
                  {l.prep ? "Prep" : clock(l.at ?? (started ? elapsed : 0))}
                </span>
                <input
                  ref={(el) => {
                    if (el) inputs.current.set(l.id, el);
                    else inputs.current.delete(l.id);
                  }}
                  value={l.text}
                  placeholder={i === lines.length - 1 && !l.text ? "Type a point, then Return" : ""}
                  onChange={(e) => onChange(l, e.target.value)}
                  onKeyDown={(e) => onKey(l, e)}
                />
              </div>
            ))}
          </div>
          <div className="live-hint">One point per line. Each is stamped with the time you started typing it, and you can go back and edit any line.</div>
        </div>
      </div>
      <div className="live-bar">
        <div className="meters">
          <Meter label="You" level={status.micLevel} />
          <Meter label="Call" level={status.systemLevel} />
        </div>
        <div className={`mic-status ${micStatus.tone}`}>
          <MicIcon size={13} />
          <span>{micStatus.text}</span>
        </div>
        <button
          className={`mic-button ${micStatus.tone}`}
          title={micStatus.text}
          onClick={() => (micOpen ? setMicOpen(false) : openMic())}
        >
          {micStatus.tone ? <WarningIcon size={14} /> : <MicIcon />}
          <span>{device?.name ?? (mic ? mic.name : "Same as Mac")}</span>
          <ChevronDownIcon size={9} style={{ transform: "rotate(180deg)" }} />
        </button>
      </div>
      {micOpen && (
        <>
          <div className="popover-backdrop" onClick={() => setMicOpen(false)} />
          <div className="mic-popover">
            <div className="title">Microphone</div>
            {!devices ? (
              <div className="item muted">
                <Spinner />
                Looking for microphones…
              </div>
            ) : (
              micChoices(mic, devices).map((o) => (
                <div
                  key={o.value}
                  className={`item ${o.missing ? "missing" : ""}`}
                  onClick={() => {
                    api.setMic(choose(o.value, devices, mic));
                    setMicOpen(false);
                  }}
                >
                  <span className="tick" style={{ visibility: (mic?.uid ?? "") === o.value ? "visible" : "hidden" }}>
                    <CheckIcon size={12} />
                  </span>
                  <span style={{ flex: 1, minWidth: 0 }}>{o.label}</span>
                </div>
              ))
            )}
            <div className="foot">Call audio is everything your Mac plays. It’s always recorded, so Oatcake can tell the voices apart.</div>
          </div>
        </>
      )}
    </>
  );
}
