# Changelog

Notable changes to Resim are documented here. This file follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2] - 2026-10-23

### Changed

- Maximum JPEG compression refines intermediate quality levels to find smaller validated files while retaining the existing 16 dB quality floor in every RGB channel and the limit of ten lossy attempts. Other profiles and formats keep their current settings.

### Added

- JPG and PNG size and timing comparisons with ImageOptim, including measurement and metadata differences, plus reproducible comparison and paired JPEG benchmark tools.
- Regression coverage for intermediate JPEG quality selection and cancellation after a smaller candidate has been found.

## [0.2.1] - 2026-10-21

### Changed

- The DMG opens with a subtle sunset background, Resim and Applications icons, and directional arrows for drag-to-install. The layout supports Retina displays and keeps the included instructions hidden.
- Packaging verifies the mounted installer's background, icon positions, Applications shortcut, and app signature before preparing release assets.

### Fixed

- Removed the fragmented white highlights around the app icon's edges at small Finder sizes while preserving its colors and interior glass relief.

## 0.2.0 - 2026-10-21

### Added

- Conservative, Web, and Maximum compression profiles, with adaptive quality searches for JPEG, lossy WebP, AVIF, and HEIC. Each profile keeps the smallest candidate that passes its visual-quality and preservation checks.
- A technical README table describing encoder quality levels and validation thresholds, plus a local before/after comparison tool for reviewing file size and image detail.
- Local release automation builds from a clean clone, tests, signs and notarizes through the Mac's Keychain, then publishes the DMG and SHA-256 checksum as Latest on GitHub. The landing keeps its permanent download URL, and no Apple signing credentials are stored on GitHub.

### Changed

- Web is now the default profile for automatic optimization, including saved settings without a profile. Explicit Lossless, file-saving, and privacy preferences are retained. PNG, GIF, SVG, and lossless WebP keep their lossless behavior across profiles.

### Fixed

- The isolated launch check now uses a system tool to check external dependencies on clean macOS runners.
- HEIC coverage uses a portable padded sample for accepted optimization and checks safe fallback across native encoder differences without relaxing the Conservative RGB quality gate.

## 0.1.0 - 2026-10-20

Initial release prepared locally.

### Added

- Offline image optimization for macOS 14 and later on Apple Silicon and Intel, with bundled codecs and no account requirement.
- Support for PNG, JPEG, static WebP, HEIC/HEIF, AVIF, GIF animations, and self-contained static SVG, with automatic and lossless optimization modes.
- Drag-and-drop and file-picker import, a processing queue with cancellation, error retries, and Finder integration.
- Validated replacement of originals or saving optimized copies beside the source or in a selected folder. Failed, cancelled, or non-shrinking optimizations leave originals unchanged.
- Optional selective removal of known personal metadata for supported formats, and an interface localized in English and Spanish.
- Universal 2 DMG packaging with a checksum and optional Developer ID signing and Apple notarization.

### Fixed

- Bound Swift 6.2 type-checking work when constructing animated GIF test fixtures so the test suite can compile reliably.

[Unreleased]: https://github.com/nicoandrade/resim/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/nicoandrade/resim/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/nicoandrade/resim/compare/v0.2.0...v0.2.1
