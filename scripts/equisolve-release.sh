#!/usr/bin/env bash
#
# Builds Equisolve's release of VoiceInk: the LOCAL_BUILD variant (no license check,
# no iCloud), with the bundle ID com.equisolve.VoiceInk, no Sparkle update feed,
# signed with Equisolve's Developer ID and hardened runtime, then notarized and stapled.
#
# Kept separate from scripts/release.sh so upstream changes to that script merge cleanly.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_PATH="$REPO_ROOT/VoiceInk.xcodeproj"
SCHEME="VoiceInk"
LOCAL_XCCONFIG="$REPO_ROOT/LocalBuild.xcconfig"
ENTITLEMENTS="$REPO_ROOT/release/equisolve/VoiceInk.entitlements"
DERIVED_DATA="$REPO_ROOT/.equisolve-build"
WHISPER_FRAMEWORK="${VOICEINK_WHISPER_FRAMEWORK:-$HOME/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework}"

TEAM_ID="3MMFZ6XFFA"
BUNDLE_ID="com.equisolve.VoiceInk"
IDENTITY="${VOICEINK_EQUISOLVE_IDENTITY:-Developer ID Application: Equisolve LLC ($TEAM_ID)}"
NOTARY_PROFILE="${VOICEINK_EQUISOLVE_NOTARY_PROFILE:-VoiceInk-Equisolve-Notarization}"

