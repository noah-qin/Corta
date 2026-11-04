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

import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { contentRoot, generate } from "./generate-content.mjs";
await generate();
let timer;
let refreshing = false,
  pending = false;
async function refresh() {
  if (refreshing) {
    pending = true;
    return;
  }
  refreshing = true;
  do {
    pending = false;
    try {
      await generate();
      console.log("[content] refreshed");
    } catch (error) {
      console.error("[content]", error.message);
    }
  } while (pending);
  refreshing = false;
}

function update() {
  clearTimeout(timer);
  timer = setTimeout(refresh, 180);
}
const watchers = [
  fs.watch(path.join(contentRoot, "docs"), { recursive: true }, update),
  fs.watch(contentRoot, (event, file) => {
    if (["README.md", "CHANGELOG.md"].includes(String(file))) update();
  }),
];
const child = spawn(
  "bun",
  [
    "--bun",
    "next",
    "dev",
    "--webpack",
    "--hostname",
    "127.0.0.1",
    ...process.argv.slice(2),
  ],
  { stdio: "inherit", env: process.env },
);
function stop(signal) {
  watchers.forEach((w) => w.close());
  child.kill(signal);
}
process.on("SIGINT", () => stop("SIGINT"));
process.on("SIGTERM", () => stop("SIGTERM"));
child.on("exit", (code) => {
  watchers.forEach((w) => w.close());
  process.exit(code ?? 0);
});
