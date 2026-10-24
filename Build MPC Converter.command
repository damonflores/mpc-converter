#!/bin/bash
# Double-click me in Finder to build "MPC Converter.app" (opens Terminal).
cd "$(dirname "$0")"
xattr -dr com.apple.quarantine . 2>/dev/null
if ./build.sh; then
  echo ""
  echo "Done. MPC Converter.app is in the build folder (Finder window opened)."
else
  echo ""
  echo "Build failed. Copy everything above and paste it to Claude."
fi
read -n 1 -s -r -p "Press any key to close…"
