#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
REPOSITORY="tacshi/MirrorPhone"

fail() {
  print -u2 -- "error: $*"
  exit 1
}

if (( $# != 1 )); then
  print -u2 -- "usage: ${0:t} <version>"
  exit 64
fi

VERSION="$1"
VERSION_PATTERN='^[0-9]+([.][0-9]+){0,2}$'
[[ "$VERSION" =~ $VERSION_PATTERN ]] || fail \
  "version must contain one to three numeric components, such as 1.2.3"

for tool in codesign gh git hdiutil shasum xcrun; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done

cd "$ROOT"

[[ -z "$(git status --porcelain)" ]] || fail \
  "the working tree must be clean before creating a release"

BRANCH="$(git symbolic-ref --quiet --short HEAD)" || fail \
  "releases must be created from a branch, not a detached HEAD"
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || fail \
  "$BRANCH does not have an upstream branch"

gh auth status --hostname github.com >/dev/null 2>&1 || fail \
  "GitHub CLI is not authenticated; run: gh auth login"

print -- "Checking the remote release state..."
git fetch --quiet origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$UPSTREAM")" ]] || fail \
  "$BRANCH must exactly match $UPSTREAM; push or pull before releasing"

TAG="v$VERSION"
if git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
  [[ "$(git rev-list -n 1 "$TAG")" == "$(git rev-parse HEAD)" ]] || fail \
    "$TAG already points to a different commit"
fi

DMG="$ROOT/dist/MirrorPhone-$VERSION.dmg"
CHECKSUM="$DMG.sha256"

print -- "Building, signing, and notarizing MirrorPhone $VERSION..."
"$ROOT/build-dmg.sh" "$VERSION"

[[ -f "$DMG" ]] || fail "expected artifact was not produced: $DMG"
codesign --verify --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
hdiutil verify "$DMG" >/dev/null

(
  cd "${DMG:h}"
  shasum -a 256 "${DMG:t}" > "${CHECKSUM:t}"
)

if ! git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
  git tag --annotate "$TAG" --message "MirrorPhone $VERSION"
fi

print -- "Pushing $TAG and uploading a draft GitHub release..."
git push origin "$TAG"
gh release create "$TAG" \
  "$DMG#MirrorPhone $VERSION for macOS" \
  "$CHECKSUM#SHA-256 checksum" \
  --repo "$REPOSITORY" \
  --verify-tag \
  --generate-notes \
  --draft

print -- "Draft release created. Review it before publishing:"
print -- "  gh release view $TAG --repo $REPOSITORY --web"
print -- "Publish after review with:"
print -- "  gh release edit $TAG --repo $REPOSITORY --draft=false"
