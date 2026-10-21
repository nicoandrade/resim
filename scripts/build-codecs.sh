#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CMAKE="${CMAKE:-cmake}"
command -v "$CMAKE" >/dev/null || { echo 'Install CMake (development only).' >&2; exit 1; }
command -v nasm >/dev/null || { echo 'Install NASM to retain Intel SIMD.' >&2; exit 1; }
mkdir -p vendor/cache vendor/src vendor/build/include vendor/build/lib Resim/Resources/Codecs Resim/Resources/Licenses
fetch() {
 local name="$1" url="$2" sum="$3"
 [[ -f "vendor/cache/$name" ]] || curl --fail --location --retry 3 "$url" --output "vendor/cache/$name"
 echo "$sum  vendor/cache/$name" | shasum -a 256 -c -
}
fetch mozjpeg-4.1.5.tar.gz https://github.com/mozilla/mozjpeg/archive/refs/tags/v4.1.5.tar.gz 9fcbb7171f6ac383f5b391175d6fb3acde5e64c4c4727274eade84ed0998fcc1
fetch libwebp-1.6.0.tar.gz https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
fetch oxipng-9.1.5.tar.gz https://github.com/oxipng/oxipng/archive/refs/tags/v9.1.5.tar.gz 8f99d5c67efa2a7550023bf610b90e65d421375c9ed7f37097f83ae5c05f85bd
for dep in mozjpeg-4.1.5 libwebp-1.6.0 oxipng-9.1.5; do
 [[ -d "vendor/src/$dep" ]] || tar -xf "vendor/cache/$dep.tar.gz" -C vendor/src
done
for arch in arm64 x86_64; do
 "$CMAKE" -S vendor/src/mozjpeg-4.1.5 -B "vendor/build/mozjpeg-$arch" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DPNG_SUPPORTED=OFF -DREQUIRE_SIMD=ON
 "$CMAKE" --build "vendor/build/mozjpeg-$arch" --target jpeg-static --parallel 4
 "$CMAKE" -S vendor/src/libwebp-1.6.0 -B "vendor/build/webp-$arch" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF -DWEBP_ENABLE_SIMD=ON -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
 "$CMAKE" --build "vendor/build/webp-$arch" --target webp libwebpmux webpdemux sharpyuv --parallel 4
 if [[ "$arch" = arm64 ]]; then target=aarch64-apple-darwin; else target=x86_64-apple-darwin; fi
 MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --manifest-path vendor/src/oxipng-9.1.5/Cargo.toml --release --locked --target "$target"
done
lipo -create vendor/build/mozjpeg-{arm64,x86_64}/libjpeg.a -output vendor/build/lib/libjpeg.a
for lib in webp webpmux webpdemux sharpyuv; do
 lipo -create "vendor/build/webp-arm64/lib$lib.a" "vendor/build/webp-x86_64/lib$lib.a" -output "vendor/build/lib/lib$lib.a"
done
cp vendor/src/mozjpeg-4.1.5/{jpeglib.h,jmorecfg.h,jerror.h} vendor/build/include/
cp vendor/build/mozjpeg-arm64/jconfig.h vendor/build/include/
mkdir -p vendor/build/include/webp
cp vendor/src/libwebp-1.6.0/src/webp/*.h vendor/build/include/webp/
lipo -create vendor/src/oxipng-9.1.5/target/{aarch64,x86_64}-apple-darwin/release/oxipng -output Resim/Resources/Codecs/oxipng
chmod 755 Resim/Resources/Codecs/oxipng
strip -x Resim/Resources/Codecs/oxipng
cp vendor/src/mozjpeg-4.1.5/LICENSE.md Resim/Resources/Licenses/MozJPEG-LICENSE.md
cp vendor/src/mozjpeg-4.1.5/README.ijg Resim/Resources/Licenses/MozJPEG-README.ijg
# Preserve the relative README.ijg link in the unmodified upstream license.
cp vendor/src/mozjpeg-4.1.5/README.ijg Resim/Resources/Licenses/README.ijg
cp vendor/src/mozjpeg-4.1.5/simd/nasm/jsimdext.inc Resim/Resources/Licenses/MozJPEG-SIMD-notice.txt
cp vendor/src/libwebp-1.6.0/COPYING Resim/Resources/Licenses/libwebp-COPYING.txt
cp vendor/src/libwebp-1.6.0/PATENTS Resim/Resources/Licenses/libwebp-PATENTS.txt
cp vendor/src/oxipng-9.1.5/LICENSE Resim/Resources/Licenses/Oxipng-LICENSE.txt
python3 scripts/codec-license-notices.py
for bin in vendor/build/lib/*.a Resim/Resources/Codecs/oxipng; do lipo -archs "$bin"; done

bash scripts/build-avif.sh

bash scripts/build-gif.sh

bash scripts/build-svg.sh