XCODE_DEVELOPER_DIR="${VOICEINK_XCODE_DEVELOPER_DIR:-${DEVELOPER_DIR:-}}"
if [[ -z "$XCODE_DEVELOPER_DIR" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
if [[ -n "$XCODE_DEVELOPER_DIR" ]]; then
    export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
fi

RELEASE_TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
OUTPUT_ROOT="${VOICEINK_EQUISOLVE_OUTPUT_ROOT:-$HOME/Downloads/VoiceInk Equisolve Builds}"
OUTPUT_DIR="$OUTPUT_ROOT/VoiceInk-Equisolve-$RELEASE_TIMESTAMP"
SKIP_NOTARIZATION=0
ALLOW_DIRTY=0
SETUP_NOTARIZATION=0
VERIFY_APP=""

usage() {
    cat <<'EOF'
Usage:
  scripts/equisolve-release.sh [options]
  scripts/equisolve-release.sh --setup-notarization

Builds VoiceInk with the bundle ID com.equisolve.VoiceInk, signs it with
Equisolve's Developer ID and hardened runtime, notarizes it, and staples the ticket.
The script never commits, pushes, tags, or uploads anything except the
notarization submission.

Options:
  --identity <name or SHA>    Signing identity. Default: Equisolve's Developer ID.
                              Use - for an ad-hoc test build (implies --skip-notarization).
  --notary-profile <name>     notarytool Keychain profile.
                              Default: VoiceInk-Equisolve-Notarization.
  --output-dir <directory>    Override the timestamped Downloads directory.
  --skip-notarization         Sign but don't submit to Apple. The result is a test build.
  --allow-dirty               Permit a dirty Git working tree.
  --setup-notarization        Store notarization credentials in the Keychain and exit.
  --verify <VoiceInk.app>     Check a signed app's bundle ID, Info.plist, entitlements,
                              hardened runtime, and team, and exit. Add --identity -
                              to skip the team check for an ad-hoc build.
  -h, --help                  Show this help.
EOF
}

log() {
    printf '\n==> %s\n' "$1"
}

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

# Checks a signed app against the release rules. With AD_HOC=1, skips the team check.
verify_app() {
    local app="$1"
    local plist="$app/Contents/Info.plist"
    local bundle_id entitlements forbidden key candidate details count=0

    log "Verifying $app"
    codesign --verify --deep --strict --verbose=2 "$app" || fail "Signature check failed: $app"

    bundle_id="$(plutil -extract CFBundleIdentifier raw "$plist")"
    [[ "$bundle_id" == "$BUNDLE_ID" ]] || fail "Unexpected bundle identifier: $bundle_id"
    for key in SUFeedURL SUPublicEDKey; do
        if plutil -extract "$key" raw "$plist" >/dev/null 2>&1; then
            fail "Info.plist still has $key"
        fi
    done

    entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)" \
        || fail "Can't read entitlements: $app"
    for forbidden in com.apple.developer.icloud com.apple.developer.aps-environment keychain-access-groups \
        com.apple.security.cs.disable-library-validation; do
        [[ "$entitlements" != *"$forbidden"* ]] || fail "Signed entitlements include $forbidden"
    done

    # Every Mach-O file needs hardened runtime and, for a Developer ID build, Equisolve's team.
    while IFS= read -r candidate; do
        [[ "$(file -b "$candidate")" == *Mach-O* ]] || continue
        count=$((count + 1))
        details="$(codesign -dv --verbose=2 "$candidate" 2>&1)" || fail "Unsigned code: $candidate"
        grep -E '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' >/dev/null <<<"$details" \
            || fail "Hardened runtime is off: $candidate"
        if [[ "$AD_HOC" == "0" ]]; then
            grep -Fx "TeamIdentifier=$TEAM_ID" >/dev/null <<<"$details" \
                || fail "Not signed by team $TEAM_ID: $candidate"
        fi
    done < <(find "$app/Contents" -type f -perm -111)
    [[ "$count" -gt 0 ]] || fail "No code found to check"
    printf 'Checked %s Mach-O files.\n' "$count"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity)
            [[ $# -ge 2 ]] || fail "--identity requires a value"
            IDENTITY="$2"
            shift 2
            ;;
        --notary-profile)
            [[ $# -ge 2 ]] || fail "--notary-profile requires a name"
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || fail "--output-dir requires a path"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip-notarization)
            SKIP_NOTARIZATION=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        --setup-notarization)
            SETUP_NOTARIZATION=1
            shift
            ;;
        --verify)
            [[ $# -ge 2 ]] || fail "--verify requires a path"
            VERIFY_APP="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

if [[ "$SETUP_NOTARIZATION" == "1" ]]; then
    printf 'Apple ID of an Equisolve developer account member: '
    read -r APPLE_ID || true
    [[ -n "$APPLE_ID" ]] || fail "Apple ID is required"
    printf '\nnotarytool will securely prompt for your app-specific password.\n'
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --validate
    printf '\nSaved and validated notarytool profile: %s\n' "$NOTARY_PROFILE"
    exit 0
fi

AD_HOC=0
if [[ "$IDENTITY" == "-" ]]; then
    AD_HOC=1
    SKIP_NOTARIZATION=1
fi

if [[ -n "$VERIFY_APP" ]]; then
    [[ -d "$VERIFY_APP" ]] || fail "App not found: $VERIFY_APP"
    verify_app "$VERIFY_APP"
    exit 0
fi

require_command codesign
require_command ditto
require_command file
require_command git
require_command plutil
require_command security
require_command shasum
require_command spctl
require_command xcodebuild
require_command xcrun

[[ -d "$WHISPER_FRAMEWORK" ]] || fail "Whisper framework not found: $WHISPER_FRAMEWORK. Run: make whisper"
[[ -f "$ENTITLEMENTS" ]] || fail "Entitlements not found: $ENTITLEMENTS"
[[ -f "$LOCAL_XCCONFIG" ]] || fail "Build settings not found: $LOCAL_XCCONFIG"

if [[ "$AD_HOC" == "0" ]]; then
    security find-identity -v -p codesigning | grep -F "$IDENTITY" >/dev/null \
        || fail "Signing identity is unavailable: $IDENTITY"
fi

if [[ "$SKIP_NOTARIZATION" == "0" ]]; then
    log "Checking notarization credentials"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null \
        || fail "Notarization profile '$NOTARY_PROFILE' is unavailable. Run: make equisolve-release-setup"
fi

if [[ "$ALLOW_DIRTY" == "0" && -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    fail "Git working tree is not clean. Commit your changes or pass --allow-dirty."
fi

if [[ -e "$OUTPUT_DIR" && -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    fail "Output directory is not empty: $OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ARCHIVE_PATH="$OUTPUT_DIR/VoiceInk.xcarchive"
APP_PATH="$OUTPUT_DIR/VoiceInk.app"
WORK_DIR="$OUTPUT_DIR/work"
mkdir -p "$WORK_DIR"

# Build without signing; this script signs every piece of code below. Signing in
# xcodebuild would apply one bundle ID and one entitlements file to every target.
log "Archiving VoiceInk (LOCAL_BUILD, unsigned)"
rm -rf "$DERIVED_DATA"
xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -archivePath "$ARCHIVE_PATH" \
    -xcconfig "$LOCAL_XCCONFIG" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    DEVELOPMENT_TEAM="" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
    -skipPackagePluginValidation \
    -skipMacroValidation

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/VoiceInk.app"
[[ -d "$ARCHIVED_APP" ]] || fail "Archived VoiceInk.app not found at $ARCHIVED_APP"
ditto "$ARCHIVED_APP" "$APP_PATH"

INFO_PLIST="$APP_PATH/Contents/Info.plist"

log "Setting the bundle ID and removing the Sparkle update feed"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"
for key in SUFeedURL SUPublicEDKey; do
    if plutil -extract "$key" raw "$INFO_PLIST" >/dev/null 2>&1; then
        plutil -remove "$key" "$INFO_PLIST"
    fi
done

SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime)
if [[ "$AD_HOC" == "0" ]]; then
    SIGN_ARGS+=(--timestamp)
fi

sign_code() {
    codesign "${SIGN_ARGS[@]}" "$@"
}

# Sign from the inside out: loose libraries and helper executables, then nested
# bundles deepest first, then the app. Nested bundles keep their own entitlements,
# such as those of Sparkle's Downloader service.
log "Signing nested code with: $IDENTITY"
while IFS= read -r dylib; do
    sign_code "$dylib"
done < <(find "$APP_PATH/Contents" -type f -name '*.dylib' | sort)

for helper in "$APP_PATH"/Contents/Frameworks/Sparkle.framework/Versions/*/Autoupdate; do
    [[ -f "$helper" ]] && sign_code "$helper"
done

while IFS= read -r bundle; do
    sign_code --preserve-metadata=entitlements "$bundle"
done < <(find "$APP_PATH/Contents" -type d \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) \
    | awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2-)

log "Signing VoiceInk.app"
sign_code --entitlements "$ENTITLEMENTS" "$APP_PATH"

verify_app "$APP_PATH"

if [[ "$SKIP_NOTARIZATION" == "0" ]]; then
    APP_ZIP="$WORK_DIR/VoiceInk-notarize.zip"
    log "Submitting VoiceInk.app for notarization"
    ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    spctl -a -t exec -vv "$APP_PATH"
else
    log "Skipping notarization"
fi

SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
DIST_ZIP="$OUTPUT_DIR/VoiceInk-Equisolve-$SHORT_VERSION.zip"
log "Packaging $DIST_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$DIST_ZIP"
DIST_SHA256="$(shasum -a 256 "$DIST_ZIP" | awk '{print $1}')"

log "Code signature"
codesign -dv --verbose=4 "$APP_PATH" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|Authority|TeamIdentifier|Timestamp|Runtime Version|Signature size)'
codesign -dr - "$APP_PATH" 2>&1 | grep -F 'designated'

printf '\nEquisolve release prepared.\n'
printf 'Version:       %s (%s)\n' "$SHORT_VERSION" "$BUILD_VERSION"
printf 'Bundle ID:     %s\n' "$BUNDLE_ID"
printf 'App:           %s\n' "$APP_PATH"
printf 'Zip:           %s\n' "$DIST_ZIP"
printf 'Zip SHA-256:   %s\n' "$DIST_SHA256"
if [[ "$SKIP_NOTARIZATION" == "1" ]]; then
    printf 'Notarization:  skipped (test build only; Gatekeeper will block it on other Macs)\n'
else
    printf 'Notarization:  accepted and stapled\n'
fi
