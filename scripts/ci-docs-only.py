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

"""Conservative docs-only detection using complete Git diffs, never API file limits.

CodeQL is selected per language against main's latest analysis of it, not
against the event's own diff: a language whose analysed inputs are unchanged
since that analysis reuses its results, so a skipped or cancelled main scan
can never leave a stale baseline behind.
"""

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
    languages = set()
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


NATIVE_SUFFIXES = (".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".m", ".mm")
TEST_ROOTS = ("CortaTests/", "CortaUITests/", "CortaPerformanceTests/")
BUILD_INPUTS = ("Package.swift", "Package.resolved", "project.pbxproj")
ANALYSIS_INPUTS = (".github/workflows/codeql.yml", "scripts/codeql-extract.py")


def analysed_languages(path):
    """The CodeQL languages whose analysis this path can change."""
    name = path.rsplit("/", 1)[-1]
    if path in ANALYSIS_INPUTS:
        return set(LANGUAGES)
    if name in BUILD_INPUTS or path.endswith(".xcconfig"):
        return {"swift", "c-cpp"}
    if path.startswith(".github/") and path.endswith((".yml", ".yaml")) or name in ("action.yml", "action.yaml"):
        return {"actions"}
    if path.endswith(".py"):
        return {"python"}
    if path.endswith(NATIVE_SUFFIXES):
        return {"c-cpp"}
    # Extraction compiles production targets only; tests never reach the database.
    if path.endswith(".swift") and not path.startswith(TEST_ROOTS) and "/Tests/" not in path:
        return {"swift"}
    return set()


def main_baselines(api=None):
    """Main's latest successful CodeQL analysis per language: {language: (id, commit)}."""
    if api is None:
        def api(path):
            return json.loads(subprocess.check_output(["gh", "api", path]))
    repository = os.environ["GITHUB_REPOSITORY"]
    analyses = api(f"repos/{repository}/code-scanning/analyses"
                   "?ref=refs/heads/main&tool_name=CodeQL&per_page=100")
    baselines = {}
    for analysis in analyses:  # Newest first.
        language = analysis.get("category", "").removeprefix("/language:").strip("/")
        if language in LANGUAGES and language not in baselines and not analysis.get("error"):
            baselines[language] = (analysis["id"], analysis["commit_sha"])
    return baselines


def reusable_baselines(baselines, head, git):
    """The analyses whose language has no analysed change between their commit and head."""
    reusable = {}
    for language, (analysis_id, commit) in baselines.items():
        try:
            git(["merge-base", "--is-ancestor", commit, head])
            output = git(["diff", "--no-renames", "--name-only", "-z", commit + ".." + head])
        except subprocess.CalledProcessError:
            continue  # Unknown or unrelated commit: analyse afresh.
        paths = [path.decode("utf-8") for path in output.split(b"\0") if path]
        if not any(language in analysed_languages(path) for path in paths):
            reusable[language] = analysis_id
    return reusable


def select_languages(event_name, routed, reusable):
    """Languages to analyse, and the main analyses a PR uploads for the rest."""
    if event_name == "push":
        routed = ()  # The PR ran the routed analyses; main rescans changed inputs only.
    analyse = [language for language in LANGUAGES if language in routed or language not in reusable]
    return analyse, {language: reusable[language] for language in LANGUAGES if language not in analyse}


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
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        paths = changed_paths(event_name, event)
        scope = scope_for_paths(paths)
        only_docs = bool(paths) and all(is_documentation(path) for path in paths)
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Cannot classify changes; running full CI: {error}")
        paths, scope, only_docs = [], full_scope(), False
    reusable = {}
    if paths:  # An unknown diff analyses every language.
        try:
            def git(args):
                return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL)
            reusable = reusable_baselines(main_baselines(), os.environ["GITHUB_SHA"], git)
        except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
            print(f"Cannot read main's CodeQL analyses; analysing every language: {error}")
    scope["languages"], baselines = select_languages(event_name, scope["languages"], reusable)
    value = str(only_docs).lower()
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"docs_only={value}\n")
        for name in CHECKS:
            output.write(f"{name}={str(scope[name]).lower()}\n")
        output.write("languages=" + json.dumps(scope["languages"]) + "\n")
        output.write("codeql_baselines=" + json.dumps(baselines) + "\n")
    print(f"docs_only={value}; scope={json.dumps(scope, sort_keys=True)}; reused={json.dumps(baselines)}")


if __name__ == "__main__":
    main()
