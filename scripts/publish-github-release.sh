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
NOTES_FILE="${2:-}"

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
[ -n "$NOTES_FILE" ] || NOTES_FILE="$ROOT_DIR/docs/release-notes/v$VERSION.md"
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
"$ROOT_DIR/scripts/verify-release.sh" "$DIST_DIR"

cd "$ROOT_DIR"
[ "$(git describe --exact-match --tags HEAD 2>/dev/null || true)" = "$TAG" ] || {
  echo "HEAD must be tagged $TAG before creating its GitHub Release." >&2
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
LOCAL_TAG_SHA="$(git rev-parse "$TAG^{commit}")"
REMOTE_TAG_SHA="$(git ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}" | awk -v tag="refs/tags/$TAG" '$2 == tag { direct = $1 } $2 == tag "^{}" { peeled = $1 } END { print peeled != "" ? peeled : direct }')"
[ -n "$REMOTE_TAG_SHA" ] || {
  echo "Tag $TAG has not been pushed to origin." >&2
  exit 1
}
[ "$LOCAL_TAG_SHA" = "$REMOTE_TAG_SHA" ] || {
  echo "Remote tag $TAG does not point to the current release commit." >&2
  exit 1
}

if gh release view "$TAG" >/dev/null 2>&1; then
  [ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" = true ] || {
    echo "Release $TAG is already published and cannot be modified by this script." >&2
    exit 1
  }
  gh release edit "$TAG" --title "$TAG" --notes-file "$NOTES_FILE"
  gh release upload "$TAG" --clobber \
    "$DMG_PATH#macOS Disk Image" \
    "$ZIP_PATH#macOS ZIP archive" \
    "$CHECKSUMS_PATH#SHA-256 checksums"
else
  gh release create "$TAG" \
    --draft \
    --title "$TAG" \
    --notes-file "$NOTES_FILE" \
    "$DMG_PATH#macOS Disk Image" \
    "$ZIP_PATH#macOS ZIP archive" \
    "$CHECKSUMS_PATH#SHA-256 checksums"
fi

EXPECTED_ASSETS="$(printf '%s\n' "$(basename "$CHECKSUMS_PATH")" "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")" | LC_ALL=C sort)"
ACTUAL_ASSETS="$(gh release view "$TAG" --json assets --jq '.assets[].name' | LC_ALL=C sort)"
[ "$ACTUAL_ASSETS" = "$EXPECTED_ASSETS" ] || {
  echo "Draft Release $TAG must contain exactly the DMG, ZIP, and SHA256SUMS.txt assets." >&2
  exit 1
}

if [ "$PUBLISH" = true ]; then
  gh release edit "$TAG" --draft=false --latest
  echo "Published GitHub Release $TAG."
else
  echo "Draft GitHub Release $TAG is ready for review. Re-run with --publish to publish it."
fi
