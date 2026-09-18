#!/usr/bin/env python3
"""Check repository-local Markdown links and HTML assets without network access.

Inline links, reference definitions and HTML href/src attributes are checked.
Fenced code and inline code are ignored. URL fragments, remote URLs and DocC
symbol references are outside this check; review those in their renderer.
"""

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def destinations(source):
    """Yield local-link candidates while preserving line numbers for diagnostics."""
    fence = None
    for number, line in enumerate(source.splitlines(), 1):
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            continue
        if fence:
            continue
        line = re.sub(r"(`+).*?\1", "", line)
        patterns = [
            r"\]\(\s*(<[^>]+>|[^\s)]+)",
            r"^\s{0,3}\[[^\]]+\]:\s*(<[^>]+>|\S+)",
            r'''(?:src|href)\s*=\s*["']([^"']+)["']''',
        ]
        for pattern in patterns:
            for match in re.finditer(pattern, line):
                yield number, match.group(1).strip("<>")


def check(files):
    errors = []
    for path in files:
        for line, destination in destinations(path.read_text(encoding="utf-8")):
            url = urlsplit(destination)
            if url.scheme or url.netloc or not url.path:
                continue
            target = unquote(url.path)
            resolved = ROOT / target.lstrip('/') if target.startswith('/') else path.parent / target
            if not resolved.exists():
                errors.append(f"{path.relative_to(ROOT)}:{line}: missing target: {destination}")
    return errors


def main():
    # Include newly created documentation before it has been staged, while
    # respecting .gitignore so build products never enter the scan.
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT, check=True, capture_output=True,
    )
    files = sorted({ROOT / name for name in result.stdout.decode().split('\0')
                    if name.endswith('.md') and (ROOT / name).is_file()})
    errors = check(files)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f"Checked local links and assets in {len(files)} Markdown files.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
