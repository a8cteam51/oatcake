import { useEffect, useRef, useState } from "react";
import { api, type Calendar, type Config, type SecretName } from "./api.ts";
import { hhmm } from "./format.ts";
import { EyeIcon, EyeOffIcon } from "./icons.tsx";
import { micHint, MicSelect, useInputs } from "./MicSelect.tsx";
import { Segmented, Select } from "./ui.tsx";

type Effort = Config["llm"]["claudeCode"]["effort"];
const EFFORTS: { value: Effort; label: string }[] = [
  { value: "low", label: "Low" },
  { value: "medium", label: "Medium" },
  { value: "high", label: "High" },
];
/** "~/Documents/…/Meetings": long paths lose their middle; hover shows the full path. */
function shortPath(full: string): string {
  const p = full.replace(/^\/Users\/[^/]+/, "~");
  return p.length <= 46 ? p : `${p.slice(0, 20)}…${p.slice(-24)}`;
}

const ANTHROPIC_MODELS = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"];

/** The Settings window. Every change is saved as it's made; there's no Save button. */
export function SettingsWindow() {
  const [config, setConfig] = useState<Config | null>(null);
  const [calendar, setCalendar] = useState<Calendar | null>(null);
  const { devices, refresh } = useInputs();
  const saveTimer = useRef<ReturnType<typeof setTimeout>>(undefined);

  useEffect(() => {
    api.getConfig().then(setConfig);
    api.getCalendar().then(setCalendar);
    const offCal = api.onCalendarChanged(setCalendar);
    const offConfig = api.onConfigChanged((c) => setConfig((mine) => (mine && JSON.stringify(mine) === JSON.stringify(c) ? mine : c)));
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && window.close();
    window.addEventListener("keydown", onKey);
    return () => {
      offCal();
      offConfig();
      window.removeEventListener("keydown", onKey);
    };
  }, []);

  if (!config) return <div className="settings-window" />;

  /** Typing saves after a short pause; clicks save straight away. */
  const update = (patch: Partial<Config>, delay = 0) => {
    const next = { ...config, ...patch };
    setConfig(next);
    clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => api.setConfig(next), delay);
  };
  const llm = config.llm;
  const updateLlm = (patch: Partial<Config["llm"]>, delay = 0) => update({ llm: { ...llm, ...patch } }, delay);
  const hint = devices ? micHint(config.mic, devices) : { text: "", tone: "" as const };
  // The main process sends a calendar (possibly still fetching) when an address is saved, and null when it's removed.
  const calendarOn = calendar !== null;
  const upcoming = (calendar?.events ?? []).filter((e) => new Date(e.end) > new Date()).length;
  const calStatus = !calendarOn
    ? "Not set up — Upcoming is hidden."
    : calendar?.fetching
      ? "Fetching…"
      : calendar?.error
        ? calendar.updatedAt
          ? `Last fetch failed: ${calendar.error.replace(/^Couldn't update the calendar: /, "")}`
          : calendar.error
        : calendar?.updatedAt
          ? `Updated ${hhmm(new Date(calendar.updatedAt))} · ${upcoming} upcoming event${upcoming === 1 ? "" : "s"}`
          : "Fetching…";

  return (
    <div className="settings-window">
      <div className="settings-title">Settings</div>
      <div className="settings-body">
        <Group label="You">
          <Row title="Your name" sub="Labels your microphone track in every transcript.">
            <input className="field" style={{ width: 200 }} placeholder="Your name" value={config.myName} onChange={(e) => update({ myName: e.target.value }, 400)} />
          </Row>
        </Group>

        <Group label="Recording">
          {/* A problem (unplugged, none found) is said once, full width under the row. */}
          <Row title="Microphone" sub={hint.tone ? undefined : hint.text} note={hint.tone ? hint : undefined}>
            <div onMouseDown={refresh}>
              <MicSelect width={270} value={config.mic} devices={devices ?? []} onChange={(mic) => api.setMic(mic).then(() => setConfig({ ...config, mic }))} />
            </div>
          </Row>
          <Row title="Keep call audio after saving" sub="When off, the audio is deleted once a meeting is saved. The transcript, notes and summary stay.">
            <span className={`switch ${config.keepAudio ? "on" : ""}`} onClick={() => update({ keepAudio: !config.keepAudio })}>
              <span />
            </span>
          </Row>
        </Group>

        <Group label="Storage">
          <Row
            title="Meetings folder"
            sub={
              <span className="mono" title={config.outputDir}>
                {shortPath(config.outputDir)}
              </span>
            }
          >
            {/* The main process saves the folder you pick; the new setting arrives as a config change. */}
            <button className="btn" onClick={() => api.chooseFolder()}>
              Choose…
            </button>
          </Row>
        </Group>

        <Group
          label="Calendar"
          foot="In Google Calendar, open Settings, pick your calendar under “Settings for my calendars”, then copy “Secret address in iCal format” from the Integrate calendar section. Without one, Upcoming is hidden."
        >
          <div className="group-stack" style={{ padding: "12px 14px", gap: 7 }}>
            <span>Private iCal address</span>
            <SecretKey name="calendar" placeholder="https://calendar.google.com/calendar/ical/…/basic.ics" />
            <span className={`sub ${calendarOn && calendar?.error ? "red" : ""}`}>{calStatus}</span>
          </div>
          <Row title="Remind me before calls" sub="5 minutes before each call, a notification with a button that opens the call and starts recording, ready for notes.">
            <span className={`switch ${config.callReminders ? "on" : ""}`} onClick={() => update({ callReminders: !config.callReminders })}>
              <span />
            </span>
          </Row>
        </Group>

        <Group label="Transcription" foot="Runs on your Mac. Audio never leaves it for transcription.">
          {[
            { value: "parakeet-unified-en", title: "Parakeet English", sub: "Fastest. English only." },
            { value: "parakeet-tdt-v3", title: "Parakeet — 25 European languages", sub: "A little slower. Detects the language of each call." },
          ].map((m) => (
            <div key={m.value} className="radio-row" onClick={() => update({ asrModel: m.value })}>
              <span className={`radio ${config.asrModel === m.value ? "on" : ""}`} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div>{m.title}</div>
                <div className="sub">{m.sub}</div>
              </div>
            </div>
          ))}
        </Group>

        <Group
          label="Summaries and name suggestions"
          foot={
            {
              "claude-code": "Uses your Claude Code sign-in on this Mac. No API key needed.",
              anthropic: "Billed to your Anthropic account. The key is stored encrypted, with its key in your Keychain.",
              "openai-compatible": "Any server that speaks the OpenAI chat API, such as Ollama or LM Studio. Name suggestions need a model that follows instructions well.",
            }[llm.provider]
          }
        >
          <Row title="Provider">
            <Segmented
              size="small"
              value={llm.provider}
              onChange={(provider) => updateLlm({ provider })}
              options={[
                { value: "claude-code", label: "Claude Code" },
                { value: "anthropic", label: "Anthropic API" },
                { value: "openai-compatible", label: "OpenAI-compatible" },
              ]}
            />
          </Row>
          {llm.provider === "claude-code" && (
            <>
              <Row title="Model">
                <Select
                  width={200}
                  value={llm.claudeCode.model}
                  onChange={(model) => updateLlm({ claudeCode: { ...llm.claudeCode, model } })}
                  options={[
                    { value: "", label: "Default" },
                    { value: "sonnet", label: "Sonnet" },
                    { value: "opus", label: "Opus" },
                    { value: "haiku", label: "Haiku" },
                  ]}
                />
              </Row>
              <Row title="Effort" sub={EFFORT_HINT}>
                <Segmented size="small" value={llm.claudeCode.effort} onChange={(effort) => updateLlm({ claudeCode: { ...llm.claudeCode, effort } })} options={EFFORTS} />
              </Row>
            </>
          )}
          {llm.provider === "anthropic" && (
            <>
              <div className="group-stack">
                <span>API key</span>
                <SecretKey name="anthropic" placeholder="sk-ant-…" />
              </div>
              <Row title="Model">
                <Select
                  width={220}
                  value={llm.anthropic.model}
                  onChange={(model) => updateLlm({ anthropic: { ...llm.anthropic, model } })}
                  options={[...new Set([...ANTHROPIC_MODELS, llm.anthropic.model])].map((m) => ({ value: m, label: m }))}
                />
              </Row>
              <Row title="Effort" sub={EFFORT_HINT}>
                <Segmented size="small" value={llm.anthropic.effort} onChange={(effort) => updateLlm({ anthropic: { ...llm.anthropic, effort } })} options={EFFORTS} />
              </Row>
            </>
          )}
          {llm.provider === "openai-compatible" && (
            <>
              <div className="group-stack">
                <span>
                  Endpoint {!llm.openai.baseUrl.trim() && <span className="required">Required</span>}
                </span>
                <input
                  className={`field mono ${llm.openai.baseUrl.trim() ? "" : "missing"}`}
                  spellCheck={false}
                  placeholder="e.g. http://localhost:11434/v1"
                  value={llm.openai.baseUrl}
                  onChange={(e) => updateLlm({ openai: { ...llm.openai, baseUrl: e.target.value } }, 400)}
                />
              </div>
              <div className="group-stack">
                <span>
                  API key <span className="muted" style={{ fontSize: 11 }}>· optional for local servers</span>
                </span>
                <SecretKey name="openai" placeholder="sk-…" />
              </div>
              <Row title="Model" sub={llm.openai.model.trim() ? undefined : "Required"} tone="amber">
                <input
                  className={`field mono ${llm.openai.model.trim() ? "" : "missing"}`}
                  style={{ width: 200 }}
                  spellCheck={false}
                  placeholder="e.g. llama3.1:70b"
                  value={llm.openai.model}
                  onChange={(e) => updateLlm({ openai: { ...llm.openai, model: e.target.value } }, 400)}
                />
              </Row>
              <Row title="Effort" sub={EFFORT_HINT}>
                <Segmented size="small" value={llm.openai.effort} onChange={(effort) => updateLlm({ openai: { ...llm.openai, effort } })} options={EFFORTS} />
              </Row>
            </>
          )}
          <TestRow
            key={llm.provider}
            missing={llm.provider === "openai-compatible" && (!llm.openai.baseUrl.trim() || !llm.openai.model.trim()) ? "Fill in the endpoint and model first." : undefined}
          />
        </Group>
      </div>
    </div>
  );
}

