# QA guide

Use this guide to reproduce checks for the current source. Local reports are build artifacts and are not public release evidence. Record the revision, macOS/Xcode versions, architecture, and test outcome when preparing a release; sanitize anything shared publicly.

## Automated checks

```sh
bash scripts/build.sh
bash scripts/test.sh
bash scripts/smoke.sh
```

`build.sh` creates a Release Universal 2 app and checks signatures and architecture slices. `test.sh` runs the shared scheme in Debug on the host architecture. Codec dependencies are built when missing. The benchmark test is intentionally skipped during the normal suite.

The suite covers codec preservation and rejection paths, source snapshots and integrity, deduplication, output collisions, cancellation, retries, per-admission settings, and bounded batch processing. Format-specific integration tests exercise native codecs and bundled helpers using the included fixtures. GIF tests independently render frames with Image I/O and check timing and metadata. SVG tests compare native rendering and XML semantics, including IDs, styles, high-precision numbers, text, comments, and metadata.

`smoke.sh` launches a copy outside the repository with only system tools on `PATH`. It checks the app and Oxipng architecture/dependency information and confirms the process remains running. It does not validate a Finder gesture, the complete UI, or runtime behavior on another architecture.

## Seven-format Release QA

```sh
bash scripts/qa-release.sh
```

This opt-in hosted XCTest generates 140 inputs (20 per supported format) with raster dimensions from 1600×1200 to 3000×2000, runs both optimization modes, cancellation and recovery, and metadata-removal policy checks. It adds work during processing, reserves existing output names, hashes every source, checks published dimensions and sizes, and validates rendered results independently. The ordinary test suite skips this heavier scenario. The command uses a separate project, DerivedData directory and app identifier under `.build/`, with a host named **Resim QA Host**, to keep its process separate from the normal app.

The generated corpus remains in `.build/release-qa-corpus/` for native UI checks. Its manifest records input hashes and the generation recipe. `.build/release-qa.json` records results, codec timings, sampled host RSS, and MainActor heartbeat intervals. Host RSS includes XCTest, generation, independent verification and allocator retention; it excludes helper processes and must not be reported as standalone app memory.

JPEG preservation is checked through exact DCT coefficients and quantization tables. Image I/O may round individual RGB samples differently for baseline and progressive JPEG even when those values are identical; that decoder behavior does not redefine JPEG losslessness. Actual recompression still requires its quality checks. Other raster outputs are decoded independently with Image I/O, and SVG rendering uses AppKit.

The default corpus uses original deterministic artwork and an enlarged IJG test photograph; resizing does not add photographic detail. For a real high-resolution photograph, put a suitable image at `.build/release-qa-source.jpg` before running and keep its provenance and usage terms locally. The script does not download images. Corpus reuse requires matching recipe and content hashes.

## Performance and failure checks

Run these after building:

```sh
bash scripts/benchmark.sh
python3 scripts/measure-launch.py
python3 scripts/check-full-disk.py
```

- The Release benchmark writes `.build/benchmark.json`: five full-resolution iterations per fixture/mode, median, nearest-rank p95, savings, applicable quality checks, and test-host RSS. Its corpus currently covers PNG, JPEG, and WebP; it does not benchmark HEIC, AVIF, GIF, or SVG. Test-host RSS is not the standalone app's idle memory.
- Launch measurement records initial-in-session and warm launches through `onAppear`, before confirmed first display, plus idle RSS. An initial-in-session launch is not a cold-cache launch.
- The full-disk check uses a disposable 16 MiB HFS+ image to exercise actual `ENOSPC`, source integrity, and temporary-file cleanup. It does not fill the host disk.

For a real batch, open the Release app first, then run the monitor before adding files:

```sh
python3 scripts/monitor-resources.py --app dist/Resim.app \
  --seconds 300 --interval 0.2 --output-prefix .build/final-qa-resources
```

The monitor selects the exact executable inside that bundle and fails clearly if it is absent or not running. Use `--pid` to select one process if multiple instances match. It never launches an app, silently switches to another copy, or includes unrelated helpers. It stops with a failed report if the selected app exits during sampling.

