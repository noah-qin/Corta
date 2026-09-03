#!/bin/bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 APP_PATH VERSION [OUTPUT_DIRECTORY]" >&2
  exit 2
fi

app=$1
version=$2
output_directory=${3:-dist}

test -d "$app" || { echo "application not found: $app" >&2; exit 1; }
mkdir -p "$output_directory"

archive="$output_directory/Corta-$version.zip"
codesign --verify --deep --strict --verbose=2 "$app"
ditto -c -k --keepParent --sequesterRsrc "$app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"

echo "$archive"
cat "$archive.sha256"
