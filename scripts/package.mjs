// Packages out/Oatcake-darwin-arm64/Oatcake.app (ad-hoc signed, not notarised).
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { packager } from "@electron/packager";
import { flipFuses, FuseV1Options, FuseVersion } from "@electron/fuses";

if (!existsSync("recorder/build/OatcakeRecorder.app")) execFileSync("sh", ["recorder/build.sh"], { stdio: "inherit" });

// Use Electron's own download cache when it already holds this version, rather than downloading again.
const { version } = JSON.parse(readFileSync("node_modules/electron/package.json", "utf8"));
const cache = path.join(os.homedir(), "Library/Caches/electron");
const zip = `electron-v${version}-darwin-arm64.zip`;
const electronZipDir = existsSync(cache)
  ? readdirSync(cache).map((d) => path.join(cache, d)).find((d) => existsSync(path.join(d, zip)))
  : undefined;

const [appDir] = await packager({
  electronZipDir,
  dir: ".",
  out: "out",
  overwrite: true,
  platform: "darwin",
  arch: "arm64",
  name: "Oatcake",
  appBundleId: "local.oatcake",
  appCategoryType: "public.app-category.productivity",
  // Built from assets/icon.png with iconutil (the source is assets/icon.svg).
  icon: "assets/Oatcake.icns",
  // The native speech library loads .node and .dylib files, which can't live inside the asar archive.
  asar: { unpack: "**/node_modules/sherpa-onnx-*/**" },
  extraResource: ["recorder/build/OatcakeRecorder.app"],
  ignore: [/^\/(src|recorder|scripts|out|assets)(\/|$)/, /\.map$/, /^\/tsconfig\.json$/],
  extendInfo: {
    NSMicrophoneUsageDescription: "Oatcake records your microphone so your side of the call is in the transcript.",
    NSAudioCaptureUsageDescription: "Oatcake records call audio so the other people on the call are in the transcript.",
    // Call reminders stay on screen with their button until dealt with, like Calendar's alerts.
    NSUserNotificationAlertStyle: "alert",
  },
});

const app = `${appDir}/Oatcake.app`;
// Close Electron's developer back doors in the shipped app: no running it as plain Node
// (ELECTRON_RUN_AS_NODE), no NODE_OPTIONS or --inspect, and only the app code in its (checked) asar.
await flipFuses(app, {
  version: FuseVersion.V1,
  [FuseV1Options.RunAsNode]: false,
  [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
  [FuseV1Options.EnableNodeCliInspectArguments]: false,
  [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
  [FuseV1Options.OnlyLoadAppFromAsar]: true,
});
execFileSync("codesign", ["--force", "--deep", "--sign", "-", app], { stdio: "inherit" });
console.log(`Packaged ${app}`);
