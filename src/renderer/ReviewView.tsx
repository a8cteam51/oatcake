import { useEffect, useRef, useState } from "react";
import { api, type Analysis, type Decision, type Recording } from "./api.ts";
import { cleanError, clock, minutes, pathAbove, person } from "./format.ts";
import { KnownIcon, PauseIcon, PlayIcon, QuoteIcon, WarningIcon } from "./icons.tsx";
import { recordingMeta } from "./ProcessingView.tsx";
import { Avatar, Spinner } from "./ui.tsx";

const ME = "me";

interface Voice {
  name: string;
  mixed: boolean;
  /** Merged into another voice ("me" for your microphone). */
  into: string | null;
}

type Clip = { text: string; start: number; end: number; clip: string };

export function ReviewView(props: {
  rec: Recording;
  onSaved(path: string, folder: string): void;
  onDiscard(): void;
}) {
  const id = props.rec.id;
  const [data, setData] = useState<Awaited<ReturnType<typeof api.getAnalysis>> | null>(null);
  const [voices, setVoices] = useState<Record<string, Voice>>({});
  const [showTranscript, setShowTranscript] = useState(false);
  const [saving, setSaving] = useState("");
  const [error, setError] = useState("");
  const audio = useRef<HTMLAudioElement | null>(null);
  const [playing, setPlaying] = useState<{ file: string; pct: number } | null>(null);

  useEffect(() => {
    api.getAnalysis(id).then(
      (d) => {
        setData(d);
        setVoices(Object.fromEntries(d.analysis.speakers.map((s) => [s.id, { name: s.suggestion?.name ?? "", mixed: false, into: null }])));
      },
      (e) => setError(cleanError(e)),
    );
    const off = api.onSaveProgress((from, step) => from === id && setSaving(step));
    return () => {
      off();
      audio.current?.pause();
    };
  }, [id]);

  if (!data) return error ? <div className="empty-state">{error}</div> : <div className="toolbar empty" />;
  const analysis: Analysis = data.analysis;
  const myName = data.myName || "You";
  const label = (sid: string) => `Voice ${analysis.speakers.findIndex((s) => s.id === sid) + 1}`;
  const set = (sid: string, patch: Partial<Voice>) => setVoices((all) => ({ ...all, [sid]: { ...all[sid], ...patch } }));

  /** The name a line will be saved under, following merges. */
  const nameOf = (sid: string, seen = new Set<string>()): string => {
    if (sid === ME) return myName;
    const v = voices[sid];
    if (!v) return "Unknown";
    if (v.into && !seen.has(sid)) {
      seen.add(sid);
      return nameOf(v.into, seen);
    }
    return v.mixed ? "Several people" : v.name.trim() || label(sid);
  };

  const play = async (file: string) => {
    audio.current?.pause();
    if (playing?.file === file) return setPlaying(null);
    const a = new Audio(await api.clip(file));
    a.ontimeupdate = () => a.duration && setPlaying({ file, pct: (a.currentTime / a.duration) * 100 });
    a.onended = () => setPlaying(null);
    audio.current = a;
    setPlaying({ file, pct: 0 });
    a.play();
  };
  const clips = (list: Clip[]) => (
    <div className="clips">
      {list.map((q) => {
        const on = playing?.file === q.clip;
        return (
          <div key={q.clip} className={`clip ${on ? "on" : ""}`} title={q.text} onClick={() => play(q.clip)}>
            {on ? <PauseIcon size={10} /> : <PlayIcon size={10} />}
            {clock(q.start)}
            <i style={{ width: on ? `${playing.pct}%` : 0 }} />
          </div>
        );
      })}
    </div>
  );

  const save = async () => {
    setError("");
    setSaving("Saving");
    const decisions: Record<string, Decision> = Object.fromEntries(
      Object.entries(voices).map(([sid, v]) => [
        sid,
        // An unnamed voice is sent with no name: it's saved as "Voice N" but never remembered as a person.
        v.into ? { kind: "merge", into: v.into } : v.mixed ? { kind: "mixed" } : { kind: "name", name: v.name.trim() },
      ]),
    );
    try {
      const folder = data.folder ?? "";
      props.onSaved(await api.saveRecording(id, decisions, folder), folder);
    } catch (e) {
      setError(cleanError(e));
      setSaving("");
    }
  };

  const visible = analysis.speakers.filter((s) => !voices[s.id]?.into);
  const unnamed = visible.filter((s) => !voices[s.id].mixed && !voices[s.id].name.trim()).length;

  /** The voice's "⋯" menu: merge into another voice (or you), or mark as mixed. */
  const voiceMenu = async (sid: string) => {
    const v = voices[sid];
    const targets = visible.filter((o) => o.id !== sid && !voices[o.id].mixed);
    const choice = await api.popupMenu([
      ...(v.mixed
        ? []
        : [
            {
              label: "Merge with",
              submenu: [
                { id: `merge:${ME}`, label: `${myName} (your microphone)` },
                ...targets.map((o) => ({ id: `merge:${o.id}`, label: voices[o.id].name.trim() || label(o.id) })),
              ],
            },
          ]),
      { id: "mixed", label: v.mixed ? "Not mixed" : "Mark as mixed (several people)" },
    ]);
    if (choice === "mixed") set(sid, { mixed: !v.mixed });
    else if (choice?.startsWith("merge:")) set(sid, { into: choice.slice(6) });
  };
  const me = analysis.me;
  const meTalk = me?.seconds ?? analysis.lines.filter((l) => l.speaker === ME).reduce((n, l) => n + l.end - l.start, 0);

  return (
    <>
      <div className="toolbar" style={{ flexWrap: "nowrap" }}>
        <span style={{ fontWeight: 600 }}>Who’s who</span>
        <span className="muted" style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", minWidth: 0 }}>
          · {props.rec.title}
        </span>
        <div className="spacer" />
        <button className="btn ghost" onClick={() => setShowTranscript((v) => !v)}>
          {showTranscript ? "Hide transcript" : "Show transcript"}
        </button>
        <button className="btn" disabled={!!saving} onClick={props.onDiscard}>
          Discard…
        </button>
        {unnamed > 0 && !saving && (
          <span className="muted" title="Unnamed voices are saved as “Voice 1”, “Voice 2”…" style={{ fontSize: 12 }}>
            {unnamed} voice{unnamed === 1 ? "" : "s"} unnamed
          </span>
        )}
        <button className="btn primary" style={{ padding: "0 16px" }} title="Save names and write the summary" disabled={!!saving} onClick={save}>
          Save
        </button>
      </div>
      <div className="review">
        <div className="review-scroll">
          <div className="review-page">
            <div>
              <div className="page-path">{pathAbove(data.folder ?? "", props.rec.title)}</div>
              <div className="page-title" style={{ fontSize: 22, marginTop: 3 }}>
                {props.rec.title}
              </div>
              <div className="muted" style={{ marginTop: 4 }}>
                {recordingMeta(props.rec)}
              </div>
              <p className="muted" style={{ marginTop: 12, lineHeight: 1.5 }}>
                Check who’s who before saving. Names label the transcript, and Oatcake remembers these voices next time.
              </p>
            </div>
            {saving && (
              <div className="notice blue">
                <Spinner />
                {saving === "Saving voiceprints" || saving === "Saving" ? "Saving…" : `${saving}…`}
              </div>
            )}
            {error && <div className="notice red">{error}</div>}
            {analysis.speakers.length === 0 && (
              <div className="notice amber">
                <WarningIcon size={15} style={{ marginTop: 1 }} />
                <div>
                  <div style={{ fontWeight: 600 }}>No other voices were heard</div>
                  <div style={{ color: "var(--fg)", opacity: 0.85 }}>
                    Only your microphone picked anything up. If people were talking on the call, check that OatcakeRecorder is allowed in
                    System Settings › Privacy &amp; Security › Screen &amp; System Audio Recording.
                  </div>
                </div>
              </div>
            )}
            {analysis.warnings.map((w) => (
              <div key={w} className="notice amber">
                {w}
              </div>
            ))}

            <div className="voice-card">
              <div className="voice-head">
                <Avatar name={myName} size={30} />
                <div className="who">
                  <div>{myName} · your microphone</div>
                  <div>{minutes(meTalk)} talking</div>
                </div>
              </div>
              {me?.quotes.length ? clips(me.quotes) : null}
              <div className="voice-note">Labelled with your name from Settings.</div>
            </div>

            {visible.map((s) => {
              const v = voices[s.id];
              const shown = v.mixed ? "Several people" : v.name.trim() || label(s.id);
              const absorbed = analysis.speakers.filter((o) => voices[o.id]?.into === s.id);
              const p = person(shown, false);
              const fromSuggestion = s.suggestion && v.name === s.suggestion.name && !v.mixed;
              return (
                <div key={s.id} className="voice-card">
                  <div className="voice-head">
                    <span className="avatar" style={{ width: 30, height: 30, fontSize: 13, background: v.mixed ? "light-dark(#8e8e93,#636366)" : p.color }}>
                      {v.mixed ? "?" : p.initial}
                    </span>
                    <div className="who">
                      <div>{shown}</div>
                      <div>
                        {v.name.trim() || v.mixed ? `${label(s.id)} · ` : ""}
                        {minutes(s.seconds)} talking
                      </div>
                    </div>
                    <button className="btn icon-only" title="Merge or mark as mixed" onClick={() => voiceMenu(s.id)}>
                      ⋯
                    </button>
                  </div>
                  {clips(s.quotes)}
                  {!v.mixed && (
                    <div className="stack" style={{ gap: 6 }}>
                      <input
                        className="field name"
                        list="known-people"
                        placeholder="Who is this?"
                        value={v.name}
                        onChange={(e) => set(s.id, { name: e.target.value })}
                      />
                      {fromSuggestion && s.suggestion && (
                        <div className={`source ${s.suggestion.how === "voice" ? "known" : ""}`}>
                          {s.suggestion.how === "voice" ? <KnownIcon size={13} /> : <QuoteIcon size={13} />}
                          <span style={{ minWidth: 0 }}>
                            {s.suggestion.how === "voice"
                              ? "Recognised from before"
                              : `Guessed from the conversation${s.suggestion.detail ? ` · “${s.suggestion.detail.replace(/^["“]|["”]$/g, "")}”` : ""}`}
                          </span>
                        </div>
                      )}
                    </div>
                  )}
                  {(v.mixed || absorbed.length > 0) && (
                    <div className="voice-note">
                      {v.mixed
                        ? "More than one person shares this voice, so their lines will be labelled “Several people”."
                        : `Includes ${absorbed.map((o) => label(o.id)).join(", ")}.`}
                      {!v.mixed && absorbed.length > 0 && (
                        <>
                          {" "}
                          <a onClick={() => absorbed.forEach((o) => set(o.id, { into: null }))}>Undo</a>
                        </>
                      )}
                    </div>
                  )}
                </div>
              );
            })}
            <datalist id="known-people">
              {data.people.map((n) => (
                <option key={n} value={n} />
              ))}
            </datalist>
          </div>
        </div>
        {showTranscript && (
          <div className="review-transcript">
            <div className="list-head">
              <div className="section-label">Transcript</div>
              <span>Updates as you name voices</span>
            </div>
            {analysis.lines.map((l, i) => {
              const name = nameOf(l.speaker);
              return (
                <div key={i} className="line">
                  <div className="who">
                    <span style={{ color: /^(Voice \d+|Several people|Unknown)$/.test(name) ? "var(--fg2)" : person(name, false).color }}>{name}</span>
                    <span>{clock(l.start)}</span>
                  </div>
                  <span>{l.text}</span>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </>
  );
}
