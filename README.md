# Resim

A local image optimizer for macOS 14 and later, built with SwiftUI and Swift 6. Resim supports PNG, JPEG, WebP, HEIC, AVIF, GIF, and self-contained SVG, including GIF animations. Builds contain both Apple Silicon and Intel architectures.

Resim works offline, requires no account, and includes its codecs. There is no telemetry or automatic updater.

The interface supports English and Spanish and automatically follows your macOS language preferences. You can override the language for Resim in **System Settings → General → Language & Region → Applications**. See [Languages](docs/LOCALIZATION.md) for details.

## Use

Drop images from Finder into the window, or choose **Add Images…** (`⌘O`). Processing starts automatically. By default, Resim replaces each original with the validated, smaller image, keeping its name and location. If optimization fails, is cancelled, or produces no reduction, the original stays unchanged. **No Reduction** is a valid result.

In **Resim → Settings…** (`⌘,`), choose:

- **Automatic**: choose **Conservative** for fidelity, **Web** (default) for adaptive compression with small visual changes, or **Maximum compression** for smaller files with more visible detail loss. Web and Maximum try several quality levels against the same source and keep the smallest validated result.
- **Lossless**: preserves decoded samples or JPEG coefficients, plus supported presentation data. Some images will not become smaller.
- Replace originals (default), save copies beside them, or save copies in an output folder. Copy modes preserve originals and use `name-optimized.ext`; name collisions receive a number. Previously saved copy preferences are retained when upgrading.
- Optional removal of known personal metadata. This is selective and does not guarantee anonymity; unknown metadata and information visible in pixels may remain. HEIC and SVG require this option to be disabled.

