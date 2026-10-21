# Test fixtures

Except for the IJG photographs identified below, image samples are generated from locally authored deterministic patterns and fictitious EXIF/GPS data. Do not add personal photographs or real identifying metadata.

## Generated samples

- `rgba.png` and `Fóto Ñ 试.PNG`: gradients, partial transparency, and nonzero RGB under zero alpha. The latter name exercises Unicode handling.
- `rgb16.png`: native 16-bit RGB samples that are not merely expanded 8-bit values.
- `palette.png`: palette transparency; `fine-lines.png`: fine detail.
- `landscape.png` and `landscape.jpg`: a synthetic landscape with deterministic noise.
- `orientation-gps.jpg`: orientation 6 and fictitious GPS, author, and device tags.
- `already-compressed.jpg`: a low-quality JPEG for fallback behavior.
- `exact-alpha.webp`: exact lossless WebP; `lossy.webp`: lossy WebP.
- `animated.png` and `animated.webp`: animated containers for rejection by content.
- `corrupt.png` and `not-image.jpg`: invalid inputs.
- `grayscale.jpg`, `progressive.jpg`, `cmyk.jpg`, `icc-444.jpg`, and `degraded.jpg`: MozJPEG-generated variations of a deterministic pattern. The quality-10 sample exercises quality-gate rejection against a quality-100 reference.
- `accepted-auto.jpg`: a smooth pattern, `RGB = 100 + (x / 3 + y / 3) / 8`, used to exercise accepted automatic recompression. `smooth-auto.jpg` exercises a conservative fallback.

`sRGB.icc` is obtained from the system's `CGColorSpace.sRGB` and tests color-profile preservation. HEIC tests generate their own procedural samples through Image I/O at runtime. AVIF, GIF, and SVG samples have separate [AVIF](AVIF-README.md), [GIF](GIF-README.md), and [SVG](SVG-README.md) documentation.

Regenerate the main corpus after building the codec dependencies:

```sh
bash scripts/generate-fixtures.sh
python3 scripts/generate-gif-fixtures.py
```

The shell script includes AVIF generation. GIF generation is a separate step. Existing fixtures can be used by tests without downloading images or running the generators.

## IJG provenance

`photo-ijg.jpg` is the unmodified `testimages/testorig.jpg` from MozJPEG 4.1.5, originating in the Independent JPEG Group corpus. `photo-quality100.jpg` is generated from its `testorig.ppm`. Preserve the original notices and license in [IJG-README.txt](IJG-README.txt) with these samples.

This software is based in part on the work of the Independent JPEG Group.
