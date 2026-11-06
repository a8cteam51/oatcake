// Bundles the main process, preload, analysis worker and window into dist/.
import { build } from "esbuild";
import { cpSync, mkdirSync, rmSync } from "node:fs";

rmSync("dist", { recursive: true, force: true });
mkdirSync("dist/renderer", { recursive: true });

const common = { bundle: true, sourcemap: true, logLevel: "warning", target: "es2023" };

await Promise.all([
  build({
    ...common,
    entryPoints: ["src/main/main.ts", "src/main/preload.ts", "src/main/analyse-worker.ts"],
    outdir: "dist/main",
    platform: "node",
    format: "cjs",
    outExtension: { ".js": ".cjs" },
    // Native addon (and its dylibs) must load from node_modules.
    external: ["electron", "sherpa-onnx-node"],
  }),
  build({
    ...common,
    entryPoints: { app: "src/renderer/main.tsx" },
    outdir: "dist/renderer",
    platform: "browser",
    format: "iife",
    jsx: "automatic",
    define: { "process.env.NODE_ENV": '"production"' },
  }),
]);

cpSync("src/renderer/index.html", "dist/renderer/index.html");
cpSync("src/renderer/styles.css", "dist/renderer/styles.css");
console.log("Built dist/");
