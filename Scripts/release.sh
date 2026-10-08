#!/bin/bash
# Builds a signed, notarized and stapled Quickclean DMG and tags the release.
#
#   Scripts/release.sh <version> <channel>      e.g. Scripts/release.sh 0.0.1 alpha
#
# channel: alpha | beta | rc | stable. Requires a clean working tree whose
# Sources/QuickcleanCore/Version.swift already says <version> and <channel>.
# Notarization uses the notarytool keychain profile in $NOTARY_PROFILE (default "notarytool").
set -euo pipefail

VERSION=${1:-}
CHANNEL=${2:-}
IDENTITY=${SIGN_IDENTITY:-"Developer ID Application: David Barkan (L26TPPMPF3)"}
TEAM=${TEAM_ID:-L26TPPMPF3}
PROFILE=${NOTARY_PROFILE:-notarytool}

die() { echo "release: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3 (got '$VERSION')"
case $CHANNEL in alpha|beta|rc|stable) ;; *) die "channel must be alpha, beta, rc or stable (got '$CHANNEL')" ;; esac

cd "$(git rev-parse --show-toplevel)"
[[ -z $(git status --porcelain) ]] || die "working tree has uncommitted changes"
COMMIT=$(git rev-parse HEAD)
grep -q "version = \"$VERSION\"" Sources/QuickcleanCore/Version.swift || die "Version.swift does not say $VERSION"
grep -q "channel = \"$CHANNEL\"" Sources/QuickcleanCore/Version.swift || die "Version.swift does not say channel $CHANNEL"
security find-identity -v -p codesigning | grep -qF "$IDENTITY" || die "signing identity not found: $IDENTITY"

if [[ $CHANNEL == stable ]]; then TAG="v$VERSION"; NAME="Quickclean-$VERSION"
else TAG="v$VERSION-$CHANNEL"; NAME="Quickclean-$VERSION-$CHANNEL"; fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"

BUILD=$(git rev-list --count HEAD)
OUT="build/release/$TAG"
rm -rf "$OUT"
mkdir -p "$OUT"

step "Testing"
swift test > "$OUT/tests.log" 2>&1 || { tail -30 "$OUT/tests.log"; die "tests failed"; }

step "Archiving $NAME (build $BUILD)"
xcodegen generate --spec App/project.yml --quiet
xcodebuild archive -project App/Quickclean.xcodeproj -scheme Quickclean -configuration Release \
    -archivePath "$OUT/Quickclean.xcarchive" -derivedDataPath build/dd-release \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" QC_CHANNEL="$CHANNEL" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    > "$OUT/archive.log" 2>&1 || { grep -E "error:" "$OUT/archive.log" | head -20; die "archive failed (see $OUT/archive.log)"; }
xcodebuild -exportArchive -archivePath "$OUT/Quickclean.xcarchive" \
    -exportOptionsPlist Scripts/ExportOptions.plist -exportPath "$OUT/export" \
    > "$OUT/export.log" 2>&1 || { tail -20 "$OUT/export.log"; die "export failed"; }
APP="$OUT/export/Quickclean.app"

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE=$(codesign -dv "$APP" 2>&1)
[[ $SIGNATURE =~ flags=.*runtime ]] || die "hardened runtime is not enabled"
[[ $SIGNATURE == *"TeamIdentifier=$TEAM"* ]] || die "app is not signed by team $TEAM"

notarize() {
    local file=$1 log=$2
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json > "$log" || true
    local status
    status=$(/usr/bin/python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("status", ""))
except Exception: print("")' "$log")
    if [[ $status != Accepted ]]; then
        local id
        id=$(/usr/bin/python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("id", ""))
except Exception: print("")' "$log")
        cat "$log" >&2
        [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        die "notarization of $(basename "$file") returned '$status'"
    fi
}

step "Notarizing app"
ditto -c -k --keepParent "$APP" "$OUT/Quickclean.zip"
notarize "$OUT/Quickclean.zip" "$OUT/notary-app.json"
xcrun stapler staple "$APP"

step "Building DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Quickclean.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/$NAME.dmg"
hdiutil create -volname "Quickclean $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing DMG"
notarize "$DMG" "$OUT/notary-dmg.json"
xcrun stapler staple "$DMG"

step "Gatekeeper checks"
xcrun stapler validate "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

[[ $(git rev-parse HEAD) == "$COMMIT" ]] || die "HEAD moved during the build; not tagging (built $COMMIT)"
git tag -a "$TAG" -m "Quickclean $VERSION ($CHANNEL)" "$COMMIT"

step "Done"
echo "tag:      $TAG (not pushed)"
echo "artifact: $DMG"
echo "sha256:   $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
