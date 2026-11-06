import fs from "node:fs";
import path from "node:path";
import sherpa from "sherpa-onnx-node";
import { SAMPLE_RATE, slice } from "./audio.ts";
import { VOICEPRINTS_PATH } from "./config.ts";
import { writeAtomic } from "./files.ts";
import { EMBEDDING_MODEL, SEGMENTATION_MODEL, modelPath } from "./models.ts";

export interface Turn {
  start: number;
  end: number;
  speaker: number;
}

/** Small clusters are merged when their voices are at least this similar (cosine). */
const MERGE_SIMILARITY = 0.65;

/**
 * Splits the call audio into turns by voice. Speaker numbers only mean something within this call.
 *
 * Two stages, tuned on real meeting audio with known speakers (AMI ES2002a): sherpa-onnx at
 * a low threshold gives many small but mostly pure clusters (85–90% pure), then those are
 * merged by average voice similarity. That kept purity at 85–86% with far fewer clusters,
 * where sherpa's own clustering at any single threshold either over-split (17 clusters for
 * 4 people) or lumped people together (74–77% pure).
 */
export function diarize(samples: Float32Array): Turn[] {
  const diarizer = new sherpa.OfflineSpeakerDiarization({
    segmentation: { pyannote: { model: path.join(modelPath(SEGMENTATION_MODEL), "model.onnx") }, numThreads: 4 },
    embedding: { model: modelPath(EMBEDDING_MODEL), numThreads: 4 },
    clustering: { numClusters: -1, threshold: 0.5 },
    minDurationOn: 0.3,
    minDurationOff: 0.5,
  });
  return mergeByVoice(samples, diarizer.process(samples));
}

/** Clusters with less speech than this after merging are folded into the closest main voice. */
const MIN_SPEAKER_SECONDS = 5;

function mergeByVoice(samples: Float32Array, turns: Turn[]): Turn[] {
  type Cluster = { ids: number[]; embedding: number[]; seconds: number };
  const ids = [...new Set(turns.map((t) => t.speaker))];
  const own = (id: number) => turns.filter((t) => t.speaker === id);
  const secondsOf = (id: number) => own(id).reduce((n, t) => n + t.end - t.start, 0);

  // Only clusters with enough clean speech take part in merging; short ones are noisy and chain people together.
  let clusters: Cluster[] = ids.flatMap((id) => {
    const embedding = embed(samples, own(id));
    return embedding ? [{ ids: [id], embedding, seconds: secondsOf(id) }] : [];
  });

  // Average linkage: repeatedly merge the most similar pair, weighting by speech time.
  for (;;) {
    let best = -1;
    let pair: [number, number] = [-1, -1];
    for (let i = 0; i < clusters.length; i++) {
      for (let j = i + 1; j < clusters.length; j++) {
        const s = cosine(clusters[i].embedding, clusters[j].embedding);
        if (s > best) [best, pair] = [s, [i, j]];
      }
    }
    if (best < MERGE_SIMILARITY) break;
    const [a, b] = [clusters[pair[0]], clusters[pair[1]]];
    const merged = {
      ids: [...a.ids, ...b.ids],
      embedding: normalise(a.embedding.map((x, k) => x * a.seconds + b.embedding[k] * b.seconds)),
      seconds: a.seconds + b.seconds,
    };
    clusters = clusters.filter((_, k) => k !== pair[0] && k !== pair[1]).concat(merged);
  }

  const main = clusters.filter((c) => c.seconds >= MIN_SPEAKER_SECONDS);
  if (!main.length) return turns;
  const label = new Map<number, number>();
  main.forEach((c) => c.ids.forEach((id) => label.set(id, c.ids[0])));

  // Everything else joins the main voice its audio sounds closest to (or, below half a second, the nearest turn).
  const voiced = turns.filter((t) => label.has(t.speaker));
  for (const id of ids.filter((id) => !label.has(id))) {
    const embedding = embed(samples, own(id), 0.5, 0);
    if (embedding) {
      const closest = main.reduce((x, y) => (cosine(embedding, x.embedding) >= cosine(embedding, y.embedding) ? x : y));
      label.set(id, closest.ids[0]);
    }
  }
  return turns.map((t) => {
    if (label.has(t.speaker)) return { ...t, speaker: label.get(t.speaker)! };
    const mid = (t.start + t.end) / 2;
    const nearest = voiced.reduce((x, y) =>
      Math.abs((x.start + x.end) / 2 - mid) <= Math.abs((y.start + y.end) / 2 - mid) ? x : y,
    );
    return { ...t, speaker: label.get(nearest.speaker)! };
  });
}

