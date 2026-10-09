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

"""Validate a squash-merge subject using CONTRIBUTING's commit convention."""

import os
import re
import sys

TYPES = ("feat", "fix", "docs", "style", "refactor", "perf", "test",
         "build", "ci", "chore", "revert")
SUBJECT = re.compile(
    r"(" + "|".join(TYPES) + r")(?:\([a-z0-9][a-z0-9._/-]*\))?!?: ([a-z].*)")


def validate(title):
    """Return an actionable error, or None; scopes are not an allowlist."""
    if any(ord(character) < 32 or ord(character) == 127 for character in title):
        return "Use a single line without control characters."
    if len(title) > 72:
        return "Keep the complete title at 72 characters or fewer."
    if not SUBJECT.fullmatch(title):
        return ("Use type(scope): description with an allowed type, an optional "
                "lowercase scope and !, and a lowercase description first letter. "
                "Allowed types: " + ", ".join(TYPES) + ".")
    if title.endswith("."):
        return "Do not end the title with a period."
    if title != title.rstrip():
        return "Do not end the title with whitespace."
    return None


def main():
    # The workflow passes untrusted title text through env, never shell source.
    error = validate(os.environ.get("PR_TITLE", ""))
    if error:
        print("Invalid PR title: " + error, file=sys.stderr)
        return 1
    print("PR title follows the commit convention.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
