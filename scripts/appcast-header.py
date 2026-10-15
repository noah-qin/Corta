# Copyright 2026 Noah Qin
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

"""Point the update feed's header comment at files that still exist.

The feed is signed whole, so a stale path in its comment can only be
corrected in the run that is about to sign it again. Every backticked
repository path in the comments before `<rss` that no longer exists is
rewritten to the one file with its name; none, or several, fails the run.
"""

from pathlib import Path
import re
import sys

PATH = re.compile(r"`([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\.[A-Za-z0-9]+)`")


def refresh(text, root):
    """The feed with its header's stale paths fixed, and what changed."""
    end = text.find("<rss")
    if end < 0:
        raise ValueError("no <rss> element")
    header, changes = text[:end], []

    def fix(match):
        path = match.group(1)
        if (root / path).exists():
            return match.group(0)
        found = sorted(p.relative_to(root).as_posix() for p in root.rglob(Path(path).name)
                       if ".git" not in p.parts and ".build" not in p.parts)
        if len(found) != 1:
            raise ValueError(f"{path}: {len(found)} candidates {found}")
        changes.append((path, found[0]))
        return f"`{found[0]}`"

    return PATH.sub(fix, header) + text[end:], changes


def main(argv):
    if len(argv) != 2:
        sys.exit("usage: appcast-header.py FEED")
    feed = Path(argv[1])
    text = feed.read_text(encoding="utf-8")
    updated, changes = refresh(text, Path.cwd())
    for old, new in changes:
        print(f"{old} -> {new}")
    if updated != text:
        feed.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv)
