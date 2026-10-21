#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-Release}"
codecs_ready=1
for library in jpeg webpmux webpdemux webp sharpyuv; do
  [[ -f "vendor/build/lib/lib$library.a" ]] || codecs_ready=0
done
if [[ ! -x Resim/Resources/Codecs/oxipng || "$codecs_ready" != 1 ]]; then
  bash scripts/build-codecs.sh
fi
if [[ ! -f vendor/build/lib/libavif.a || ! -f vendor/build/lib/libaom.a ]]; then
  bash scripts/build-avif.sh
fi
if [[ ! -x Resim/Resources/Codecs/gifsicle || ! -x Resim/Resources/Codecs/gifdiff ]]; then
  bash scripts/build-gif.sh
fi
bash scripts/build-svg.sh --if-needed
python3 scripts/generate-project.py
xcodebuild -project Resim.xcodeproj -scheme Resim -configuration "$configuration" \
  -destination 'generic/platform=macOS' -derivedDataPath .build/xcode \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build "$@"
app=".build/xcode/Build/Products/$configuration/Resim.app"
# Remove artifacts left by hosted tests before signing the standalone product.
rm -rf "$app/Contents/PlugIns"
for helper in oxipng gifsicle gifdiff resim-svg; do
  codesign --force --sign - --options runtime "$app/Contents/Resources/Codecs/$helper"
  lipo "$app/Contents/Resources/Codecs/$helper" -verify_arch arm64
  lipo "$app/Contents/Resources/Codecs/$helper" -verify_arch x86_64
done
codesign --force --sign - --options runtime "$app"
codesign --verify --deep --strict "$app"
lipo "$app/Contents/MacOS/Resim" -verify_arch arm64
lipo "$app/Contents/MacOS/Resim" -verify_arch x86_64
lipo "$app/Contents/Resources/Codecs/oxipng" -verify_arch arm64
lipo "$app/Contents/Resources/Codecs/oxipng" -verify_arch x86_64
printf '\nApp: %s\n' "$PWD/$app"
