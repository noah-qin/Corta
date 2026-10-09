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

"""Exercise real Git history and release file updates in isolated fixtures."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepare_release", SCRIPTS / "prepare-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PrepareReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.original = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.original)
        self.addCleanup(self.temporary.cleanup)
        for name in release.FILES:
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
        (self.root / release.FILES[0]).write_text(
            "MARKETING_VERSION = 1.2.3;\nCURRENT_PROJECT_VERSION = 6;\n" * 2)
        (self.root / release.FILES[1]).write_text('public static let string = "1.2.3"\n')
        (self.root / "CHANGELOG.md").write_text(
            "# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- Recovery.\n\n"
            "## [1.2.3] — 2026-01-01\n\n- Old changes.\n\n"
            "[Unreleased]: https://github.com/noah-qin/Corta/compare/v1.2.3...main\n"
            "[1.2.3]: https://github.com/noah-qin/Corta/releases/tag/v1.2.3\n")
        (self.root / "README.md").write_text(
            "## Install\n\nRequires macOS 26.0; Intel last supported in [1.0.1](old).\n"
            "shasum -a 256 -c Corta-1.2.3.zip.sha256\nunzip Corta-1.2.3.zip\n\n"
            "> **Release status:** [1.2.3](tag),\n> published yesterday.\n\n"
            "For updates, install 1.1.1 shell integration.\n")
        (self.root / "appcast.xml").write_text(
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            '<channel><item><sparkle:version>9</sparkle:version></item></channel></rss>')
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgSign", "false")
        self.git("config", "tag.gpgSign", "false")
        self.commit("initial release")
        self.git("tag", "v1.2.3")
        self.commit("fix: recover $HOME and `literal`", empty=True)

    def git(self, *args):
        return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL).strip()

    def commit(self, message, empty=False):
        self.git("add", ".")
        self.git("commit", "-qm", message, *(('--allow-empty',) if empty else ()))

    def prepare(self, bump="patch"):
        return release.prepare(self.root, bump, "2026-10-06")

    def test_patch_keeps_all_versions_and_builds_consistent(self):
        self.assertEqual(self.prepare(), {"version": "1.2.4", "tag": "v1.2.4", "build": 10})
        project = (self.root / release.FILES[0]).read_text()
        self.assertEqual(project.count("MARKETING_VERSION = 1.2.4;"), 2)
        self.assertEqual(project.count("CURRENT_PROJECT_VERSION = 10;"), 2)
        self.assertIn('string = "1.2.4"', (self.root / release.FILES[1]).read_text())
        changelog = (self.root / "CHANGELOG.md").read_text()
        self.assertIn("## [Unreleased]\n\n## [1.2.4] — 2026-10-06", changelog)
        self.assertIn("- Recovery.", release.section(changelog, "1.2.4"))
        self.assertIn("fix: recover $HOME and `literal`", release.section(changelog, "1.2.4"))
        self.assertEqual(release.section(changelog, "1.2.3"), "- Old changes.")
        readme = (self.root / "README.md").read_text()
        self.assertIn("Corta-1.2.4.zip.sha256", readme)
        self.assertIn("[1.0.1](old)", readme)
        self.assertIn("1.1.1 shell integration", readme)

    def test_explicit_minor(self):
        self.assertEqual(self.prepare("minor")["version"], "1.3.0")

    def test_explicit_major(self):
        self.assertEqual(self.prepare("major")["version"], "2.0.0")

    def test_numeric_tag_order_ignores_prereleases(self):
        self.git("tag", "v1.2.9")
        self.git("tag", "v1.2.10")
        self.git("tag", "v9.0.0-beta")
        self.assertEqual(self.prepare()["version"], "1.2.11")

    def test_manually_chosen_higher_version_is_respected(self):
        for name in release.FILES[:2]:
            path = self.root / name
            path.write_text(path.read_text().replace("1.2.3", "1.3.0"))
        self.assertEqual(self.prepare()["version"], "1.3.0")

    def test_new_push_after_failed_preparation_gets_a_new_section(self):
        self.prepare()
        self.commit("chore: release 1.2.4")
        self.commit("fix: resolve signing failure", empty=True)
        self.assertEqual(self.prepare()["version"], "1.2.5")
        changelog = (self.root / "CHANGELOG.md").read_text()
        self.assertEqual(changelog.count("## [1.2.4]"), 1)
        self.assertIn("fix: resolve signing failure", release.section(changelog, "1.2.5"))

    def test_empty_unreleased_still_collects_commits(self):
        path = self.root / "CHANGELOG.md"
        path.write_text(path.read_text().replace("### Fixed\n\n- Recovery.\n\n", ""))
        self.commit("chore: publish 1.2.3 to the update feed", empty=True)
        self.prepare()
        notes = release.section(path.read_text(), "1.2.4")
        self.assertIn("fix: recover", notes)
        self.assertNotIn("chore: publish", notes)

    def test_invalid_metadata_does_not_partially_update_files(self):
        path = self.root / "CHANGELOG.md"
        path.write_text(path.read_text().replace("[Unreleased]:", "[Missing]:"))
        before = {name: (self.root / name).read_bytes() for name in release.FILES}
        with self.assertRaisesRegex(ValueError, "comparison link"):
            self.prepare()
        self.assertEqual(before, {name: (self.root / name).read_bytes() for name in release.FILES})

    def test_disagreeing_project_configurations_fail(self):
        path = self.root / release.FILES[0]
        path.write_text(path.read_text() + "MARKETING_VERSION = 1.2.2;\n")
        with self.assertRaisesRegex(ValueError, "disagree"):
            self.prepare()

    def test_first_release_without_tags(self):
        self.git("tag", "-d", "v1.2.3")
        self.assertEqual(self.prepare()["version"], "1.2.4")

    def test_rehearsal_changes_no_git_refs_and_creates_transferable_patch(self):
        (self.root / "scripts").mkdir()
        shutil.copy(SCRIPTS / "prepare-release.py", self.root / "scripts")
        refs = self.git("show-ref")
        output = self.root / "output.txt"
        environment = dict(os.environ, DRY_RUN="true", BUMP="patch", GITHUB_OUTPUT=str(output),
                           GITHUB_RUN_ID="42")
        result = subprocess.run(["bash", str(SCRIPTS / "prepare-release.sh")],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("show-ref"), refs)
        self.assertIn("tag=v1.2.4", output.read_text())
        self.assertIn("published=false", output.read_text())
        self.git("restore", ".")
        self.git("apply", "rehearsal.patch")
        self.assertIn('string = "1.2.4"', (self.root / release.FILES[1]).read_text())

    def automatic_fixture(self):
        """Mock only GitHub; branching, commits, push and fetch use real Git."""
        remote = self.root / "remote.git"
        self.git("init", "--bare", str(remote))
        self.git("branch", "-M", "main")
        self.git("remote", "add", "origin", str(remote))
        self.git("push", "-q", "origin", "main", "--tags")
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy(SCRIPTS / "prepare-release.py", scripts)
        shutil.copy(SCRIPTS / "check-pr-title.py", scripts)
        binaries = self.root / "bin"
        binaries.mkdir()
        gh = binaries / "gh"
        gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
path = pathlib.Path('github-state.json')
state = json.loads(path.read_text()) if path.exists() else {}
def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()
if args[:2] == ['pr', 'list']:
    print('1' if state else '')
elif args[:2] == ['pr', 'create']:
    state = {'state': 'OPEN', 'head': git('rev-parse', 'HEAD'), 'ci': 0}
    print('https://example.invalid/pull/1')
elif args[:2] == ['pr', 'view']:
    field = args[args.index('--json') + 1]
    print({'number': '1', 'state': state.get('state'), 'headRefOid': state.get('head'),
           'mergeCommit': state.get('head')}[field])
elif args[:2] == ['workflow', 'run']:
    state['ci'] += 1
elif args[:2] == ['run', 'list']:
    print('11')
elif args[:2] == ['run', 'watch']:
    pass
elif args[:2] == ['run', 'view']:
    for name in ('Terminal core (SwiftPM)', 'App, tests and the update feed'):
        print(f"{name}\t{state.get('conclusion', 'success')}\thttps://example.invalid/job")
    if state.get('title_job'):
        print("Pull request title\\tskipped\\thttps://example.invalid/title-job")
elif args[:1] == ['api'] and args[1].endswith('/pulls'):
    if state.get('title_api_error'):
        sys.exit(1)
    print(state.get('title', 'chore: release 1.2.4'))
elif args[:3] == ['api', '--method', 'POST']:
    fields = dict(arg.split('=', 1) for arg in args[4:] if '=' in arg)
    state.setdefault('statuses', []).append([args[3], fields['context'], fields['state']])
elif args[:2] == ['pr', 'merge']:
    git('--git-dir=remote.git', 'update-ref', 'refs/heads/main', state['head'])
    state['state'] = 'MERGED'
elif args[:2] == ['release', 'view']:
    if not state.get('published'):
        sys.exit(1)
    print(json.dumps({'isDraft': False, 'targetCommitish': state['head']}))
else:
    raise SystemExit('Unexpected GitHub command: ' + repr(args))
path.write_text(json.dumps(state))
''')
        gh.chmod(0o755)
        return dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                    DRY_RUN="false", BUMP="patch", GITHUB_RUN_ID="42",
                    GITHUB_OUTPUT=str(self.root / "output.txt"), RUNNER_TEMP=str(self.root),
                    GITHUB_REPOSITORY="noah-qin/Corta")

    def run_automatic(self, environment):
        return subprocess.run(["bash", str(SCRIPTS / "prepare-release.sh")],
                              env=environment, capture_output=True, text=True)

    def test_automatic_preparation_retries_same_merged_commit(self):
        environment = self.automatic_fixture()
        first = self.run_automatic(environment)
        self.assertEqual(first.returncode, 0, first.stderr)
        head = self.git("rev-parse", "HEAD")
        second = self.run_automatic(environment)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        state = json.loads((self.root / "github-state.json").read_text())
        self.assertEqual(state["ci"], 1)
        output = (self.root / "output.txt").read_text()
        self.assertEqual(output.count("tag=v1.2.4"), 2)
        self.assertEqual(output.count(f"commit={head}"), 2)

    def test_dispatched_ci_is_reported_as_the_pr_head_statuses(self):
        environment = self.automatic_fixture()
        result = self.run_automatic(environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads((self.root / "github-state.json").read_text())
        head = state["head"]
        self.assertEqual(state["statuses"], [
            [f"repos/noah-qin/Corta/statuses/{head}", "Terminal core (SwiftPM)", "success"],
            [f"repos/noah-qin/Corta/statuses/{head}", "App, tests and the update feed", "success"],
        ])

    def test_a_job_that_did_not_succeed_is_never_reported_as_passed(self):
        environment = self.automatic_fixture()
        bash = shutil.which("bash")
        (self.root / "github-state.json").write_text(json.dumps({"head": "abc", "conclusion": "cancelled"}))
        result = subprocess.run([bash, str(SCRIPTS / "report-ci-statuses.sh"), "11", "abc"],
                                env=environment, capture_output=True, text=True, cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads((self.root / "github-state.json").read_text())
        self.assertEqual([status[2] for status in state["statuses"]], ["failure", "failure"])

    def test_dispatched_title_status_checks_the_actual_bot_title(self):
        environment = self.automatic_fixture()
        for title, expected in (("chore: release 1.2.4", "success"),
                                ("chore: publish 1.2.4 to the update feed", "success"),
                                ("Fix releases", "failure"),
                                ("fix: preserve $(false) and `literal`", "success")):
            with self.subTest(title=title):
                state_path = self.root / "github-state.json"
                state_path.write_text(json.dumps({"head": "abc", "title_job": True, "title": title}))
                result = subprocess.run(["bash", str(SCRIPTS / "report-ci-statuses.sh"), "11", "abc"],
                                        env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                statuses = json.loads(state_path.read_text())["statuses"]
                self.assertEqual(statuses[-1][1:3], ["Pull request title", expected])

    def test_title_lookup_failure_is_not_reported_as_a_pass(self):
        environment = self.automatic_fixture()
        state_path = self.root / "github-state.json"
        state_path.write_text(json.dumps({"head": "abc", "title_job": True, "title_api_error": True}))
        result = subprocess.run(["bash", str(SCRIPTS / "report-ci-statuses.sh"), "11", "abc"],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        statuses = json.loads(state_path.read_text())["statuses"]
        self.assertEqual(statuses[-1][1:3], ["Pull request title", "failure"])

    def test_retry_of_published_release_only_hands_off_to_feed(self):
        environment = self.automatic_fixture()
        first = self.run_automatic(environment)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.git("tag", "v1.2.4")
        self.git("push", "origin", "refs/tags/v1.2.4")
        path = self.root / "github-state.json"
        state = json.loads(path.read_text())
        state["published"] = True
        path.write_text(json.dumps(state))
        second = self.run_automatic(environment)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("published=true", (self.root / "output.txt").read_text())

    def test_old_failed_run_cannot_overtake_a_newer_release(self):
        environment = self.automatic_fixture()
        first = self.run_automatic(environment)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.git("tag", "v1.3.0")
        second = self.run_automatic(environment)
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("newer release tag exists", second.stderr)


if __name__ == "__main__":
    unittest.main()