let extractor: InstanceType<typeof sherpa.SpeakerEmbeddingExtractor> | undefined;

/**
 * A voice fingerprint from up to 60 s of one speaker's longest turns. Only turns of at
 * least `minTurn` seconds are used; null when they add up to less than `minSeconds`.
 */
export function embed(
  samples: Float32Array,
  turns: { start: number; end: number }[],
  minSeconds = 2,
  minTurn = 1,
): number[] | null {
  extractor ??= new sherpa.SpeakerEmbeddingExtractor({ model: modelPath(EMBEDDING_MODEL), numThreads: 4 });
  const chosen = turns.filter((t) => t.end - t.start >= minTurn).sort((a, b) => b.end - b.start - (a.end - a.start));
  const parts: Float32Array[] = [];
  let total = 0;
  for (const t of chosen) {
    if (total >= 60) break;
    parts.push(slice(samples, t.start, t.end));
    total += t.end - t.start;
  }
  if (total < minSeconds) return null;
  const audio = new Float32Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    audio.set(p, at);
    at += p.length;
  }
  const stream = extractor.createStream();
  stream.acceptWaveform({ samples: audio, sampleRate: SAMPLE_RATE });
  stream.inputFinished();
  if (!extractor.isReady(stream)) return null;
  return normalise(Array.from(extractor.compute(stream, false)));
}

function normalise(v: number[]): number[] {
  const norm = Math.hypot(...v) || 1;
  return v.map((x) => x / norm);
}

const cosine = (a: number[], b: number[]) => a.reduce((sum, x, i) => sum + x * b[i], 0);

// Voiceprints: several fingerprints per person (one per call, newest kept), because
// people sound different on Zoom, Meet and a laptop mic.

const MAX_SAMPLES_PER_PERSON = 10;
// OpenWhispr's thresholds for this embedding model (liveSpeakerIdentifier.js).
const MATCH_THRESHOLD = 0.65;
const MATCH_MARGIN = 0.03;

interface Voiceprints {
  model: string;
  people: Record<string, { samples: { embedding: number[]; call: string; at: string }[] }>;
}

export function loadVoiceprints(): Voiceprints {
  if (!fs.existsSync(VOICEPRINTS_PATH)) return { model: EMBEDDING_MODEL.target, people: {} };
  return JSON.parse(fs.readFileSync(VOICEPRINTS_PATH, "utf8"));
}

export function knownPeople(): string[] {
  return Object.keys(loadVoiceprints().people).sort();
}

/** Best voice match, only when it clears the threshold and beats the runner-up by the margin. */
export function match(embedding: number[], prints = loadVoiceprints()): { name: string; score: number } | null {
  const scores = Object.entries(prints.people)
    .map(([name, p]) => ({ name, score: Math.max(...p.samples.map((s) => cosine(embedding, s.embedding))) }))
    .sort((a, b) => b.score - a.score);
  const [best, next] = scores;
  if (!best || best.score < MATCH_THRESHOLD) return null;
  if (next && best.score - next.score < MATCH_MARGIN) return null;
  return best;
}

export function addVoiceprints(entries: { name: string; embedding: number[] }[], call: string): void {
  const prints = loadVoiceprints();
  for (const { name, embedding } of entries) {
    const person = (prints.people[name] ??= { samples: [] });
    person.samples.push({ embedding, call, at: new Date().toISOString() });
    person.samples = person.samples.slice(-MAX_SAMPLES_PER_PERSON);
  }
  writeAtomic(VOICEPRINTS_PATH, JSON.stringify(prints) + "\n");
}
