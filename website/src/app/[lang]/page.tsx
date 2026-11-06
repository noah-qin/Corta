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

import { Footer, Header } from "@/components/chrome";
import { content } from "@/generated/registry";
import { ProductDemo } from "@/components/product-demo";
import { dictionary, interactionDemoCopy } from "@/lib/i18n";
import {
  asset,
  download,
  href,
  metadata as makeMetadata,
  manifest,
} from "@/lib/site";
export async function generateMetadata({
  params,
}: {
  params: Promise<{ lang: string }>;
}) {
  const { lang } = await params;
  return makeMetadata(lang);
}
export default async function Home({
  params,
}: {
  params: Promise<{ lang: string }>;
}) {
  const { lang } = await params;
  const d = dictionary(lang);
  const home = manifest.home[lang as keyof typeof manifest.home];
  const Features = content[`${lang}/home`];
  const Provenance = content[`${lang}/provenance`];
  return (
    <>
      <Header lang={lang} />
      <main id="main">
        {home.contentLang !== lang && (
          <aside className="wrap notice fallback">
            <p>{d.fallback}</p>
          </aside>
        )}
        <section className="hero wrap">
          <div className="hero-copy">
            <div className="eyebrow">
              <span /> macOS · SWIFT · METAL 4
            </div>
            <h1>
              Corta
              <span className="hero-cursor" />
            </h1>
            <p className="hero-description" lang={home.contentLang}>
              {home.title}
            </p>
            <div className="actions">
              <a className="button" href={download}>
                {d.download} <span aria-hidden="true">↓</span>
              </a>
              <a className="text-link" href={href(lang, "user-guide")}>
                {d.guide} <span aria-hidden="true">→</span>
              </a>
            </div>
            <p className="release">
              <a href={href(lang, "changelog")}>v{manifest.release}</a>
              <span>{d.release}</span>
            </p>
          </div>
          <div className="mascot-stage">
            <img
              className="mascot"
              src={asset("corta-pangolin-mascot.png")}
              width="480"
              height="480"
              alt="Corta"
            />
          </div>
        </section>
        <ProductDemo
          src={asset("interaction-demo.mp4")}
          poster={{
            src: asset(manifest.images.screenshot.src),
            srcSet: manifest.images.screenshot.variants
              .map((v) => `${asset(v.file)} ${v.width}w`)
              .join(", "),
            width: manifest.images.screenshot.width,
            height: manifest.images.screenshot.height,
          }}
          copy={interactionDemoCopy[lang] || interactionDemoCopy.en}
          overview={{ href: href(lang, "overview"), label: d.overview }}
        />
        <aside className="wrap notice feature-status">
          <p>
            {d.development}{" "}
            <a href={href(lang, "changelog")}>{d.changelog} →</a>
          </p>
        </aside>
        <section className="wrap features">
          <div className="section-title">
            <span className="eyebrow">01 / CORTA</span>
            <h2>{home.section}</h2>
            <p>{d.features}</p>
          </div>
          <div className="feature-copy prose" lang={home.contentLang}>
            <Features />
          </div>
        </section>
        <section className="wrap reading">
          <div className="section-title">
            <span className="eyebrow">02 / {d.docs}</span>
            <h2>{d.guide}</h2>
          </div>
          <div className="reading-links">
            {[
              "user-guide",
              "configuration",
              "troubleshooting",
              "performance",
            ].map((slug, i) => (
              <a key={slug} href={href(lang, slug)}>
                <span>0{i + 1}</span>
                <strong>{d[slug as keyof typeof d]}</strong>
                <span aria-hidden="true">↗</span>
              </a>
            ))}
          </div>
        </section>
        <section className="wrap download-panel">
          <div>
            <span className="eyebrow">CORTA / macOS</span>
            <h2>{d.download}</h2>
            <h3>{d.requirements}</h3>
            <p lang={home.contentLang}>{home.requirements}</p>
          </div>
          <a className="button" href={download}>
            {d.download} ↓
          </a>
        </section>
        <aside className="wrap notice home-notice">
          <span aria-hidden="true">ⓘ</span>
          <p>
            {d.development}{" "}
            <a href={href(lang, "changelog")}>{d.changelog} →</a>
            <br />
            <a href={href(lang, "performance")}>{d.evidence} →</a>
          </p>
        </aside>
        {home.contentLang !== "en" && (
          <div
            className="wrap prose homepage-provenance"
            lang={home.contentLang}
          >
            <Provenance />
          </div>
        )}
      </main>
      <Footer lang={lang} />
    </>
  );
}