Profiles preserve format and dimensions. PNG, GIF, SVG and lossless WebP keep their lossless paths. Profile thresholds are an initial calibration, not a guarantee of invisible changes. See [visual comparisons](docs/QA.md#compression-profile-comparisons) to review the tradeoffs on your images. Existing saved Lossless and file-saving choices are preserved; preferences without a profile use Web.

The sidebar groups optimization and output options under **General**, metadata controls under **Privacy**, and version information and third-party licenses under **About**.

Settings apply to newly added images. Press `Esc` to cancel active and queued jobs; completed changes remain. The context menu can reveal files in Finder or retry errors. Closing or quitting during processing asks whether to continue or cancel and close. Clearing finished rows does not delete files.

## Compression profile settings

Automatic mode uses the following encoder quality candidates. **Web is the default**.
Each candidate is encoded from the same original; Resim keeps the smallest result
that passes the selected quality floor and all preservation checks. A smaller
quality number generally permits more loss, but these numbers are encoder-specific,
not percentages of retained visual quality or directly comparable across formats.

| Format / validation | Conservative | Web (default) | Maximum compression |
| --- | --- | --- | --- |
| JPEG — MozJPEG quality | 92 | 98, 95, 92, 88, 84, 80, 76 | All Web levels + 70, 64, 58 |
| Lossy WebP — libwebp quality | 90 | 98, 94, 90, 85, 80, 75, 70 | All Web levels + 60, 50, 40 |
| AVIF — libavif/AOM quality | 95 | 95, 90, 85, 80, 75, 65, 55 | All Web levels + 45, 35, 25 |
| HEIC — Image I/O quality | 0.85 | 0.95, 0.90, 0.85, 0.80, 0.75, 0.70, 0.65 | All Web levels + 0.55, 0.45, 0.35 |
| PNG — Oxipng | Lossless, preset 2, `--nx` | Same | Same |
| Lossless WebP — libwebp | Lossless, method 4, `exact=1`, `near_lossless=100` | Same | Same |
| GIF — Gifsicle | Lossless, optimization level 2; frames and timing preserved | Same | Same |
| SVG — SVGO | Attribute sorting and compact XML; no geometry simplification or numeric rounding | Same | Same |
| Minimum SSIM in **each RGB channel**, for lossy candidates | 30 dB (≈ 0.999) | 20 dB (≈ 0.990) | 16 dB (≈ 0.975) |
| Maximum lossy attempts per image | 1 | 7 | 10 |

SSIM uses libwebp's logarithmic dB representation, **not PSNR**. These thresholds
are Resim's quality policy, not universal web standards or a guarantee that every
visual difference is imperceptible. More attempts can take longer; no recompression
is published if it fails quality, preservation, or size checks. Some images
therefore produce identical results across profiles.

JPEG preserves its original chroma subsampling and uses progressive coding.
WebP uses method 4 and alpha quality 100; lossless WebP additionally uses quality
75 as its encoding-effort parameter. AVIF uses AOM speed 6 and lossless alpha.
PNG, GIF, SVG and lossless WebP remain lossless in every profile. Alpha is checked
exactly, and all formats retain their dimensions and format. Unknown metadata
can disable lossy recompression. The separate **Lossless** mode overrides the
selected profile. See [codec preservation rules](docs/CODECS.md) for details.

## Supported images

| Format | Scope |
| --- | --- |
| PNG | Static images, including 16-bit samples, palettes, and transparency |
| JPEG | Conventional 8-bit RGB or grayscale images |
| WebP | Static lossy and lossless images |
| HEIC / HEIF | Static 8-bit SDR RGB images without depth, gain maps, or auxiliary images |
| AVIF | Static 8-bit SDR images with supported container properties |
| GIF | Static images and animations; both optimization modes remain lossless |
| SVG | Self-contained static UTF-8 documents; IDs, styles, geometry, text, and metadata preserved |

Unsupported variants, including APNG, animated WebP/AVIF, CMYK/HDR JPEG, and HDR HEIC/AVIF, are rejected with an explanation. GIF plain-text extensions and user-input controls are unsupported. SVG scripts, animations, external resources, DTDs, and SVGZ are unsupported. Resim optimizes within the original format; it does not convert between formats.

Inputs are limited to 100 MB and 40 megapixels. GIF additionally has a 1,000-frame limit and a 40-million cumulative frame-pixel limit. The queue permits at most two jobs within a shared 384 MiB estimated buffer budget. An individual image estimated above 384 MiB and up to 512 MiB runs alone; larger estimates are rejected, even below the other limits. SVG is limited to 4 MiB, 50,000 XML nodes and 128 nested elements. This budget is an admission estimate, not a hard process-memory cap.

See [codec and preservation details](docs/CODECS.md).

## Build and test

Development requires macOS, Xcode 26 or later with Command Line Tools (Swift 6.2 or later), Python 3.9 or later, CMake 3.22 or later, NASM, Rust/Cargo, and Node.js 22 or later with npm (development only for the SVG bundle). Select the full Xcode developer directory before building. With Homebrew, install CMake and NASM using `brew install cmake nasm`; all build tools must be available on `PATH`.

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
bash scripts/build.sh
bash scripts/test.sh
open .build/xcode/Build/Products/Release/Resim.app
```

The first build downloads and builds checksum-pinned codec sources. Later builds reuse the local outputs. `bash scripts/build-codecs.sh` explicitly rebuilds all codecs. Network access is needed to obtain dependencies, including Cargo dependencies, but is not needed to use the app.

The shared Xcode scheme is `Resim`. The project is generated by `python3 scripts/generate-project.py`; build and test scripts run it automatically, without XcodeGen. Build settings produce a Universal 2 app with ad hoc signing for local use. Tests run on the host architecture.

Fixtures are included. See their [provenance](ResimTests/Fixtures/README.md) before adding or regenerating samples. [QA guidance](docs/QA.md) covers smoke tests, benchmarks, and manual checks. A Universal 2 build does not establish runtime compatibility on both architectures or every supported macOS version.

GitHub Actions builds Universal 2 Release, checks launch, and runs the tests on macOS 15 Apple Silicon and Intel runners. It rebuilds codecs from source without a build cache and does not publish artifacts. For the equivalent local source-isolation check, run `python3 scripts/verify-clean-build.py`; see [publication verification](docs/PUBLISHING.md#verify-a-clean-source-build).

## Package

```sh
bash scripts/package.sh
```

This creates a local ad hoc package in `dist/`. Public direct distribution requires Developer ID signing and Apple notarization; see [distribution instructions](docs/DISTRIBUTION.md). Do not put signing credentials, certificates, private keys, or local release reports in the repository.

Run `python3 scripts/release.py --publish` on your signing Mac to build from a clean clone, run tests, sign and notarize through the local Keychain, and publish the verified DMG and checksum to GitHub. The command also requires successful Apple Silicon and Intel CI checks for the source commit. Apple credentials stay on the Mac; GitHub needs no signing secrets. Run without `--publish` for a signed rehearsal. See [local release automation](docs/DISTRIBUTION.md#automated-local-releases).

Installation and updates are manual: drag Resim into Applications and replace the app when updating. Removing Resim does not remove original images or optimized copies.

## Contribute and license

Read [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidance and [SECURITY.md](SECURITY.md) for reporting security concerns. Keep documentation, comments, contributor-facing messages, and interface source strings in English. Follow the [localization guide](docs/LOCALIZATION.md) when adding or translating interface strings.

Original Resim source is available under the [MIT License](LICENSE). See [LICENSES.md](LICENSES.md) for third-party scope. Third-party components retain their own licenses and notices in [Resim/Resources/Licenses](Resim/Resources/Licenses/ThirdPartyNotices.md). The app icon uses Nucleo UI artwork under [separate terms](Resim/Resources/Licenses/Nucleo-COPYRIGHT.txt); see the [brand asset notes](Resim/Resources/Brand/README.md).

Before creating a public repository, follow the [publication checklist](docs/PUBLISHING.md).

This software is based in part on the work of the Independent JPEG Group.
