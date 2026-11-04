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
- Homepage screenshot dimensions are read from the source file (`2484 × 1524` currently) rather than guessed. `sharp` builds responsive WebP variants at 480, 768, 1200, 1680 and original width; `srcSet`/`sizes` select them for the viewport. The original is retained for source document links. Image fingerprints avoid recompressing unchanged images during watching; stale derivatives are removed. No repository image is edited. `sharp` is a build-only direct dependency; no runtime image service is needed.

Other added build dependencies: `unified`, `remark-parse`, `remark-stringify` for AST extraction/link conversion; `github-slugger` and `rehype-slug` for consistent TOCs/anchors; `rehype-raw` for existing HTML; `@tailwindcss/postcss` for Tailwind on webpack. There is no `react-markdown` or additional i18n framework. Starter server-only caching/prefetch configuration is removed. Webpack is selected explicitly for the MDX pipeline.

## Deployment configuration

| Setting | Local | GitHub project Pages | Custom domain |
| --- | --- | --- | --- |
| `CORTA_CONTENT_DIR` | `..` (default) | `..` | `..` |
| `NEXT_PUBLIC_BASE_PATH` | empty | `/Corta`, from Pages configuration | empty, from Pages configuration |
| `SITE_URL` | `http://localhost:3000` default | `https://noah-qin.github.io`, from Pages configuration | your HTTPS origin, from Pages configuration |

`SITE_URL` has no project subpath. `NEXT_PUBLIC_BASE_PATH` is a build-time setting; trailing-slash routes export directory indexes. Example subpath verification:

```sh
CI=true SITE_URL=https://noah-qin.github.io NEXT_PUBLIC_BASE_PATH=/Corta bun run build
SITE_URL=https://noah-qin.github.io NEXT_PUBLIC_BASE_PATH=/Corta bun run verify
NEXT_PUBLIC_BASE_PATH=/Corta bun run start
# http://localhost:3001/Corta/zh-CN/
```

The workflow is now installed at the Corta root `.github/workflows/website.yml`. Local builds/commits do not execute it. When ready for online publishing, choose **GitHub Actions** in repository Settings → Pages and configure any custom domain there. A future matching push to main or manual dispatch reads Pages origin/basePath, installs the frozen Bun lockfile, builds/typechecks/tests/verifies, uploads only `website/out`, and deploys via the `github-pages` environment. It does not invoke Corta's application-signing/release workflow.

Push filters cover README, CHANGELOG, all `docs/**`, `website/**` and the workflow itself, including added, modified and deleted Markdown, translations, images and website source. Fresh checkout plus output pruning prevents retired content from surviving. Publishing a new document still requires the explicit manifest. No Sites-hosted project or GitHub deployment has been created or triggered during this work.

**Unpushed changes affect only local preview. Online updates require a pushed commit and a successful Pages workflow.**
