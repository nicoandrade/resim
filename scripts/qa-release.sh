#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
# Optional local photo: .build/release-qa-source.jpg. Nothing is downloaded or
# copied into the public fixture directory. Generated inputs remain in .build.
trap 'rm -f .build/run-release-qa' EXIT
if [[ ! -x Resim/Resources/Codecs/oxipng ]]; then
  bash scripts/build-codecs.sh
fi
for library in jpeg webpmux webpdemux webp sharpyuv; do
  if [[ ! -f "vendor/build/lib/lib$library.a" ]]; then
    bash scripts/build-codecs.sh
    break
  fi
done
if [[ ! -f vendor/build/lib/libavif.a || ! -f vendor/build/lib/libaom.a ]]; then
  bash scripts/build-avif.sh
fi
if [[ ! -x Resim/Resources/Codecs/gifsicle || ! -x Resim/Resources/Codecs/gifdiff ]]; then
  bash scripts/build-gif.sh
fi
bash scripts/build-svg.sh --if-needed
clang -O2 -mmacosx-version-min=14.0 -Ivendor/build/include scripts/qa-encode-rgba.c \
  -Lvendor/build/lib -lwebp -lsharpyuv -lavif -laom -lc++ -lm -lpthread -o .build/qa-encode-rgba
touch .build/run-release-qa
python3 scripts/generate-project.py --isolated-qa
xcodebuild -project .build/ResimQA.xcodeproj -scheme Resim -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/xcode-release-qa \
  ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
  -parallel-testing-enabled NO \
  -only-testing:ResimTests/ReleaseQATests/testSevenFormatsAndLargeBatchesInRelease build-for-testing "$@"
python3 - <<'PY'
import json, pathlib, plistlib, subprocess
app = pathlib.Path('.build/xcode-release-qa/Build/Products/Release/Resim.app')
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.resim.qa.releasehost'
assert info['CFBundleDisplayName'] == info['CFBundleName'] == 'Resim QA Host'
for path in (app/'Contents/Resources').glob('*.lproj/InfoPlist.strings'):
 localized=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(path)]))
 for key in ('CFBundleDisplayName', 'CFBundleName'):
  assert key not in localized or localized[key] == 'Resim QA Host', (path, key)
print('Isolated QA host identity and localized names verified.')
PY
xcodebuild -project .build/ResimQA.xcodeproj -scheme Resim -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/xcode-release-qa \
  ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
  -parallel-testing-enabled NO \
  -only-testing:ResimTests/ReleaseQATests/testSevenFormatsAndLargeBatchesInRelease test-without-building "$@"
python3 - <<'PY'
import json
r=json.load(open('.build/release-qa.json'))
print(f"Release QA: {r['status']} | {r['os']} | host peak RSS {r['peak_host_rss_bytes']/2**20:.1f} MiB")
for b in r['batches']:
 print(f"{b['case']}: {b['total']} files, {b['optimized']} optimized, {b['unchanged']} unchanged, {b['unsupported']} unsupported, {b['cancelled']} cancelled, {b['failed']} failed; {b['elapsed_ms']/1000:.1f}s")
print('Report: .build/release-qa.json')
PY
