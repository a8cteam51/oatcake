# Speech and language models

## Speech models

FluidAudio is pinned to an exact version in `Package.swift`, with only its diarisation trait
(no text-to-speech, no prebuilt text-normalisation library). The models come from
FluidInference's Hugging Face repositories at fixed commits (`SpeechModels.pinnedRevisions`;
FluidAudio pins the diarisation models itself), so a change to a repository can't change what
Oatcake runs. Updating either is a deliberate change: bump it, then check transcripts and
speaker separation on a known meeting.

| Model | Used for | Licence |
| --- | --- | --- |
| Silero VAD | finding speech | MIT |
| Parakeet TDT 0.6B v2 | English transcription (default) | CC-BY-4.0 |
| Underdog Bark 3.0 Clean (Conway Research; a retraining of Parakeet v3) | English, leaving out "um", false starts and repeats | CC-BY-4.0 |
| Parakeet Ultra (post-trained v3) | 25 European languages | CC-BY-4.0 |
| SenseVoiceSmall (Alibaba's FunAudioLLM) | Chinese, Cantonese, Japanese, Korean and English | [FunASR Model License 1.1](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE): use, change and share with credit; "for reference and learning purposes only", and later versions apply automatically |
| pyannote community-1 (segmentation and its WeSpeaker-based embedding) | speaker turns and voice fingerprints | CC-BY-4.0 |

## Language model

Summaries, to-dos, name suggestions and Ask's answers come from one model, run on this Mac:
Alibaba's Qwen or Google's Gemma. Each one's description in Settings › Models says, in a few
words, how it did in the tests below.

| Model | By | For | Download | Licence |
| --- | --- | --- | --- | --- |
| Qwen3.6 35B-A3B (Q4_K_M) | Alibaba | Macs with 32 GB of memory or more; the default there | 20.5 GB | Apache-2.0 |
| Qwen3.5 4B (Q4_K_M) | Alibaba | Macs with less; the default there | 3.0 GB | Apache-2.0 |
| Gemma 4 26B-A4B (QAT Q4_0) | Google | Macs with 24 GB of memory or more, to choose instead | 14.4 GB | Apache-2.0 |
| Gemma 4 12B (QAT Q4_0) | Google | Macs with 16 GB of memory or more, to choose instead | 7.0 GB | Apache-2.0 |
| Qwen3 8B (Q4_K_M) | Alibaba | Older model, kept for those who chose it; the earlier default on Macs with 16 GB or more | 5.0 GB | Apache-2.0 |
| Qwen3 4B (Q4_K_M) | Alibaba | Older model, kept for those who chose it; the earlier default on Macs with 8 GB | 2.5 GB | Apache-2.0 |

- **Why these.** Measured in November 2026 on a made-up 35-minute call with an answer key, three
  runs each, every summary graded blind for factual mistakes. Serious mistakes over three
  summaries: Qwen3.6 35B-A3B 1, Qwen3.5 4B 7, Qwen3 4B 10, Qwen3 8B 17. The aim was a summary
  within two minutes on a 2023 MacBook Pro (M3 Pro), estimated from llama.cpp's own speed table
  for Apple silicon: about 100–130 seconds for the 35B-A3B and 95 for the 3.5 4B (the 8B, with
  reasoning, about 150). The 35B-A3B is quick for its size because only about 3 billion of its
  parameters work on each token. Qwen3.8 27B and Qwen3 14B were tried too: the 27B took 6–9
  minutes a summary, and the 14B was no better than the 8B and slower.
- **Gemma 4.** Measured the same way a day later, beside Qwen3.6 35B-A3B, Qwen3.5 4B and Qwen3 8B
  again. Serious mistakes over three summaries: Gemma 4 26B-A4B 1, Gemma 4 12B 5, Qwen3.6 35B-A3B
  5, Qwen3 8B 6, Qwen3.5 4B 13. The same models scored very differently from one day to the next
  (the 8B 17, then 6), so one call doesn't rank models a few mistakes apart, and the defaults
  stayed as they were. The 26B-A4B was the quickest, about 77 seconds on an M3 Pro, but its
  summaries were the shortest (415–600 words, to 670–750 for the 35B-A3B), and its to-do lists
  left out a commitment that every other model found. The 12B took about 180 seconds. With
  reasoning on, both took two to three times as long.

- **Where it comes from.** Hugging Face, at a fixed revision (`LocalModels` in
  `Sources/OatcakeCore/LocalModel.swift`): Qwen's own GGUF files for Qwen3, Google's own for
  Gemma 4 (trained for Q4_0), and llama.cpp's own
  conversions (ggml-org) for Qwen3.5 and Qwen3.6, which Qwen publishes only as weights. Each
  ggml-org file was checked by converting Qwen's weights again with llama.cpp's published steps:
  most tensors came out identical and the rest differed only in rounding, no further from Qwen's
  weights than ours. The file is checked against its
  SHA-256 when it has downloaded, and again before the model is started whenever its size or
  modification date has changed since it last passed; one that doesn't match is thrown away and
  downloaded again the next time it's needed. A download that's interrupted carries on from where
  it stopped. Settings › Models shows how far it has got, downloads it on request and removes it.
- **What runs it.** llama.cpp's server, inside Oatcake.app (MIT; the build is named in
  `Scripts/bundle.sh`, which checks it against its SHA-256; before each start Oatcake checks that
  its signature over the app still covers the server and its libraries: see
  [Security](security.md)). Oatcake starts it when there's something to write, on 127.0.0.1 at a port
  picked for the occasion, with a key made up each time so that a web page or another account on
  the Mac can't use it, and stops it after ten minutes with nothing to do, which gives its memory
  back.
