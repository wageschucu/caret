#!/bin/sh
# Signs build/Caret.app with a Developer ID certificate, notarizes it with Apple, and staples the
# ticket, so the app can be shared and launched on other Macs without Gatekeeper warnings.
#
# One-time setup (yours, not scriptable — both need your Apple account):
#   1. Apple Developer Program membership, and a "Developer ID Application" certificate installed in
#      your login keychain (Xcode → Settings → Accounts → Manage Certificates, or developer.apple.com).
#   2. xcrun notarytool store-credentials caret-notary
#      (asks for your Apple ID, team ID and an app-specific password; stored in the keychain).
#
# Usage: apps/mac/notarize.sh            (after apps/mac/build.sh)
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"  overrides certificate detection
#   NOTARY_PROFILE=caret-notary                                   overrides the keychain profile name
set -eu
cd "$(dirname "$0")"
APP="build/Caret.app"
test -d "$APP" || { echo "run apps/mac/build.sh first"; exit 1; }
IDENTITY="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
test -n "$IDENTITY" || { echo "no Developer ID Application certificate in the keychain"; exit 1; }
PROFILE="${NOTARY_PROFILE:-caret-notary}"

# Hardened runtime is required for notarization. Caret needs no special entitlements: the event
# tap and Accessibility reads are governed by TCC grants, not entitlements.
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" --identifier com.paulgettel.caret "$APP"
codesign --verify --strict --verbose=2 "$APP"
rm -f build/Caret.zip
ditto -c -k --keepParent "$APP" build/Caret.zip
xcrun notarytool submit build/Caret.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
echo "notarized and stapled: $APP"
echo "Note: the Accessibility grant is tied to the signature; the first launch of a Developer ID build needs one more grant."
