import type { Metadata } from "next";
import generated from "@/generated/manifest.json";
import { homepageTitles, label } from "@/lib/i18n";
import { basePath, getSiteOrigin } from "../../scripts/site-config.mjs";
export { basePath };
export type PageInfo = {
  file: string;
  contentLang: string;
  title: string;
  description: string;
  lastModified?: string;
  hash: string;
  toc: { title: string; id: string; depth: number }[];
};
type HomeInfo = {
  title: string;
  requirements: string;
  section: string;
  contentLang: string;
  lastModified?: string;
};
type Manifest = {
  languages: {
    code: string;
    name: string;
    features: string;
    install: string;
  }[];
  documents: { slug: string; file: string; translation?: string }[];
  pages: Record<string, PageInfo>;
  home: Record<string, HomeInfo>;
  release: string;
  images: {
    screenshot: {
      width: number;
      height: number;
      src: string;
      variants: { file: string; width: number }[];
    };
  };
};
export const manifest = generated as Manifest;
export const siteOrigin = getSiteOrigin();
export const repository = "https://github.com/noah-qin/Corta";
export const download = `${repository}/releases/latest`;
export const asset = (file: string) =>
  `${basePath}/content-assets/docs/brand/${file}`;
export const href = (lang: string, slug = "") =>
  `${basePath}/${lang}/${slug ? (slug === "changelog" ? "changelog/" : `docs/${slug}/`) : ""}`;
export const chooserUrl = `${siteOrigin}${basePath}/`;
export function pageInfo(lang: string, slug: string): PageInfo | undefined {
  return manifest.pages[`${lang}/${slug}`];
}
export function languageAlternates(slug = ""): Record<string, string> {
  const languages = Object.fromEntries(
    manifest.languages
      .filter((l) =>
        slug
          ? pageInfo(l.code, slug)?.contentLang === l.code
          : manifest.home[l.code]?.contentLang === l.code,
      )
      .map((l) => [l.code, siteOrigin + href(l.code, slug)]),
  );
  return slug ? languages : { ...languages, "x-default": chooserUrl };
}
export function metadata(lang: string, slug = ""): Metadata {
  const info = slug ? pageInfo(lang, slug) : manifest.home[lang];
  if (!info) throw new Error(`Missing page metadata: ${lang}/${slug}`);
  const contentLang = info.contentLang;
  const sourceTitle = slug
    ? info.title === "Corta"
      ? label(contentLang, slug)
      : info.title
    : homepageTitles[contentLang];
  const title = sourceTitle.startsWith("Corta")
    ? sourceTitle
    : `${sourceTitle} — Corta`;
  const description = slug ? (info as PageInfo).description : info.title;
  const canonical = siteOrigin + href(contentLang, slug);
  return {
    title,
    description,
    alternates: { canonical, languages: languageAlternates(slug) },
    openGraph: {
      type: "website",
      title,
      description,
      url: canonical,
      images: [
        {
          url: siteOrigin + asset("social-preview.png"),
          width: 1280,
          height: 640,
          alt: "Corta",
        },
      ],
    },
  };
}
export function chooserMetadata(): Metadata {
  return {
    title: "Corta — Choose your language",
    description: manifest.home.en.title,
    alternates: { canonical: chooserUrl, languages: languageAlternates() },
    openGraph: {
      type: "website",
      title: homepageTitles.en,
      description: manifest.home.en.title,
      url: chooserUrl,
      images: [
        {
          url: siteOrigin + asset("social-preview.png"),
          width: 1280,
          height: 640,
          alt: "Corta",
        },
      ],
    },
  };
}
