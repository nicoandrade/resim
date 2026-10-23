#!/usr/bin/env python3
"""Local comparison of ImageOptim.app and Resim; operates exclusively on copies.

Requires the existing built Resim codec dependencies, Pillow, and numpy.
Example: python3 scripts/compare-imageoptim.py --imageoptim /path/ImageOptim.app \
    --inputs /path/corpus --output .build/imageoptim-comparison --repetitions 3
Stages can be run separately or resumed. Use a new output folder for a new corpus.
"""
import argparse
import ctypes
import datetime
import hashlib
import json
import pathlib
import platform
import plistlib
import shutil
import statistics
import subprocess
import time
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIBS = ["jpeg", "webpmux", "webpdemux", "webp", "sharpyuv", "avif", "aom", "c++", "z"]
IO_CASES = {
    "imageoptim-default": {},
    "imageoptim-preserve": {"JpegTranStripAll": False, "PngOutRemoveChunks": False},
    "imageoptim-lossy80": {"LossyEnabled": True},
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def code_sha(path):
    # Ad hoc signing changes signature bytes; compare executable instructions.
    text = subprocess.check_output(["otool", "-arch", platform.machine(), "-s", "__TEXT", "__text", str(path)])
    return hashlib.sha256(b"\n".join(text.splitlines()[2:])).hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False) + "\n")


def build(out, swift_source=None, codec_source=None, c_optimization="-O2"):
    app = out / "ResimComparison.app"
    exe = app / "Contents/MacOS/ResimComparison"
    exe.parent.mkdir(parents=True, exist_ok=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": exe.name, "CFBundleIdentifier": "com.resim.qa.comparison",
        "CFBundlePackageType": "APPL",
    }))
    shutil.copytree(ROOT / "Resim/Resources/Codecs", app / "Contents/Resources/Codecs", dirs_exist_ok=True)
    objects = []
    for src in [*sorted((ROOT / "Resim/Native").glob("*.c")), ROOT / "scripts/compare-imageoptim-metrics.c"]:
        obj = out / (src.stem + ".o")
        source = codec_source if codec_source and src.name == "ResimCodecs.c" else src
        subprocess.run(["xcrun", "clang", c_optimization, "-mmacosx-version-min=14.0", "-I",
                        str(ROOT / "vendor/build/include"), "-I", str(ROOT / "Resim/Native"),
                        "-c", str(source), "-o", str(obj)], check=True)
        objects.append(str(obj))
    linking = ["-L", str(ROOT / "vendor/build/lib"), *["-l" + lib for lib in LIBS]]
    sources = [str(p) for folder in ("Models", "Optimizers") for p in sorted((ROOT / "Resim" / folder).glob("*.swift"))]
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "6", "-target",
                    platform.machine() + "-apple-macosx14.0", "-import-objc-header",
                    str(ROOT / "Resim/Native/Resim-Bridging-Header.h"), "-I", str(ROOT / "vendor/build/include"),
                    *sources, str(swift_source or ROOT / "scripts/compare-imageoptim.swift"), *objects, *linking,
                    "-o", str(exe)], check=True)
    subprocess.run(["xcrun", "clang", "-dynamiclib", *objects, *linking, "-o", str(out / "metrics.dylib")], check=True)
    return exe


