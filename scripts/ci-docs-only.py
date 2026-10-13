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

"""Conservative docs-only detection using complete Git diffs, never API file limits."""

import json
import os
from pathlib import Path
import re
import subprocess

ROOT_DOCS = {
    "README.md", "CHANGELOG.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md",
    "SECURITY.md", "CLAUDE.md",
}


def is_documentation(path):
    # This reference is tested against compiled app configuration and commands.
    if path == "docs/CONFIGURATION.md":
        return False
    return (path in ROOT_DOCS or
            path.startswith("docs/") and path.endswith(".md") or
            path.startswith(".github/") and path.endswith(".md"))


CHECKS = ("core", "app", "feed", "ssh", "fuzz", "script_tests")
LANGUAGES = ("swift", "c-cpp", "python", "actions")


def full_scope():
    return {**{name: True for name in CHECKS}, "languages": list(LANGUAGES)}


def scope_for_paths(paths):
    if not paths:
        return full_scope()
    scope = {**{name: False for name in CHECKS}, "languages": []}
    # The independent scanning rule needs a real analysis on every PR.
    languages = {"actions"}
    for path in paths:
        if is_documentation(path):
            continue
        if path == "docs/CONFIGURATION.md":
            scope["app"] = True
        elif path.startswith("CortaTerminal/"):
            scope.update(core=True, app=True, ssh=True, fuzz=True)
            if path.endswith(".swift") and "/Tests/" not in path:
                languages.add("swift")
            if path.endswith((".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm")):
                languages.add("c-cpp")
            if path.endswith(("Package.swift", "Package.resolved")):
                return full_scope()
        elif path.startswith(("Corta/", "CortaTests/", "CortaUITests/", "CortaPerformanceTests/",
                              "AppIcon.icon/", "AppIconDev.icon/", "TestPlans/")):
            scope["app"] = True
            if path.startswith("Corta/") and path.endswith(".swift"):
                languages.add("swift")
            if path.endswith((".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm")):
                languages.update(("swift", "c-cpp"))
        elif path == "appcast.xml":
            scope["feed"] = True
        elif path == "scripts/verify-appcast.swift" or path == "scripts/tests/test_appcast_formats.py":
            scope["feed"] = True
            scope["script_tests"] = True
            languages.add("python" if path.endswith(".py") else "swift")
        elif path == "script/verify_ssh_integration.py":
            scope.update(core=True, ssh=True)
            languages.add("python")
        elif path in ("scripts/ci-docs-only.py", "scripts/codeql-extract.py"):
            return full_scope()  # Changes to routing/extraction validate every lane.
        elif path.startswith("scripts/") and path.endswith(".py"):
            scope["script_tests"] = True
            languages.add("python")
        else:
            return full_scope()  # Build settings, shell scripts, dependencies, unknown files.
    scope["languages"] = sorted(languages)
    return scope


def changed_paths(event_name, event, git=None):
    if event_name == "pull_request":
        base = event["pull_request"]["base"]["sha"]
        head = event["pull_request"]["head"]["sha"]
        separator = "..."
    elif event_name == "workflow_dispatch" and event.get("inputs", {}).get("scope") == "changed":
        base, head = "origin/main", os.environ["GITHUB_SHA"]
        separator = "..."
    elif event_name == "push":
        base, head = event["before"], event["after"]
        separator = ".."
    else:
        return []  # Manual release/feed CI runs all checks.
    if any(not re.fullmatch(r"[0-9a-fA-F]{40}", sha) or set(sha) == {"0"}
           for sha in (base, head) if sha != "origin/main"):
        return []
    if git is None:
        def git(args):
            return subprocess.check_output(["git", *args])
    output = git(["diff", "--no-renames", "--name-only", "-z", base + separator + head])
    return [path.decode("utf-8") for path in output.split(b"\0") if path]


def docs_only(event_name, event, git=None):
    paths = changed_paths(event_name, event, git)
    return bool(paths) and all(is_documentation(path) for path in paths)


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        paths = changed_paths(os.environ["GITHUB_EVENT_NAME"], event)
        scope = scope_for_paths(paths)
        only_docs = bool(paths) and all(is_documentation(path) for path in paths)
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Cannot classify changes; running full CI: {error}")
        scope = full_scope()
        only_docs = False
    value = str(only_docs).lower()
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"docs_only={value}\n")
        for name in CHECKS:
            output.write(f"{name}={str(scope[name]).lower()}\n")
        output.write("languages=" + json.dumps(scope["languages"]) + "\n")
    print(f"docs_only={value}; scope={json.dumps(scope, sort_keys=True)}")


if __name__ == "__main__":
    main()
