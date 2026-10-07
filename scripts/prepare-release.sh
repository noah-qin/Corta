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

# Called only by Release on main. The version PR obeys the normal CI rules.
set -euo pipefail

branch="chore/release-${GITHUB_RUN_ID}"
files=(Corta.xcodeproj/project.pbxproj CortaTerminal/Sources/CortaTerminal/Version.swift CHANGELOG.md README.md)

if [ "${DRY_RUN:-false}" = true ]; then
  metadata=$(python3 scripts/prepare-release.py --bump "${BUMP:-patch}")
  git diff --binary -- "${files[@]}" > rehearsal.patch
  {
    echo "tag=$(jq -r .tag <<< "$metadata")"
    echo "commit=$(git rev-parse HEAD)"
    echo "published=false"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

# A run rerun after a signing/upload/feed failure must use the same version
# and commit. A new manual dispatch prepares a new release on another branch.
pr=$(gh pr list --head "$branch" --base main --state all --json number --jq '.[0].number // empty')
if [ -z "$pr" ]; then
  metadata=$(python3 scripts/prepare-release.py --bump "${BUMP:-patch}")
  tag=$(jq -r .tag <<< "$metadata")
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git checkout -b "$branch"
  git add -- "${files[@]}"
  git commit -m "chore: release ${tag#v}"
  # The same run may have stopped between pushing and opening its PR.
  # Never overwrite a branch somebody else changed.
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
    git fetch origin "$branch"
    test "$(git diff --stat HEAD FETCH_HEAD)" = "" || {
      echo '::error::Existing preparation branch differs; inspect it before retrying.'; exit 1;
    }
    git reset --hard FETCH_HEAD
  else
    git push -u origin "$branch"
  fi
  cat > "$RUNNER_TEMP/release-pr.md" <<'BODY'
Automatically synchronizes the application and terminal version, advances the Sparkle build number, closes Unreleased with the changes and commit subjects, and refreshes the download instructions.

The Release workflow explicitly runs CI, merges this PR once required checks pass, and builds that exact merge commit. Publication still requires tests, Developer ID signing, Apple notarisation and the release checks.
BODY
  url=$(gh pr create --base main --head "$branch" --title "chore: release ${tag#v}" \
    --body-file "$RUNNER_TEMP/release-pr.md")
  pr=$(gh pr view "$url" --json number --jq .number)
fi

state=$(gh pr view "$pr" --json state --jq .state)
if [ "$state" = CLOSED ]; then
  echo "::error::Release PR #$pr was closed without merging. Inspect it before retrying."
  exit 1
fi
if [ "$state" != MERGED ]; then
  # GITHUB_TOKEN-created PRs do not trigger pull_request workflows.
  expected=$(gh pr view "$pr" --json headRefOid --jq .headRefOid)
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gh workflow run ci.yml --ref "$branch"
  run_id=""
  for _ in $(seq 1 24); do
    run_id=$(gh run list --workflow ci.yml --branch "$branch" --event workflow_dispatch \
      --limit 20 --json databaseId,headSha,createdAt \
      --jq ".[] | select(.headSha == \"$expected\" and .createdAt >= \"$started\") | .databaseId" | head -1)
    [ -z "$run_id" ] || break
    sleep 5
  done
  test -n "$run_id" || { echo '::error::Preparation CI did not start.'; exit 1; }
  gh run watch "$run_id" --exit-status --interval 30
  bash "$(dirname "$0")/report-ci-statuses.sh" "$run_id" "$expected"
  gh pr merge "$pr" --squash --auto --delete-branch --match-head-commit "$expected"
  # Do not sign while auto-merge is merely pending (strict required checks).
  for _ in $(seq 1 120); do
    state=$(gh pr view "$pr" --json state --jq .state)
    [ "$state" != MERGED ] || break
    [ "$state" != CLOSED ] || { echo '::error::Preparation PR was closed.'; exit 1; }
    sleep 10
  done
  test "$state" = MERGED || { echo '::error::Preparation PR is still awaiting merge; rerun after resolving its checks.'; exit 1; }
fi

commit=$(gh pr view "$pr" --json mergeCommit --jq .mergeCommit.oid)
git fetch origin main
git checkout --detach "$commit"
version=$(python3 -c 'import re; from pathlib import Path; print(re.search(r"MARKETING_VERSION = ([^;]+);", Path("Corta.xcodeproj/project.pbxproj").read_text())[1])')
tag="v$version"
# An old failed run must not make an older version the latest release after
# a newer pipeline has completed. Start a new main run to release fixes.
VERSION="$version" python3 - <<'PY'
import os
import re
import subprocess
version = tuple(map(int, os.environ['VERSION'].split('.')))
tags = subprocess.check_output(['git', 'tag'], text=True).splitlines()
if any(tuple(map(int, tag[1:].split('.'))) > version
       for tag in tags if re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag)):
    raise SystemExit('A newer release tag exists; refusing to resume an older release.')
PY
published=false
if gh release view "$tag" --json isDraft,targetCommitish > "$RUNNER_TEMP/release.json"; then
  if [ "$(jq -r .isDraft "$RUNNER_TEMP/release.json")" = false ]; then
    git fetch origin "refs/tags/$tag:refs/tags/$tag"
    test "$(git rev-parse "$tag^{commit}")" = "$commit" || {
      echo "::error::$tag was published from another commit"; exit 1;
    }
    published=true
  fi
fi
{
  echo "tag=$tag"
  echo "commit=$commit"
  echo "published=$published"
} >> "$GITHUB_OUTPUT"
