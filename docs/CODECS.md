# Codecs and preservation

Resim optimizes images within their existing format and publishes only validated, smaller results. By default, it atomically replaces the original at the same path, after verifying that the source has not changed since admission. Copy modes preserve the original and publish beside it or in a chosen folder without overwriting existing copies. All encoding and validation use a private snapshot of the admitted source; changed input files are rejected.

## Bundled engines

| Format | Engine | Integration |
| --- | --- | --- |
| PNG | Oxipng 9.1.5 | Bundled command-line helper |
| JPEG | MozJPEG 4.1.5 | Static library and C bridge |
| WebP | libwebp 1.6.0 | Static libraries and C bridge |
| HEIC | macOS Image I/O and HEVC encoder | System frameworks |
| AVIF | libavif 1.4.2 and AOM 3.14.1 | Static libraries and C bridge |
| GIF | Gifsicle 1.98 (`gifsicle` and `gifdiff`) | Bundled command-line helpers |

Official source archives and SHA-256 checksums are pinned in `scripts/build-codecs.sh`, `scripts/build-avif.sh`, and `scripts/build-gif.sh`. Codecs are built for arm64 and x86_64 with a macOS 14 deployment target. The app uses system libraries and its own bundled codecs, without requiring a Homebrew installation at runtime. Dependency downloads happen during development builds only.

Exact upstream notices are copied into `Resim/Resources/Licenses/`, including Oxipng's transitive dependency notices. The GIF build also includes the corresponding unmodified Gifsicle source archive and build recipe with the distributed helpers. Preserve these files when packaging.

## Lossless behavior

- **PNG:** Oxipng preset 2, one thread, and `--nx` avoid sample-depth and palette transformations. Validation compares native samples without drawing, conversion to 8 bits, or alpha premultiplication. ICC profile bytes are compared after streaming zlib decompression. Semantically equivalent trimming of trailing opaque `tRNS` entries is allowed. The descriptive `iCCP` profile name may be normalized; profile content must remain equal.
- **JPEG:** the bridge reuses original coefficients and quantization tables, optimizes entropy/progressive coding, and compares DCT coefficients, tables, subsampling, and color space. Original JFIF/Adobe marker parameters are preserved. CMYK/YCCK, non-8-bit precision, MPF, and known gain-map/HDR markers are excluded. JPEG errors and `longjmp` handling stay inside C.
- **WebP:** lossless encoding uses `exact = 1`, method 4, and `near_lossless = 100`, followed by exact RGBA comparison, including RGB under zero alpha. Already-lossy WebP keeps its encoded image and alpha chunks in Lossless mode. Container order and unknown chunks are preserved and checked with libwebp demux/mux APIs.
- **HEIC:** Image I/O copies encoded content without HEVC recompression. Native samples, full Image I/O properties, orientation, ICC, and opaque EXIF/XMP payloads are checked. If a smaller valid copy cannot be produced, the result is No Reduction.
- **AVIF:** AV1 lossless re-encoding must preserve decoded native YUV/alpha planes, color parameters, ICC, EXIF/XMP, crop, pixel aspect ratio, rotation, and mirroring. Lossless describes preservation of decoded samples; it does not identify whether the input was originally encoded lossily.
- **GIF:** both modes use Gifsicle optimization level 2 with empty frames retained. `gifdiff` checks rendered equivalence. Structural validation also requires the same dimensions, aspect ratio, background color, individual raw delays, loop count, and retained metadata payloads at the same frame positions. Delta rectangles and disposal choices may change. There is no palette quantization, lossy LZW, or frame dropping.

## Compression profiles

Automatic mode offers three ordered profiles. **Web** is the default, including when migrating preferences without a profile. Explicit Lossless mode and file-saving/privacy choices are retained. A selected profile is captured with each admitted job; changing settings cannot change queued work. Lossless mode overrides the profile.

