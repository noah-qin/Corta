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

"""Reuse preparation tests only for the same source tree and pinned toolchain."""

import json
import os
from pathlib import Path
import re
import subprocess


def successful_tests(run, head):
    if run.get("headSha") != head or run.get("conclusion") != "success":
        return False
    expected = {"Terminal core (SwiftPM)": "Test", "App, tests and the update feed": "Build and test"}
    jobs = {job["name"]: job for job in run.get("jobs", [])}
    return all(name in jobs and jobs[name].get("conclusion") == "success" and
               any(step["name"] == step_name and step.get("conclusion") == "success"
                   for step in jobs[name].get("steps", []))
               for name, step_name in expected.items())


def can_reuse(run, head, tested_tree, release_tree, ci_pin, release_pin, dry_run, clean):
    return (not dry_run and clean and bool(tested_tree) and tested_tree == release_tree and
            bool(ci_pin) and ci_pin == release_pin and successful_tests(run, head))


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def main():
    reuse = False
    run_id, head = os.environ.get("CI_RUN", ""), os.environ.get("TESTED_HEAD", "")
    if os.environ.get("DRY_RUN") != "true" and re.fullmatch(r"[0-9]+", run_id) and re.fullmatch(r"[0-9a-f]{40}", head):
        try:
            run = json.loads(subprocess.check_output(
                ["gh", "run", "view", run_id, "--json", "headSha,conclusion,jobs"], text=True))
            subprocess.run(["git", "fetch", "origin", head], check=True)
            reuse = can_reuse(run, head, git("rev-parse", head + "^{tree}"), git("rev-parse", "HEAD^{tree}"),
                              git("show", head + ":.xcode-version"), Path(".xcode-version").read_text().strip(), False,
                              not git("status", "--porcelain", "--untracked-files=no"))
        except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
            print(f"Preparation evidence unavailable; running tests: {error}")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"reuse={str(reuse).lower()}\n")
    print("Reuse verified preparation tests." if reuse else "Run release tests; matching preparation evidence is unavailable.")


if __name__ == "__main__":
    main()
