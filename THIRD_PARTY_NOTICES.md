# Third-party notices

## OpenWhispr

`Sources/OatcakeRecorder/main.swift` adapts the Core Audio process tap from OpenWhispr's
`resources/macos-audio-tap.swift`. The echo-duplicate approach in
`Sources/OatcakeCore/Analysis.swift` follows OpenWhispr's `diarization.js`.

MIT License

Copyright (c) 2024 OpenWhispr Team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Loominate

`install.sh` adapts Loominate's installer (github.com/a8cteam51/loominate, by WordPress.com
Special Projects at Automattic), and the update design (a signed manifest on each GitHub
release, checking the new app against the running app's code-signing identity, swapping after
quit) follows Loominate's. Loominate is GPL-2.0-or-later, used here under GPL-3.0.

## FluidAudio

The speech pipeline uses FluidAudio (github.com/FluidInference/FluidAudio), linked into the app,
under the Apache License 2.0 (https://www.apache.org/licenses/LICENSE-2.0). It includes a port of
BUT's VBx clustering (Apache-2.0) and fastcluster, whose license follows.

### fastcluster

Copyright:
  * Until package version 1.1.23: © 2011 Daniel Müllner <https://danifold.net>
  * All changes from version 1.1.24 on: © Google Inc. <https://www.google.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Models (downloaded on first run, not bundled)

From FluidInference's Core ML conversions on Hugging Face:

- NVIDIA Parakeet TDT 0.6B v2 and Parakeet Ultra (moondream's post-training of v3): CC-BY-4.0
- pyannote speaker-diarization-community-1 (segmentation and WeSpeaker-based embedding): CC-BY-4.0
- Silero VAD: MIT
