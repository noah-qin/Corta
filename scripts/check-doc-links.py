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

"""Check local Markdown links without building the app (DocumentationDriftTests)."""

from pathlib import Path
import re
import subprocess
from urllib.parse import unquote

FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
INLINE = re.compile(r"(`+).*?\1")
LINKS = [re.compile(r"\]\(\s*(<[^>]+>|[^\s)]+)"),
         re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(<[^>]+>|\S+)"),
         re.compile(r"(?:src|href)\s*=\s*[\"']([^\"']+)[\"']")]


def destinations(text):
    fence = None
    for number, raw in enumerate(text.split("\n"), 1):
        marker = FENCE.match(raw)
        if marker:
            token = marker[1]
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            continue
        if fence is not None:
            continue
        line = INLINE.sub("", raw)
        for pattern in LINKS:
            for match in pattern.finditer(line):
                yield number, match[1].strip("<>")


def local_target(destination, file, root):
    if destination.startswith("//") or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", destination):
        return None
    path = re.split(r"[?#]", destination, maxsplit=1)[0]
    if not path:
        return None
    path = unquote(path)
    return root / path[1:] if path.startswith("/") else file.parent / path


def check(root):
    files = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root)
    missing = []
    for name in sorted(set(files.decode("utf-8").split("\0"))):
        file = root / name
        if not name.endswith(".md") or not file.is_file():
            continue
        for line, destination in destinations(file.read_text()):
            target = local_target(destination, file, root)
            if target is not None and not target.exists():
                missing.append(f"{name}:{line}: missing target: {destination}")
    return missing


if __name__ == "__main__":
    missing = check(Path(__file__).resolve().parents[1])
    for message in missing:
        print(message)
    if missing:
        raise SystemExit(1)
    print("All local Markdown links resolve.")
