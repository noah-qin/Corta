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

import type { MDXComponents } from "mdx/types";
import type { HTMLAttributes } from "react";
function heading(Tag: "h1" | "h2" | "h3" | "h4") {
  return function Heading({
    id,
    children,
    ...props
  }: HTMLAttributes<HTMLHeadingElement>) {
    return (
      <Tag id={id} {...props}>
        {children}
        {id && (
          <a className="heading-link" href={`#${id}`} aria-label={`#${id}`}>
            <span aria-hidden="true">#</span>
          </a>
        )}
      </Tag>
    );
  };
}
export function useMDXComponents(): MDXComponents {
  return {
    h1: heading("h1"),
    h2: heading("h2"),
    h3: heading("h3"),
    h4: heading("h4"),
    table: (props) => (
      <div className="table-scroll" tabIndex={0}>
        <table {...props} />
      </div>
    ),
  };
}
