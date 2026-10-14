#!/usr/bin/env bash
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

# Usage: cancel-held-pr-runs.sh <branch>
#
# The repository holds every outside contributor's workflow runs for
# approval, and github-actions[bot] counts as one: opening the version or
# feed PR leaves a pull_request run of each PR workflow waiting, with no
# jobs. Nobody approves it — the dispatched CI is what the PR is checked
# by (report-ci-statuses.sh) — so when the PR merges and its branch is
# deleted, GitHub marks the held run failed, "likely because of a workflow
# file issue". Every release then showed two red runs (1.2.0: #783, #786;
# 1.2.1: #805, #807) beside a green one.
#
# Cancelling the held runs leaves them grey instead. A run GitHub will not
# cancel is deleted, since it never ran anything. This tidies the run
# list and nothing else, so a failure here is a warning, never a failed
# release.
set -uo pipefail

branch=$1
runs=$(gh run list --branch "$branch" --event pull_request --status action_required \
  --limit 50 --json databaseId --jq '.[].databaseId' 2>/dev/null) || {
  echo "::warning::Could not list held pull_request runs on $branch."
  exit 0
}

for run in $runs; do
  if gh run cancel "$run" >/dev/null 2>&1; then
    echo "Cancelled held pull_request run $run on $branch."
  elif gh api --method DELETE "repos/$GITHUB_REPOSITORY/actions/runs/$run" >/dev/null 2>&1; then
    echo "Deleted held pull_request run $run on $branch."
  else
    echo "::warning::Held pull_request run $run on $branch is left as it is."
  fi
done
exit 0