def imageoptim(original_app, inputs, out, repetitions):
    results_path = out / "imageoptim-results.json"
    rows = json.loads(results_path.read_text()) if results_path.exists() else []
    done = {(r["case"], r["name"]) for r in rows}
    original_info = plistlib.loads((original_app / "Contents/Info.plist").read_bytes())
    defaults = plistlib.loads((original_app / "Contents/Resources/defaults.plist").read_bytes())
    configs = {}
    for label, overrides in IO_CASES.items():
        app = out / (label + ".app")
        if not app.exists():
            shutil.copytree(original_app, app, symlinks=True)
        # Separate bundle identity prevents modifying the user's app preferences.
        info = dict(original_info)
        info["CFBundleIdentifier"] = "com.resim.qa." + label + "." + hashlib.sha256(str(out).encode()).hexdigest()[:10]
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        config = {**defaults, **overrides, "SUEnableAutomaticChecks": False, "SUHasLaunchedBefore": True}
        configs[label] = config
        (app / "Contents/Resources/defaults.plist").write_bytes(plistlib.dumps(config))
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, capture_output=True)
        exe = app / "Contents/MacOS/ImageOptim"
        assert code_sha(exe) == code_sha(original_app / "Contents/MacOS/ImageOptim")
        for source in inputs:
            if (label, source.name) in done:
                continue
            folder = out / label
            folder.mkdir(exist_ok=True)
            target = folder / source.name
            timings, hashes, sizes = [], [], []
            row = {"case": label, "name": source.name, "file": str(target.relative_to(out))}
            for trial in range(repetitions):
                shutil.copyfile(source, target)
                log = folder / (source.name + f".trial{trial}.log")
                started = time.perf_counter()
                try:
                    with log.open("w") as stream:
                        completed = subprocess.run([str(exe), str(target)], stdout=stream, stderr=stream, timeout=180)
                    timings.append((time.perf_counter() - started) * 1000)
                    if completed.returncode:
                        row["error"] = f"exit {completed.returncode}"
                        break
                    hashes.append(sha(target)); sizes.append(target.stat().st_size)
                except subprocess.TimeoutExpired:
                    row["error"] = "timeout after 180 seconds"
                    break
            if not row.get("error"):
                row.update(bytes=sizes[-1], samples_ms=timings, deterministic=len(set(hashes)) == 1,
                           sha256=hashes[-1], sizes=sizes)
            rows.append(row)
            write_json(results_path, rows)
            print(label, source.name, row.get("bytes", row.get("error")), flush=True)
    write_json(out / "imageoptim-configs.json", configs)


