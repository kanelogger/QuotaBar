#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="QuotaBar.xcodeproj"
SCHEME="QuotaBar"
APP_NAME="QuotaBar"
SPEC_FILE="$ROOT_DIR/project.yml"
RESOLVED_FILE="QuotaBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_environment() {
  [ -n "${!1:-}" ] || {
    echo "Missing required environment variable: $1" >&2
    exit 1
  }
}

read_setting() {
  awk -F ': ' -v key="$1" '$1 ~ "^[[:space:]]*" key "$" { gsub(/\"/, "", $2); print $2; exit }' "$SPEC_FILE"
}

for command in git xcodegen xcodebuild xcrun codesign spctl ditto hdiutil shasum security plutil; do
  require_command "$command"
done

require_environment DEVELOPMENT_TEAM
require_environment DEVELOPER_IDENTITY
require_environment NOTARY_PROFILE

VERSION="$(read_setting MARKETING_VERSION)"
BUILD_NUMBER="$(read_setting CURRENT_PROJECT_VERSION)"
TAG="v$VERSION"
[ -n "$VERSION" ] && [ -n "$BUILD_NUMBER" ] || {
  echo "MARKETING_VERSION and CURRENT_PROJECT_VERSION must be set in project.yml." >&2
  exit 1
}

cd "$ROOT_DIR"
[ -z "$(git status --porcelain --untracked-files=all)" ] || {
  echo "Release builds require a clean worktree." >&2
  exit 1
}
[ "$(git describe --exact-match --tags HEAD 2>/dev/null || true)" = "$TAG" ] || {
  echo "HEAD must be tagged $TAG before building a release." >&2
  exit 1
}
git rev-parse --verify --quiet origin/main >/dev/null || {
  echo "Cannot verify the release tag against origin/main. Fetch origin/main first." >&2
  exit 1
}
git merge-base --is-ancestor HEAD origin/main || {
  echo "Release tag $TAG must point to a commit merged into origin/main." >&2
  exit 1
}
git ls-files --error-unmatch "$RESOLVED_FILE" >/dev/null 2>&1 || {
  echo "SwiftPM lockfile must be tracked before releasing: $RESOLVED_FILE" >&2
  exit 1
}

security find-identity -v -p codesigning | grep -F "$DEVELOPER_IDENTITY" >/dev/null || {
  echo "Developer ID identity not found: $DEVELOPER_IDENTITY" >&2
  exit 1
}
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || {
  echo "Notarytool Keychain profile is unavailable: $NOTARY_PROFILE" >&2
  exit 1
}

WORK_DIR="$ROOT_DIR/build/release-$VERSION"
DIST_DIR="$ROOT_DIR/dist/v$VERSION"
case "$WORK_DIR" in
  "$ROOT_DIR"/build/release-*) ;;
  *) echo "Refusing unsafe build directory: $WORK_DIR" >&2; exit 1 ;;
esac
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$DIST_DIR"

ARCHIVE_PATH="$WORK_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$WORK_DIR/export"
EXPORT_OPTIONS="$WORK_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
NOTARY_ZIP="$WORK_DIR/$APP_NAME-notary.zip"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION-macos.zip"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
CHECKSUMS_PATH="$DIST_DIR/SHA256SUMS.txt"
NOTARY_RESULT="$WORK_DIR/notary-result.json"

save_notary_log() {
  submission_id="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
  if [ -n "$submission_id" ]; then
    xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "$WORK_DIR/notary-log.json" || true
  fi
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g" <<< "$1"
}

DEVELOPER_IDENTITY_XML="$(xml_escape "$DEVELOPER_IDENTITY")"
DEVELOPMENT_TEAM_XML="$(xml_escape "$DEVELOPMENT_TEAM")"

cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingCertificate</key>
  <string>$DEVELOPER_IDENTITY_XML</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>$DEVELOPMENT_TEAM_XML</string>
</dict>
</plist>
EOF

xcodegen generate
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -derivedDataPath "$WORK_DIR/TestDerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  test

git diff --quiet -- "$RESOLVED_FILE" && [ -z "$(git status --porcelain -- "$RESOLVED_FILE")" ] || {
  echo "SwiftPM resolution changed. Commit Package.resolved before releasing." >&2
  exit 1
}

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_IDENTITY="$DEVELOPER_IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_PATH"

[ -d "$APP_PATH" ] || {
  echo "Export did not produce $APP_NAME.app." >&2
  exit 1
}

codesign --verify --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH/Contents/Frameworks/QuotaCore.framework"
codesign -d --verbose=4 "$APP_PATH" 2>&1 | grep -q 'Runtime Version=' || {
  echo "Hardened Runtime is missing from the app signature." >&2
  exit 1
}

ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
if ! xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m --output-format json > "$NOTARY_RESULT"; then
  save_notary_log
  echo "Notarization failed. Results: $NOTARY_RESULT" >&2
  exit 1
fi
notary_status="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
[ "$notary_status" = "Accepted" ] || {
  save_notary_log
  echo "Notarization did not return Accepted. Results: $NOTARY_RESULT" >&2
  exit 1
}

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

rm -f "$ZIP_PATH" "$DMG_PATH" "$CHECKSUMS_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --verbose=4 "$DMG_PATH"

(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUMS_PATH")")

echo "Release artifacts created for $TAG (build $BUILD_NUMBER):"
echo "  $DMG_PATH"
echo "  $ZIP_PATH"
echo "  $CHECKSUMS_PATH"
