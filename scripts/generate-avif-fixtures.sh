#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f vendor/build/lib/libavif.a || ! -f vendor/build/lib/libaom.a ]]; then
  bash scripts/build-avif.sh
fi
mkdir -p .build
clang -O2 -mmacosx-version-min=14.0 -Ivendor/build/include \
  scripts/generate-avif-fixtures.c -Lvendor/build/lib \
  -lavif -laom -lc++ -lm -lpthread -o .build/generate-avif-fixtures
.build/generate-avif-fixtures ResimTests/Fixtures
