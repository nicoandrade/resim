#!/bin/bash
# Launch an isolated bundle outside the repository, with no developer tools on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="${1:-$PWD/.build/xcode/Build/Products/Release/Resim.app}"
[[ -d "$source_app" ]] || { echo 'App missing; run scripts/build.sh.' >&2; exit 1; }
scratch="$(mktemp -d /tmp/resim-smoke.XXXXXX)"
trap 'if [[ -n "${pid:-}" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$scratch"' EXIT
ditto "$source_app" "$scratch/Resim.app"
app="$scratch/Resim.app"
for bin in "$app/Contents/MacOS/Resim" "$app/Contents/Resources/Codecs/oxipng"; do
  lipo "$bin" -verify_arch arm64
  lipo "$bin" -verify_arch x86_64
  if otool -L "$bin" | tail -n +2 | rg '/opt/homebrew|/usr/local|vendor/'; then
    echo 'Unexpected external dependency' >&2; exit 1
  fi
done
codesign --verify --deep --strict "$app"
PATH=/usr/bin:/bin "$app/Contents/Resources/Codecs/oxipng" --version
PATH=/usr/bin:/bin "$app/Contents/MacOS/Resim" > "$scratch/launch.log" 2>&1 &
pid=$!
sleep 2
kill -0 "$pid"
ps -o pid=,rss=,etime=,comm= -p "$pid"
echo 'Smoke launch OK. Check UI interaction and compression separately; this script does not run the Intel slice.'
