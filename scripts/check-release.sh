#!/bin/bash
# The one packaging check (B15 / T11). `scripts/package-release.sh`,
# `scripts/release.sh`, `.github/workflows/release.yml` and
# `.github/workflows/appcast.yml` all call this
# rather than each carrying its own copy of the rules, so a local package
# and a CI package are rejected for the same reasons — and a rule added
# here reaches every route at once.
#
#   check-release.sh APP [--version V] [--archive ZIP] [--appcast]
#                        [--require-notarized]
#
# Always: the app's Info.plist agrees with project.pbxproj on the marketing
# version, the build number and the deployment target; the build number is
# an integer; CHANGELOG.md has a heading for the version; README.md names
# the release archive for it; the code signature verifies.
#
#   --version V          V (a tag with its `v` stripped) must be the version.
#   --archive ZIP        ZIP is named Corta-V.zip, holds Corta.app, and its
#                        ZIP.sha256 sidecar matches its contents.
#   --appcast            appcast.xml has an item for this version and build
#                        whose enclosure names the GitHub release URL for
#                        the archive and, with --archive, its exact length.
#   --require-notarized  the signature is a Developer ID one, Gatekeeper
#                        accepts the app, and the notarization ticket is
#                        stapled.
#
# Exit status is the number of failed checks; every failure is printed.
set -uo pipefail

if [ "$#" -lt 1 ]; then
  sed -n '2,25p' "$0" >&2
  exit 2
fi

app=$1; shift
expected_version=""
archive=""
check_appcast=false
require_notarized=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) expected_version=$2; shift 2 ;;
    --archive) archive=$2; shift 2 ;;
    --appcast) check_appcast=true; shift ;;
    --require-notarized) require_notarized=true; shift ;;
    *) echo "check-release: unknown argument $1" >&2; exit 2 ;;
  esac
done

repo_root=$(cd "$(dirname "$0")/.." && pwd)
pbxproj="$repo_root/Corta.xcodeproj/project.pbxproj"
plist="$app/Contents/Info.plist"
failures=0

fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
pass() { echo "ok    $*"; }

# One value per build setting across every configuration, or the project
# itself disagrees with itself.
project_setting() {
  local values
  values=$(grep -E "^\s*$1 = " "$pbxproj" | sed -E 's/.*= *"?([^";]*)"?;.*/\1/' | sort -u)
  if [ "$(echo "$values" | wc -l | tr -d ' ')" != "1" ]; then
    fail "$1 has more than one value in project.pbxproj: $(echo "$values" | tr '\n' ' ')"
    echo "$values" | head -1
  else
    echo "$values"
  fi
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null; }

if [ ! -d "$app" ] || [ ! -f "$plist" ]; then
  fail "no application bundle at $app"
  exit 1
fi

project_version=$(project_setting MARKETING_VERSION)
project_build=$(project_setting CURRENT_PROJECT_VERSION)
project_target=$(project_setting MACOSX_DEPLOYMENT_TARGET)
bundle_version=$(plist_value CFBundleShortVersionString)
bundle_build=$(plist_value CFBundleVersion)
bundle_target=$(plist_value LSMinimumSystemVersion)

# --- Versions ---------------------------------------------------------------

if [ "$bundle_version" = "$project_version" ] && [ -n "$bundle_version" ]; then
  pass "CFBundleShortVersionString $bundle_version matches MARKETING_VERSION"
else
  fail "CFBundleShortVersionString '$bundle_version' != MARKETING_VERSION '$project_version'"
fi

if [ -n "$expected_version" ]; then
  if [ "$bundle_version" = "$expected_version" ]; then
    pass "version matches the requested $expected_version"
  else
    fail "version '$bundle_version' != requested '$expected_version' (is the tag right?)"
  fi
fi

if [ "$bundle_build" = "$project_build" ] && [ -n "$bundle_build" ]; then
  pass "CFBundleVersion $bundle_build matches CURRENT_PROJECT_VERSION"
else
  fail "CFBundleVersion '$bundle_build' != CURRENT_PROJECT_VERSION '$project_build'"
fi
# Sparkle compares build numbers, so a non-integer or a repeated one makes
# an update invisible to everyone on the previous release.
if [[ "$bundle_build" =~ ^[0-9]+$ ]]; then
  pass "build number is an integer"
else
  fail "build number '$bundle_build' is not an integer Sparkle can compare"
fi

if [ "$bundle_target" = "$project_target" ] && [ -n "$bundle_target" ]; then
  pass "LSMinimumSystemVersion $bundle_target matches MACOSX_DEPLOYMENT_TARGET"
else
  fail "LSMinimumSystemVersion '$bundle_target' != MACOSX_DEPLOYMENT_TARGET '$project_target'"
fi

# --- Documents that name the version ---------------------------------------

if grep -q "^## \[$bundle_version\]" "$repo_root/CHANGELOG.md"; then
  pass "CHANGELOG.md has a [$bundle_version] section"
else
  fail "CHANGELOG.md has no '## [$bundle_version]' heading"
fi

if grep -q "Corta-$bundle_version\.zip" "$repo_root/README.md"; then
  pass "README.md names Corta-$bundle_version.zip"
else
  fail "README.md does not name Corta-$bundle_version.zip — its download instructions are stale"
fi

if grep -q "macOS $bundle_target" "$repo_root/README.md"; then
  pass "README.md states the macOS $bundle_target minimum"