The JSONL records a UTC timestamp, PID, parent PID, executable, and RSS for the app and its current descendants. The summary includes the initial baseline, last sample and timestamp, maximum sampled app/aggregate RSS, and separate Oxipng, Gifsicle, gifdiff, and SVG-helper measurements. JPEG, WebP, HEIC, and AVIF execute inside the app, so their memory is included in app RSS. A helper with zero observed samples was not observed; that does not prove it never ran. Short-lived processes and peaks between samples can be missed, and shared pages can be counted by more than one process. These are sampled resident-set sizes, not maximum allocations or a hard memory-budget guarantee. Reports stay under local `.build/` and must be reviewed before sharing.

Small synthetic fixtures are useful for regression checks. Their timings and savings do not predict every real photograph, large image, or animation. Report the measurement method and machine class alongside performance numbers.

### Memory comparisons

After building codecs and generating the seven-format corpus, run:

```sh
python3 scripts/memory-qa.py --output .build/memory-qa-after
```

Use a new output directory for every run. The script compiles the production queue and codecs as an optimized headless probe, uses the existing corpus in native-picker order, and samples that process plus its descendants. It never changes originals or app preferences. `--format avif` (or another extension) isolates one format; `--mode lossless` selects the other mode. `--source-root` can build a saved source snapshot against the same bundled codec libraries. Run comparisons sequentially on the same machine, without concurrent builds or other codec workloads. Compare result hashes and time as well as peak RSS.

The probe disables App Nap for its run without preventing system sleep. It also queries its own lifetime peak physical footprint with `TASK_VM_INFO`; this includes startup and hash verification, excludes helpers, and is a different metric from sampled aggregate RSS. Compare like metrics using the same harness.

This probe excludes SwiftUI and XCTest; its figures must not be labeled standalone GUI app memory. Repeat the batch in the signed app with the resource monitor for the final app measurement. The queue admits individual jobs with estimates up to 512 MiB, but overlaps jobs only within a 384 MiB estimated working set, balancing batch speed and memory. Larger valid jobs run alone, in ready-queue order. Blocking codecs run on two fixed OS threads. Each completed worker releases image buffers and drains its autorelease pool before handing its reservation back; large jobs also request release of unused allocator pages. These measures reduce overlap and retention; neither estimate is a hard RSS cap.

The native SSIM implementation avoids importing duplicate full-frame ARGB pictures. To verify identical scores and acceptance against the previous libwebp picture API:

```sh
clang -O2 -Ivendor/build/include scripts/check-ssim.c -Lvendor/build/lib \
  -ljpeg -lwebpmux -lwebpdemux -lwebp -lsharpyuv -lz -lm -o .build/check-ssim
.build/check-ssim
```

This deterministic check includes all five scores, alpha rejection, small/odd sizes and samples around the 30 dB boundary. Full-resolution codec and metadata checks remain in the test suite.

## Manual app checks

Use generated or redistribution-safe images. Do not add personal photos, locations, or device metadata to the test corpus or public reports.

1. Add disposable copies of each supported format through the system picker and by dragging from Finder, including a Unicode filename. Confirm that processing starts, default replacement keeps the original name and path, and No Reduction leaves bytes unchanged.
2. Exercise Automatic and Lossless, metadata removal, replacement, copies beside originals, and a custom output folder. Verify that copy modes preserve original bytes and avoid overwriting existing copies. Confirm settings persist and affect newly admitted work. HEIC and SVG with metadata removal enabled must explain their exclusion.
3. Check Optimized, No Reduction, Unsupported, Error, and Cancelled rows. One invalid file must not prevent valid files from completing. Retry a recoverable error and reveal original/result files in Finder.
4. Use multiple inputs with identical basenames. Existing files must remain intact, and outputs must receive unique names. No Reduction must not create a copy.
5. Process a larger batch while selecting and scrolling. Press `Esc`; queued and active jobs must cancel without publishing cancelled candidates. Completed changes must remain.
6. Close and quit during work. Continue must keep the queue running; cancel and close must wait for cleanup and exit without orphaned helpers.
7. Inspect transparency, color, orientation, fine detail, and animation timing/loops against the originals. Visual inspection complements the strict sample/coefficient tests.
8. Check light/dark appearance, keyboard access, accessibility labels, Reduce Motion, and Reduce Transparency. Automated accessibility-tree inspection does not replace a VoiceOver session.

## Release checks and limits

