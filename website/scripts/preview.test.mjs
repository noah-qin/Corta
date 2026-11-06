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

import { test } from "bun:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createPreviewServer } from "./preview.mjs";

test("preview serves MP4 probes, seeks and HEAD with exact byte boundaries", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "corta-preview-"));
  const content = Buffer.from("0123456789");
  fs.writeFileSync(path.join(root, "demo.mp4"), content);
  fs.writeFileSync(path.join(root, "404.html"), "Not found");
  const server = createPreviewServer(root, "/Corta");
  try {
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const url = `http://127.0.0.1:${server.address().port}/Corta/demo.mp4`;
    const full = await fetch(url);
    assert.equal(full.status, 200);
    assert.equal(full.headers.get("content-type"), "video/mp4");
    assert.equal(full.headers.get("accept-ranges"), "bytes");
    assert.equal(full.headers.get("content-length"), "10");
    assert.deepEqual(Buffer.from(await full.arrayBuffer()), content);
    const head = await fetch(url, { method: "HEAD" });
    assert.equal(head.status, 200);
    assert.equal(head.headers.get("content-length"), "10");
    assert.equal((await head.arrayBuffer()).byteLength, 0);
    for (const [range, expected, boundary] of [
      ["bytes=0-1", "01", "bytes 0-1/10"],
      ["bytes=5-", "56789", "bytes 5-9/10"],
      ["bytes=-3", "789", "bytes 7-9/10"],
      ["bytes=7-99", "789", "bytes 7-9/10"],
    ]) {
      const response = await fetch(url, { headers: { Range: range } });
      assert.equal(response.status, 206, range);
      assert.equal(response.headers.get("content-type"), "video/mp4");
      assert.equal(response.headers.get("content-range"), boundary, range);
      assert.equal(
        response.headers.get("content-length"),
        String(expected.length),
      );
      assert.equal(await response.text(), expected, range);
    }
    for (const range of [
      "bytes=10-",
      "bytes=6-2",
      "bytes=-0",
      "bytes=-",
      "bytes=invalid",
    ]) {
      const response = await fetch(url, { headers: { Range: range } });
      assert.equal(response.status, 416, range);
      assert.equal(response.headers.get("content-range"), "bytes */10");
      assert.equal(await response.text(), "");
    }
    const multiple = await fetch(url, { headers: { Range: "bytes=0-1,4-5" } });
    assert.equal(multiple.status, 200);
    assert.deepEqual(Buffer.from(await multiple.arrayBuffer()), content);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  }
});
