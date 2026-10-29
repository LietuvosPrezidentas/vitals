#!/bin/bash
# Builds Vitals.app.
#   ./build.sh           build only
#   ./build.sh install   also copy to ~/Applications and start it
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Vitals"

APP=build/Vitals.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Vitals"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature (no developer certificate on this Mac); hardened runtime stops code being injected.
codesign --force --sign - --identifier local.vitals.app --options runtime "$APP"
echo "built $APP"

if [[ " $* " == *" install "* ]]; then
  pkill -x Vitals || true
  sleep 0.5
  mkdir -p ~/Applications
  rm -rf ~/Applications/Vitals.app
  ditto "$APP" ~/Applications/Vitals.app
  open ~/Applications/Vitals.app
  echo "installed and started ~/Applications/Vitals.app"
fi
