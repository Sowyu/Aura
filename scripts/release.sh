#!/bin/bash
# release.sh: build a signed Release DMG, sign it for Sparkle, write the appcast and
# publish a GitHub release. Every installed copy then sees the update through the feed
# in Info.plist, https://github.com/Sowyu/Aura/releases/latest/download/appcast.xml.
#
# usage: scripts/release.sh <version> [--notes notes.md]
#
# Needs: a clean tree on the branch to release, xcodegen, gh (logged in), an
# "Apple Development" identity, and the Sparkle EdDSA key in the login keychain
# (Sparkle's generate_keys put it there; the matching public key is SUPublicEDKey).
# The DMG is signed but not notarized: a first launch from the DMG needs a right-click
# and Open. Sparkle clears quarantine on the updates it installs itself.
set -euo pipefail

VERSION="${1:-}"
NOTES=""
shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes) NOTES="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/release.sh <major.minor.patch> [--notes notes.md]" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="Sowyu/Aura"
IDENTITY="Apple Development"
TEAM="${AURA_TEAM_ID:-8Q677AYRU7}"
ENTITLEMENTS="$ROOT/aura/Info/aura.entitlements"
DD="$ROOT/build/dd-release"
DMG="$ROOT/build/Aura-$VERSION.dmg"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

step() { printf '\n\033[1;34m→ %s\033[0m\n' "$*"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

step "Preflight"
[[ -z "$(git status --porcelain)" ]] || die "uncommitted changes; commit first"
command -v xcodegen >/dev/null || die "xcodegen missing (brew install xcodegen)"
command -v gh >/dev/null || die "gh missing (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh is not logged in"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || die "no \"$IDENTITY\" identity in the keychain"
security find-generic-password -s "https://sparkle-project.org" -a ed25519 >/dev/null 2>&1 \
    || die "no Sparkle EdDSA key in the keychain; run generate_keys from Sparkle's bin"
git rev-parse "v$VERSION" >/dev/null 2>&1 && die "tag v$VERSION already exists"
[[ -z "$NOTES" || -f "$NOTES" ]] || die "notes file not found: $NOTES"

step "Version $VERSION"
BUILD=$(( $(grep 'CURRENT_PROJECT_VERSION:' project.yml | tr -dc '0-9') + 1 ))
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $VERSION/; s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD/" project.yml
xcodegen -q
git add project.yml aura/Info/Info.plist
git commit -q -m "release: v$VERSION (build $BUILD)"
git tag "v$VERSION"

step "Building Release"
rm -rf "$DD" "$ROOT/build/dmg" "$ROOT/build/sparkle"
xcodebuild -project Aura.xcodeproj -scheme aura -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$DD" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" build > build/release-build.log 2>&1 \
    || { tail -40 build/release-build.log; die "build failed, see build/release-build.log"; }
APP="$DD/Build/Products/Release/Aura.app"
[[ -d "$APP" ]] || die "no app at $APP"
# The scheme also builds the unit-test bundle into the app. It has no place in a release.
rm -rf "$APP/Contents/PlugIns/auraTests.xctest"
# Xcode re-signs Sparkle.framework on copy but not the XPC services and helpers inside
# it, which a plain build leaves ad-hoc signed (Archive and Export would do this). The
# sandboxed installer path needs them signed like the app, innermost first, as Sparkle's
# sandboxing guide spells out.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    [[ -e "$nested" ]] || continue
    codesign --force --sign "$IDENTITY" --options runtime --preserve-metadata=entitlements "$nested"
done
codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP" || die "signature check failed"
xattr -cr "$APP"

step "DMG"
mkdir -p build/dmg
ditto "$APP" build/dmg/Aura.app
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Aura $VERSION" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$IDENTITY" "$DMG"

step "Sparkle appcast"
mkdir -p build/sparkle
cp "$DMG" build/sparkle/
if [[ -n "$NOTES" ]]; then
    # Sparkle shows HTML; a plain rendering of the markdown is enough.
    python3 - "$NOTES" "build/sparkle/Aura-$VERSION.html" <<'PY'
import html, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
out, in_list = [], False
for line in lines:
    s = line.strip()
    if s.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        out.append("<li>" + html.escape(s[2:]) + "</li>")
        continue
    if in_list: out.append("</ul>"); in_list = False
    if s.startswith("#"): out.append("<h3>" + html.escape(s.lstrip("# ")) + "</h3>")
    elif s: out.append("<p>" + html.escape(s) + "</p>")
if in_list: out.append("</ul>")
open(sys.argv[2], "w", encoding="utf-8").write("<html><body>" + "\n".join(out) + "</body></html>\n")
PY
fi
GENERATE_APPCAST=$(find "$DD/SourcePackages/artifacts" -path '*/Sparkle/bin/generate_appcast' | head -1)
[[ -x "$GENERATE_APPCAST" ]] || die "generate_appcast not found under $DD/SourcePackages"
"$GENERATE_APPCAST" --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" build/sparkle >/dev/null
[[ -f build/sparkle/appcast.xml ]] || die "appcast was not written"
grep -q "sparkle:edSignature" build/sparkle/appcast.xml || die "appcast carries no EdDSA signature"

step "Publishing"
git push origin HEAD "v$VERSION"
NOTES_ARGS=(--notes "Aura $VERSION")
[[ -n "$NOTES" ]] && NOTES_ARGS=(--notes-file "$NOTES")
gh release create "v$VERSION" "$DMG" build/sparkle/appcast.xml --repo "$REPO" --title "Aura $VERSION" "${NOTES_ARGS[@]}"
echo
echo "Released v$VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
echo "Installed copies pick it up on their next check (at launch, then every 6 hours)."
