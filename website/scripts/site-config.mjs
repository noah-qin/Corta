// Shared by the generator, Next config, metadata and verification scripts.
export const basePath = (process.env.NEXT_PUBLIC_BASE_PATH || "").replace(
  /\/$/,
  "",
);
if (
  basePath &&
  (!basePath.startsWith("/") ||
    basePath.startsWith("//") ||
    /[?#\\\s]/.test(basePath) ||
    basePath.split("/").some((part) => part === ".." || part === "."))
) {
  throw new Error(
    "NEXT_PUBLIC_BASE_PATH must be an absolute URL path, such as /Corta, or empty.",
  );
}
export function getSiteOrigin() {
  const required =
    process.env.CI === "true" || process.env.WEBSITE_DEPLOYMENT === "1";
  const configured = process.env.SITE_URL;
  if (required && !configured)
    throw new Error("SITE_URL is required for CI/deployment builds.");
  const url = new URL(configured || "http://localhost:3000");
  if (
    !["http:", "https:"].includes(url.protocol) ||
    url.pathname !== "/" ||
    url.search ||
    url.hash ||
    url.username ||
    url.password
  ) {
    throw new Error(
      "SITE_URL must be an HTTP(S) origin without a path, query, credentials or fragment.",
    );
  }
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (
    required &&
    (url.protocol !== "https:" ||
      /^(localhost|127(?:\.\d+){3}|0\.0\.0\.0|\[?::1\]?)$/i.test(host) ||
      host.endsWith(".localhost"))
  ) {
    throw new Error(
      "SITE_URL must be a public HTTPS origin for CI/deployment builds.",
    );
  }
  return url.origin;
}