- **How it's asked.** As each model's makers advise: its own sampling settings, never greedy
  decoding and room for a long reply. Whether it reasons before it replies is set for each task
  (Settings › Summaries), and choosing a model in Settings › Models sets the switches to what
  suits it, saying which changed. Qwen3.5, Qwen3.6 and Gemma 4 start with all of them off: Qwen's
  reason for 6,000–10,000 tokens before a summary, minutes on a slower Mac, and their summaries
  were no better for it; Gemma 4 took two to three times as long. With it off, Qwen3.5 4B leaves voices for you to name rather than suggest names;
  with it on it suggests them, but takes several minutes. Qwen3 starts with it on for summaries,
  name suggestions and Ask, where it measured better (decisions given to the right person, fewer
  invented names, answers that keep to the question), and off for to-dos, which lost detail with
  it; drafts for sharing start on too, as summaries do (not measured). A server of your own is
  told only once you've chosen the
  switch it takes (Settings › Models › Reasoning switch: Ollama's `reasoning_effort` or llama.cpp's
  `enable_thinking`); until then it decides for itself. The summary and the to-dos are
  two requests about the same transcript, each with its task after the transcript; the to-dos,
  the name suggestions and Ask's first step come back as JSON the server holds to a schema, sent
  as it's written: the model fills in the fields in the schema's order, and a to-do's task has to
  come before its time (time first, it makes a to-do of every few minutes of the call). The
  summary's instructions are yours to change, and so is what counts as a to-do (Settings › Summaries).
- **How much it reads at once.** As little as the job needs, up to what this Mac's memory allows
  (the 35B-A3B takes about 21 GB plus 0.02 GB for every thousand tokens, the 3.5 4B about 3 GB plus
  0.03, Gemma 4 26B-A4B about 15.5 GB plus 0.03, Gemma 4 12B about 8.5 GB plus 0.02, the Qwen3 8B
  about 5 GB plus 0.14; an hour's call is around 12,000). Qwen3.5, Qwen3.6 and Gemma 4 read
  262,144 tokens natively, more than Oatcake ever sends. Qwen3 reads 32,768; a longer call
  stretches that with YaRN, by no more than it needs. A server of your own is sent as much at once as you've told Oatcake it holds
  (Settings › Models › Context), or 32,768 tokens. A call too long for this Mac (or for that
  server) is summarised in parts, which are then joined.
- **A model of your own.** Any server with the same chat API on this Mac or your network (Ollama,
  LM Studio, your own llama.cpp). Oatcake only talks to a local address, and sends no key. It
  doesn't follow a redirect from that address to another (the redirect is reported as an error). It
  sends none of Oatcake's sampling settings either: the server's own apply, as they suit its model.
  Each request still says how long the reply may be and, where one is needed, the JSON shape.

Changing the model or llama.cpp's build is a deliberate change, like the speech models: change the
revision and checksum together, then check summaries, to-dos and names on a known call.

Parakeet and Bark give each word's time, so a line that two people share is split between them.
SenseVoice gives a stretch of speech (up to 14 seconds) as text alone, so the whole stretch goes to
the voice that said most of it. It's asked for punctuation (FluidAudio leaves it out unless asked),
and a stretch it returns nothing for, not even a language, is tried again in two halves: one
Japanese test sentence came back empty until it was. Checked with synthesised speech (`say`), not
real calls:

- **Bark 3.0 Clean** wrote the English test passage exactly, with punctuation. On LibriSpeech its
  makers measure it a little behind Parakeet v3 (4.66% of words wrong on test-other, to 4.12%);
  it's meant for conversation, which LibriSpeech isn't. The verbatim Bark 3.0 isn't offered: it
  wrote the same passage without capitals or punctuation.
- **SenseVoice** got the Chinese and Japanese test sentences nearly right, with a word or two
  misheard (迁移 as 签移), the Korean with a repeated syllable, and English noticeably worse than
  Parakeet ("morning oil" for "morning all").

## Accuracy


On two AMI meetings with four known speakers (ES2004a and IS1009a, 14–17 minutes each),
FluidAudio found all four people both times and gave 76–78% of speech to the right voice; the
Electron version's sherpa-onnx pipeline found five at 59% on the same audio and scoring.
Voiceprints from one meeting scored 0.85–0.95 against the same person in another (ES2004c) and
at most 0.34 against anyone else; a match needs 0.6 and a lead of 0.1 over the next person.
Expect to merge a split voice now and then, and to mark a voice "mixed" when two people sound
alike.

The live transcript names voices one line at a time, by the same rule. Replaying ES2004c (39
minutes) as a call, with voiceprints from ES2004a, 91% of the speaking time was named right and 1%
wrong (a line two people shared). With nobody known and one line of 4 s or more named by hand for
each person, 91% was right and none wrong; when the lines named were only 2 s, 75% was right.
Lines under 2 s mostly stay unnamed. Fingerprinting the lines took 15–22 ms each, about 6 s of CPU
over the 39 minutes, and the helper used about 180 MB more memory at its peak. It fingerprints one
window at a time: at FluidAudio's default of 32, its peaks reached 650 MB.
