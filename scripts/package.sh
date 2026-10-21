#!/bin/bash
# SIGN_IDENTITY='Developer ID Application: <name> (<team-id>)' NOTARY_PROFILE='profile' scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."
identity="${SIGN_IDENTITY:--}"
if [[ "${REQUIRE_NOTARIZATION:-0}" == 1 && -z "${NOTARY_PROFILE:-}" ]]; then
  echo 'Public distribution requires NOTARY_PROFILE. See docs/DISTRIBUTION.md.' >&2
  exit 1
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ "$identity" != - ]] || { echo 'Notarization requires a Developer ID SIGN_IDENTITY.' >&2; exit 1; }
  # Validate authentication before rebuilding or replacing any distribution artifact.
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null
  mkdir -p .build
  notary_logs="$(mktemp -d "$PWD/.build/notarization.XXXXXX")"
  printf 'Notarization receipts: %s\n' "$notary_logs"
fi
notarize() {
  local artifact="$1" receipt="$notary_logs/$2.json" submission_exit=0
  xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json >"$receipt" || submission_exit=$?
  cat "$receipt"
  [[ "$submission_exit" == 0 ]] || return "$submission_exit"
  python3 - "$receipt" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit(f"Apple did not accept submission {result.get('id')}: {result.get('status')}. See docs/DISTRIBUTION.md.")
PY
}
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then bash scripts/build.sh; fi
source_app="$PWD/.build/xcode/Build/Products/Release/Resim.app"
[[ -d "$source_app" ]] || { echo 'Release app missing. Run scripts/build.sh.' >&2; exit 1; }
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$source_app" "$staging/Resim.app"
app="$staging/Resim.app"
# Hosted Release tests may leave their bundle in the product directory.
rm -rf "$app/Contents/PlugIns"
if [[ "$identity" == - ]]; then
  for helper in oxipng gifsicle gifdiff resim-svg; do
    codesign --force --sign - --options runtime "$app/Contents/Resources/Codecs/$helper"
  done
  codesign --force --sign - --options runtime "$app"
else
  for helper in oxipng gifsicle gifdiff resim-svg; do
    codesign --force --timestamp --sign "$identity" --options runtime "$app/Contents/Resources/Codecs/$helper"
  done
  codesign --force --timestamp --sign "$identity" --options runtime "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
lipo "$app/Contents/MacOS/Resim" -verify_arch arm64
lipo "$app/Contents/MacOS/Resim" -verify_arch x86_64
for helper in oxipng gifsicle gifdiff resim-svg; do
  lipo "$app/Contents/Resources/Codecs/$helper" -verify_arch arm64
  lipo "$app/Contents/Resources/Codecs/$helper" -verify_arch x86_64
done
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$app" "$staging/Resim-notary.zip"
  notarize "$staging/Resim-notary.zip" app
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi
ln -s /Applications "$staging/Applications"
rm -f "$staging/Resim-notary.zip"
cp docs/README.txt "$staging/README.txt"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg="$PWD/dist/Resim-$version.dmg"
hdiutil create -volname Resim -srcfolder "$staging" -ov -format UDZO "$dmg"
if [[ "$identity" != - ]]; then codesign --force --timestamp --sign "$identity" "$dmg"; fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notarize "$dmg" dmg
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  spctl --assess --type execute --verbose=2 "$app"
fi
rm -rf "$PWD/dist/Resim.app"
ditto "$app" "$PWD/dist/Resim.app"
(cd "$PWD/dist" && shasum -a 256 "$(basename "$dmg")") > "$dmg.sha256"
printf '\nApp: %s/dist/Resim.app\nDMG: %s\n' "$PWD" "$dmg"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then python3 scripts/verify-package.py --require-notarized; fi
# GitHub's latest/download URL requires the same asset name in every release.
# Copy only after signing, stapling and any required verification have finished.
cp "$dmg" "$staging/Resim.dmg"
mv -f "$staging/Resim.dmg" "$PWD/dist/Resim.dmg"
(cd "$PWD/dist" && shasum -a 256 Resim.dmg) > "$staging/Resim.dmg.sha256"
mv -f "$staging/Resim.dmg.sha256" "$PWD/dist/Resim.dmg.sha256"
printf 'Latest-release assets: %s/dist/Resim.dmg and Resim.dmg.sha256\n' "$PWD"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then echo 'Notarization pending: configure NOTARY_PROFILE for public distribution.'; fi
