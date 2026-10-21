#!/bin/bash
# Build checksum-pinned static AVIF dependencies for the same two app architectures.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
mkdir -p vendor/cache vendor/src vendor/build/lib vendor/build/include/avif Resim/Resources/Licenses
fetch() {
 local archive="$1" url="$2" checksum="$3"
 [[ -f "vendor/cache/$archive" ]] || curl --fail --location --retry 3 "$url" --output "vendor/cache/$archive"
 echo "$checksum  vendor/cache/$archive" | shasum -a 256 -c -
}
fetch libavif-1.4.2.tar.gz https://github.com/AOMediaCodec/libavif/archive/refs/tags/v1.4.2.tar.gz 2b645287340ba5a631d268b551dc2d72bd73ac33335962dd36dcdb6d8366921d
fetch aom-3.14.1.tar.gz https://storage.googleapis.com/aom-releases/libaom-3.14.1.tar.gz 44bf90dbd23e734d50e70a8c41c285193922938bd0d3bc2ee56764d181d55ef5
[[ -d vendor/src/libavif-1.4.2 ]] || tar -xf vendor/cache/libavif-1.4.2.tar.gz -C vendor/src
[[ -d vendor/src/libaom-3.14.1 ]] || tar -xf vendor/cache/aom-3.14.1.tar.gz -C vendor/src
for arch in arm64 x86_64; do
 cmake -S vendor/src/libaom-3.14.1 -B "vendor/build/aom-$arch" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DAOM_TARGET_CPU="$arch" -DBUILD_SHARED_LIBS=OFF -DCONFIG_PIC=1 \
  -DENABLE_DOCS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF -DENABLE_TOOLS=OFF \
  -DCONFIG_AV1_HIGHBITDEPTH=1 -DCONFIG_WEBM_IO=0 -DCONFIG_LIBYUV=0
 cmake --build "vendor/build/aom-$arch" --target aom --parallel 4
 cmake -S vendor/src/libavif-1.4.2 -B "vendor/build/avif-$arch" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF -DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF \
  -DAVIF_CODEC_AOM=SYSTEM -DAVIF_LIBYUV=OFF -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=TRUE \
  -DAOM_INCLUDE_DIR="$root/vendor/src/libaom-3.14.1" -DAOM_LIBRARY="$root/vendor/build/aom-$arch/libaom.a"
 cmake --build "vendor/build/avif-$arch" --target avif_static --parallel 4
done
lipo -create vendor/build/avif-{arm64,x86_64}/libavif.a -output vendor/build/lib/libavif.a
lipo -create vendor/build/aom-{arm64,x86_64}/libaom.a -output vendor/build/lib/libaom.a
cp vendor/src/libavif-1.4.2/include/avif/avif.h vendor/build/include/avif/
cp vendor/src/libavif-1.4.2/LICENSE Resim/Resources/Licenses/libavif-LICENSE.txt
cp vendor/src/libaom-3.14.1/LICENSE Resim/Resources/Licenses/libaom-LICENSE.txt
cp vendor/src/libaom-3.14.1/PATENTS Resim/Resources/Licenses/libaom-PATENTS.txt
lipo -archs vendor/build/lib/libavif.a
lipo -archs vendor/build/lib/libaom.a
