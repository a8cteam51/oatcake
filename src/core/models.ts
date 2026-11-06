import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { MODELS_DIR } from "./config.ts";

const RELEASES = "https://github.com/k2-fsa/sherpa-onnx/releases/download";

interface Download {
  /** File or folder the download produces inside MODELS_DIR. */
  target: string;
  url: string;
  /** SHA-256 of the downloaded file, checked before it's used (GitHub's published digest where it has one). */
  sha256: string;
  /** Tarballs are extracted into MODELS_DIR. */
  tarball?: boolean;
}

/**
 * Speech-to-text models sherpa-onnx can run. To try another model, add an entry and
 * set `asrModel` in config.json. sherpa-onnx also supports Whisper, Canary and Cohere
 * Transcribe through other `modelConfig` keys.
 */
export const ASR_MODELS: Record<string, { download: Download; modelConfig(dir: string): object }> = {
  "parakeet-unified-en": nemoTransducer(
    "sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming",
    "99f63605b3a85a54c250c0869670a687b7d6598a47bf2421515e1f839a76e150",
  ),
  "parakeet-tdt-v3": nemoTransducer(
    "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
    "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf",
  ),
};

function nemoTransducer(dir: string, sha256: string) {
  return {
    download: { target: dir, url: `${RELEASES}/asr-models/${dir}.tar.bz2`, sha256, tarball: true },
    modelConfig: (root: string) => ({
      transducer: {
        encoder: path.join(root, "encoder.int8.onnx"),
        decoder: path.join(root, "decoder.int8.onnx"),
        joiner: path.join(root, "joiner.int8.onnx"),
      },
      tokens: path.join(root, "tokens.txt"),
      modelType: "nemo_transducer",
      numThreads: 4,
    }),
  };
}

export const VAD_MODEL: Download = {
  target: "silero_vad.onnx",
  url: `${RELEASES}/asr-models/silero_vad.onnx`,
  sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
};
// GitHub publishes no digest for these two; hashed from downloads on 5 Nov 2026.
export const SEGMENTATION_MODEL: Download = {
  target: "sherpa-onnx-pyannote-segmentation-3-0",
  url: `${RELEASES}/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2`,
  sha256: "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488",
  tarball: true,
};
/** Voice fingerprints. Saved voiceprints only match fingerprints from the same model. */
export const EMBEDDING_MODEL: Download = {
  target: "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx",
  url: `${RELEASES}/speaker-recongition-models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx`,
  sha256: "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b",
};

export const modelPath = (d: Download) => path.join(MODELS_DIR, d.target);

/** Downloads any missing models. First run fetches about 700 MB. */
export function ensureModels(asrModel: string, onProgress: (message: string) => void): void {
  const asr = ASR_MODELS[asrModel];
  if (!asr) throw new Error(`Unknown asrModel "${asrModel}". Options: ${Object.keys(ASR_MODELS).join(", ")}`);
  fs.mkdirSync(MODELS_DIR, { recursive: true });
  for (const d of [VAD_MODEL, SEGMENTATION_MODEL, EMBEDDING_MODEL, asr.download]) {
    if (fs.existsSync(modelPath(d))) continue;
    onProgress(`Downloading ${d.target} (first run only)`);
    const file = path.join(MODELS_DIR, path.basename(d.url) + ".part");
    execFileSync("/usr/bin/curl", ["-sSfL", "-o", file, d.url]);
    const sum = execFileSync("/usr/bin/shasum", ["-a", "256", file], { encoding: "utf8" }).split(" ")[0];
    if (sum !== d.sha256) {
      fs.rmSync(file, { force: true });
      throw new Error(`The download of ${d.target} didn't match its expected checksum, so it wasn't used. Try again later.`);
    }
    if (d.tarball) {
      execFileSync("/usr/bin/tar", ["xjf", file, "-C", MODELS_DIR]);
      fs.rmSync(file);
    } else {
      fs.renameSync(file, modelPath(d));
    }
  }
}
