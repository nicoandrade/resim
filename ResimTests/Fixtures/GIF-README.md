# GIF fixtures

Generated locally and deterministically by `python3 scripts/generate-gif-fixtures.py`.
The generator implements minimal GIF89a/LZW directly; it uses no optimizer and no
third-party image library. Palette images use deliberately inefficient clear
codes before every sample, so optimization must produce an actual smaller file.

- `gif-static.gif`: 128×96, one opaque palette frame.
- `gif-animated.gif`: 64×48, six transparent frames; disposals 1/2/3;
  raw delays 0, 1, 2, 7, 20, 7 hundredths; finite loop count 3; final frame
  intentionally identical to its predecessor.
- `gif-loop-infinite.gif` / `gif-no-loop.gif`: two frames, respectively infinite
  looping and no loop extension. Absence and a zero loop count are distinct.
- `gif-opaque-delta.gif`: a locally authored 32×32, two-frame opaque animation,
  made with the existing generator's `gif` and `frame` functions. Frame one is
  entirely palette index 0; frame two replaces its left half with index 2. Both
  use disposal 1 and a seven-centisecond delay. Gifsicle 1.98 reduces 1,612 to
  112 bytes by introducing transparency in the second frame's delta. `gifdiff`
  and independent Image I/O renders confirm identical composited pixels. The
  queue test covers both modes so this valid representation cannot fail the
  generic alpha-property check.
- `GIFQueueTests` also generates a 1600×1200 three-frame animation in memory,
  using genuine inefficient LZW clear codes rather than artificial padding. A
  280×280 opaque rectangle moves over a black background; delays are 7, 13, and
  25 centiseconds, with loop count 3. Both modes must publish a smaller copy,
  retain the source SHA-256, and match all full-resolution Image I/O RGBA frames,
  timing, and loop metadata. The multi-megabyte input is not stored in the repo.
- Metadata: GIF comments and image-name extension; actual sRGB ICC profile from
  the existing fixture; Adobe XMP extension; opaque `RESIMTEST01` application
  bytes (including NUL and non-ASCII data). Stripping removes only comments and
  image names; color/application payloads and animation controls remain intact.
- `gif-oversized.gif`, `gif-cumulative-pixels.gif`, `gif-too-many-frames.gif`:
  deliberately malformed or excessive admission fixtures, never decoder inputs.

Integration tests independently render every frame with Apple Image I/O and
compare exact canonical RGBA bytes, plus raw delays, loop count and extension
bytes. They exercise the bundled real optimizer in both modes, not a mock.
