import { languages } from "@/lib/i18n";
import { href, asset, manifest, chooserMetadata } from "@/lib/site";
export const metadata = chooserMetadata();
export default function Entry() {
  return (
    <main id="main" className="language-entry wrap">
      <img
        src={asset("corta-pangolin-mascot.png")}
        width="180"
        height="180"
        alt="Corta"
      />
      <h1>Corta</h1>
      <p>{manifest.home.en.title}</p>
      <nav aria-label="Language">
        {languages.map((l) => (
          <a key={l.code} lang={l.code} hrefLang={l.code} href={href(l.code)}>
            {l.name} <span>→</span>
          </a>
        ))}
      </nav>
    </main>
  );
}
