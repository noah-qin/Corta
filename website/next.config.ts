import type { NextConfig } from "next";
import createMDX from "@next/mdx";
import { basePath, getSiteOrigin } from "./scripts/site-config.mjs";
getSiteOrigin();
const config: NextConfig = {
  output: "export",
  trailingSlash: true,
  basePath,
  images: { unoptimized: true },
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
