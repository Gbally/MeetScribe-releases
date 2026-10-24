#!/bin/sh
# Notarizes a Developer ID–signed DMG so macOS opens MeetScribe without any warning, then
# staples the ticket (works offline too). Called by release.sh when SIGN_ID is set.
#
#   Once: xcrun notarytool store-credentials meetscribe-notary \
#             --apple-id you@example.com --team-id ABCDE12345
#         (asks for an app-specific password, made at appleid.apple.com → Sign-In and Security)
#   Then: ./scripts/notarize.sh dist/MeetScribe-<version>.dmg
set -e
DMG=${1:?usage: notarize.sh path/to/MeetScribe.dmg}
PROFILE=${NOTARY_PROFILE:-meetscribe-notary}
echo "• Notarizing $(basename "$DMG") (usually 1–5 min)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
