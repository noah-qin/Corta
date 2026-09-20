#!/bin/bash
# Signs one already-built, notarized release archive into appcast.xml.
#
# `.github/workflows/release.yml` is what builds, signs, notarizes, staples
# and drafts the GitHub Release when a `v*` tag is pushed, and
# `.github/workflows/appcast.yml` is what signs the published release into
# appcast.xml (D20) — this script does not repeat any of that (building
# the same artifact in two places is how they drift). It is the manual
# route for when the workflow cannot run: download the published .zip,
# run this, and open a pull request with the result.
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

# "Corta-0.1.0.zip" -> "v0.1.0": the tag whose GitHub Release actually
# hosts this exact archive. Without --download-url-prefix,
# generate_appcast defaults the enclosure URL to raw.githubusercontent.com
# on main, which hosts appcast.xml itself but never the archive — every
# update would advertise successfully and then 404 on download.
archive_name=$(basename "$archive")
version=$(echo "$archive_name" | sed -E 's/^Corta-(.+)\.zip$/\1/')
if [ "$version" = "$archive_name" ]; then
  echo "error: expected a filename like Corta-X.Y.Z.zip, got: $archive_name" >&2
  exit 1
fi
download_url_prefix="https://github.com/noah-qin/Corta/releases/download/v${version}/"

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
echo "    Download URL prefix: $download_url_prefix"
"$sparkle_bin/generate_appcast" --download-url-prefix "$download_url_prefix" "$work"
cp "$work/appcast.xml" "$repo_root/appcast.xml"

# The archive just signed is the one the feed now advertises: unzip it and
# hold the app, the archive, the sidecar and the new appcast entry to the
# one check every packaging route runs (B15). A feed entry whose build
# number, URL or length disagrees with the archive is an update nobody can
# install, and this is the last moment it can be caught before the push.
echo "==> Checking the app, the archive and the appcast entry agree"
unpacked="$work/unpacked"
rm -rf "$unpacked"
mkdir -p "$unpacked"
ditto -x -k "$archive" "$unpacked"
sidecar="$archive.sha256"
if [ ! -f "$sidecar" ]; then
  shasum -a 256 "$archive" > "$sidecar"
fi
"$repo_root/scripts/check-release.sh" "$unpacked/Corta.app" --version "$version" \
  --archive "$archive" --appcast --require-notarized

cat <<EOF

Done. appcast.xml updated in place at $repo_root/appcast.xml.

Left to do by hand:
  1. Review the diff: git -C "$repo_root" diff appcast.xml
  2. Commit and push it — that is what makes the update visible to every
     already-installed Corta (INFOPLIST_KEY_SUFeedURL points straight at
     this file on the main branch, no separate server).
EOF
