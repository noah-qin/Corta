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

import createMDX from "@next/mdx";
import type { NextConfig } from "next";
import { basePath, getSiteOrigin } from "./scripts/site-config.mjs";

getSiteOrigin();
const config: NextConfig = {
  output: "export",
  trailingSlash: true,
  basePath,
  images: { unoptimized: true },
  // Two root layouts, one under a dynamic segment: no layout can hold a 404
  // for every unmatched URL, so it is its own document.
  experimental: { globalNotFound: true },
  pageExtensions: ["ts", "tsx", "js", "jsx", "md", "mdx"],
  // Cache Components and partial prefetching require a server; this site exports HTML.
  turbopack: {
    rules: { "*.css": { loaders: ["@tailwindcss/turbopack"], as: "*.css" } },
  },
};
export default createMDX({
  extension: /\.mdx?$/,
  options: {
    format: "md", // Repository .md is Markdown, never executable MDX expressions.
    remarkPlugins: ["remark-gfm"],
    rehypePlugins: ["rehype-raw", "rehype-slug"],
  },
})(config);
