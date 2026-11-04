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
