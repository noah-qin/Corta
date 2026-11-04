import { notFound } from "next/navigation";
import { Header, Footer } from "@/components/chrome";
import { dictionary, label } from "@/lib/i18n";
import { manifest, href, repository, pageInfo } from "@/lib/site";
import { content } from "@/generated/registry";
export function Document({ lang, slug }: { lang: string; slug: string }) {
  const info = pageInfo(lang, slug);
  const Content = content[`${lang}/${slug}`];
  if (!info || !Content) notFound();
  const d = dictionary(lang);
  const docs = manifest.documents;
  const index = docs.findIndex((doc) => doc.slug === slug);
  return (
    <>
      <Header lang={lang} slug={slug} />
      <div className="docs-layout wrap">
        <aside className="sidebar">
          <p className="eyebrow">CORTA / {d.docs}</p>
          <nav aria-label={d.docs}>
            {docs.map((doc) => (
              <a
                key={doc.slug}
                href={href(lang, doc.slug)}
                aria-current={doc.slug === slug ? "page" : undefined}
              >
                {label(lang, doc.slug)}
                <span aria-hidden="true">{doc.slug === slug ? "↗" : ""}</span>
              </a>
            ))}
          </nav>
        </aside>
        <main id="main" className="document">
          <div className="breadcrumbs">
            <a href={href(lang)}>{d.home}</a>
            <span>/</span>
            {label(lang, slug)}
          </div>
          <aside className="notice">
            <p>
              {d.development}{" "}
              <a href={href(lang, "changelog")}>{d.changelog} →</a>
            </p>
          </aside>
          {info.contentLang !== lang && (
            <aside className="notice fallback" role="note">
              <p>
                {d.fallback} <a href={href("en", slug)}>English →</a>
              </p>
            </aside>
          )}
          <div className="source-line">
            <span>{info.file}</span>
            <a href={`${repository}/blob/main/${info.file}`}>{d.source} ↗</a>
          </div>
          <details className="mobile-toc">
            <summary>{d.toc}</summary>
            <nav aria-label={d.toc}>
              {info.toc
                .filter((h) => h.depth > 1)
                .map((h) => (
                  <a key={h.id} href={`#${h.id}`} lang={info.contentLang}>
                    {h.title}
                  </a>
                ))}
            </nav>
          </details>
          <article className="prose" lang={info.contentLang}>
            <Content />
          </article>
          <nav className="page-pagination">
            {index > 0 ? (
              <a href={href(lang, docs[index - 1].slug)}>
                <small>← {d.previous}</small>
                {label(lang, docs[index - 1].slug)}
              </a>
            ) : (
              <span />
            )}
            {index < docs.length - 1 && (
              <a href={href(lang, docs[index + 1].slug)}>
                <small>{d.next} →</small>
                {label(lang, docs[index + 1].slug)}
              </a>
            )}
          </nav>
        </main>
        <aside className="toc">
          <p className="eyebrow">{d.toc}</p>
          <nav aria-label={d.toc}>
            {info.toc
              .filter((h) => h.depth > 1)
              .map((h) => (
                <a
                  key={h.id}
                  className={h.depth === 3 ? "indent" : ""}
                  href={`#${h.id}`}
                  lang={info.contentLang}
                >
                  {h.title}
                </a>
              ))}
          </nav>
        </aside>
      </div>
      <Footer lang={lang} />
    </>
  );
}
