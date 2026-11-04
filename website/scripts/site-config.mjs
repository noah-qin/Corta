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
