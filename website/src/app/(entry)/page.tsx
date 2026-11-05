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

import { languages } from "@/lib/i18n";
import { asset, chooserMetadata, href, manifest } from "@/lib/site";
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
