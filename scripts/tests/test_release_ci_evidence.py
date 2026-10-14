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

"""Release must rerun tests whenever matching successful preparation evidence is absent."""

import importlib.util
from pathlib import Path
import unittest
import json
import os
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("evidence", Path(__file__).resolve().parents[1] / "release-ci-evidence.py")
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.run = {"headSha": "head", "conclusion": "success", "jobs": [
            {"name": name, "conclusion": "success", "steps": [{"name": step, "conclusion": "success"}]}
            for name, step in (("Terminal core (SwiftPM)", "Test"),
                               ("App, tests and the update feed", "Build and test"))
        ]}

    def reuse(self, **overrides):
        arguments = dict(run=self.run, head="head", tested_tree="tree", release_tree="tree",
                         ci_pin="26.6.0", release_pin="26.6.0", dry_run=False, clean=True)
        arguments.update(overrides)
        return evidence.can_reuse(**arguments)

    def test_same_tree_and_successful_tests_can_be_reused(self):
        self.assertTrue(self.reuse())

    def test_dry_run_dirty_tree_changed_source_or_toolchain_runs_tests(self):
        for change in ({"dry_run": True}, {"clean": False}, {"release_tree": "different"},
                       {"tested_tree": ""}, {"release_pin": "27.0"}, {"head": "other"}):
            self.assertFalse(self.reuse(**change), change)

    def test_failed_missing_or_skipped_tests_are_not_evidence(self):
        self.run["conclusion"] = "failure"
        self.assertFalse(self.reuse())
        self.run["conclusion"] = "success"
        self.run["jobs"][0]["steps"][0]["conclusion"] = "skipped"
        self.assertFalse(self.reuse())
        self.run["jobs"].pop()
        self.assertFalse(self.reuse())


    def test_cli_checks_real_git_trees_and_dirty_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.PIPE, text=True).strip()
            git("init", "-q")
            git("config", "user.name", "Test")
            git("config", "user.email", "test@example.invalid")
            (root / ".xcode-version").write_text("26.6.0\n")
            (root / "README.md").write_text("source")
            git("add", ".")
            git("commit", "-qm", "tested")
            head = git("rev-parse", "HEAD")
            git("clone", "-q", "--bare", ".", "remote.git")
            git("remote", "add", "origin", str(root / "remote.git"))
            git("commit", "--allow-empty", "-qm", "squash with identical source")
            self.run["headSha"] = head
            (root / "run.json").write_text(json.dumps(self.run))
            binary = root / "bin"
            binary.mkdir()
            gh = binary / "gh"
            gh.write_text('#!/bin/sh\ncat "' + str(root / "run.json") + '"\n')
            gh.chmod(0o755)
            output = root / "output"
            env = dict(os.environ, PATH=str(binary) + ":" + os.environ["PATH"], CI_RUN="123",
                       TESTED_HEAD=head, DRY_RUN="false", GITHUB_OUTPUT=str(output))
            def invoke():
                output.write_text("")
                result = subprocess.run([sys.executable, "-B", str(Path(evidence.__file__))],
                                        cwd=root, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                return output.read_text()
            self.assertEqual(invoke(), "reuse=true\n")
            (root / "README.md").write_text("dirty source")
            self.assertEqual(invoke(), "reuse=false\n")
            git("restore", "README.md")
            (root / "README.md").write_text("new committed source")
            git("add", "README.md")
            git("commit", "-qm", "different tree")
            self.assertEqual(invoke(), "reuse=false\n")


if __name__ == "__main__":
    unittest.main()
