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

// End-to-end static-export integrity check, including translated and fallback routes.
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import sharp from "sharp";
import { basePath as configuredBase, getSiteOrigin } from "./site-config.mjs";
const root = path.resolve("out");
const base = configuredBase;
const origin = getSiteOrigin();
const manifest = JSON.parse(
  fs.readFileSync("src/generated/manifest.json", "utf8"),
);
const htmlFiles = [];
function scan(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const f = path.join(dir, entry.name);
    if (entry.isDirectory()) scan(f);
    else if (f.endsWith(".html")) htmlFiles.push(f);
  }
}
scan(root);
const cache = new Map(
  htmlFiles.map((file) => {
    const html = fs.readFileSync(file, "utf8");
    return [
      file,
      {
        html,
        ids: new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1])),
      },
    ];
  }),
);
let links = 0,
  images = 0;
const issues = [];
for (const [file, { html }] of cache) {
  // Inspect server HTML before a browser silently repairs invalid nested anchors.
  const markup = html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, "");
  let anchorDepth = 0;
  for (const tag of markup.matchAll(/<\/?a\b[^>]*>/gi)) {
    if (/^<\//.test(tag[0])) anchorDepth = Math.max(0, anchorDepth - 1);
    else {
      if (anchorDepth > 0)
        issues.push(
          `${path.relative(root, file)}: nested anchor (hydration risk)`,
        );
      anchorDepth++;
    }
  }
  for (const m of html.matchAll(/\b(href|src)="([^"]+)"/g)) {
    const [_, attr, encoded] = m;
    const url = encoded.replaceAll("&amp;", "&");
    if (/^(?:[a-z][\w+.-]*:|\/\/)/i.test(url) || !url || url === "#") continue;
    const current =
      base + "/" + path.relative(root, file).replace(/index\.html$/, "");
    const parsed = new URL(url, "http://local" + current);
    if (!parsed.pathname.startsWith(base + "/") && base) {
      issues.push(`${file}: missing base path ${url}`);
      continue;
    }
    let target = path.resolve(
      root,
      "." + decodeURIComponent(parsed.pathname.slice(base.length)),
    );
    if (fs.existsSync(target) && fs.statSync(target).isDirectory())
      target = path.join(target, "index.html");
    if (!fs.existsSync(target)) {
      issues.push(`${path.relative(root, file)}: missing ${url}`);
      continue;
    }
    if (attr === "src") images++;
    else links++;
    if (
      parsed.hash &&
      cache.has(target) &&
      !cache.get(target).ids.has(decodeURIComponent(parsed.hash.slice(1)))
    )
      issues.push(`${path.relative(root, file)}: missing anchor ${url}`);
  }
}
const decode = (value) =>
  value.replace(
    /&(?:amp|quot|apos|lt|gt|#(?:x[0-9a-f]+|[0-9]+));/gi,
    (entity) => {
      const named = {
        "&amp;": "&",
        "&quot;": '"',
        "&apos;": "'",
        "&lt;": "<",
        "&gt;": ">",
      };
      return (
        named[entity] ??
        String.fromCodePoint(
          parseInt(
            entity.slice(entity[2] === "x" ? 3 : 2, -1),
            entity[2] === "x" ? 16 : 10,
          ),
        )
      );
    },
  );
const attributes = (tag) =>
  Object.fromEntries(
    [...tag.matchAll(/([\w:-]+)="([^"]*)"/g)].map((m) => [
      m[1].toLowerCase(),
      decode(m[2]),
    ]),
  );
const elements = (html, name) =>
  [...html.matchAll(new RegExp(`<${name}\\b[^>]*>`, "gi"))].map((m) =>
    attributes(m[0]),
  );
const pagePath = (lang, slug = "") =>
  `${base}/${lang}/${slug ? (slug === "changelog" ? "changelog/" : `docs/${slug}/`) : ""}`;
const expectedUrls = new Map([[`${origin}${base}/`, undefined]]);
const expectedLanguages = (slug) =>
  Object.fromEntries(
    manifest.languages
      .filter((l) =>
        slug
          ? manifest.pages[`${l.code}/${slug}`].contentLang === l.code
          : manifest.home[l.code].contentLang === l.code,
      )
      .map((l) => [l.code, origin + pagePath(l.code, slug)]),
  );
