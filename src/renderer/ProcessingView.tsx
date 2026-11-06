import { useState } from "react";
import type { Recording } from "./api.ts";
import { hhmm, longDate, minutes, pathAbove } from "./format.ts";
import { WarningIcon } from "./icons.tsx";

export const STEPS = ["Transcribing your microphone", "Transcribing the call audio", "Telling voices apart", "Matching voices", "Suggesting names from the conversation"];

export interface JobProgress {
  step: string;
  fraction?: number;
  error?: string;
}

/** The failure in plain words; the raw message stays behind "Details". */
export function explain(error: string): string {
  if (/JSON|Unexpected (end|token)/i.test(error)) return "Its recording details couldn’t be read. The files may be damaged or incomplete.";
  if (/ENOENT|no such file/i.test(error)) return "Some of its audio files are missing.";
  if (/model|download|fetch|network/i.test(error)) return "The speech models couldn’t be loaded. Check your internet connection, then try again.";
  if (/code \d+/.test(error)) return "The processing helper stopped unexpectedly. Trying again usually works.";
  return "Something went wrong while processing this recording. Trying again usually works.";
}

/** Step 1–5 for a progress message; downloads and model loading count as step 1. */
export const stepNumber = (step: string) => Math.max(1, STEPS.indexOf(step) + 1);

export function recordingMeta(rec: Recording): string {
  const start = new Date(rec.startedAt);
  const length = rec.endedAt ? (+new Date(rec.endedAt) - +start) / 1000 : null;
  return [longDate(start), hhmm(start), length !== null && minutes(length)].filter(Boolean).join(" · ");
}

export function ProcessingView(props: { rec: Recording; progress?: JobProgress; onRetry(): void; onDiscard(): void }) {
  const { rec, progress } = props;
  const [details, setDetails] = useState(false);
  const step = progress?.step ?? "Starting";
  const n = stepNumber(step);
  const within = progress?.fraction ?? (STEPS.includes(step) ? 0.5 : 0.1);
  const failed = !!progress?.error;
  return (
    <>
      <div className="toolbar">
        <span style={{ fontWeight: 600 }}>{progress?.error ? "Couldn’t finish" : "Processing"}</span>
        <span className="muted" style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", minWidth: 0 }}>
          · {rec.title}
        </span>
        <div className="spacer" />
        {!failed && (
          <button className="btn" onClick={props.onDiscard}>
            Discard…
          </button>
        )}
      </div>
      <div className="centered">
        <div className="processing">
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            <div className="small">{pathAbove(rec.folder ?? "", rec.title)}</div>
            <div className="title">{rec.title}</div>
            <div className="small">{recordingMeta(rec)}</div>
          </div>
          {failed ? (
            <>
              <div className="fail-box">
                <WarningIcon size={15} />
                <div style={{ flex: 1 }}>
                  <div className="what">Couldn’t finish “{STEPS.includes(step) ? step : "Getting the recording ready"}”</div>
                  <div className="why">
                    {explain(progress?.error ?? "")} <a onClick={() => setDetails((d) => !d)}>{details ? "Hide details" : "Details"}</a>
                  </div>
                  {details && <div className="raw-error">{progress?.error}</div>}
                </div>
              </div>
              <div style={{ display: "flex", gap: 8 }}>
                <button className="btn primary" style={{ fontWeight: 500 }} onClick={props.onRetry}>
                  Try again
                </button>
                <button className="btn" onClick={props.onDiscard}>
                  Discard…
                </button>
              </div>
            </>
          ) : (
            <>
              <div className="progress-line">
                <span>{step}…</span>
                <span>Step {n} of 5</span>
              </div>
              <div className="progress-bar">
                <div style={{ width: `${(((n - 1 + within) / 5) * 100).toFixed(1)}%` }} />
              </div>
              <div className="small" style={{ lineHeight: 1.5 }}>
                An hour-long call takes a few minutes. You can keep working — it’ll wait under Needs review.
              </div>
            </>
          )}
        </div>
      </div>
    </>
  );
}
