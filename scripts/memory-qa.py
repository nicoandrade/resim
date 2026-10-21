#!/usr/bin/env python3
"""Compare fixed inputs with a headless production queue, including helper RSS."""
import argparse
import importlib.util
import json
import pathlib
import platform
import plistlib
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent


def build_probe(source_root, output):
    app = output / "MemoryProbe.app"
    executable = app / "Contents/MacOS/MemoryProbe"
    executable.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "MemoryProbe", "CFBundleIdentifier": "com.resim.qa.memory",
        "CFBundleName": "MemoryProbe", "CFBundlePackageType": "APPL",
    }))
    shutil.copytree(ROOT / "Resim/Resources/Codecs", app / "Contents/Resources/Codecs")
    objects = []
    for source in sorted((source_root / "Resim/Native").glob("*.c")):
        obj = output / (source.stem + ".o")
        subprocess.run(["xcrun", "clang", "-Os", "-mmacosx-version-min=14.0",
                        "-I", str(ROOT / "vendor/build/include"), "-c", str(source), "-o", str(obj)], check=True)
        objects.append(str(obj))
    sources = [str(p) for folder in ("Models", "Optimizers")
               for p in sorted((source_root / "Resim" / folder).glob("*.swift"))]
    sources += [str(source_root / "Resim/Services" / name) for name in ("QueueCoordinator.swift", "SafeFiles.swift")]
    pool_source = source_root / "Resim/Services/BlockingCodecPool.swift"
    if pool_source.exists():
        sources.append(str(pool_source))
    sources.append(str(ROOT / "scripts/memory-probe.swift"))
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "6",
                    "-target", platform.machine() + "-apple-macosx14.0",
                    "-import-objc-header", str(source_root / "Resim/Native/Resim-Bridging-Header.h"),
                    "-I", str(ROOT / "vendor/build/include"), *sources, *objects,
                    "-L", str(ROOT / "vendor/build/lib"),
                    *["-l" + name for name in ("jpeg", "webpmux", "webpdemux", "webp", "sharpyuv", "avif", "aom", "c++", "z")],
                    "-o", str(executable)], check=True)
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=pathlib.Path, default=ROOT / ".build/release-qa-corpus")
    parser.add_argument("--output", type=pathlib.Path, required=True, help="new local evidence directory")
    parser.add_argument("--source-root", type=pathlib.Path, default=ROOT)
    parser.add_argument("--probe", type=pathlib.Path, help="reuse an already compiled probe bundle")
    parser.add_argument("--mode", choices=("automatic", "lossless"), default="automatic")
    parser.add_argument("--format", choices=("all", "png", "jpg", "webp", "heic", "avif", "gif", "svg"), default="all")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    app = args.probe.resolve() if args.probe else build_probe(args.source_root.resolve(), output)
    executable = app / "Contents/MacOS/MemoryProbe"
    spec = importlib.util.spec_from_file_location("resim_resources", ROOT / "scripts/monitor-resources.py")
    monitor = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = monitor
    spec.loader.exec_module(monitor)
    rows = []
    started = time.monotonic()
    with (output / "process.log").open("w") as log, (output / "samples.jsonl").open("w") as samples:
        child = subprocess.Popen([str(executable), str(args.inputs.resolve()), str(output / "results"),
                                  args.mode, args.format], stdout=log, stderr=subprocess.STDOUT)
        try:
            while child.poll() is None:
                processes = monitor.read_processes()
                process = next((p for p in processes if p.pid == child.pid), None)
                if process:
                    row = monitor.sample(processes, process, app, time.monotonic() - started)
                    rows.append(row)
                    samples.write(json.dumps(row, sort_keys=True) + "\n")
                    samples.flush()
                if time.monotonic() - started > 1300:
                    raise TimeoutError("Memory QA exceeded 1300 seconds")
                time.sleep(0.2)
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=30)
    if child.returncode or not rows:
        raise RuntimeError(f"Probe failed: exit {child.returncode}; see {output / 'process.log'}")
    result = json.loads((output / "results/result.json").read_text())
    footprint = result.get("physical_footprint", {})
    summary = {"method": "Headless production queue and codecs, fixed existing corpus, fresh process. No SwiftUI or XCTest. Samples include app and its descendants; shared pages may be counted twice and short peaks/helpers may be missed.",
               "probe": str(app), "exit_code": child.returncode, "samples": len(rows),
               "peak_app_mib": max(x["app_rss_bytes"] for x in rows) / 2**20,
               "peak_app_and_descendants_mib": max(x["aggregate_rss_bytes"] for x in rows) / 2**20,
               "last_app_mib": rows[-1]["app_rss_bytes"] / 2**20,
               "own_process_lifetime_peak_footprint_mib": (footprint["lifetime_peak_bytes"] / 2**20
                                                            if footprint.get("available") else None),
               "elapsed_s": result["elapsed_s"], "mode": args.mode, "filter": args.format,
               "total": result["total"], "source_hashes_unchanged": result["source_hashes_unchanged"]}
    (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