for (const [file, { html }] of cache) {
  for (const set of html.matchAll(/\bsrcSet="([^"]+)"/gi))
    for (const candidate of decode(set[1]).split(",")) {
      const [url, width] = candidate.trim().split(/\s+/);
      assert.match(width, /^\d+w$/);
      const relative = new URL(url, origin).pathname.slice(base.length);
      const target = path.join(root, relative);
      assert.ok(fs.existsSync(target), `Missing responsive image ${url}`);
    }
}
for (const language of manifest.languages) {
  const lang = language.code;
  for (const slug of ["", ...manifest.documents.map((d) => d.slug)]) {
    const route = slug
      ? slug === "changelog"
        ? "changelog"
        : `docs/${slug}`
      : "";
    const file = path.join(root, lang, route, "index.html");
    const html = cache.get(file)?.html;
    assert.ok(html, `${lang}/${slug} missing`);
    assert.ok(
      html.includes(`<html lang="${lang}"`),
      `${lang}/${slug}: html lang`,
    );
    const info = slug ? manifest.pages[`${lang}/${slug}`] : manifest.home[lang];
    const links = elements(html, "link");
    const metas = elements(html, "meta");
    const canonical = links.find((l) => l.rel === "canonical")?.href;
    assert.equal(
      canonical,
      origin + pagePath(info.contentLang, slug),
      `${lang}/${slug}: canonical source language`,
    );
    const description = metas.find((m) => m.name === "description")?.content;
    assert.equal(
      description,
      slug ? info.description : info.title,
      `${lang}/${slug}: source description`,
    );
    const alternates = Object.fromEntries(
      links
        .filter((l) => l.rel === "alternate" && l.hreflang)
        .map((l) => [l.hreflang, l.href]),
    );
    const expected = expectedLanguages(slug);
    if (!slug) expected["x-default"] = `${origin}${base}/`;
    assert.deepEqual(
      alternates,
      expected,
      `${lang}/${slug}: real hreflang variants`,
    );
    if (info.contentLang === lang)
      expectedUrls.set(canonical, info.lastModified);
    if (slug && info.contentLang !== lang) {
      const original = cache.get(
        path.join(
          root,
          "en",
          slug === "changelog" ? "changelog" : `docs/${slug}`,
          "index.html",
        ),
      ).html;
      assert.equal(
        html.match(/<title>(.*?)<\/title>/s)?.[1],
        original.match(/<title>(.*?)<\/title>/s)?.[1],
        `${lang}/${slug}: fallback title language`,
      );
    }
    if (!slug) {
      const screenshot = elements(html, "img").find((i) => i.srcset);
      assert.equal(Number(screenshot?.width), manifest.images.screenshot.width);
      assert.equal(
        Number(screenshot?.height),
        manifest.images.screenshot.height,
      );
    }
    if (slug) {
      const info = manifest.pages[`${lang}/${slug}`];
      if (info.contentLang !== lang) {
        assert.ok(
          html.includes("notice fallback"),
          `${lang}/${slug}: fallback absent`,
        );
        assert.ok(
          html.includes('<article class="prose" lang="en"'),
          `${lang}/${slug}: content lang`,
        );
        assert.ok(
          !html.includes(
            `hrefLang="${lang}" href="${process.env.SITE_URL || "http://localhost:3000"}${base}/${lang}/${route}/"`,
          ),
          "fallback incorrectly listed as translated hreflang",
        );
      }
    }
  }
}
const chooser = cache.get(path.join(root, "index.html")).html;
assert.equal(
  elements(chooser, "link").find((l) => l.rel === "canonical")?.href,
  `${origin}${base}/`,
);
assert.equal(
  elements(chooser, "link").find((l) => l.hreflang === "x-default")?.href,
  `${origin}${base}/`,
);
const xml = fs.readFileSync(path.join(root, "sitemap.xml"), "utf8");
const sitemapEntries = [...xml.matchAll(/<url>([\s\S]*?)<\/url>/g)].map(
  (match) => ({
    url: decode(match[1].match(/<loc>(.*?)<\/loc>/)?.[1] || ""),
    date: match[1].match(/<lastmod>(.*?)<\/lastmod>/)?.[1],
  }),
);
assert.deepEqual(
  new Set(sitemapEntries.map((e) => e.url)),
  new Set(expectedUrls.keys()),
  "sitemap contains exactly the canonical pages and real translations",
);
assert.equal(
  sitemapEntries.length,
  expectedUrls.size,
  "duplicate sitemap entries",
);
for (const entry of sitemapEntries)
  assert.equal(
    entry.date,
    expectedUrls.get(entry.url),
    `${entry.url}: true source lastmod`,
  );
const robots = fs.readFileSync(path.join(root, "robots.txt"), "utf8");
assert.ok(robots.includes(`Sitemap: ${origin}${base}/sitemap.xml`));
for (const variant of manifest.images.screenshot.variants) {
  const image = await sharp(
    path.join(root, "content-assets/docs/brand", variant.file),
  ).metadata();
  assert.equal(image.width, variant.width);
  assert.equal(image.format, "webp");
}
console.log(
  `Verified SEO metadata, ${sitemapEntries.length} canonical sitemap URLs, committed-source dates, and responsive WebP assets.`,
);
if (issues.length) {
  console.error([...new Set(issues)].slice(0, 100).join("\n"));
  console.error(`${issues.length} local link/anchor issues`);
  process.exit(1);
}
console.log(
  `Verified ${manifest.languages.length} languages, ${manifest.languages.length * (manifest.documents.length + 1)} localized pages, ${links} internal links and ${images} image/resource references. All local targets and anchors resolve.`,
);
