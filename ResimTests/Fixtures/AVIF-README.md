# AVIF fixtures

Generated from locally authored deterministic patterns with libavif 1.4.2 and AOM 3.14.1. Regenerate with `bash scripts/generate-avif-fixtures.sh` after building the codec libraries. The color sample uses `sRGB.icc`, whose origin is documented in the [fixture README](README.md).

- `avif-lossless-alpha.avif`: lossless 4:4:4, alpha 0/127/255, and RGB under transparency.
- `avif-lossy.avif`: a lossy source used to verify that Lossless mode preserves decoded YUV samples.
- `avif-auto.avif`: a lossless gradient large enough to exercise accepted automatic recompression.
- `avif-orientation-icc.avif`: ICC, EXIF with fictitious author/orientation data, unknown XMP, cropping, pixel aspect ratio, rotation, and mirroring.
- `avif-degraded.avif`: deliberately low quality for SSIM rejection.
- `avif-animated.avif`: a rejected two-image sequence.
- `avif-hdr10.avif`: rejected 10-bit/PQ content.
- `avif-gain-map.avif`: a rejected gain map.
- `avif-unknown-property.avif`: a rejected opaque property whose meaning cannot be safely preserved.

Lossless samples contain a valid 16 KiB BMFF `free` box, allowing a reproducible reduction without relying on compression heuristics. Automatic mode uses quality 95, checks every RGB channel for at least 30 dB SSIM, and requires exact alpha and RGB under complete transparency.
