// Small shared pieces of the design: segmented controls, selects, avatars, the spinner, the
// recording dot, the confirmation sheet, toasts and the update state.
import { useEffect, useState } from "react";
import { SelectChevrons } from "./icons.tsx";
import { api, type UpdateState } from "./api.ts";
import { cleanError, person } from "./format.ts";

export function Segmented<T extends string>(props: {
  options: { value: T; label: string; title?: string }[];
  value: T;
  onChange(value: T): void;
  size?: "small" | "normal";
}) {
  return (
    <div className={`segmented ${props.size === "small" ? "small" : ""}`}>
      {props.options.map((o) => (
        <span key={o.value} title={o.title} className={o.value === props.value ? "on" : ""} onClick={() => props.onChange(o.value)}>
          {o.label}
        </span>
      ))}
    </div>
  );
}

export function Select(props: {
  value: string;
  onChange(value: string): void;
  options: { value: string; label: string }[];
  width?: number;
  title?: string;
}) {
  return (
    <div className="select" style={props.width ? { width: props.width } : undefined}>
      <select value={props.value} title={props.title} onChange={(e) => props.onChange(e.target.value)}>
        {props.options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      <SelectChevrons />
    </div>
  );
}

export function Avatar({ name, size = 24, color }: { name: string; size?: number; color?: string }) {
  const p = person(name);
  return (
    <span className="avatar" style={{ width: size, height: size, background: color ?? p.color, fontSize: Math.round(size * 0.42) }}>
      {p.initial}
    </span>
  );
}

export const Spinner = ({ size = 12 }: { size?: number }) => <span className="spinner" style={{ width: size, height: size }} />;
export const RecDot = () => <span className="rec-dot" />;

export function Checkbox({ checked, onClick }: { checked: boolean; onClick?(): void }) {
  return (
    <span className={`checkbox ${checked ? "on" : ""}`} onClick={onClick}>
      <svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" style={{ strokeWidth: 2.5, strokeLinecap: "round", strokeLinejoin: "round" }}>
        <path d="M3.5 8.5l3 3 6-7" />
      </svg>
    </span>
  );
}

export interface Confirmation {
  title: string;
  text: string;
  ok: string;
  cancel: string;
  onOk(): void | Promise<void>;
}

/** The design's confirmation sheet. Esc or a click outside cancels; Return confirms. */
export function ConfirmSheet({ confirm, onClose }: { confirm: Confirmation; onClose(): void }) {
  const ok = () => {
    onClose();
    // A failure (say, the recording had already stopped) is shown rather than lost.
    Promise.resolve()
      .then(confirm.onOk)
      .catch((e) => toast(cleanError(e)));
  };
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (e.key !== "Escape" && e.key !== "Enter") return;
      // Otherwise the same Return also presses whichever button has focus (often the one that opened this).
      e.preventDefault();
      e.stopPropagation();
      if (e.key === "Escape") onClose();
      else ok();
    };
    window.addEventListener("keydown", key, true);
    return () => window.removeEventListener("keydown", key, true);
  }, [confirm]);
  return (
    <>
      <div className="sheet-backdrop" onClick={onClose} />
      <div className="sheet" role="dialog">
        <div className="sheet-title">{confirm.title}</div>
        <div className="muted">{confirm.text}</div>
        <div className="sheet-buttons">
          <button className="btn" onClick={onClose}>
            {confirm.cancel}
          </button>
          <button className="btn red" onClick={ok}>
            {confirm.ok}
          </button>
        </div>
      </div>
    </>
  );
}

// Toasts: one at a time, gone after a couple of seconds.
let showToast: (text: string) => void = () => {};
export const toast = (text: string) => showToast(text);
export function ToastHost() {
  const [text, setText] = useState<string | null>(null);
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    showToast = (t) => {
      clearTimeout(timer);
      setText(t);
      timer = setTimeout(() => setText(null), 2400);
    };
  }, []);
  return text ? <div className="toast">{text}</div> : null;
}

/** The update check's state, kept current by the main process (Settings › Updates and the sidebar's notice). */
export function useUpdate(): UpdateState | null {
  const [state, setState] = useState<UpdateState | null>(null);
  useEffect(() => {
    api.getUpdate().then(setState);
    return api.onUpdateChanged(setState);
  }, []);
  return state;
}
