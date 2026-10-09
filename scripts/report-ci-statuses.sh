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

# Usage: report-ci-statuses.sh <ci-run-id> <commit>
#
# A PR opened with GITHUB_TOKEN starts no pull_request workflow, so Release
# and the feed dispatch CI on the branch instead. GitHub does not count a
# workflow_dispatch run's checks toward a PR's required checks, though: the
# 1.1.5 version PR sat BLOCKED behind two green checks until it timed out.
# This copies each job's conclusion from that run onto the commit as a
# status of the same name — what the ruleset requires — linked to the job.
# A job that did not succeed is reported as failed, never as passed.
set -euo pipefail

run_id=$1
commit=$2
jobs=$(gh run view "$run_id" --json jobs \
  --jq '.jobs[] | [.name, (.conclusion // ""), .url] | @tsv')
test -n "$jobs" || { echo "::error::CI run $run_id has no jobs to report."; exit 1; }

while IFS=$'\t' read -r name conclusion url; do
  # Bot-created PRs receive workflow_dispatch checks instead of PR events.
  # The PR-only title job is skipped there; validate the actual matching
  # PR title with the same checker before reporting its required status.
  if [ "$name" = "Pull request title" ] && [ "$conclusion" = skipped ]; then
    if title=$(gh api "repos/$GITHUB_REPOSITORY/commits/$commit/pulls" \
      --jq "map(select(.state == \"open\" and .head.sha == \"$commit\")) | if length == 1 then .[0].title else error(\"Expected one open PR for CI head\") end") &&
       PR_TITLE="$title" python3 -B scripts/check-pr-title.py; then
      conclusion=success
    else
      conclusion=failure
    fi
  fi
  state=failure
  [ "$conclusion" != success ] || state=success
  gh api --method POST "repos/$GITHUB_REPOSITORY/statuses/$commit" \
    -f state="$state" -f context="$name" -f target_url="$url" \
    -f description="CI run $run_id (workflow_dispatch): $conclusion" > /dev/null
  echo "$name: $state (CI run $run_id)"
done <<< "$jobs"