else
  fail "README.md does not state 'macOS $bundle_target' as the minimum"
fi

# --- Signature -------------------------------------------------------------

if codesign --verify --deep --strict "$app" 2>/dev/null; then
  pass "code signature verifies"
else
  fail "codesign --verify --deep --strict failed for $app"
fi

if $require_notarized; then
  authority=$(codesign -dvv "$app" 2>&1 | grep '^Authority=' | head -1)
  if [[ "$authority" == *"Developer ID Application"* ]]; then
    pass "signed with a Developer ID identity"
  else
    fail "not signed with a Developer ID identity: ${authority:-no authority}"
  fi
  if xcrun stapler validate "$app" >/dev/null 2>&1; then
    pass "notarization ticket is stapled"
  else
    fail "no stapled notarization ticket (xcrun stapler validate)"
  fi
  if spctl --assess --type exec "$app" 2>/dev/null; then
    pass "Gatekeeper accepts the app"
  else
    fail "spctl --assess rejects the app"
  fi
fi

# --- Archive ---------------------------------------------------------------

archive_length=""
if [ -n "$archive" ]; then
  if [ "$(basename "$archive")" = "Corta-$bundle_version.zip" ]; then
    pass "archive is named Corta-$bundle_version.zip"
  else
    fail "archive is named $(basename "$archive"), not Corta-$bundle_version.zip"
  fi
  if [ -f "$archive" ] && unzip -Z1 "$archive" 2>/dev/null | grep -q '^Corta\.app/Contents/Info\.plist$'; then
    pass "archive contains Corta.app"
  else
    fail "archive $archive is missing or does not contain Corta.app at its root"
  fi
  if [ -f "$archive.sha256" ]; then
    recorded=$(cut -d' ' -f1 "$archive.sha256")
    actual=$(shasum -a 256 "$archive" | cut -d' ' -f1)
    if [ "$recorded" = "$actual" ]; then
      pass "sha256 sidecar matches the archive"
    else
      fail "sha256 sidecar ($recorded) does not match the archive ($actual)"
    fi
  else
    fail "no $archive.sha256 beside the archive"
  fi
  [ -f "$archive" ] && archive_length=$(stat -f %z "$archive")
fi

# --- Appcast ---------------------------------------------------------------

if $check_appcast; then
  appcast="$repo_root/appcast.xml"
  expected_url="https://github.com/noah-qin/Corta/releases/download/v$bundle_version/Corta-$bundle_version.zip"
  item=$(python3 - "$appcast" "$bundle_version" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(sys.argv[1]).getroot()
for item in root.iter("item"):
    short = item.findtext("sparkle:shortVersionString", namespaces=ns)
    if short != sys.argv[2]:
        continue
    enclosure = item.find("enclosure")
    print(item.findtext("sparkle:version", default="", namespaces=ns))
    print(enclosure.get("url", "") if enclosure is not None else "")
    print(enclosure.get("length", "") if enclosure is not None else "")
    print("signed" if enclosure is not None and enclosure.get("{%s}edSignature" % ns["sparkle"]) else "unsigned")
    break
PY
  )
  if [ -z "$item" ]; then
    fail "appcast.xml has no item for version $bundle_version"
  else
    appcast_build=$(echo "$item" | sed -n 1p)
    appcast_url=$(echo "$item" | sed -n 2p)
    appcast_length=$(echo "$item" | sed -n 3p)
    appcast_signed=$(echo "$item" | sed -n 4p)
    if [ "$appcast_build" = "$bundle_build" ]; then
      pass "appcast item carries build $bundle_build"
    else
      fail "appcast item for $bundle_version carries build '$appcast_build', app has $bundle_build"
    fi
    if [ "$appcast_url" = "$expected_url" ]; then
      pass "appcast enclosure points at the GitHub release archive"
    else
      fail "appcast enclosure url is '$appcast_url', expected $expected_url"
    fi
    if [ "$appcast_signed" = "signed" ]; then
      pass "appcast enclosure carries an EdDSA signature"
    else
      fail "appcast enclosure has no sparkle:edSignature"
    fi
    # Presence is not validity. A signature made with a private key whose
    # public half is not the SUPublicEDKey the shipped app carries is
    # well-formed and rejected by every installed Corta — an update nobody
    # can install, with every check above green. The sha256 sidecar does
    # not catch it: it proves the bytes are the published bytes, not that
    # the key pairs with the app.
    if [ -n "$archive" ]; then
      if swift "$repo_root/scripts/verify-appcast.swift" "$appcast" \
        "$repo_root/Sparkle-Info.plist" --archive "$archive" \
        --version "$bundle_version"; then
        pass "appcast signature verifies under the app's SUPublicEDKey"
      else
        fail "appcast signature does not verify under the app's SUPublicEDKey"
      fi
    fi
    if [ -n "$archive_length" ]; then
      if [ "$appcast_length" = "$archive_length" ]; then
        pass "appcast enclosure length matches the archive ($archive_length bytes)"
      else
        fail "appcast enclosure length $appcast_length != archive size $archive_length"
      fi
    fi
  fi
fi

if [ "$failures" -eq 0 ]; then
  echo "check-release: all checks passed for Corta $bundle_version ($bundle_build)"
else
  echo "check-release: $failures check(s) failed"
fi
exit "$failures"