Follow [DISTRIBUTION.md](DISTRIBUTION.md) for signing, notarization, package integrity, and a fresh browser-download/Finder installation check. Verify bundled third-party notices and Gifsicle's corresponding source archive/build recipe.

Run on Apple Silicon and Intel hardware, including macOS 14. A Universal 2 build confirms that both slices exist; a host test run confirms only the environment where it ran. Keep unexecuted environments explicitly pending in release records.

Review logs, JSON, screenshots, metadata, and generated manifests before publishing. Remove personal paths, signing identities, credentials, machine identifiers, and unrelated user content. Local `.build/`, `dist/`, and historical QA reports should stay outside source control.


## Compression profile comparisons

Build codecs first, then generate an optimized, local comparison:

```sh
python3 scripts/compare-profiles.py --output .build/profile-comparison
```

Open `.build/profile-comparison/index.html`. It includes a before/after divider,
profile switching, fit/100%/200% views, original/result downloads, encoded byte
counts, savings and per-image timings. PNG previews are independently decoded by
Image I/O at full resolution with orientation applied. Preview sizes are never
reported as compressed file sizes. 100% means one image pixel per CSS pixel;
Retina display scaling still applies. The viewer needs no network connection.

The default inputs combine the redistributable IJG photograph at its native
resolution, existing WebP/AVIF fixtures, and original 1200×800 artwork with small
text, fine lines and a gradient encoded as JPEG, PNG, HEIC, WebP and AVIF.
The tool also makes WebP/AVIF versions of the IJG photograph using the existing
QA encoder; these are separately encoded sources, not cross-format conversions
performed by the production optimizer. These are calibration
examples, not a representative photographic benchmark. IJG provenance and license
are in `ResimTests/Fixtures/README.md` and `IJG-README.txt`. The demo removes
Image I/O-generated Photoshop APP13 metadata from its default JPEG copies
without modifying coefficients, to exercise recompression. Custom `--inputs`
files are never normalized; unknown markers still disable recompression.

To evaluate real local images without modifying them:

```sh
python3 scripts/compare-profiles.py --inputs /path/to/images --output .build/profile-comparison-photos
```

Use a new output directory each time. Supported inputs are static JPG, PNG, WebP,
AVIF and HEIC; app safety limits and unsupported-input exclusions still apply.
The tool saves immutable source copies, all three results, full-resolution previews
and `results.json` (hashes, sizes, times and JPEG/WebP SSIM). No files are uploaded.
Review results at their intended display size, then inspect text, faces, foliage,
edges, gradients and transparency at 100%/200%. Compare each profile against the
same original, never a previously compressed result. Review at least several real
photographs and screenshots before declaring the Web threshold visually calibrated.

`CompressionProfileTests` covers preference migration/round trips, the Web default,
quality and alpha rejection, decreasing sizes across stronger profiles on a fixed
corpus, exact lossless overrides, and source preservation. Historical 30 dB
regressions explicitly exercise Conservative. Queue tests check captured profiles
and persistence. Release QA and replacement-mode checks use the new Web default.

Maximum JPEG also has an intermediate-quality regression and a late-cancellation
check that observes callback counts instead of relying on wall-clock timing.
The bounded adaptive search can be checked under arbitrary/nonmonotonic outcomes:

```sh
clang -O1 -g -fsanitize=address,undefined -Ivendor/build/include \
  scripts/check-jpeg-search.c -Lvendor/build/lib \
  -ljpeg -lwebpmux -lwebpdemux -lwebp -lsharpyuv -lz -lm \
  -o .build/check-jpeg-search
.build/check-jpeg-search
```

For paired Release-optimized processor measurements against a frozen C source:

```sh
python3 scripts/benchmark-jpeg-maximum.py --inputs /path/to/jpeg-corpus \
  --baseline-source /path/to/ResimCodecs-before.c \
  --output .build/jpeg-maximum-paired --repetitions 5
```

Both variants use the same current Swift code, resources and native libraries;
only the codec C source differs. The harness alternates execution order and
checks full-resolution RGB quality, ICC, orientation, dimensions and source
integrity. It also compares Lossless, Conservative and Web output hashes on the
original corpus. It excludes application startup and is not a GUI batch timing.
Run it sequentially, without another benchmark or build in progress.
