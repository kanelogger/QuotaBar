#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_FILE="$ROOT_DIR/project.yml"
PUBLISH=false

if [ "${1:-}" = "--publish" ]; then
  PUBLISH=true
  shift
fi

DIST_DIR="${1:-}"
NOTES_FILE="${2:-$ROOT_DIR/docs/release-notes/v1.0.0.md}"

read_setting() {
  awk -F ': ' -v key="$1" '$1 ~ "^[[:space:]]*" key "$" { gsub(/\"/, "", $2); print $2; exit }' "$SPEC_FILE"
}

command -v gh >/dev/null 2>&1 || { echo "Missing required command: gh" >&2; exit 1; }
gh auth status >/dev/null || {
  echo "GitHub CLI is not authenticated. Run: gh auth login -h github.com" >&2
  exit 1
}

VERSION="$(read_setting MARKETING_VERSION)"
TAG="v$VERSION"
[ -n "$DIST_DIR" ] || DIST_DIR="$ROOT_DIR/dist/$TAG"
case "$DIST_DIR" in
  /*) ;;
  *) DIST_DIR="$ROOT_DIR/$DIST_DIR" ;;
esac

DMG_PATH="$DIST_DIR/QuotaBar-$VERSION.dmg"
ZIP_PATH="$DIST_DIR/QuotaBar-$VERSION-macos.zip"
CHECKSUMS_PATH="$DIST_DIR/SHA256SUMS.txt"
for file in "$DMG_PATH" "$ZIP_PATH" "$CHECKSUMS_PATH" "$NOTES_FILE"; do
  [ -f "$file" ] || { echo "Missing required file: $file" >&2; exit 1; }
done

cd "$ROOT_DIR"
[ "$(git describe --exact-match --tags HEAD 2>/dev/null || true)" = "$TAG" ] || {
  echo "HEAD must be tagged $TAG before creating its GitHub Release." >&2
  exit 1
}
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || {
  echo "Tag $TAG has not been pushed to origin." >&2
  exit 1
}

if ! gh release view "$TAG" >/dev/null 2>&1; then
  gh release create "$TAG" \
    --draft \
    --title "$TAG" \
    --notes-file "$NOTES_FILE" \
    "$DMG_PATH#macOS Disk Image" \
    "$ZIP_PATH#macOS ZIP archive" \
    "$CHECKSUMS_PATH#SHA-256 checksums"
fi

if [ "$PUBLISH" = true ]; then
  gh release edit "$TAG" --draft=false --latest
  echo "Published GitHub Release $TAG."
else
  echo "Draft GitHub Release $TAG is ready for review. Re-run with --publish to publish it."
fi
