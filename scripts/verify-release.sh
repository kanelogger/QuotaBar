#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="QuotaBar"
DIST_DIR="${1:-}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for command in codesign ditto hdiutil shasum spctl xcrun find mktemp; do
  require_command "$command"
done

[ -n "$DIST_DIR" ] || {
  echo "Usage: $0 <release-directory>" >&2
  exit 1
}

case "$DIST_DIR" in
  /*) ;;
  *) DIST_DIR="$ROOT_DIR/$DIST_DIR" ;;
esac

[ -d "$DIST_DIR" ] || {
  echo "Release directory does not exist: $DIST_DIR" >&2
  exit 1
}

shopt -s nullglob
DMG_CANDIDATES=("$DIST_DIR"/"$APP_NAME"-*.dmg)
ZIP_CANDIDATES=("$DIST_DIR"/"$APP_NAME"-*-macos.zip)
shopt -u nullglob
[ "${#DMG_CANDIDATES[@]}" -eq 1 ] && [ "${#ZIP_CANDIDATES[@]}" -eq 1 ] || {
  echo "Expected exactly one QuotaBar DMG and ZIP in $DIST_DIR." >&2
  exit 1
}
DMG_PATH="${DMG_CANDIDATES[0]}"
ZIP_PATH="${ZIP_CANDIDATES[0]}"
CHECKSUMS_PATH="$DIST_DIR/SHA256SUMS.txt"
[ -f "$CHECKSUMS_PATH" ] || {
  echo "Expected DMG, ZIP, and SHA256SUMS.txt in $DIST_DIR." >&2
  exit 1
}

DMG_NAME="$(basename "$DMG_PATH")"
ZIP_NAME="$(basename "$ZIP_PATH")"
VERSION="${DMG_NAME#"$APP_NAME"-}"
VERSION="${VERSION%.dmg}"
[ "$ZIP_NAME" = "$APP_NAME-$VERSION-macos.zip" ] || {
  echo "DMG and ZIP versions do not match." >&2
  exit 1
}
[ "$(<"$CHECKSUMS_PATH")" = "$(cd "$DIST_DIR" && shasum -a 256 "$ZIP_NAME" "$DMG_NAME")" ] || {
  echo "SHA256SUMS.txt must contain exactly the selected DMG and ZIP." >&2
  exit 1
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-release.XXXXXX")"
MOUNT_POINT="$WORK_DIR/mount"
cleanup() {
  if mount | grep -F "on $MOUNT_POINT " >/dev/null 2>&1; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

(cd "$DIST_DIR" && shasum -a 256 -c "$(basename "$CHECKSUMS_PATH")")

ditto -x -k "$ZIP_PATH" "$WORK_DIR/zip"
ZIP_APP="$(find "$WORK_DIR/zip" -maxdepth 1 -name "$APP_NAME.app" -print -quit)"
[ -d "$ZIP_APP" ] || { echo "ZIP does not contain $APP_NAME.app." >&2; exit 1; }

codesign --verify --strict --verbose=2 "$ZIP_APP"
codesign --verify --strict --verbose=2 "$ZIP_APP/Contents/Frameworks/QuotaCore.framework"
codesign -d --verbose=4 "$ZIP_APP" 2>&1 | grep -q 'Runtime Version='
xcrun stapler validate "$ZIP_APP"
spctl --assess --type execute --verbose=4 "$ZIP_APP"

mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
DMG_APP="$MOUNT_POINT/$APP_NAME.app"
[ -d "$DMG_APP" ] || { echo "DMG does not contain $APP_NAME.app." >&2; exit 1; }

codesign --verify --strict --verbose=2 "$DMG_APP"
codesign --verify --strict --verbose=2 "$DMG_APP/Contents/Frameworks/QuotaCore.framework"
codesign -d --verbose=4 "$DMG_APP" 2>&1 | grep -q 'Runtime Version='
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --verbose=4 "$DMG_PATH"

echo "Release artifacts verified: $DIST_DIR"