The [README profile table](../README.md#compression-profile-settings) lists every format's quality candidates, fixed encoder settings, and per-profile quality floors.

These are initial calibration values for visual review, not universal web standards or percentages of retained visual quality. libwebp expresses SSIM in dB; these floors correspond approximately to SSIM 0.999, 0.990 and 0.975. They are **not PSNR**. Global metrics may miss local artifacts, and the smallest accepted result among these bounded trials is not necessarily the smallest perceptually acceptable encoding in existence.

Each attempt encodes the same admitted original; no candidate is recompressed. The smallest validated candidate wins, including the safe lossless candidate where available. No larger result is published. Web tries at most seven lossy levels, Maximum ten; this uses more CPU/time than Conservative. Attempts are sequential inside the existing bounded worker pool, with cancellation between attempts and native cancellation callbacks where available. Per-attempt validation buffers are released before the next attempt.

Format and dimensions remain unchanged. PNG, GIF, SVG, and lossless WebP retain their lossless paths in all profiles. JPEG retains original subsampling and progressive coding. WebP uses method 4 and alpha quality 100. AVIF uses AOM speed 6 and lossless alpha. HEIC tries a native lossless copy before optional HEVC recompression. Unknown JPEG markers, metadata between scans, and uninterpretable WebP/XMP extensions can disable recompression.

Lossy candidates must pass full-resolution validation with finite SSIM scores at or above the selected floor in **every** RGB channel. The libwebp distortion API returns B/G/R/A/All scores; acceptance uses the individual RGB channels. Alpha is checked exactly; AVIF also checks hidden RGB under zero alpha. Preservation checks are never relaxed by the selected profile. HEIC remains restricted to 8-bit SDR RGB without sequences or auxiliary images; AVIF rejects HDR, gain maps, animation, progressive content, and unsupported container properties.

The native `rc_*_optimize` profile argument uses 0 for Lossless, 1 for Conservative (the previous automatic behavior), 2 for Web, and 3 for Maximum. Existing `rc_*_ssim_rgb` diagnostics retain their 30 dB contract; profile-aware checks use `rc_rgba_quality_rgb` or `rc_avif_quality_rgb`.

## Metadata and privacy

Personal-metadata removal is selective. EXIF is reconstructed to retain supported presentation information, such as orientation, embedded ICC data, transfer/chromaticity, YCbCr interpretation, ColorSpace, Gamma, and interoperability. GPS, author/device tags, MakerNote, and thumbnails are removed when safely understood. Malformed EXIF is retained rather than partially interpreted.

JPEG comments and known personal XMP can be removed. JFIF density is preserved while its thumbnail is removed. XMP carrying presentation data or unknown namespaces is retained. PNG removes known personal text keywords and `tIME`, preserves unknown text/XMP, and uses the same selective EXIF handling. AVIF uses that EXIF routine and preserves unknown XMP. GIF removes comment and image-name extensions only; ICC, XMP, and application payloads remain.

HEIC does not support personal-metadata removal. Enabling that setting excludes HEIC with an explanation. When disabled, its metadata is preserved in full. A bounded BMFF reader restores original opaque EXIF/XMP items if Image I/O rewrites them; unsupported layouts are rejected.

Metadata removal does not guarantee anonymization. Private information can remain in unknown metadata or the image pixels themselves.

## Resource limits and cancellation

Inputs are limited to 100 MB and 40 megapixels. GIF permits at most 1,000 frames and 40 million accumulated frame pixels. Additional parser limits include 4,096 PNG chunks, 64 MiB decompressed PNG ICC profiles, and bounded HEIC/GIF metadata. Malformed or unsupported inputs are rejected before expensive native decoding where the parsers can establish the limit.

The coordinator permits at most two jobs within 384 MiB of estimated aggregate buffer memory. An individual image estimated above 384 MiB and up to 512 MiB runs alone; estimates above 512 MiB are rejected. Estimates include decoded samples, comparison buffers, compressed input, and overhead; they are not hard RSS limits. Large images may be rejected below the pixel limit.

Native work runs in the bounded worker pool. Cancellation terminates and waits for bundled helper processes; libwebp checks a callback. Noninterruptible JPEG, HEVC, and AOM calls finish before their candidates are discarded. Publication checks cancellation again, so cancelled work does not publish a result.

## SVG

SVG uses SVGO 4.1.0 through an isolated, Universal 2 native helper running the system JavaScriptCore interpreter with JIT disabled. No Node.js runtime is distributed. `scripts/build-svg.sh` uses pinned npm dependencies and their lockfile to generate the bundle, compile its SHA-256 into the helper, and include the exact dependency notices.

Both modes use a conservative policy: SVGO attribute sorting and compact XML serialization, with native XML recovery for original comments and protected text. The default SVGO preset is not enabled. No geometry simplification, numeric rounding, ID cleanup, style rewriting, rasterization or metadata removal is performed. Before publication, native XML validation compares all attributes, element order, text, comments and metadata; only harmless formatting whitespace in known SVG containers may differ. A smaller candidate that fails equivalence is discarded.

The optimizer parses SVG as data and never renders or executes it. XML external entity resolution is disabled, and DTDs/entities, scripts, event handlers, animations, foreignObject and external references are excluded. Local fragment references and embedded PNG/JPEG/WebP data are supported. The initial scope is self-contained UTF-8 SVG, not SVGZ. Personal metadata removal must be disabled so that licenses, accessibility descriptions and unknown RDF/XML are preserved. Admission is bounded to 4 MiB, 50,000 XML nodes, 256 attributes per element and depth 128; the isolated process is cancellable and has a 20-second timeout.