def png16_pixels(path):
    """Decode native RGB16 fixture samples, retaining all 16 bits (no Pillow reduction)."""
    data = path.read_bytes(); offset = 8; compressed = bytearray(); header = None
    while offset < len(data):
        size = int.from_bytes(data[offset:offset+4], "big")
        kind = data[offset+4:offset+8]; payload = data[offset+8:offset+8+size]
        if kind == b"IHDR": header = payload
        if kind == b"IDAT": compressed.extend(payload)
        offset += size + 12
    w = int.from_bytes(header[:4], "big"); h = int.from_bytes(header[4:8], "big")
    if header[8:] != bytes([16, 2, 0, 0, 0]): return None
    raw = zlib.decompress(compressed); stride = w * 6; previous = bytearray(stride); result = bytearray()
    for y in range(h):
        start = y * (stride+1); filt = raw[start]; line = bytearray(raw[start+1:start+1+stride])
        for x in range(stride):
            a = line[x-6] if x >= 6 else 0; b = previous[x]; c = previous[x-6] if x >= 6 else 0
            p = a+b-c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            predict = [0, a, b, (a+b)//2, a if pa <= pb and pa <= pc else b if pb <= pc else c][filt]
            line[x] = (line[x]+predict) & 255
        result.extend(line); previous = line
    return bytes(result)


def analyze(inputs, out, app):
    from PIL import Image, ImageOps, __version__ as pillow_version
    import numpy as np
    lib = ctypes.CDLL(str(out / "metrics.dylib"))
    ptr = ctypes.c_void_p
    lib.qa_rgba_metrics.argtypes = [ptr, ptr, ctypes.c_int, ctypes.c_int, ptr]
    for name in ["rc_jpeg_coefficients_equal", "rc_jpeg_ssim_rgb"]:
        getattr(lib, name).argtypes = [ptr, ctypes.c_size_t, ptr, ctypes.c_size_t] + ([ptr] if "ssim" in name else [])
    rows = json.loads((out / "resim-results.json").read_text()) + json.loads((out / "imageoptim-results.json").read_text())
    refinement_path = out / "jpeg-refinement-results.json"
    refinement = json.loads(refinement_path.read_text()) if refinement_path.exists() else None
    if refinement:
        rows.extend(refinement["rows"])
    search_path = out / "jpeg-search-results.json"
    search = json.loads(search_path.read_text()) if search_path.exists() else []
    for item in search:
        for threshold, label in [(20, "calibration-web20"), (16, "calibration-max16")]:
            if item["auto_safe"]:
                file = f"jpeg-search/floor{threshold}-" + item["name"]
                chosen = item["best"][str(threshold)]
            else:
                file = "resim-lossless/" + item["name"]
                chosen = {"quality": "lossless", "bytes": (out / file).stat().st_size}
            rows.append(dict(name=item["name"], case=label, bytes=chosen["bytes"], file=file,
                             kind="offline-calibration", encoder_quality=chosen["quality"], floor_db=threshold))
    sources = {p.name: p for p in inputs}
    samples = []
    previews = out / "previews"; previews.mkdir(exist_ok=True)
    originals = out / "originals"; originals.mkdir(exist_ok=True)
    for source in inputs:
        shutil.copyfile(source, originals / source.name)
        sample = dict(name=source.name, bytes=source.stat().st_size, sha256=sha(source),
                      format=source.suffix[1:], file="originals/" + source.name)
        if source.suffix != ".svg":
            with Image.open(source) as image:
                sample.update(width=image.width, height=image.height, frames=getattr(image, "n_frames", 1))
                ImageOps.exif_transpose(image).convert("RGBA").save(previews / (source.name + ".png"))
            sample["preview"] = "previews/" + source.name + ".png"
        if source.suffix in (".svg", ".gif"):
            sample["preview"] = sample["file"]
        samples.append(sample)
    for row in rows:
        if row.get("error"): continue
        source = sources[row["name"]]; candidate = out / row["file"]
        row["saved_percent"] = 100 * (1 - row["bytes"] / source.stat().st_size)
        if row.get("samples_ms"):
            row["median_ms"] = statistics.median(row["samples_ms"])
            row["max_ms"] = max(row["samples_ms"])
        if source.suffix == ".svg":
            row["validation"] = "SVG rendering not measured"
            row["preview"] = row["file"]
            continue
        a = Image.open(source); b = Image.open(candidate)
        row["dimensions_equal"] = a.size == b.size
        if not row["dimensions_equal"]:
            row["validation"] = "Dimensions changed; pixel metrics skipped"
            a.close(); b.close()
            continue
        row["icc_equal"] = a.info.get("icc_profile") == b.info.get("icc_profile")
        row["exif_equal"] = a.info.get("exif") == b.info.get("exif")
        row["orientation_equal"] = a.getexif().get(274, 1) == b.getexif().get(274, 1)
        row["frames_equal"] = getattr(a, "n_frames", 1) == getattr(b, "n_frames", 1)
        row["loop_equal"] = a.info.get("loop") == b.info.get("loop")
        row["comments_equal"] = a.info.get("comment") == b.info.get("comment")
        aa = np.asarray(a.convert("RGBA")); bb = np.asarray(b.convert("RGBA"))
        row["decoded_rgba8_equal"] = bool(np.array_equal(aa, bb))
        row["alpha_equal"] = bool(np.array_equal(aa[:,:,3], bb[:,:,3]))
        visible = (aa[:,:,3] > 0) | (bb[:,:,3] > 0)
        row["visible_pixels_equal"] = bool(np.array_equal(aa[visible], bb[visible]))
        if source.name == "rgb16.png":
            row["native_rgb16_equal"] = png16_pixels(source) == png16_pixels(candidate) and png16_pixels(candidate) is not None
        if source.suffix == ".gif":
            frames_same = row["frames_equal"]; durations_same = frames_same
            for i in range(min(getattr(a, "n_frames", 1), getattr(b, "n_frames", 1))):
                a.seek(i); b.seek(i)
                frames_same &= bool(np.array_equal(np.asarray(a.convert("RGBA")), np.asarray(b.convert("RGBA"))))
                durations_same &= a.info.get("duration") == b.info.get("duration")
            row["all_frames_equal"] = bool(frames_same); row["durations_equal"] = bool(durations_same)
            diff = subprocess.run([str(ROOT / "Resim/Resources/Codecs/gifdiff"), "--brief", "--ignore-redundancy",
                                   "--", str(source), str(candidate)], capture_output=True)
            row["visual_timeline_equal"] = diff.returncode == 0 and not diff.stdout and not diff.stderr
        else:
            scores = (ctypes.c_float * 5)()
            if source.suffix in (".jpg", ".jpeg"):
                ab = source.read_bytes(); bc = candidate.read_bytes()
                row["identical_dct"] = lib.rc_jpeg_coefficients_equal(ab, len(ab), bc, len(bc)) == 1
                lib.rc_jpeg_ssim_rgb(ab, len(ab), bc, len(bc), scores)
            else:
                lib.qa_rgba_metrics(aa.ctypes.data, bb.ctypes.data, a.width, a.height, scores)
            row["ssim_db_bgr"] = list(scores)[:3]; row["min_rgb_ssim_db"] = min(scores[:3])
        preview = previews / (row["case"] + "-" + source.name + ".png")
        b.seek(0); ImageOps.exif_transpose(b).convert("RGBA").save(preview)
        row["preview"] = str(preview.relative_to(out))
        if source.suffix == ".gif": row["preview"] = row["file"]
        a.close(); b.close()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    report = dict(samples=samples, rows=rows, imageoptim_version=info["CFBundleShortVersionString"],
                  measured_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  pillow_version=pillow_version,
                  imageoptim_executable_sha256=sha(app / "Contents/MacOS/ImageOptim"),
                  imageoptim_code_sha256=code_sha(app / "Contents/MacOS/ImageOptim"),
                  jpeg_search=search,
                  jpeg_refinement=refinement,
                  effort=json.loads((out / "effort-results.json").read_text()) if (out / "effort-results.json").exists() else [],
                  resim_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                  os=platform.platform(), architecture=platform.machine(),
                  method="Same immutable inputs. Resim: optimized production NativeImageProcessor, sequential repeated calls; timing excludes app launch and publication. ImageOptim: original app executable and engines, copied bundle with isolated defaults; synchronous fresh process per image/trial; timing includes app launch and save. Timing categories are not directly equivalent. JPEG SSIM: production MozJPEG decode + libwebp per RGB channel. PNG: Pillow RGBA8 + libwebp; RGB16 additionally decoded at native depth. GIF: every rendered frame, raw durations and loop. SVG: size only, visual equivalence not independently verified. Metadata differences are reported separately. No uploads or production config changes.")
    write_json(out / "results.json", report)
    template = (ROOT / "scripts/imageoptim-comparison.html").read_text()
    (out / "index.html").write_text(template.replace("/* REPORT */", json.dumps(report, ensure_ascii=False).replace("<", "\\u003c")))
    print(out / "index.html")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--imageoptim", type=pathlib.Path, required=True)
    parser.add_argument("--inputs", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--stage", choices=["all", "build", "resim", "imageoptim", "analyze"], default="all")
    args = parser.parse_args()
    if args.repetitions < 1: parser.error("repetitions must be positive")
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    inputs = sorted(p for p in args.inputs.resolve().iterdir() if p.suffix.lower() in [".png", ".jpg", ".jpeg", ".gif", ".svg"])
    before = {p.name: sha(p) for p in inputs}
    manifest = out / "inputs-sha256.json"
    if manifest.exists():
        assert json.loads(manifest.read_text()) == before, "Corpus differs from this run; use a new output folder"
    else:
        write_json(manifest, before)
    if args.stage in ["all", "build"]: build(out)
    if args.stage in ["all", "resim"]:
        subprocess.run([str(out / "ResimComparison.app/Contents/MacOS/ResimComparison"), str(args.inputs.resolve()), str(out), str(args.repetitions)], check=True)
    if args.stage in ["all", "imageoptim"]: imageoptim(args.imageoptim.resolve(), inputs, out, args.repetitions)
    if args.stage in ["all", "analyze"]: analyze(inputs, out, args.imageoptim.resolve())
    assert {p.name: sha(p) for p in inputs} == before, "Inputs changed"


if __name__ == "__main__":
    main()
