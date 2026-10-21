#!/bin/bash
# Build an offline SVG optimizer using the system JavaScriptCore interpreter.
set -euo pipefail
cd "$(dirname "$0")/.."
# Reuse the helper only while both its sources and generated outputs match.
svg_stamp=.build/svg-runtime/build.sha256
svg_signature() {
 shasum -a 256 scripts/build-svg.sh scripts/svg-helper.swift \
  scripts/svg-tooling/{build.mjs,entry.js,package.json,package-lock.json} \
  scripts/svg-tooling/notices/boolbase-LICENSE \
  Resim/Resources/Codecs/{resim-svg,svgo.js,svgo-manifest.json} | shasum -a 256
}
if [[ "${1:-}" == --if-needed && -f "$svg_stamp" && \
      -x Resim/Resources/Codecs/resim-svg && -f Resim/Resources/Codecs/svgo.js && \
      -f Resim/Resources/Codecs/svgo-manifest.json ]]; then
 if [[ "$(svg_signature)" == "$(cat "$svg_stamp")" ]]; then
  exit 0
 fi
fi
svg_sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p .build/svg-runtime Resim/Resources/Codecs
npm ci --ignore-scripts --no-audit --no-fund --prefix scripts/svg-tooling
node scripts/svg-tooling/build.mjs
for svg_arch in arm64 x86_64; do
 xcrun swiftc -O -parse-as-library -sdk "$svg_sdk" \
  -target "$svg_arch-apple-macos14.0" -framework JavaScriptCore \
  scripts/svg-helper.swift .build/svg-runtime/BundleDigest.swift \
  -o ".build/svg-runtime/resim-svg-$svg_arch"
done
lipo -create .build/svg-runtime/resim-svg-arm64 .build/svg-runtime/resim-svg-x86_64 \
 -output Resim/Resources/Codecs/resim-svg
strip -x Resim/Resources/Codecs/resim-svg
chmod 755 Resim/Resources/Codecs/resim-svg
codesign --force --sign - --options runtime Resim/Resources/Codecs/resim-svg
lipo Resim/Resources/Codecs/resim-svg -verify_arch arm64
lipo Resim/Resources/Codecs/resim-svg -verify_arch x86_64
svg_signature > "$svg_stamp"
