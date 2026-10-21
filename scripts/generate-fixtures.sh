#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/generate-fixtures.py
swift scripts/generate-jpeg-fixtures.swift
mkdir -p .build
xcrun clang -O2 -Ivendor/build/include scripts/generate-webp-fixtures.c \
  vendor/build/lib/libwebpmux.a vendor/build/lib/libwebp.a vendor/build/lib/libsharpyuv.a \
  -o .build/generate-webp-fixtures
.build/generate-webp-fixtures

xcrun clang -O2 -Ivendor/build/include scripts/generate-variant-fixtures.c \
  vendor/build/lib/libjpeg.a -o .build/generate-variant-fixtures
.build/generate-variant-fixtures
cp vendor/src/mozjpeg-4.1.5/testimages/testorig.jpg ResimTests/Fixtures/photo-ijg.jpg
cp vendor/src/mozjpeg-4.1.5/README.ijg ResimTests/Fixtures/IJG-README.txt

bash scripts/generate-avif-fixtures.sh
python3 scripts/generate-gif-fixtures.py
