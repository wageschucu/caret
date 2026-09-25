#!/bin/sh
# Builds Caret.app from the Swift package. Command Line Tools are enough; Xcode is not required.
# Usage: apps/mac/build.sh [--run | --install]
#   --run      relaunch from apps/mac/build/Caret.app
#   --install  copy to /Applications/Caret.app and relaunch from there (use this for the login item)
set -eu
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"
swift build -c release 2>&1 | grep -v '^\[' || true
BIN=".build/release/Caret"
test -x "$BIN" || { echo "build failed"; exit 1; }
APP="build/Caret.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Caret"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Caret</string>
  <key>CFBundleIdentifier</key><string>com.paulgettel.caret</string>
  <key>CFBundleName</key><string>Caret</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
  <key>CFBundleIconFile</key><string>Caret</string>
  <key>CaretHelperRepo</key><string>__REPO__</string>
  <key>NSAppleEventsUsageDescription</key><string>Caret searches your recent Mail messages when you ask it to reply to one. Nothing is sent or changed in Mail.</string>
  <key>NSContactsUsageDescription</key><string>Caret looks up people you name when drafting an email, so the address is filled in. Matches stay on this Mac.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Caret adds events you confirm to your calendar, and removes them when you press Undo.</string>
</dict>
</plist>
EOF
# Sign. An ad-hoc signature ("-") changes with every build, and macOS ties the Accessibility
# grant to the signature, so each rebuild must be re-approved. Set CARET_SIGN_IDENTITY to the
# name of a code-signing certificate (a self-signed one from Keychain Access is enough) to keep
# a stable identity across rebuilds.
# Unset: use "Caret Dev" automatically when that certificate exists.
# (A self-signed certificate is listed as untrusted, so do not filter with -v.)
if [ -z "${CARET_SIGN_IDENTITY:-}" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"Caret Dev"'; then
  CARET_SIGN_IDENTITY="Caret Dev"
fi
sed -i '' "s|__REPO__|$REPO|" "$APP/Contents/Info.plist"
[ -f Resources/Caret.icns ] && cp Resources/Caret.icns "$APP/Contents/Resources/Caret.icns"
codesign --force --sign "${CARET_SIGN_IDENTITY:--}" --identifier com.paulgettel.caret "$APP" >/dev/null
[ -n "${CARET_SIGN_IDENTITY:-}" ] && echo "signed with $CARET_SIGN_IDENTITY" || echo "ad-hoc signed (Accessibility must be re-granted after each rebuild; see README)"
echo "built $APP"
if [ "${1:-}" = "--run" ] || [ "${1:-}" = "--install" ]; then
  pkill -x Caret 2>/dev/null || true
  # The app starts its own helper; a relaunch must not leave the old one serving old code.
  pkill -f "node --env-file-if-exists=.env src/server.js" 2>/dev/null || true
  sleep 1
  if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/Caret.app
    ditto "$APP" /Applications/Caret.app
    echo "installed /Applications/Caret.app"
    open /Applications/Caret.app
  else
    open "$APP"
  fi
fi
