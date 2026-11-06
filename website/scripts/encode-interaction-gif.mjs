// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

// node website/scripts/encode-interaction-gif.mjs frames.rgba output.gif
// Input: 150 consecutive 960 × 588 RGBA frames from render-interaction-demo.
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
const require = createRequire(new URL("../package.json", import.meta.url));
const sharp = require("sharp");
const [input, output] = process.argv.slice(2);
if (!input || !output)
  throw new Error("Usage: encode-interaction-gif.mjs frames.rgba output.gif");
const width = 960,
  height = 588,
  frames = 150;
const raw = await readFile(input);
if (raw.length !== width * height * frames * 4)
  throw new Error("Unexpected raw frame length");
await sharp(raw, {
  raw: { width, height: height * frames, channels: 4, pageHeight: height },
})
  .gif({
    colours: 128,
    dither: 0.25,
    effort: 7,
    interFrameMaxError: 1,
    loop: 0,
    delay: Array.from({ length: frames }, (_, i) => [70, 60, 70][i % 3]),
  })
  .toFile(output);
console.log(`Encoded ${frames} frames to ${output}`);
