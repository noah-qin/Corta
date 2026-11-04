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

import type { MetadataRoute } from "next";
import {
  manifest,
  siteOrigin,
  href,
  chooserUrl,
  languageAlternates,
} from "@/lib/site";
export const dynamic = "force-static";
export default function sitemap(): MetadataRoute.Sitemap {
  const entries: MetadataRoute.Sitemap = [
    { url: chooserUrl, alternates: { languages: languageAlternates() } },
  ];
  for (const { code } of manifest.languages) {
    const home = manifest.home[code];
    if (home.contentLang === code)
      entries.push({
        url: siteOrigin + href(code),
        ...(home.lastModified ? { lastModified: home.lastModified } : {}),
        alternates: { languages: languageAlternates() },
      });
    for (const doc of manifest.documents) {
      const info = manifest.pages[`${code}/${doc.slug}`];
      if (info.contentLang !== code) continue;
      entries.push({
        url: siteOrigin + href(code, doc.slug),
        ...(info.lastModified ? { lastModified: info.lastModified } : {}),
        alternates: { languages: languageAlternates(doc.slug) },
      });
    }
  }
  return entries;
}
