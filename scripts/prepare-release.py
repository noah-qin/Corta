#!/usr/bin/env python3
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

"""Prepare consistent release metadata without building or writing to GitHub."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

FILES = (
    "Corta.xcodeproj/project.pbxproj",
    "CortaTerminal/Sources/CortaTerminal/Version.swift",
    "CHANGELOG.md",
    "README.md",
)


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def semver(value):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ValueError(f"Expected a stable semantic version, got {value!r}")
    return tuple(map(int, value.split(".")))


def setting(project, name):
    values = set(re.findall(rf"\b{name} = ([^;]+);", project))
    if len(values) != 1:
        raise ValueError(f"Project configurations disagree about {name}: {values}")
    return values.pop()


def section(changelog, version):
    match = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|^\[Unreleased\]:|\Z)",
                      changelog, re.M | re.S)
    if not match:
        raise ValueError(f"CHANGELOG has no section for {version}")
    return match.group(1).strip()


def prepare(root, bump="patch", date=None):
    date = date or datetime.now(timezone.utc).date().isoformat()
    paths = {name: root / name for name in FILES}
    texts = {name: path.read_text() for name, path in paths.items()}
    project = texts[FILES[0]]
    current = setting(project, "MARKETING_VERSION")
    project_build = int(setting(project, "CURRENT_PROJECT_VERSION"))
    if f'public static let string = "{current}"' not in texts[FILES[1]]:
        raise ValueError("The terminal and project versions disagree")

    # Ignore prerelease/non-version tags. Only ancestors describe this code.
    tags = [tag for tag in git("tag", "--merged", "HEAD").splitlines()
            if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag)]
    previous = max(tags, key=lambda tag: semver(tag[1:])) if tags else None
    base = max(semver(current), semver(previous[1:]) if previous else (0, 0, 0))
    # Respect a manually chosen higher version. Otherwise the default is a
    # patch; dispatch may explicitly choose a minor or major release.
    already_prepared = re.search(rf"^## \[{re.escape(current)}\]", texts["CHANGELOG.md"], re.M)
    if previous and semver(current) > semver(previous[1:]) and bump == "patch" and not already_prepared:
        version = current
    else:
        major, minor, patch = base
        version = {"patch": f"{major}.{minor}.{patch + 1}",
                   "minor": f"{major}.{minor + 1}.0",
                   "major": f"{major + 1}.0.0"}[bump]
    if git("tag", "--list", f"v{version}"):
        raise ValueError(f"Tag v{version} already exists; refusing to reuse a version")

    feed = ET.parse(root / "appcast.xml")
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    builds = [int(node.text) for node in feed.iter(namespace + "version")]
    build = max([project_build, *builds]) + 1
    project = re.sub(r"\bMARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {version};", project)
    project = re.sub(r"\bCURRENT_PROJECT_VERSION = [^;]+;", f"CURRENT_PROJECT_VERSION = {build};", project)
    texts[FILES[0]] = project
    texts[FILES[1]] = texts[FILES[1]].replace(
        f'public static let string = "{current}"', f'public static let string = "{version}"')

    changelog = texts["CHANGELOG.md"]
    unreleased = section(changelog, "Unreleased")
    subjects = git("log", "--format=%s", f"{previous}..HEAD" if previous else "HEAD").splitlines()
    subjects = [subject for subject in subjects
                if not subject.startswith(("chore: release ", "chore: publish "))]
    notes = unreleased
    if not unreleased and subjects:
        notes += "\n\n### Commits\n\n" + "\n".join(f"- {subject}" for subject in subjects)
    notes = notes.strip() or "- Release maintenance."
    # Replace only Unreleased's body, leaving all historical notes intact.
    changelog = re.sub(r"(^## \[Unreleased\][^\n]*\n).*?(?=^## \[|^\[Unreleased\]:|\Z)",
                       lambda m: m.group(1) + f"\n## [{version}] - {date}\n\n{notes}\n\n",
                       changelog, count=1, flags=re.M | re.S)
    repository = "https://github.com/noah-qin/Corta"
    changelog, count = re.subn(r"^\[Unreleased\]:.*$",
                             f"[Unreleased]: {repository}/compare/v{version}...main\n"
                             f"[{version}]: {repository}/releases/tag/v{version}",
                             changelog, count=1, flags=re.M)
    if count != 1:
        raise ValueError("CHANGELOG is missing its Unreleased comparison link")
    texts["CHANGELOG.md"] = changelog

    readme = texts["README.md"]
    # Historical compatibility and shell-integration instructions retain
    # their old versions; only the current download/status changes.
    start = readme.index("## Install")
    end = readme.index("For updates,", start)
    install = readme[start:end]
    install = re.sub(r"Corta-[0-9]+\.[0-9]+\.[0-9]+\.zip", f"Corta-{version}.zip", install)
    install, count = re.subn(r"> \*\*Release status:\*\*.*?(?=\n\n|\Z)",
                            f"> **Release status:** [{version}]({repository}/releases/tag/v{version}),\n"
                            f"> prepared on {date}. Manually running Release on `main` starts tests,\n"
                            "> build, sign and notarise the app, publish a release, and update\n"
                            "> the signed update feed. See [GitHub Releases](https://github.com/noah-qin/Corta/releases/latest)\n"
                            "> for the latest successfully published build.",
                            install, count=1, flags=re.S)
    if count != 1:
        raise ValueError("README is missing its release status block")
    texts["README.md"] = readme[:start] + install + readme[end:]
    # Validate all input before writing any file.
    for name, path in paths.items():
        path.write_text(texts[name])
    return {"version": version, "tag": f"v{version}", "build": build}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bump", choices=("patch", "minor", "major"), default="patch")
    parser.add_argument("--notes", metavar="VERSION")
    args = parser.parse_args()
    if args.notes:
        print(section(Path("CHANGELOG.md").read_text(), args.notes))
    else:
        print(json.dumps(prepare(Path.cwd(), args.bump)))


if __name__ == "__main__":
    main()
