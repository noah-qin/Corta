#!/bin/bash
# Prints the path to the most recently built Release Corta.app, or exits 1
# with a message on stderr. Shared by the measurement scripts in this
# directory so each doesn't re-guess the DerivedData path.
set -euo pipefail

app=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -maxdepth 6 -type d -path "*/Build/Products/Release/Corta.app" \
  -print0 2>/dev/null | xargs -0 ls -dt 2>/dev/null | head -1)

if [ -z "$app" ] || [ ! -d "$app" ]; then
  echo "error: no Release Corta.app found under DerivedData." >&2
  echo "  Build one first:" >&2
  echo "  xcodebuild -project Corta.xcodeproj -scheme Corta -configuration Release build" >&2
  exit 1
fi

echo "$app"
