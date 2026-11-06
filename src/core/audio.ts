import fs from "node:fs";

export const SAMPLE_RATE = 16_000;

/** Reads a raw 16 kHz mono PCM16 file into floats in [-1, 1]. */
export function readPcm(file: string): Float32Array {
  if (!fs.existsSync(file)) return new Float32Array(0);
  const bytes = fs.readFileSync(file);
  const ints = new Int16Array(bytes.buffer, bytes.byteOffset, Math.floor(bytes.length / 2));
  const out = new Float32Array(ints.length);
  for (let i = 0; i < ints.length; i++) out[i] = ints[i] / 32768;
  return out;
}

export function slice(samples: Float32Array, start: number, end: number): Float32Array {
  return samples.subarray(
    Math.max(0, Math.floor(start * SAMPLE_RATE)),
    Math.min(samples.length, Math.ceil(end * SAMPLE_RATE)),
  );
}

/** Writes floats as a 16 kHz mono PCM16 WAV file (for review clips played with afplay). */
export function writeWav(file: string, samples: Float32Array): void {
  const data = Buffer.alloc(samples.length * 2);
  for (let i = 0; i < samples.length; i++) {
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, samples[i])) * 32767), i * 2);
  }
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + data.length, 4);
  header.write("WAVEfmt ", 8);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); // PCM
  header.writeUInt16LE(1, 22); // mono
  header.writeUInt32LE(SAMPLE_RATE, 24);
  header.writeUInt32LE(SAMPLE_RATE * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(data.length, 40);
  fs.writeFileSync(file, Buffer.concat([header, data]));
}
