// Minimal types for the parts of sherpa-onnx-node this app uses (the package ships JSDoc only).
declare module "sherpa-onnx-node" {
  interface OfflineStream {
    acceptWaveform(wave: { samples: Float32Array; sampleRate: number }): void;
  }
  export class OfflineRecognizer {
    constructor(config: object);
    createStream(): OfflineStream;
    decode(stream: OfflineStream): void;
    getResult(stream: OfflineStream): { text: string; tokens: string[]; timestamps: number[] };
  }
  export class Vad {
    constructor(config: object, bufferSizeInSeconds: number);
    acceptWaveform(samples: Float32Array): void;
    isEmpty(): boolean;
    front(enableExternalBuffer?: boolean): { start: number; samples: Float32Array };
    pop(): void;
    flush(): void;
  }
  export class OfflineSpeakerDiarization {
    constructor(config: object);
    process(samples: Float32Array): { start: number; end: number; speaker: number }[];
  }
  interface OnlineStream {
    acceptWaveform(wave: { samples: Float32Array; sampleRate: number }): void;
    inputFinished(): void;
  }
  export class SpeakerEmbeddingExtractor {
    constructor(config: object);
    createStream(): OnlineStream;
    isReady(stream: OnlineStream): boolean;
    compute(stream: OnlineStream, enableExternalBuffer?: boolean): Float32Array;
  }
}
