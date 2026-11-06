# Corta website

This is the website source in the Corta repository. Markdown in the repository root and `docs/` is the only maintained document-content source. There is no nested Git repository.

## Local preview

From the Corta root:

```sh
cd website
bun install --frozen-lockfile
bun run dev
```

Open http://localhost:3000/zh-CN/ or `/en/`; `/` is the language chooser. No `.env.local` is needed: `CORTA_CONTENT_DIR` defaults to `..`, relative to this website directory. An optional override can point to a different checkout using a relative path.

The development wrapper prepares content before Next starts, then watches root README/CHANGELOG and all of `docs/`. Edits, translation additions/deletions and referenced image changes regenerate only changed output; Next updates the preview. Regeneration is serialized, including responsive-image processing. Restart development after changing generator code or environment variables.

```sh
bun run build    # Markdown preparation and static export to out/
bun run check    # TypeScript
bun run test     # origin/basePath, source-date and prose-extraction regression tests
bun run verify   # HTML/links/anchors, SEO, sitemap, responsive assets
bun run start    # static production preview at http://localhost:3001/
```

`bun run dev --port 3002` and `PORT=3002 bun run start` select a different port. Both servers bind loopback. The development preview watches documents; the static `out/` preview changes only after a new build. `next start` is not used because no production server is required.

## Content and languages

`scripts/content.config.mjs` is the explicit publication manifest and locale/path map: overview, documentation index, user guide, features, configuration, troubleshooting, performance, conformance, security, brand assets and changelog. Other repository Markdown is not automatically published; links to it resolve to GitHub.

The nine languages match the existing repository: English, 简体中文, 繁體中文, 日本語, 한국어, Deutsch, Français, Español and Português (Brasil). Existing translated overview/user guide/troubleshooting files are read from `docs/i18n/<locale>/`. Missing translations show English with a localized notice and article `lang=en`. UI translations, including localized homepage titles, live in `src/lib/i18n.ts`; document text is never translated/generated/overwritten. Source-commit and freshness notices are retained in both overview pages and the homepage. Switching language preserves the page, without carrying a fragment whose translated heading might differ. Explicit English-original links stay English.

The fixed homepage reads semantic AST selectors: the unique strong introduction mentioning Swift, the feature table beneath the locale's declared heading, and the requirements paragraph mentioning macOS beneath the declared install heading. Missing/ambiguous content fails preparation. The benchmark feature row is omitted by its label to preserve measurement context in the full reference. The displayed version comes from the first numeric CHANGELOG release heading and is labelled as a recorded version, rather than an online release lookup. Screenshots and feature notices explicitly refer to the main development tree, with Unreleased linked.

`src/generated/` and `public/content-assets/` are generated and ignored. They are not a second maintained content source. Preparation rewrites Markdown/reference/HTML links, copies referenced assets, computes TOCs, preserves explicit anchors and removes obsolete output. Required English documents must be removed from the manifest when retired. Optional translation deletion falls back to English and removes its translated SEO entry. Referenced missing images fail the build.

`@next/mdx` matches Next 16.4.5. The loader uses `format: 'md'`, `remark-gfm`, `rehype-raw` and `rehype-slug`: existing HTML remains renderable and ordinary Markdown is not executed as MDX expressions. Heading source links and the `#` permalink are siblings, preventing nested-anchor hydration failures. Raw exported HTML is checked before browser repairs could hide invalid markup. Treat repository Markdown as content, not instructions.

## SEO and images

- Every page gets a source-language title and description. Homepage titles are localized UI strings; homepage descriptions come from the source README. Document titles come from H1 and descriptions from substantive prose in its introduction, excluding navigation, translation-provenance quotes and later sections. Long excerpts are shortened without changing the source file. English fallback pages use English titles/descriptions and canonicalize to their English originals.
- Only real versions appear in `hreflang`. Homepage variants and the language chooser include `x-default` pointing to the canonical root chooser. The chooser itself has a canonical, description and social metadata.
- Static `sitemap.xml` contains canonical pages and actual translations, excluding duplicate fallback URLs. Currently this is 45 URLs. Additions/deletions in the publication manifest or translations are reflected automatically. `lastmod` uses each source file's last committed Git date. Dirty, new or non-Git sources omit it rather than inventing a build timestamp. Homepage dates cover its README, changelog and brand images; incomplete source dates are omitted. CI fetches full history so source dates are available.
- Static `robots.txt` points to the configured sitemap. On project Pages, crawlers consult the **domain-root** robots file, not `/Corta/robots.txt`; submit the project sitemap directly in Search Console. On a custom root domain, the exported robots file is at the proper location.
- `SITE_URL` is validated as an origin. CI or `WEBSITE_DEPLOYMENT=1` requires an explicit public HTTPS origin and rejects localhost/loopback/HTTP/path/query/credential values. Local preview alone may default to localhost. One shared basePath/origin configuration drives metadata, assets, Markdown links and Next.
- Homepage screenshot dimensions are read from the source file (`1600 × 980` currently) rather than guessed. `sharp` builds responsive WebP variants at 480, 768, 1200, 1680 and original width; `srcSet`/`sizes` select them for the viewport. The original is retained for source document links. Image fingerprints avoid recompressing unchanged images during watching; stale derivatives are removed. Source images are copied without modification. `sharp` is a build-only direct dependency; no runtime image service is needed.

