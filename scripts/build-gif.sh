#!/bin/bash
# Reproducible standalone GIF tools; no X11 viewer or external runtime dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
gif_sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p vendor/cache vendor/src vendor/build Resim/Resources/Codecs Resim/Resources/Licenses/Gifsicle
archive=vendor/cache/gifsicle-1.98.tar.gz
[[ -f "$archive" ]] || curl --fail --location --retry 3 https://www.lcdf.org/gifsicle/gifsicle-1.98.tar.gz --output "$archive"
echo "e9d4cc0816db95c64d32e79f778836db0f1f7eb15868490bd330104e5146b66e  $archive" | shasum -a 256 -c -
[[ -d vendor/src/gifsicle-1.98 ]] || tar -xf "$archive" -C vendor/src
for arch in arm64 x86_64; do
 mkdir -p "vendor/build/gifsicle-$arch"
 (cd "vendor/build/gifsicle-$arch"
  CC="$(xcrun --find clang) -arch $arch" CFLAGS="-O2 -isysroot $gif_sdk -mmacosx-version-min=14.0" \
   LDFLAGS="-isysroot $gif_sdk -mmacosx-version-min=14.0" "$root/vendor/src/gifsicle-1.98/configure" \
   --disable-gifview --disable-threads --build="$(uname -m)-apple-darwin" --host="$arch-apple-darwin"
  make -j4
 )
done
for tool in gifsicle gifdiff; do
 lipo -create "vendor/build/gifsicle-arm64/src/$tool" "vendor/build/gifsicle-x86_64/src/$tool" \
  -output "Resim/Resources/Codecs/$tool"
 strip -x "Resim/Resources/Codecs/$tool"
 chmod 755 "Resim/Resources/Codecs/$tool"
 codesign --force --sign - --options runtime "Resim/Resources/Codecs/$tool"
 lipo "Resim/Resources/Codecs/$tool" -verify_arch arm64
 lipo "Resim/Resources/Codecs/$tool" -verify_arch x86_64
done
# Include unmodified corresponding source plus the exact build recipe with the tools.
cp vendor/src/gifsicle-1.98/COPYING Resim/Resources/Licenses/Gifsicle/COPYING
cp vendor/src/gifsicle-1.98/README.md Resim/Resources/Licenses/Gifsicle/README.md
cp "$archive" Resim/Resources/Licenses/Gifsicle/gifsicle-1.98.tar.gz
cp scripts/build-gif.sh Resim/Resources/Licenses/Gifsicle/build-gif.sh
