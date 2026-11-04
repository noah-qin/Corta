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
