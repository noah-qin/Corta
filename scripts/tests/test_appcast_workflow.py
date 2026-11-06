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

"""Hold the signing job to what it may run: nothing from the tag's tree.

The Sparkle key cannot be revoked (D20), and every step of a job in the
`release` environment can reach it: the runner holds the job's secrets, and
a step can replace the tools a later one runs. So what matters is the whole
job, not only the step that names the key. Workflows cannot be run here; these
read the file, which `actionlint` and a rehearsal still have to confirm.
"""

import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/appcast.yml").read_text(encoding="utf-8")
# What runs repository code, or the tool the key is handed to.
RUNS_REPOSITORY_CODE = re.compile(r"swift run|swift scripts/|scripts/|--package-path|generate_appcast")
# What would put another commit's files where something could run them.
MOVES_THE_TREE = re.compile(r"git (checkout|switch|worktree|archive|reset|restore)")


def job(name):
    """The lines of one job, by its two-space indent under `jobs:`."""
    lines = WORKFLOW[WORKFLOW.index("\njobs:\n"):].splitlines()
    start = lines.index(f"  {name}:")
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"  \S", lines[i])), len(lines))
    return lines[start:end]


def steps(name):
    """Each step of a job, as its text."""
    found, current = [], None
    for line in job(name):
        if line.startswith("      - "):
            current = [line]
            found.append(current)
        elif current is not None:
            current.append(line)
    return ["\n".join(step) for step in found]


class SigningJobTests(unittest.TestCase):
    def setUp(self):
        self.steps = steps("sign")

    def index(self, text):
        return next(i for i, step in enumerate(self.steps) if text in step)

    def test_the_job_checks_out_main_and_only_main(self):
        checkouts = [step for step in self.steps if "actions/checkout" in step]
        self.assertEqual(len(checkouts), 1)
        self.assertRegex(checkouts[0], r"\n\s+ref: main\n")
        self.assertIn("persist-credentials: false", checkouts[0])
        self.assertEqual(self.index("actions/checkout"), 0)

    def test_no_step_moves_another_commit_into_the_tree(self):
        for step in self.steps:
            self.assertNotRegex(step, MOVES_THE_TREE, step)

    def test_the_tag_must_be_on_main_before_any_repository_code(self):
        ancestor = self.index("git merge-base --is-ancestor")
        self.assertIn('"$commit" origin/main', self.steps[ancestor])
        first_code = next(i for i, step in enumerate(self.steps) if RUNS_REPOSITORY_CODE.search(step))
        self.assertLess(ancestor, first_code)

    def test_the_tag_is_resolved_once_to_a_commit(self):
        step = self.steps[self.index("git merge-base --is-ancestor")]
        self.assertIn('refs/tags/$tag^{commit}', step)
        self.assertIn('commit=$commit', step)
        self.assertIn("--source-ref", self.steps[self.index("corta-release-check")])
        self.assertIn("steps.version.outputs.commit", self.steps[self.index("corta-release-check")])

    def test_only_the_signing_step_holds_a_secret(self):
        holders = [step for step in self.steps if "secrets." in step]
        self.assertEqual(len(holders), 1)
        self.assertIn("SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}", holders[0])

    def test_the_signing_step_runs_only_the_pinned_tool(self):
        step = self.steps[self.index("secrets.SPARKLE_PRIVATE_KEY")]
        self.assertIn("sparkle/bin/generate_appcast", step)
        without_tool = step.replace("sparkle/bin/generate_appcast", "")
        self.assertNotRegex(without_tool, re.compile(r"scripts/|swift|python|\./|CortaTerminal|bash |make "))

    def test_the_header_is_refreshed_by_mains_script_without_the_key(self):
        step = self.steps[self.index("appcast-header.py")]
        self.assertNotIn("secrets.", step)
        self.assertNotIn("SPARKLE_PRIVATE_KEY", step)
        self.assertLess(self.index("appcast-header.py"), self.index("secrets.SPARKLE_PRIVATE_KEY"))

    def test_the_feed_is_checked_after_it_is_signed_and_before_it_is_handed_on(self):
        self.assertLess(self.index("secrets.SPARKLE_PRIVATE_KEY"), self.index("corta-release-check"))
        self.assertLess(self.index("corta-release-check"), self.index("actions/upload-artifact"))

    def test_the_tag_input_reaches_no_shell_directly(self):
        for line in job("sign"):
            if "${{ inputs.tag }}" in line:
                self.assertRegex(line, r"^\s+TAG: ")


class RehearsalTests(unittest.TestCase):
    def test_a_manual_run_can_stop_before_publishing(self):
        dispatch = WORKFLOW[WORKFLOW.index("workflow_dispatch:"):WORKFLOW.index("\nconcurrency:")]
        self.assertRegex(dispatch, r"dry_run:\n(.*\n)*?\s+type: boolean")
        self.assertIn("if: ${{ !inputs.dry_run && needs.sign.outputs.changed == 'true' }}", "\n".join(job("publish")))


class SparklePinTests(unittest.TestCase):
    def test_the_release_guide_names_the_version_the_app_is_pinned_to(self):
        resolved = json.loads((ROOT / "Corta.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
                              .read_text(encoding="utf-8"))
        pin = next(p["state"] for p in resolved["pins"] if p["identity"] == "sparkle")
        guide = (ROOT / "docs/RELEASING.md").read_text(encoding="utf-8")
        self.assertIn(f"Sparkle {pin['version']} is pinned to revision", guide)
        self.assertIn(pin["revision"], guide)
        self.assertIn(f'SPARKLE_VERSION: "{pin["version"]}"', WORKFLOW)


if __name__ == "__main__":
    unittest.main()
