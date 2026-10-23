#!/usr/bin/env python3
"""Offline dense JPEG search: distinguish sparse candidates from quality limits.

Every candidate is encoded from its original using the production MozJPEG
encoder and metadata admission policy. This does not change shipping settings.
Timings are deliberately not benchmarked here. Needs existing codec libraries.
"""
import argparse
import ctypes
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


class Buffer(ctypes.Structure):
    _fields_ = [("bytes", ctypes.c_void_p), ("size", ctypes.c_size_t)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--comparison", type=pathlib.Path, required=True)
    args = parser.parse_args(); base = args.comparison.resolve()
    out = base / "jpeg-search"; out.mkdir(exist_ok=True)
    dylib = out / "probe.dylib"
    subprocess.run(["xcrun", "clang", "-O2", "-dynamiclib", "-I", str(ROOT / "vendor/build/include"),
                    str(ROOT / "scripts/compare-jpeg-search.c"), "-L", str(ROOT / "vendor/build/lib"),
                    "-ljpeg", "-lwebpmux", "-lwebpdemux", "-lwebp", "-lsharpyuv", "-lz", "-o", str(dylib)], check=True)
    lib = ctypes.CDLL(str(dylib)); ptr = ctypes.c_void_p
    lib.qa_jpeg_auto_safe.argtypes = [ptr, ctypes.c_size_t]
    lib.qa_jpeg_encode.argtypes = [ptr, ctypes.c_size_t, ctypes.c_int, ctypes.POINTER(Buffer)]
    lib.rc_buffer_free.argtypes = [ctypes.POINTER(Buffer)]
    lib.rc_jpeg_ssim_rgb.argtypes = [ptr, ctypes.c_size_t, ptr, ctypes.c_size_t, ptr]
    results = []
    for source in sorted((base / "inputs").glob("*.jpg")):
        original = source.read_bytes()
        row = dict(name=source.name, auto_safe=bool(lib.qa_jpeg_auto_safe(original, len(original))), trials=[])
        if not row["auto_safe"]:
            results.append(row); continue
        best = {threshold: (base / "resim-lossless" / source.name).read_bytes() for threshold in [20, 18, 16, 14, 12]}
        choices = {threshold: dict(quality="lossless", min_rgb_ssim_db=99.0, bytes=len(data)) for threshold, data in best.items()}
        for quality in range(98, 57, -1):
            buffer = Buffer()
            try:
                if not lib.qa_jpeg_encode(original, len(original), quality, ctypes.byref(buffer)):
                    raise RuntimeError(f"Could not encode {source.name} at {quality}")
                candidate = ctypes.string_at(buffer.bytes, buffer.size)
            finally:
                lib.rc_buffer_free(ctypes.byref(buffer))
            scores = (ctypes.c_float * 5)()
            lib.rc_jpeg_ssim_rgb(original, len(original), candidate, len(candidate), scores)
            score = min(scores[:3])
            trial = dict(quality=quality, bytes=len(candidate), min_rgb_ssim_db=score)
            row["trials"].append(trial)
            for threshold in best:
                if score >= threshold and len(candidate) < len(best[threshold]):
                    best[threshold] = candidate; choices[threshold] = trial
        row["best"] = choices
        for threshold, data in best.items(): (out / (f"floor{threshold}-" + source.name)).write_bytes(data)
        results.append(row)
        (base / "jpeg-search-results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(source.name, choices, flush=True)
    (base / "jpeg-search-results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
