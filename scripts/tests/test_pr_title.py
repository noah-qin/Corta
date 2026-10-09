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

"""Check accepted bot titles, convention boundaries and hostile input."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-pr-title.py"
spec = importlib.util.spec_from_file_location("pr_title", SCRIPT)
titles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(titles)


class PRTitleTests(unittest.TestCase):
    def test_every_documented_type_and_open_scope(self):
        for kind in titles.TYPES:
            for scope in ("", "(terminal)", "(new-scope)", "(ssh/sftp)"):
                for breaking in ("", "!"):
                    with self.subTest(kind=kind, scope=scope, breaking=breaking):
                        self.assertIsNone(titles.validate(f"{kind}{scope}{breaking}: improve input"))

    def test_release_and_dependabot_titles(self):
        for title in ("chore: release 1.1.9", "chore: publish 1.1.9 to the update feed",
                      "ci: bump actions/checkout from 6 to 7",
                      "build(deps): bump Sparkle from 2.9.6 to 2.10.0"):
            self.assertIsNone(titles.validate(title))

    def test_length_boundary_includes_prefix(self):
        self.assertIsNone(titles.validate("fix: " + "a" * 67))
        self.assertIsNotNone(titles.validate("fix: " + "a" * 68))

    def test_invalid_titles(self):
        for title in ("", "Fix shortcut hints", "feature: add something", "FIX: improve input",
                      "fix(UI): improve input", "fix(): improve input", "fix:Improve input",
                      "fix: Improve input", "fix: improve input.", "fix: improve input ",
                      "fix: improve\ninput", "fix: improve\rinput", "fix: improve\tinput"):
            with self.subTest(title=title):
                self.assertIsNotNone(titles.validate(title))

    def test_cli_uses_env_without_executing_title(self):
        title = "fix: preserve $HOME and `literal` and $(false)"
        result = subprocess.run([sys.executable, str(SCRIPT)],
                                env=dict(os.environ, PR_TITLE=title), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(title, result.stdout)
        failed = subprocess.run([sys.executable, str(SCRIPT)],
                                env=dict(os.environ, PR_TITLE="Fix input"), capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1)
        self.assertIn("Invalid PR title", failed.stderr)


if __name__ == "__main__":
    unittest.main()
