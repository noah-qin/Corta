#!/bin/bash
# Signs one already-built, notarized release archive into appcast.xml.
#
# `.github/workflows/release.yml` is what builds, signs, notarizes, staples
# and drafts the GitHub Release when a `v*` tag is pushed — this script does
# not repeat any of that (building the same artifact in two places is how
# they drift). Run this after downloading that workflow's .zip from the
# draft release you have reviewed and are ready to publish.
#
# Requires, once per machine:
#   - Sparkle's generate_keys already run (its private key lives in the
#     login keychain; this script only needs to find the CLI binaries)
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 PATH_TO_DOWNLOADED_RELEASE_ZIP" >&2
  echo "  e.g. $0 ~/Downloads/Corta-0.1.0.zip" >&2
  exit 2
fi

archive=$1
test -f "$archive" || { echo "error: no such file: $archive" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$repo_root/.build/appcast-sign"
rm -rf "$work"
mkdir -p "$work"
cp "$archive" "$work/"
cp "$repo_root/appcast.xml" "$work/appcast.xml"

# Sparkle's CLI tools (sign_update/generate_appcast) are not vendored — they
# come down as part of the SPM package artifact into DerivedData, whose path
# includes a build-specific hash. Locate the most recent match rather than
# hardcode one machine's path, and let SPARKLE_BIN_DIR override it.
if [ -n "${SPARKLE_BIN_DIR:-}" ]; then
  sparkle_bin="$SPARKLE_BIN_DIR"
else
  sparkle_bin=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -maxdepth 6 -type d -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" \
    -print0 2>/dev/null | xargs -0 ls -dt 2>/dev/null | head -1)
fi
if [ -z "$sparkle_bin" ] || [ ! -x "$sparkle_bin/generate_appcast" ]; then
  echo "error: can't find Sparkle's generate_appcast. Open Corta.xcodeproj in" >&2
  echo "Xcode once to resolve packages, or set SPARKLE_BIN_DIR to the" >&2
  echo "directory containing generate_appcast/sign_update." >&2
  exit 1
fi

echo "==> Signing $archive into the update feed"
"$sparkle_bin/generate_appcast" "$work"
cp "$work/appcast.xml" "$repo_root/appcast.xml"

cat <<EOF

Done. appcast.xml updated in place at $repo_root/appcast.xml.

Left to do by hand:
  1. Review the diff: git -C "$repo_root" diff appcast.xml
  2. Commit and push it — that is what makes the update visible to every
     already-installed Corta (INFOPLIST_KEY_SUFeedURL points straight at
     this file on the main branch, no separate server).
EOF
