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

import "./globals.css";
import { languages } from "@/lib/i18n";
import { asset, href } from "@/lib/site";

export const metadata = {
  title: "Page not found — Corta",
  icons: { icon: asset("corta-pangolin-mascot.png") },
};

/** An unmatched URL names no language, so the way back offers them all. */
export default function GlobalNotFound() {
  return (
    <html lang="en">
      <body>
        <main id="main" className="not-found wrap">
          <img
            src={asset("corta-pangolin-mascot.png")}
            width="120"
            height="120"
            alt=""
          />
          <h1>Page not found</h1>
          <p>This address does not lead to a page on this site.</p>
          <nav aria-label="Language" className="language-entry-links">
            {languages.map((l) => (
              <a
                key={l.code}
                lang={l.code}
                hrefLang={l.code}
                href={href(l.code)}
              >
                {l.name} <span>→</span>
              </a>
            ))}
          </nav>
        </main>
      </body>
    </html>
  );
}
