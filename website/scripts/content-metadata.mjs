import { execFileSync } from "node:child_process";
const text = (node) => node.value ?? node.children?.map(text).join("") ?? "";
// Navigation paragraphs are mostly links. Select substantive prose in the H1
// introduction, excluding translation-provenance blockquotes and later sections.
function prose(node) {
  if (["link", "linkReference", "image", "imageReference"].includes(node.type))
    return "";
  return node.value ?? node.children?.map(prose).join("") ?? "";
}
export function descriptionFromIntroduction(tree, file) {
  const nodes = tree.children;
  const h1 = nodes.findIndex(
    (node) => node.type === "heading" && node.depth === 1,
  );
  const stop = nodes.findIndex(
    (node, i) => i > h1 && node.type === "heading" && node.depth <= 2,
  );
  const introduction = nodes.slice(h1 + 1, stop < 0 ? undefined : stop);
  const paragraph = introduction.find(
    (node) =>
      node.type === "paragraph" && prose(node).replace(/\s/g, "").length >= 25,
  );
  if (!paragraph)
    throw new Error(`No substantive introduction for SEO description: ${file}`);
  const result = text(paragraph).replace(/\s+/g, " ").trim();
  return Array.from(result).length > 200
    ? Array.from(result).slice(0, 197).join("") + "…"
    : result;
}
export function sourceDates(root) {
  const memo = new Map();
  return (file) => {
    if (memo.has(file)) return memo.get(file);
    let date;
    try {
      // Dirty/new files have no reliable committed modification time. Omit it.
      const options = {
        cwd: root,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      };
      const status = execFileSync(
        "git",
        ["status", "--porcelain", "--", file],
        options,
      ).trim();
      if (!status) {
        const value = execFileSync(
          "git",
          ["log", "-1", "--format=%cI", "--", file],
          options,
        ).trim();
        if (value && !Number.isNaN(Date.parse(value)))
          date = new Date(value).toISOString();
      }
    } catch {
      /* External snapshots without Git simply omit lastmod. */
    }
    memo.set(file, date);
    return date;
  };
}