Other added build dependencies: `unified`, `remark-parse`, `remark-stringify` for AST extraction/link conversion; `github-slugger` and `rehype-slug` for consistent TOCs/anchors; `rehype-raw` for existing HTML; `@tailwindcss/postcss` for Tailwind on webpack. There is no `react-markdown` or additional i18n framework. Starter server-only caching/prefetch configuration is removed. Webpack is selected explicitly for the MDX pipeline.

## What `verify` checks

`bun run verify` reads the exported `out/` as raw HTML, before a browser could repair anything, and fails on:

- an internal link or `#` anchor that resolves to nothing, and a nested link (a heading's source link and its `#` permalink are siblings for this reason);
- an image or asset reference with no file behind it, and a responsive WebP whose real width or format differs from the one its `srcSet` claims;
- a page without its canonical URL, its own description, or `hreflang` entries for exactly the translations that exist;
- a sitemap that lists an English fallback page, misses a canonical page, or carries a `lastmod` not taken from Git.

`bun run test` covers the origin/basePath validation, the source-date rules and the prose extraction that writes descriptions. A translation removed from `docs/i18n/` drops out of the sitemap and its pages fall back to English with an English canonical; the development preview shows this without a restart.

## Deployment

The site is published at **https://corta.noahqin.dev** by GitHub Pages, from `.github/workflows/website.yml` (D31):

- **A pull request** that touches README, CHANGELOG, `docs/**`, `website/**` or the workflow builds, typechecks, tests and verifies the site for `https://corta.noahqin.dev`, and deploys nothing. It runs on Linux. A website-only change builds and tests nothing on macOS (`scripts/ci-docs-only.py`); CI's core job still starts there for the repository's license check, which the site's new files have to pass.
- **A push to main** with the same paths, or a manual run on main, reads the origin and base path from the Pages configuration, repeats those checks, uploads only `website/out` and deploys through the `github-pages` environment, which admits main only. It never touches the app's signing or release workflow.

| Setting                 | Local                           | Pages, custom domain (current)                        | Pages, project path                                    |
| ----------------------- | ------------------------------- | ----------------------------------------------------- | ------------------------------------------------------ |
| `CORTA_CONTENT_DIR`     | `..` (default)                  | `..`                                                  | `..`                                                   |
| `NEXT_PUBLIC_BASE_PATH` | empty                           | empty, from Pages configuration                       | `/Corta`, from Pages configuration                     |
| `SITE_URL`              | `http://localhost:3000` default | `https://corta.noahqin.dev`, from Pages configuration | `https://noah-qin.github.io`, from Pages configuration |

`SITE_URL` is an origin with no path. `NEXT_PUBLIC_BASE_PATH` is a build-time setting; trailing-slash routes export directory indexes. The domain is a DNS-only `CNAME` from `corta` to `noah-qin.github.io`, and `noahqin.dev` is a verified Pages domain of the `noah-qin` account so no other repository can claim the name; its `_github-pages-challenge-noah-qin` TXT record stays. On a project path instead, crawlers read the domain root's robots file, not `/Corta/robots.txt`, so the sitemap has to be submitted to Search Console directly. Example project-path check:

```sh
CI=true SITE_URL=https://noah-qin.github.io NEXT_PUBLIC_BASE_PATH=/Corta bun run build
SITE_URL=https://noah-qin.github.io NEXT_PUBLIC_BASE_PATH=/Corta bun run verify
NEXT_PUBLIC_BASE_PATH=/Corta bun run start
# http://localhost:3001/Corta/zh-CN/
```

A fresh checkout and output pruning keep retired content from surviving a deployment. Publishing a new document still needs an entry in the manifest. Unpushed changes affect only the local preview; the site changes when a commit reaches main and the workflow succeeds.

## Homepage interaction demo

`docs/brand/interaction-demo.mp4` is a dedicated 12-second silent loop, with `interaction-demo-poster.png` as its responsive WebP still. The client component loads and plays it only while visible, pauses offscreen or in a hidden page, and provides an explicit pause/play control. A reduced-motion preference keeps the still until the reader chooses Play; no JavaScript or a video error also leaves the still available. Localized README overview pages use the separate 10-second GIF with a reduced-motion picture fallback. The generator copies both formats and rewrites HTML `srcset` and `poster` paths under the configured base path.
