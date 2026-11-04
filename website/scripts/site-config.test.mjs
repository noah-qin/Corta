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
import { spawnSync, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  sourceDates,
  descriptionFromIntroduction,
} from "./content-metadata.mjs";
import { unified } from "unified";
import parse from "remark-parse";
function config(env) {
  return spawnSync(
    process.execPath,
    [
      "-e",
      "import {getSiteOrigin,basePath} from './scripts/site-config.mjs'; console.log(JSON.stringify({origin:getSiteOrigin(),basePath}));",
    ],
    {
      cwd: process.cwd(),
      encoding: "utf8",
      env: {
        ...process.env,
        CI: "",
        WEBSITE_DEPLOYMENT: "",
        SITE_URL: "",
        NEXT_PUBLIC_BASE_PATH: "",
        ...env,
      },
    },
  );
}
test("deployment rejects absent/local/non-HTTPS/ambiguous origins", () => {
  for (const value of [
    "",
    "http://example.com",
    "https://localhost",
    "https://localhost.",
    "https://127.0.0.1",
    "https://[::1]",
    "https://example.com/Corta",
    "https://user:password@example.com",
    "https://example.com?preview=1",
  ]) {
    const result = config({ CI: "true", SITE_URL: value });
    assert.notEqual(result.status, 0, `accepted ${value}`);
  }
});
test("project paths and custom domains retain one origin and one basePath", () => {
  for (const [origin, basePath] of [
    ["https://noah-qin.github.io", "/Corta"],
    ["https://corta.example", ""],
  ]) {
    const result = config({
      CI: "true",
      SITE_URL: origin,
      NEXT_PUBLIC_BASE_PATH: basePath,
    });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), { origin, basePath });
  }
  const local = config({});
  assert.equal(local.status, 0, local.stderr);
  assert.equal(JSON.parse(local.stdout).origin, "http://localhost:3000");
  for (const basePath of ["Corta", "/../Corta", "/Corta?x=1", "//host"]) {
    assert.notEqual(
      config({ NEXT_PUBLIC_BASE_PATH: basePath }).status,
      0,
      `accepted ${basePath}`,
    );
  }
});
test("description selects prose, excluding navigation and provenance", () => {
  const tree = unified()
    .use(parse)
    .parse(
      "# Guide\n\n[Documentation index](README.md) · [Overview](../README.md)\n\n> Translated from an older commit.\n\nThis is the useful guide introduction, containing instructions for terminal users.\n\n## Another section\n\nThis is not the introduction.",
    );
  assert.equal(
    descriptionFromIntroduction(tree, "guide.md"),
    "This is the useful guide introduction, containing instructions for terminal users.",
  );
});
test("lastmod is a committed source date; dirty, new and non-Git sources omit it", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "corta-seo-dates-"));
  const git = (...args) =>
    execFileSync("git", args, {
      cwd: root,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      env: {
        ...process.env,
        GIT_AUTHOR_DATE: "2024-01-02T03:04:05Z",
        GIT_COMMITTER_DATE: "2024-01-02T03:04:05Z",
      },
    });
  try {
    fs.writeFileSync(path.join(root, "guide.md"), "# Original\n");
    assert.equal(sourceDates(root)("guide.md"), undefined);
    git("init", "-q");
    git("add", "guide.md");
    git(
      "-c",
      "user.name=Website test",
      "-c",
      "user.email=website-test@example.invalid",
      "commit",
      "-qm",
      "Fixture source",
    );
    assert.equal(sourceDates(root)("guide.md"), "2024-01-02T03:04:05.000Z");
    fs.appendFileSync(path.join(root, "guide.md"), "\nChanged locally\n");
    assert.equal(sourceDates(root)("guide.md"), undefined);
    fs.writeFileSync(path.join(root, "new.md"), "# New");
    assert.equal(sourceDates(root)("new.md"), undefined);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
