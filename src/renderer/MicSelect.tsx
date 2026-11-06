import { useCallback, useEffect, useState } from "react";
import { api, type Config, type InputDevice } from "./api.ts";
import { Select } from "./ui.tsx";

const SAME_AS_MAC = "";

/** The Mac's microphones, re-read on demand so newly connected ones appear. */
export function useInputs() {
  const [devices, setDevices] = useState<InputDevice[] | null>(null);
  const refresh = useCallback(() => api.listInputs().then(setDevices, () => setDevices([])), []);
  useEffect(() => {
    refresh();
  }, [refresh]);
  return { devices, refresh };
}

export interface MicChoice {
  value: string;
  label: string;
  missing?: boolean;
}

/**
 * "Same as Mac (now …)", each microphone, and the saved one if it's gone: marked "(not connected)"
 * unless the caller says so in a hint of its own.
 */
export function micChoices(mic: Config["mic"], devices: InputDevice[], markMissing = true): MicChoice[] {
  const current = devices.find((d) => d.isDefault) ?? devices[0];
  const missing = mic && !devices.some((d) => d.uid === mic.uid);
  return [
    { value: SAME_AS_MAC, label: current ? `Same as Mac (now ${current.name})` : "Same as Mac (no microphone found)" },
    ...devices.map((d) => ({ value: d.uid, label: d.name })),
    ...(missing ? [{ value: mic.uid, label: markMissing ? `${mic.name} (not connected)` : mic.name, missing: true }] : []),
  ];
}

/** What will record, for the hint under the picker: tone "" | "amber" | "red". */
export function micHint(mic: Config["mic"], devices: InputDevice[]): { text: string; tone: "" | "amber" | "red" } {
  const current = devices.find((d) => d.isDefault) ?? devices[0];
  if (!current) return { text: "No microphone found. Connect one to record your side of the call.", tone: "red" };
  if (mic && !devices.some((d) => d.uid === mic.uid)) return { text: `${mic.name} isn’t connected, so Oatcake will use ${current.name}.`, tone: "amber" };
  return { text: `Records from ${mic ? mic.name : current.name}.`, tone: "" };
}

export function choose(value: string, devices: InputDevice[], mic: Config["mic"]): Config["mic"] {
  if (value === SAME_AS_MAC) return null;
  const device = devices.find((d) => d.uid === value);
  return device ? { uid: device.uid, name: device.name } : mic;
}

/** The microphone picker used on New recording and in Settings, both of which say underneath when it's unplugged. */
export function MicSelect(props: { value: Config["mic"]; devices: InputDevice[]; onChange(mic: Config["mic"]): void; width?: number }) {
  return (
    <Select
      width={props.width}
      value={props.value?.uid ?? SAME_AS_MAC}
      onChange={(v) => props.onChange(choose(v, props.devices, props.value))}
      options={micChoices(props.value, props.devices, false)}
    />
  );
}
