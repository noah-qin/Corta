import { dictionary, languages } from "@/lib/i18n";
import { asset, href, download, repository } from "@/lib/site";
export function Header({ lang, slug = "" }: { lang: string; slug?: string }) {
  const d = dictionary(lang);
  return (
    <>
      <a className="skip" href="#main">
        {d.skip}
      </a>
      <header className="site-header">
        <div className="header-inner">
          <a className="wordmark" href={href(lang)}>
            <img
              src={asset("corta-pangolin-mascot.png")}
              alt=""
              width="40"
              height="40"
            />
            Corta
            <span className="cursor" />
          </a>
          <nav aria-label={d.home}>
            <a
              aria-current={slug && slug !== "changelog" ? "page" : undefined}
              href={href(lang, "user-guide")}
            >
              {d.docs}
            </a>
            <a
              aria-current={slug === "changelog" ? "page" : undefined}
              href={href(lang, "changelog")}
            >
              {d.changelog}
            </a>
            <a className="github" href={repository}>
              GitHub ↗
            </a>
          </nav>
          <details className="language">
            <summary>
              {languages.find((l) => l.code === lang)?.name}
              <svg
                width="12"
                height="12"
                viewBox="0 0 12 12"
                fill="none"
                aria-hidden="true"
                focusable="false"
              >
                <path
                  d="m3 4.5 3 3 3-3"
                  stroke="currentColor"
                  strokeWidth="1.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </summary>
            <nav aria-label={d.language}>
              {languages.map((l) => (
                <a
                  key={l.code}
                  href={href(l.code, slug)}
                  lang={l.code}
                  hrefLang={l.code}
                  aria-current={l.code === lang ? "true" : undefined}
                >
                  {l.name}
                  {l.code === lang ? " ✓" : ""}
                </a>
              ))}
            </nav>
          </details>
          <a className="button small" href={download}>
            {d.download}
            <span aria-hidden="true"> ↗</span>
          </a>
        </div>
      </header>
    </>
  );
}
export function Footer({ lang }: { lang: string }) {
  const d = dictionary(lang);
  return (
    <footer className="footer">
      <div>
        <a className="wordmark" href={href(lang)}>
          Corta
          <span className="cursor" />
        </a>
        <p>{d.footer}</p>
      </div>
      <nav>
        <a href={href(lang, "user-guide")}>{d.docs}</a>
        <a href={href(lang, "changelog")}>{d.changelog}</a>
        <a href={repository}>{d.openSource} ↗</a>
      </nav>
    </footer>
  );
}
