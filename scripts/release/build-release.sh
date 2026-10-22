#!/bin/bash
# Builds Relvora for distribution. Used by .github/workflows/release.yml; also runs locally.
#
#   VERSION=1.2.0 SIGNING=developer-id TEAM_ID=… \
#     [NOTARY_KEY_PATH=AuthKey.p8 NOTARY_KEY_ID=… NOTARY_ISSUER_ID=…] scripts/release/build-release.sh
#       Signs with the "Developer ID Application" certificate in the keychain (hardened runtime, secure timestamp),
#       then notarizes and staples when the notary key is given. Output: Relvora-<version>.zip (+ .sha256).
#
#   VERSION=1.2.0 SIGNING=adhoc scripts/release/build-release.sh
#       Unsigned test package; needs no certificates. Gatekeeper blocks it on other Macs. Output:
#       Relvora-<version>-unsigned.zip.
#
# Never prints or stores credentials. Optional: BUILD_NUMBER (default 1), OUTPUT_DIR (default build/release).
set -euo pipefail

VERSION=${VERSION:?Set VERSION, e.g. 1.2.0 or 2.0.0-beta.1}
SIGNING=${SIGNING:-adhoc}
BUILD_NUMBER=${BUILD_NUMBER:-1}
OUTPUT_DIR=${OUTPUT_DIR:-build/release}
# CFBundleShortVersionString takes up to three integers; a prerelease suffix stays in the file name only.
MARKETING_VERSION=${VERSION%%[-+]*}

cd "$(dirname "$0")/../.."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
ARCHIVE="$OUTPUT_DIR/Relvora.xcarchive"

# The release bundle ID has no suffix (ADR 0007); command-line settings override Config/*.xcconfig.
COMMON=(
    -project Relvora.xcodeproj -scheme Relvora -configuration Release
    -destination "generic/platform=macOS" -archivePath "$ARCHIVE"
    MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    RELVORA_BUNDLE_ID_SUFFIX=
)

case "$SIGNING" in
developer-id)
    TEAM_ID=${TEAM_ID:?Set TEAM_ID for Developer ID signing}
    echo "▸ Archiving $VERSION ($BUILD_NUMBER), signed with Developer ID"
    xcodebuild archive -quiet "${COMMON[@]}" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID" \
        OTHER_CODE_SIGN_FLAGS="--timestamp"

    OPTIONS="$OUTPUT_DIR/ExportOptions.plist"
    /usr/libexec/PlistBuddy -c "Add :method string developer-id" \
        -c "Add :teamID string $TEAM_ID" \
        -c "Add :signingStyle string manual" \
        -c "Add :signingCertificate string Developer ID Application" "$OPTIONS" >/dev/null
    xcodebuild -exportArchive -quiet -archivePath "$ARCHIVE" -exportPath "$OUTPUT_DIR/export" \
        -exportOptionsPlist "$OPTIONS"
    APP="$OUTPUT_DIR/export/Relvora.app"

    echo "▸ Verifying the signature"
    codesign --verify --deep --strict --verbose=2 "$APP"
    codesign --display --verbose=2 "$APP" 2>&1 | grep -q "flags=0x10000(runtime)" ||
        { echo "error: hardened runtime is off" >&2; exit 1; }

    if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
        echo "▸ Notarizing (this can take a few minutes)"
        SUBMISSION="$OUTPUT_DIR/notarize.zip"
        ditto -c -k --keepParent "$APP" "$SUBMISSION"
        RESULT=$(xcrun notarytool submit "$SUBMISSION" --key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" \
            --issuer "${NOTARY_ISSUER_ID:?}" --wait --output-format json)
        STATUS=$(/usr/bin/plutil -extract status raw - <<<"$RESULT")
        if [[ "$STATUS" != "Accepted" ]]; then
            ID=$(/usr/bin/plutil -extract id raw - <<<"$RESULT")
            echo "error: notarization status $STATUS" >&2
            xcrun notarytool log "$ID" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" >&2
            exit 1
        fi
        rm "$SUBMISSION"
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP"
        echo "▸ Gatekeeper assessment"
        spctl --assess --type execute --verbose=2 "$APP"
    else
        echo "warning: no notary key; the app is signed but NOT notarized" >&2
    fi
    ZIP="$OUTPUT_DIR/Relvora-$VERSION.zip"
    ;;
adhoc)
    echo "▸ Archiving $VERSION ($BUILD_NUMBER), ad-hoc signed (test package, not for distribution)"
    xcodebuild archive -quiet "${COMMON[@]}" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
    APP="$ARCHIVE/Products/Applications/Relvora.app"
    codesign --verify --deep --strict "$APP"
    ZIP="$OUTPUT_DIR/Relvora-$VERSION-unsigned.zip"
    ;;
*)
    echo "error: SIGNING must be developer-id or adhoc" >&2
    exit 2
    ;;
esac

/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" -c "Print :CFBundleShortVersionString" \
    -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" | paste -sd ' ' - | sed 's/^/▸ Bundle: /'
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$ZIP")" >"$(basename "$ZIP").sha256")
echo "▸ Built $ZIP"
echo "zip=$ZIP" >>"${GITHUB_OUTPUT:-/dev/null}"
