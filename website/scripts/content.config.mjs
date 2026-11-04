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

// Explicit publication list. Repository Markdown outside this list stays on GitHub.
export const languages = [
  ["en", "English", "Why Corta", "Install"],
  ["zh-CN", "简体中文", "为什么选 Corta", "安装"],
  ["zh-Hant", "繁體中文", "為什麼選 Corta", "安裝"],
  ["ja", "日本語", "Corta を選ぶ理由", "インストール"],
  ["ko", "한국어", "왜 Corta인가", "설치"],
  ["de", "Deutsch", "Warum Corta", "Installation"],
  ["fr", "Français", "Pourquoi Corta", "Installation"],
  ["es", "Español", "Por qué Corta", "Instalación"],
  ["pt-BR", "Português (Brasil)", "Por que o Corta", "Instalação"],
].map(([code, name, features, install]) => ({ code, name, features, install }));
export const documents = [
  { slug: "overview", file: "README.md", translation: "README.md" },
  { slug: "index", file: "docs/README.md" },
  {
    slug: "user-guide",
    file: "docs/USER-GUIDE.md",
    translation: "USER-GUIDE.md",
  },
  { slug: "features", file: "docs/FEATURES.md" },
  { slug: "configuration", file: "docs/CONFIGURATION.md" },
  {
    slug: "troubleshooting",
    file: "docs/TROUBLESHOOTING.md",
    translation: "TROUBLESHOOTING.md",
  },
  { slug: "performance", file: "docs/PERFORMANCE.md" },
  { slug: "conformance", file: "docs/CONFORMANCE.md" },
  { slug: "security", file: "docs/SECURITY.md" },
  { slug: "brand", file: "docs/brand/README.md" },
  { slug: "changelog", file: "CHANGELOG.md" },
];
export const repository = "https://github.com/noah-qin/Corta";
export { basePath } from "./site-config.mjs";
import { basePath } from "./site-config.mjs";
export function route(lang, slug) {
  return `${basePath}/${lang}/${slug === "changelog" ? "changelog/" : `docs/${slug}/`}`;
}
