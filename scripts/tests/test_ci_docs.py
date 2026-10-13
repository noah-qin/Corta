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

"""Exercise CI's fast path against real Git history and Markdown link fixtures."""

import importlib.util
import json
import os
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ci = load("ci_docs", "ci-docs-only.py")
links = load("doc_links", "check-doc-links.py")


class DiffTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git(["init", "-q"])
        self.git(["config", "user.name", "Test"])
        self.git(["config", "user.email", "test@example.invalid"])
        self.write("README.md", "initial")
        self.write("Corta/code.swift", "initial")
        self.base = self.commit()

    def git(self, args):
        return subprocess.check_output(["git", *args], cwd=self.root, stderr=subprocess.PIPE)

    def write(self, name, text):
        file = self.root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def commit(self):
        self.git(["add", "."])
        self.git(["commit", "-qm", "change"])
        return self.git(["rev-parse", "HEAD"]).decode().strip()

    def classify(self, head, event="push", base=None):
        base = base or self.base
        payload = {"before": base, "after": head} if event == "push" else {
            "pull_request": {"base": {"sha": base}, "head": {"sha": head}}}
        return ci.docs_only(event, payload, self.git)

    def test_documentation_and_configuration_boundary(self):
        self.write("docs/TESTING.md", "test")
        self.assertTrue(self.classify(self.commit()))
        self.write("docs/CONFIGURATION.md", "changed default")
        self.assertFalse(self.classify(self.commit()))

    def test_push_includes_earlier_code_commit(self):
        self.write("Corta/code.swift", "changed")
        self.commit()
        self.write("README.md", "changed")
        self.assertFalse(self.classify(self.commit()))

    def test_pr_ignores_unrelated_base_branch_changes(self):
        self.write("README.md", "PR docs")
        head = self.commit()
        self.git(["checkout", "-q", "--detach", self.base])
        self.write("Corta/code.swift", "new base code")
        base = self.commit()
        self.assertTrue(self.classify(head, "pull_request", base))

    def test_rename_from_code_to_documentation_is_not_docs_only(self):
        (self.root / "docs").mkdir()
        self.git(["mv", "Corta/code.swift", "docs/code.md"])
        self.assertFalse(self.classify(self.commit()))

    def test_no_three_hundred_file_limit(self):
        for index in range(310):
            self.write(f"docs/{index}.md", "docs")
        self.write("z-code.swift", "code beyond docs")
        self.assertFalse(self.classify(self.commit()))

    def test_empty_diff_manual_and_zero_sha_run_full_ci(self):
        self.assertFalse(self.classify(self.base))
        self.assertFalse(ci.docs_only("workflow_dispatch", {}))
        self.assertFalse(ci.docs_only("schedule", {}))
        self.assertFalse(self.classify(self.base, base="0" * 40))

    def test_scripts_assets_workflows_and_unknown_paths_run_full_ci(self):
        for path in ("docs/brand/compose-screenshot.swift", "docs/brand/image.png",
                     ".github/workflows/ci.yml", "appcast.xml", "Package.resolved",
                     "Corta/README.md", "unknown.md"):
            with self.subTest(path=path):
                self.assertFalse(ci.is_documentation(path))

    def test_unavailable_or_invalid_event_falls_back_to_full_ci(self):
        event_file = self.root / "event.json"
        output_file = self.root / "output"
        for payload in ({"before": "1" * 40, "after": "2" * 40}, {}):
            with self.subTest(payload=payload):
                event_file.write_text(json.dumps(payload))
                output_file.write_text("")
                result = subprocess.run(
                    [sys.executable, "-B", str(Path(ci.__file__))], cwd=self.root,
                    env=dict(os.environ, GITHUB_EVENT_NAME="push",
                             GITHUB_EVENT_PATH=str(event_file), GITHUB_OUTPUT=str(output_file)),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                values = dict(line.split("=", 1) for line in output_file.read_text().splitlines())
                self.assertEqual(values["docs_only"], "false")
                self.assertTrue(all(values[name] == "true" for name in ci.CHECKS))
                self.assertEqual(json.loads(values["languages"]), list(ci.LANGUAGES))

    def test_opt_in_dispatch_compares_against_real_main(self):
        self.git(["update-ref", "refs/remotes/origin/main", self.base])
        self.write("appcast.xml", "feed")
        head = self.commit()
        with patch.dict(os.environ, GITHUB_SHA=head):
            self.assertEqual(ci.changed_paths("workflow_dispatch", {"inputs": {"scope": "changed"}}, self.git),
                             ["appcast.xml"])
        self.assertEqual(ci.changed_paths("workflow_dispatch", {"inputs": {"scope": "full"}}, self.git), [])
        self.assertEqual(ci.scope_for_paths([]), ci.full_scope())

    def test_deleting_docs_is_docs_only(self):
        (self.root / "README.md").unlink()
        self.assertTrue(self.classify(self.commit()))


class ScopeTests(unittest.TestCase):
    def test_app_only_does_not_run_core_or_fuzz(self):
        scope = ci.scope_for_paths(["Corta/WindowController.swift"])
        self.assertTrue(scope["app"])
        self.assertFalse(scope["core"])
        self.assertFalse(scope["ssh"])
        self.assertFalse(scope["fuzz"])
        self.assertEqual(scope["languages"], ["swift"])

    def test_core_change_also_checks_the_app(self):
        scope = ci.scope_for_paths(["CortaTerminal/Sources/CortaTerminal/Parser.swift"])
        self.assertTrue(all(scope[name] for name in ("core", "app", "ssh", "fuzz")))
        self.assertEqual(scope["languages"], ["swift"])

    def test_script_only_and_feed_only(self):
        script = ci.scope_for_paths(["scripts/prepare-release.py"])
        self.assertTrue(script["script_tests"])
        self.assertFalse(script["core"])
        self.assertFalse(script["app"])
        self.assertEqual(script["languages"], ["python"])
        feed = ci.scope_for_paths(["appcast.xml"])
        self.assertTrue(feed["feed"])
        self.assertFalse(feed["app"])
        self.assertFalse(feed["core"])

    def test_mixed_changes_are_the_union(self):
        scope = ci.scope_for_paths(["README.md", "Corta/WindowController.swift", "scripts/prepare-release.py"])
        self.assertTrue(scope["app"])
        self.assertTrue(scope["script_tests"])
        self.assertFalse(scope["core"])
        self.assertEqual(scope["languages"], ["python", "swift"])

    def test_unknown_build_config_and_routing_changes_run_everything(self):
        for path in ("Corta.xcodeproj/project.pbxproj", "CortaTerminal/Package.swift",
                     "scripts/ci-docs-only.py", "scripts/codeql-extract.py", ".github/workflows/ci.yml",
                     "REUSE.toml", "scripts/prepare-release.sh", "unknown"):
            self.assertEqual(ci.scope_for_paths([path]), ci.full_scope(), path)

    def test_docs_and_configuration_reference(self):
        docs = ci.scope_for_paths(["README.md", "docs/TESTING.md"])
        self.assertFalse(any(docs[name] for name in ci.CHECKS))
        self.assertEqual(docs["languages"], [])
        reference = ci.scope_for_paths(["docs/CONFIGURATION.md"])
        self.assertTrue(reference["app"])
        self.assertFalse(reference["core"])


class CodeQLBaselineTests(DiffTests):
    def baseline(self, language="swift"):
        return {language: (7, self.base)}

    def test_analysed_inputs_by_language(self):
        cases = {
            "Corta/App.swift": {"swift"},
            "CortaTerminal/Sources/CortaTerminal/Parser.swift": {"swift"},
            "CortaTerminal/Tests/CortaTerminalTests/ParserTests.swift": set(),
            "CortaTests/AppTests.swift": set(),
            "Corta/Shim/shim.c": {"c-cpp"},
            "Corta/Shim/shim.h": {"c-cpp"},
            "scripts/prepare-release.py": {"python"},
            ".github/workflows/ci.yml": {"actions"},
            ".github/workflows/codeql.yml": set(ci.LANGUAGES),
            "scripts/codeql-extract.py": set(ci.LANGUAGES),
            "Corta.xcodeproj/project.pbxproj": {"swift", "c-cpp"},
            "CortaTerminal/Package.resolved": {"swift", "c-cpp"},
            "docs/TESTING.md": set(),
            "appcast.xml": set(),
        }
        for path, languages in cases.items():
            with self.subTest(path=path):
                self.assertEqual(ci.analysed_languages(path), languages)

    def test_latest_successful_main_analysis_per_language(self):
        analyses = [
            {"id": 5, "category": "/language:swift", "commit_sha": "b", "error": "failed"},
            {"id": 4, "category": "/language:swift", "commit_sha": "a", "error": ""},
            {"id": 3, "category": "/language:python", "commit_sha": "a", "error": ""},
            {"id": 2, "category": "/language:swift", "commit_sha": "old", "error": ""},
            {"id": 1, "category": "custom", "commit_sha": "a", "error": ""},
        ]
        requested = []
        with patch.dict(os.environ, GITHUB_REPOSITORY="owner/repo"):
            baselines = ci.main_baselines(lambda path: requested.append(path) or analyses)
        self.assertEqual(baselines, {"swift": (4, "a"), "python": (3, "a")})
        self.assertIn("ref=refs/heads/main", requested[0])

    def test_unchanged_inputs_reuse_and_changed_inputs_rescan(self):
        self.write("docs/TESTING.md", "docs")
        self.write("CortaTests/AppTests.swift", "test")
        docs = self.commit()
        self.assertEqual(ci.reusable_baselines(self.baseline(), docs, self.git), {"swift": 7})
        self.write("Corta/code.swift", "changed")
        code = self.commit()
        self.assertEqual(ci.reusable_baselines(self.baseline(), code, self.git), {})

    def test_change_since_baseline_counts_even_when_the_event_diff_is_docs(self):
        # A main scan that was cancelled or skipped must not leave a stale baseline.
        self.write("Corta/code.swift", "changed in an earlier push")
        self.commit()
        self.write("README.md", "docs")
        head = self.commit()
        self.assertEqual(ci.reusable_baselines(self.baseline(), head, self.git), {})

    def test_unknown_or_unrelated_baseline_commit_rescans(self):
        self.assertEqual(ci.reusable_baselines({"swift": (7, "1" * 40)}, self.base, self.git), {})
        tree = self.git(["rev-parse", "HEAD^{tree}"]).decode().strip()
        unrelated = self.git(["commit-tree", tree, "-m", "unrelated"]).decode().strip()
        self.assertEqual(ci.reusable_baselines({"swift": (7, unrelated)}, self.base, self.git), {})

    def test_pull_request_selection(self):
        reusable = {"swift": 1, "c-cpp": 2, "python": 3, "actions": 4}
        self.assertEqual(ci.select_languages("pull_request", [], reusable), ([], reusable))
        analyse, reused = ci.select_languages("pull_request", ["python"], reusable)
        self.assertEqual(analyse, ["python"])
        self.assertEqual(reused, {"swift": 1, "c-cpp": 2, "actions": 4})
        # Routing changes still validate every lane, and a missing baseline is scanned.
        self.assertEqual(ci.select_languages("pull_request", list(ci.LANGUAGES), reusable),
                         (list(ci.LANGUAGES), {}))
        self.assertEqual(ci.select_languages("pull_request", [], {"python": 3}),
                         (["swift", "c-cpp", "actions"], {"python": 3}))

    def test_main_push_rescans_changed_inputs_only(self):
        reusable = {"swift": 1, "c-cpp": 2, "python": 3}
        self.assertEqual(ci.select_languages("push", list(ci.LANGUAGES), reusable),
                         (["actions"], reusable))
        self.assertEqual(ci.select_languages("push", list(ci.LANGUAGES), {}), (list(ci.LANGUAGES), {}))


class LinkTests(unittest.TestCase):
    def test_code_fences_inline_code_reference_and_html(self):
        text = '\n'.join([
            '[a](docs/A.md) `[b](B.md)`', '````', '[c](C.md)',
            '```', '[still code](hidden.md)', '````',
            '[ref]: <docs/D%20E.md#part>', '<img src="assets/f.png">',
        ])
        self.assertEqual([destination for _, destination in links.destinations(text)],
                         ["docs/A.md", "docs/D%20E.md#part", "assets/f.png"])

    def test_local_paths_and_external_urls(self):
        root = Path("/repo")
        file = root / "docs/X.md"
        for url in ("https://example.com", "doc:Terminal", "mailto:a@b", "#section", "//example.com"):
            self.assertIsNone(links.local_target(url, file, root))
        self.assertEqual(links.local_target("D%20E.md#part", file, root), root / "docs/D E.md")
        self.assertEqual(links.local_target("/README.md?raw=1", file, root), root / "README.md")

    def test_missing_link_fails_and_ignored_files_are_not_scanned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", directory], check=True)
            (root / ".gitignore").write_text("ignored.md\n")
            (root / "ignored.md").write_text("[bad](missing.md)")
            (root / "README.md").write_text("[target](docs/A.md)")
            self.assertEqual(links.check(root), ["README.md:1: missing target: docs/A.md"])
            (root / "docs").mkdir()
            (root / "docs/A.md").write_text("[back](../README.md)")
            self.assertEqual(links.check(root), [])


if __name__ == "__main__":
    unittest.main()
