import sherpa from "sherpa-onnx-node";
import { SAMPLE_RATE } from "./audio.ts";
import { ASR_MODELS, VAD_MODEL, modelPath } from "./models.ts";

export interface Word {
  text: string;
  /** Seconds from the start of the track. */
  start: number;
  end: number;
}

export interface Utterance {
  start: number;
  end: number;
  text: string;
  words: Word[];
}

/** Turns a track into timed utterances. Swap the implementation to change engines. */
export interface Transcriber {
  transcribe(samples: Float32Array, onProgress?: (fraction: number) => void): Utterance[];
}

/** sherpa-onnx: Silero VAD cuts speech into chunks of up to 20 s, then the configured model decodes each. */
export function sherpaTranscriber(asrModel: string): Transcriber {
  const model = ASR_MODELS[asrModel];
  const recognizer = new sherpa.OfflineRecognizer({
    featConfig: { sampleRate: SAMPLE_RATE, featureDim: 80 },
    modelConfig: model.modelConfig(modelPath(model.download)),
  });

  return {
    transcribe(samples, onProgress) {
      const vad = new sherpa.Vad(
        {
          sileroVad: { model: modelPath(VAD_MODEL), threshold: 0.5, minSilenceDuration: 0.4,
            minSpeechDuration: 0.25, maxSpeechDuration: 20, windowSize: 512 },
          sampleRate: SAMPLE_RATE,
          numThreads: 1,
        },
        60,
      );
      const utterances: Utterance[] = [];
      const drain = () => {
        while (!vad.isEmpty()) {
          const segment = vad.front(false);
          vad.pop();
          const u = decode(segment.samples, segment.start / SAMPLE_RATE);
          if (u) utterances.push(u);
        }
      };
      const decode = (chunk: Float32Array, offset: number): Utterance | null => {
        const stream = recognizer.createStream();
        stream.acceptWaveform({ samples: chunk, sampleRate: SAMPLE_RATE });
        recognizer.decode(stream);
        const result = recognizer.getResult(stream);
        const end = offset + chunk.length / SAMPLE_RATE;
        const words = toWords(result.tokens, result.timestamps, offset, end);
        const text = result.text.trim();
        return text ? { start: offset, end, text, words } : null;
      };

      const window = 512;
      for (let i = 0; i + window <= samples.length; i += window) {
        vad.acceptWaveform(samples.subarray(i, i + window));
        if (i % (window * 2000) === 0) {
          drain();
          onProgress?.(i / samples.length);
        }
      }
      vad.flush();
      drain();
      onProgress?.(1);
      return utterances;
    },
  };
}

/** Groups subword tokens into words. A token starting with a space or "▁" begins a new word. */
function toWords(tokens: string[], timestamps: number[], offset: number, end: number): Word[] {
  const words: Word[] = [];
  tokens.forEach((token, i) => {
    const start = offset + (timestamps[i] ?? 0);
    const startsWord = /^[\s▁]/.test(token) || words.length === 0;
    const piece = token.replace(/^[\s▁]+/, "");
    if (startsWord) words.push({ text: piece, start, end: start });
    else words[words.length - 1].text += piece;
  });
  words.forEach((w, i) => (w.end = words[i + 1]?.start ?? end));
  return words.filter((w) => w.text);
}