const EFFORT_HINT = "Higher thinks longer: more careful summaries and name guesses, but slower and more usage.";

/** Settings › Test: one short request to the chosen model, with the result underneath. */
function TestRow({ missing }: { missing?: string }) {
  const [state, setState] = useState<{ running: boolean; ok?: boolean; detail?: string }>({ running: false });
  return (
    <Row
      title="Check it works"
      sub={missing ?? (state.running ? "Asking the model for a one-word reply…" : state.detail ?? "Sends one short request with these settings.")}
      tone={state.ok === false && !missing ? "red" : ""}
    >
      <button
        className="btn"
        disabled={state.running || !!missing}
        onClick={async () => {
          setState({ running: true });
          // Let a key or endpoint typed a moment ago finish saving first.
          await new Promise((r) => setTimeout(r, 700));
          setState({ running: false, ...(await api.testLlm()) });
        }}
      >
        {state.running ? "Testing…" : "Test"}
      </button>
    </Row>
  );
}

function Group(props: { label: string; foot?: string; children: React.ReactNode }) {
  return (
    <div className="group">
      <div className="section-label">{props.label}</div>
      <div className="group-box">{props.children}</div>
      {props.foot && <div className="group-foot">{props.foot}</div>}
    </div>
  );
}

function Row(props: { title: string; sub?: React.ReactNode; tone?: string; note?: { text: string; tone: string }; children: React.ReactNode }) {
  return (
    <div className={`group-row ${props.note ? "has-note" : ""}`}>
      <div className="text">
        <span>{props.title}</span>
        {props.sub && <span className={`sub ${props.tone ?? ""}`}>{props.sub}</span>}
      </div>
      {props.children}
      {props.note && <div className={`row-note ${props.note.tone}`}>{props.note.text}</div>}
    </div>
  );
}

