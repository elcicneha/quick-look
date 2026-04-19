#!/usr/bin/env bash
#
# Build a Release build of the app and package it as a zip suitable for
# distribution to people who do NOT have a paid Apple Developer account.
#
# The resulting zip is signed with the project's Personal Team (automatic
# signing). It is NOT notarized. End-users must strip the quarantine xattr
# after downloading — see the install block in README.md.
#
# Usage:
#   scripts/package.sh              # uses MARKETING_VERSION from project.pbxproj
#   scripts/package.sh 1.2.0        # override version in the output filename
#
set -euo pipefail

# --- paths -------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/QuickLookCode/QuickLookCode.xcodeproj"
SCHEME="QuickLookCode"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"

APP_NAME="Peekaboo.app"
DIST_NAME="Peekaboo"

cd "$REPO_ROOT"

# xcodebuild needs a full Xcode, not Command Line Tools. If the active
# developer dir is CLT but Xcode.app is installed, point at it for this run.
if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
        echo "==> Using DEVELOPER_DIR=$DEVELOPER_DIR"
    fi
fi

# --- version -----------------------------------------------------------------

if [[ $# -ge 1 ]]; then
    VERSION="$1"
else
    VERSION="$(grep -m1 'MARKETING_VERSION' "$PROJECT/project.pbxproj" \
        | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' \
        | tr -d ' ')"
fi

if [[ -z "$VERSION" ]]; then
    echo "error: could not determine version" >&2
    exit 1
fi

echo "==> Packaging $DIST_NAME v$VERSION"

# --- clean build -------------------------------------------------------------

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"

echo "==> xcodebuild archive (Release)"
# `archive` uses a stricter build graph than `build`, which avoids a race
# where the extension target's Swift compile starts before the
# QuickLookCodeShared framework's .swiftmodule is emitted.
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: build did not produce $APP_PATH" >&2
    exit 1
fi

EXT_PATH="$APP_PATH/Contents/PlugIns/QuickLookCodeExtension.appex"
FW_PATH="$APP_PATH/Contents/Frameworks/QuickLookCodeShared.framework"

if [[ ! -d "$EXT_PATH" ]]; then
    echo "error: extension bundle missing at $EXT_PATH" >&2
    exit 1
fi

# --- strip provisioning profile and re-sign ad-hoc --------------------------
#
# The Personal Team (free Apple ID) embeds a development provisioning profile
# whose ProvisionedDevices list contains only our machine. On any other Mac
# the kernel refuses to launch the app ("cannot be opened because of a
# problem"). Strip the profile and re-sign ad-hoc so the app launches
# anywhere.
#
# Ad-hoc signing has no team ID, so the team-scoped entitlements have to be
# dropped: application-groups, team-identifier, application-identifier.
# Effect: CacheManager's L3 disk cache (shared group container) stops working
# on users' machines; L2/L1 caches still function. Previews are slightly
# slower on cold start, but fully functional.

echo "==> Removing embedded provisioning profiles"
find "$APP_PATH" -name "embedded.provisionprofile" -delete

resign_adhoc() {
    local bundle="$1"
    local ent_file
    ent_file="$(mktemp -t quicklookcode_ent).plist"

    if codesign -d --entitlements :- "$bundle" 2>/dev/null > "$ent_file" \
       && [[ -s "$ent_file" ]]; then
        /usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups" "$ent_file" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier"   "$ent_file" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier"      "$ent_file" 2>/dev/null || true
        codesign --force --sign - --entitlements "$ent_file" "$bundle"
    else
        codesign --force --sign - "$bundle"
    fi
    rm -f "$ent_file"
}

echo "==> Re-signing ad-hoc (inner bundles first)"
resign_adhoc "$FW_PATH"
resign_adhoc "$EXT_PATH"
resign_adhoc "$APP_PATH"

# --- verify signature and entitlements --------------------------------------

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Host app entitlements (post-resign):"
codesign -d --entitlements :- "$APP_PATH" 2>/dev/null \
    | grep -E 'application-groups|app-sandbox|temporary-exception|team-identifier' || true

echo "==> Extension entitlements (post-resign):"
codesign -d --entitlements :- "$EXT_PATH" 2>/dev/null \
    | grep -E 'application-groups|app-sandbox|temporary-exception|team-identifier' || true

# --- strip our quarantine, then zip -----------------------------------------

echo "==> Stripping local quarantine xattrs"
xattr -cr "$APP_PATH"

ZIP_PATH="$DIST_DIR/${DIST_NAME}-v${VERSION}.zip"
rm -f "$ZIP_PATH"

echo "==> Zipping with ditto (preserves symlinks + code signature)"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# --- summary ----------------------------------------------------------------

SIZE="$(du -h "$ZIP_PATH" | awk '{print $1}')"
SHASUM="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

echo
echo "================================================================"
echo "  Packaged: $ZIP_PATH"
echo "  Size:     $SIZE"
echo "  SHA-256:  $SHASUM"
echo "================================================================"
echo
echo "Send the zip + these four lines to the user:"
echo
echo "  mv ~/Downloads/$APP_NAME /Applications/"
echo "  xattr -dr com.apple.quarantine /Applications/$APP_NAME"
echo "  open /Applications/$APP_NAME"
echo "  qlmanage -r && killall -HUP Finder"
echo
