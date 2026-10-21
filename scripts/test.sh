#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
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
xcodebuild -project Resim.xcodeproj -scheme Resim -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/xcode \
  ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- test "$@"
