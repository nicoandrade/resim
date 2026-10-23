#!/usr/bin/env python3
"""Measure PNG/GIF encoder effort on the same comparison corpus (after benchmarks)."""
import argparse
import importlib.util
import json
import pathlib
import statistics
import subprocess
import time
import zlib
from PIL import Image
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("comparison", ROOT / "scripts/compare-imageoptim.py")
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


def chunks(path):
    data = path.read_bytes(); offset = 8; result = []
    while offset < len(data):
        size = int.from_bytes(data[offset:offset+4], "big")
        result.append((data[offset+4:offset+8], data[offset+8:offset+8+size]))
        offset += size + 12
    return result


def equal_png(a, b):
    original, candidate = chunks(a), chunks(b)
    ignored = {b"IDAT", b"IEND", b"iCCP", b"tRNS"}
    meta = lambda xs: [(kind, payload) for kind, payload in xs if kind not in ignored]
    profiles = lambda xs: [zlib.decompress(p[p.index(0)+2:]) for kind, p in xs if kind == b"iCCP"]
    metadata = meta(original) == meta(candidate) and profiles(original) == profiles(candidate)
    aa = Image.open(a).convert("RGBA"); bb = Image.open(b).convert("RGBA")
    rgba = bool(np.array_equal(np.asarray(aa), np.asarray(bb)))
    native = True
    if a.name == "rgb16.png":
        native = comparison.png16_pixels(a) == comparison.png16_pixels(b) and comparison.png16_pixels(b) is not None
    return dict(decoded_equal=rgba, metadata_and_representation_equal=metadata,
                native_depth_equal=native, compatible_with_current_contract=rgba and metadata and native)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--comparison", type=pathlib.Path, required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    args = parser.parse_args(); base = args.comparison.resolve()
    inputs = base / "inputs"; out = base / "effort"; out.mkdir(exist_ok=True)
    rows = []
    for source in sorted(inputs.glob("*.png")):
        for label, options in [("o2-nx", ["-o", "2", "--nx"]), ("o4-nx", ["-o", "4", "--nx"]),
                               ("o6-nx", ["-o", "6", "--nx"]), ("o4-transforms", ["-o", "4"])]:
            target = out / (label + "-" + source.name)
            timings = []
            for _ in range(args.repetitions):
                target.unlink(missing_ok=True)
                start = time.perf_counter()
                subprocess.run([str(ROOT / "Resim/Resources/Codecs/oxipng"), *options, "--threads", "1",
                                "--out", str(target), "--", str(source)], check=True, capture_output=True)
                timings.append((time.perf_counter() - start) * 1000)
            rows.append(dict(name=source.name, case=label, bytes=target.stat().st_size,
                             samples_ms=timings, median_ms=statistics.median(timings), **equal_png(source, target)))
            print(source.name, label, target.stat().st_size, flush=True)
    for source in sorted(inputs.glob("*.gif")):
        for level in [2, 3]:
            target = out / (f"gif-o{level}-" + source.name); timings = []
            for _ in range(args.repetitions):
                start = time.perf_counter()
                subprocess.run([str(ROOT / "Resim/Resources/Codecs/gifsicle"), f"--optimize={level}",
                                "--optimize=keep-empty", "--no-ignore-errors", "--conserve-memory",
                                "--output", str(target), "--", str(source)], check=True, capture_output=True)
                timings.append((time.perf_counter() - start) * 1000)
            diff = subprocess.run([str(ROOT / "Resim/Resources/Codecs/gifdiff"), "--brief", "--", str(source), str(target)], capture_output=True)
            a, b = Image.open(source), Image.open(target)
            timing_equal = a.n_frames == b.n_frames and a.info.get("loop") == b.info.get("loop")
            for i in range(min(a.n_frames, b.n_frames)):
                a.seek(i); b.seek(i); timing_equal &= a.info.get("duration") == b.info.get("duration")
            rows.append(dict(name=source.name, case=f"gif-o{level}", bytes=target.stat().st_size,
                             samples_ms=timings, median_ms=statistics.median(timings),
                             rendered_equal=diff.returncode == 0 and not diff.stdout and not diff.stderr,
                             timing_equal=bool(timing_equal)))
            print(source.name, level, target.stat().st_size, flush=True)
    comparison.write_json(base / "effort-results.json", rows)


if __name__ == "__main__":
    main()
