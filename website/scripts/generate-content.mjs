import fs from "node:fs";
import sharp from "sharp";
import {
  descriptionFromIntroduction,
  sourceDates,
} from "./content-metadata.mjs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { unified } from "unified";
import parse from "remark-parse";
import gfm from "remark-gfm";
import stringify from "remark-stringify";
import GithubSlugger from "github-slugger";
import {
  languages,
  documents,
  repository,
  route,
  basePath,
} from "./content.config.mjs";
const website = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
// Explicit override for external checkout; ../ is the future monorepo default.
export const contentRoot = path.resolve(
  website,
  process.env.CORTA_CONTENT_DIR || "..",
);
const output = path.join(website, "src/generated");
const assets = path.join(website, "public/content-assets");
const parser = unified().use(parse).use(gfm);
const writer = unified().use(stringify).use(gfm);
const plain = (node) => node.value ?? node.children?.map(plain).join("") ?? "";
const read = (file) => fs.readFileSync(path.join(contentRoot, file), "utf8");
const exists = (file) => fs.existsSync(path.join(contentRoot, file));
function source(lang, doc) {
  const p = `docs/i18n/${lang}/${doc.translation}`;
  return lang !== "en" && doc.translation && exists(p) ? p : doc.file;
}
function walk(node, fn) {
  fn(node);
  node.children?.forEach((n) => walk(n, fn));
}
function writeChanged(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (!fs.existsSync(file) || fs.readFileSync(file, "utf8") !== data) {
    fs.writeFileSync(file, data);
    return true;
  }
  return false;
}
function section(tree, name) {
  const start = tree.children.findIndex(
    (n) => n.type === "heading" && n.depth === 2 && plain(n) === name,
  );
  if (start < 0) throw Error(`Missing declared homepage section: ${name}`);
  const end = tree.children.findIndex(
    (n, i) => i > start && n.type === "heading" && n.depth <= 2,
  );
  return tree.children.slice(start + 1, end < 0 ? undefined : end);
}
export async function generate() {
  if (!exists("README.md"))
    throw Error("Set CORTA_CONTENT_DIR to a Corta checkout (see README).");
  fs.mkdirSync(output, { recursive: true });
  fs.mkdirSync(assets, { recursive: true });
  const fileRoutes = new Map();
  for (const doc of documents) {
    fileRoutes.set(doc.file, {
      lang: "en",
      slug: doc.slug,
      translated: !!doc.translation,
    });
    if (doc.translation)
      for (const lang of languages.filter((l) => l.code !== "en")) {
        // Keep links to a deleted/missing translation on its localized fallback route.
        fileRoutes.set(`docs/i18n/${lang.code}/${doc.translation}`, {
          lang: lang.code,
          slug: doc.slug,
          translated: true,
        });
      }
  }
  const dateFor = sourceDates(contentRoot);
  const copied = new Set();
  const generated = new Set([
    "registry.ts",
    "manifest.json",
    "image-cache.json",
  ]);
  const metadata = {
    languages,
    documents,
    pages: {},
    home: {},
    images: {},
    release: read("CHANGELOG.md").match(/^## \[([\d.]+)\]/m)?.[1] || "",
  };
  let imports = "",
    registry = "";
  let count = 0;
  const convert = (url, file, lang, image = false) => {
    if (/^(?:[a-z][a-z\d+.-]*:|\/\/|#)/i.test(url)) return url;
    const [pathname, ...tail] = url.split(/(?=[?#])/);
    const suffix = tail.join("");
    const target = path.posix.normalize(
      path.posix.join(path.posix.dirname(file), decodeURI(pathname)),
    );
    if (target.startsWith("../") || path.posix.isAbsolute(target))
      throw Error(`Unsafe content URL: ${file}: ${url}`);
    const match = fileRoutes.get(target);
    if (match) {
      // Links explicitly back to an English original from a translation must stay English.
      const explicitEnglish =
        file.startsWith("docs/i18n/") &&
        match.lang === "en" &&
        match.translated;
      return (
        route(
          explicitEnglish ? "en" : match.lang === "en" ? lang : match.lang,
          match.slug,
        ) + suffix
      );
    }
    if (image || /\.(png|gif|jpe?g|svg|webp|avif)$/i.test(target)) {
      if (!exists(target)) throw Error(`Missing asset: ${target}`);
      const dest = path.join(assets, target);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      if (
        !fs.existsSync(dest) ||
        !fs
          .readFileSync(dest)
          .equals(fs.readFileSync(path.join(contentRoot, target)))
      )
        fs.copyFileSync(path.join(contentRoot, target), dest);
      copied.add(target);
      return `${basePath}/content-assets/${target}${suffix}`;
    }
    return `${repository}/blob/main/${target}${suffix}`;
  };
  for (const lang of languages) {
    for (const doc of documents) {
      const file = source(lang.code, doc);
      const raw = read(file);
      const tree = parser.parse(raw);
      const slugger = new GithubSlugger();
      const toc = [];
      walk(tree, (n) => {
        if (n.type === "heading") {
          const title = plain(n);
          const id = slugger.slug(title);
          if (n.depth <= 3) toc.push({ title, id, depth: n.depth });
        }
        if (n.url) n.url = convert(n.url, file, lang.code, n.type === "image");
        if (n.type === "html")
          n.value = n.value.replace(
            /\b(src|href)=(['"])(.*?)\2/g,
            (_, attr, q, url) =>
              `${attr}=${q}${convert(url, file, lang.code, attr === "src")}${q}`,
          );
      });
      const key = `${lang.code}/${doc.slug}`;
      const name = `${lang.code}--${doc.slug}.md`;
      generated.add(name);
      writeChanged(path.join(output, name), writer.stringify(tree));
      imports += `import Content${count} from './${name}';\n`;
      registry += `${JSON.stringify(key)}: Content${count++},\n`;
      metadata.pages[key] = {
        file,
        contentLang: file.startsWith("docs/i18n/") ? lang.code : "en",
        title: toc[0]?.title || doc.slug,
        description: descriptionFromIntroduction(tree, file),
        lastModified: dateFor(file),
        toc,
        hash: createHash("sha256").update(raw).digest("hex"),
      };
      if (doc.slug === "overview") {
        const original = parser.parse(raw);
        const homeLanguage = file === "README.md" ? languages[0] : lang;
        const heroes = original.children.filter(
          (n) =>
            n.type === "paragraph" &&
            n.children.length === 1 &&
            n.children[0].type === "strong" &&
            plain(n).includes("Swift"),
        );
        if (heroes.length !== 1)
          throw Error(
            `Ambiguous homepage hero in ${file}; update semantic selector.`,
          );
        const features = section(tree, homeLanguage.features).find(
          (n) => n.type === "table",
        );
        if (!features) throw Error(`Missing homepage feature table in ${file}`);
        // Omit the benchmark row by its semantic key, not its location.
        const benchmark = /^(Fast,|快，|速さ|빠름|Schnell,|Rapide,|Rápido,)/;
        const cards = features.children.filter(
          (row) =>
            plain(row.children[0]) && !benchmark.test(plain(row.children[0])),
        );
        const title = plain(heroes[0]);
        const install = section(original, homeLanguage.install).find(
          (n) => n.type === "paragraph" && plain(n).includes("macOS"),
        );
        if (!install)
          throw Error(`Missing declared requirements paragraph: ${file}`);
        metadata.home[lang.code] = {
          title,
          lastModified: (() => {
            const dates = [
              file,
              "CHANGELOG.md",
              "docs/brand/screenshot.png",
              "docs/brand/corta-pangolin-mascot.png",
            ].map(dateFor);
            return dates.every(Boolean) ? dates.sort().at(-1) : undefined;
          })(),
          requirements: plain(install),
          section: homeLanguage.features,
          contentLang: homeLanguage.code,
        };
        metadata.pages[key].description = title;
        const homeTree = {
          type: "root",
          children: cards.flatMap((row) => [
            { type: "heading", depth: 3, children: row.children[0].children },
            { type: "paragraph", children: row.children[1].children },
          ]),
        };
        const provenance = tree.children.filter((node) => {
          if (node.type !== "blockquote") return false;
          let found = false;
          walk(node, (n) => {
            if (
              n.type === "link" &&
              /\/blob\/[0-9a-f]{7,40}\/README\.md/.test(n.url)
            )
              found = true;
          });
          return found;
        });
        if (homeLanguage.code !== "en" && provenance.length !== 1)
          throw Error(`Missing translation provenance: ${file}`);
        const provenanceName = `${lang.code}--provenance.md`;
        generated.add(provenanceName);
        writeChanged(
          path.join(output, provenanceName),
          writer.stringify({ type: "root", children: provenance }),
        );
        imports += `import Content${count} from './${provenanceName}';\n`;
        registry += `${JSON.stringify(`${lang.code}/provenance`)}: Content${count++},\n`;
        const homeName = `${lang.code}--home.md`;
        generated.add(homeName);
        writeChanged(path.join(output, homeName), writer.stringify(homeTree));
        imports += `import Content${count} from './${homeName}';\n`;
        registry += `${JSON.stringify(`${lang.code}/home`)}: Content${count++},\n`;
      }
    }
  }
  // Include brand assets used by the fixed homepage layout through the same pipeline.
  for (const file of [
    "docs/brand/corta-pangolin-mascot.png",
    "docs/brand/screenshot.png",
    "docs/brand/social-preview.png",
  ])
    convert(file, "README.md", "en", true);
  // Responsive derivatives are generated from the repository image, never edited by hand.
  const screenshotFile = "docs/brand/screenshot.png";
  const screenshotPath = path.join(contentRoot, screenshotFile);
  const original = await sharp(screenshotPath).metadata();
  if (!original.width || !original.height)
    throw new Error("Missing screenshot dimensions");
  const digest = createHash("sha256")
    .update(fs.readFileSync(screenshotPath))
    .update(`webp-88-${sharp.versions.sharp}`)
    .digest("hex");
  const cacheFile = path.join(output, "image-cache.json");
  const previous = fs.existsSync(cacheFile)
    ? JSON.parse(fs.readFileSync(cacheFile, "utf8"))
    : {};
  const variants = [];
  for (const width of [
    ...new Set(
      [480, 768, 1200, 1680, original.width].filter((w) => w <= original.width),
    ),
  ]) {
    const file = `screenshot-${width}.webp`;
    const relative = `docs/brand/${file}`;
    const target = path.join(assets, relative);
    if (previous.digest !== digest || !fs.existsSync(target)) {
      await sharp(screenshotPath)
        .resize({ width, withoutEnlargement: true })
        .webp({ quality: 88, effort: 4 })
        .toFile(target);
    }
    copied.add(relative);
    variants.push({ file, width });
  }
  metadata.images.screenshot = {
    width: original.width,
    height: original.height,
    variants,
    src: (variants.find((v) => v.width >= 1200) || variants.at(-1)).file,
  };
  writeChanged(cacheFile, JSON.stringify({ digest }) + "\n");
  writeChanged(
    path.join(output, "manifest.json"),
    JSON.stringify(metadata, null, 2) + "\n",
  );
  writeChanged(
    path.join(output, "registry.ts"),
    `${imports}\nimport type {ComponentType} from 'react';\nexport const content: Record<string,ComponentType> = {\n${registry}};\n`,
  );
  for (const f of fs.readdirSync(output))
    if (!generated.has(f)) fs.rmSync(path.join(output, f));
  function clean(dir, rel = "") {
    for (const f of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, f.name),
        r = path.posix.join(rel, f.name);
      if (f.isDirectory()) {
        clean(p, r);
        if (!fs.readdirSync(p).length) fs.rmdirSync(p);
      } else if (!copied.has(r)) fs.rmSync(p);
    }
  }
  clean(assets);
  return Object.keys(metadata.pages).length;
}
if (process.argv[1] === fileURLToPath(import.meta.url))
  console.log(
    `Prepared ${await generate()} document routes from configured Corta checkout.`,
  );