/**
 * An API key or the calendar address. The main process stores it encrypted and never sends it back,
 * so a saved one shows as a hint ("Saved · ends in 4f2a"). A new value saves on Return, on leaving
 * the field, or after a pause in typing.
 */
function SecretKey(props: { name: SecretName; placeholder: string }) {
  const [status, setStatus] = useState<{ saved: boolean; hint: string } | null>(null);
  const [draft, setDraft] = useState("");
  const [shown, setShown] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const load = () => api.getSecret(props.name).then(setStatus);
  useEffect(() => {
    load();
  }, [props.name]);
  const save = async (value: string, done: boolean) => {
    clearTimeout(timer.current);
    if (!value.trim()) return;
    await api.setSecret(props.name, value);
    if (done) setDraft("");
    load();
  };
  if (!status) return <div className="secret" />;
  return (
    <div className="secret">
      <input
        className="field mono"
        style={{ flex: 1 }}
        type={shown ? "text" : "password"}
        spellCheck={false}
        autoComplete="off"
        placeholder={status.saved ? status.hint : status.hint || props.placeholder}
        title={status.saved ? "Paste a new one to replace it" : undefined}
        value={draft}
        onChange={(e) => {
          const value = e.target.value;
          setDraft(value);
          clearTimeout(timer.current);
          timer.current = setTimeout(() => save(value, false), 1200);
        }}
        onKeyDown={(e) => e.key === "Enter" && save(draft, true)}
        onBlur={() => save(draft, true)}
      />
      {/* A saved one can't be shown, so the eye only appears while typing a new one. */}
      {draft && (
        <button className="icon-btn" title="Show or hide what you're typing" onClick={() => setShown((s) => !s)}>
          {shown ? <EyeOffIcon size={15} /> : <EyeIcon size={15} />}
        </button>
      )}
      {status.saved && (
        <button
          className="btn ghost"
          title="Delete the saved one"
          onClick={async () => {
            await api.setSecret(props.name, "");
            setDraft("");
            load();
          }}
        >
          Remove
        </button>
      )}
    </div>
  );
}
