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
import http from "node:http";
import path from "node:path";

const root = path.resolve("out");
const base = (process.env.NEXT_PUBLIC_BASE_PATH || "").replace(/\/$/, "");
const port = Number(process.env.PORT || 3001);
const types = {
  ".mp4": "video/mp4",
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".png": "image/png",
  ".webp": "image/webp",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".avif": "image/avif",
  ".xml": "application/xml; charset=utf-8",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".txt": "text/plain; charset=utf-8",
};
export function createPreviewServer(directory = root, prefix = base) {
  const root = path.resolve(directory);
  const base = prefix.replace(/\/$/, "");
  if (!fs.existsSync(root))
    throw Error("Run bun run build before starting the static preview.");
  return http.createServer((req, res) => {
    let url;
    try {
      url = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
    } catch {
      res.writeHead(400).end();
      return;
    }
    if (base && url !== base && !url.startsWith(`${base}/`)) {
      res.writeHead(404).end();
      return;
    }
    url = url.slice(base.length) || "/";
    let file = path.resolve(root, `.${url}`);
    if (!file.startsWith(root + path.sep) && file !== root) {
      res.writeHead(403).end();
      return;
    }
    if (fs.existsSync(file) && fs.statSync(file).isDirectory())
      file = path.join(file, "index.html");
    if (!fs.existsSync(file)) {
      res.writeHead(404, { "Content-Type": "text/html; charset=utf-8" });
      res.end(fs.readFileSync(path.join(root, "404.html")));
      return;
    }
    const size = fs.statSync(file).size;
    const headers = {
      "Content-Type": types[path.extname(file)] || "application/octet-stream",
      "Cache-Control": "no-store",
      "Accept-Ranges": "bytes",
      "Content-Length": size,
    };
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.writeHead(405, { Allow: "GET, HEAD" }).end();
      return;
    }
    // HEAD describes the complete representation without opening a body stream.
    if (req.method === "HEAD") {
      res.writeHead(200, headers).end();
      return;
    }
    let start = 0,
      end = size - 1,
      status = 200;
    const range = req.headers.range;
    // Single byte ranges cover media probes/seeks. Ignore unsupported multi-ranges.
    if (range && !range.includes(",") && range.startsWith("bytes=")) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(range);
      const first = match?.[1],
        last = match?.[2];
      if (first) {
        start = Number(first);
        end = last ? Math.min(Number(last), size - 1) : size - 1;
      } else if (last) {
        start = Math.max(0, size - Number(last));
      }
      if (
        !match ||
        (!first && !last) ||
        !Number.isSafeInteger(start) ||
        !Number.isSafeInteger(end) ||
        start >= size ||
        end < start
      ) {
        res
          .writeHead(416, {
            ...headers,
            "Content-Range": `bytes */${size}`,
            "Content-Length": 0,
          })
          .end();
        return;
      }
      status = 206;
      headers["Content-Range"] = `bytes ${start}-${end}/${size}`;
      headers["Content-Length"] = end - start + 1;
    }
    res.writeHead(status, headers);
    if (size === 0) {
      res.end();
      return;
    }
    const stream = fs.createReadStream(file, { start, end });
    stream.on("error", (error) => res.destroy(error));
    res.on("close", () => stream.destroy());
    stream.pipe(res);
  });
}

if (import.meta.main) {
  createPreviewServer().listen(port, "127.0.0.1", () =>
    console.log(`Static preview: http://localhost:${port}${base}/`),
  );
}
