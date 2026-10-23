#!/usr/bin/env python3
"""Paired optimized production-processor benchmark against a frozen C baseline.

Uses identical Swift, resources, native dependencies and Release optimization
flags for both executables. NativeImageProcessor timing excludes process startup
and diagnostic measurements. Each maximum operation includes its normal output
validation. Run without other builds/benchmarks in parallel.
"""
import argparse
import importlib.util
import json
import pathlib
import random
import statistics
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("comparison", ROOT / "scripts/compare-imageoptim.py")
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=pathlib.Path, required=True)
    parser.add_argument("--baseline-source", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--stage", choices=["all", "build", "run"], default="all")
    args = parser.parse_args()
    if args.repetitions < 3: parser.error("Use at least three repetitions")
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    apps = {}
    for variant in ["baseline", "candidate"]:
        folder = out / variant; folder.mkdir(exist_ok=True)
        if args.stage in ["all", "build"]:
            comparison.build(folder, swift_source=ROOT / "scripts/benchmark-jpeg-maximum.swift",
                             codec_source=args.baseline_source.resolve() if variant == "baseline" else None,
                             c_optimization="-Os")
        apps[variant] = folder / "ResimComparison.app/Contents/MacOS/ResimComparison"
    fingerprints = {
        "baseline_source": comparison.sha(args.baseline_source.resolve()),
        "candidate_source": comparison.sha(ROOT / "Resim/Native/ResimCodecs.c"),
        "harness_source": comparison.sha(ROOT / "scripts/benchmark-jpeg-maximum.swift"),
        "executables": {variant: comparison.sha(path) for variant, path in apps.items()},
    }
    build_record = out / "build-inputs.json"
    if args.stage in ["all", "build"]:
        comparison.write_json(build_record, fingerprints)
    if args.stage == "build": return
    if not build_record.exists() or json.loads(build_record.read_text()) != fingerprints:
        parser.error("Build inputs changed or are missing; run --stage build before --stage run")
    inputs = sorted(args.inputs.resolve().glob("*.jpg"))
    if not inputs: parser.error("No JPEG inputs")
    hashes = {p.name: comparison.sha(p) for p in inputs}
    provenance = {"inputs_sha256": hashes, "baseline_source_sha256": comparison.sha(args.baseline_source),
                  "candidate_source_sha256": comparison.sha(ROOT / "Resim/Native/ResimCodecs.c"),
                  "method": "Paired sequential NativeImageProcessor, C -Os / Swift -O, alternating order per file/repetition, one warm-up per executable, five repetitions by default. Startup, independent SSIM/metadata checks and benchmark result copy excluded from timer; normal processor validation included."}
    comparison.write_json(out / "provenance.json", provenance)
    measurements = []

    def run(variant, source, profile="maximum"):
        work = out / variant / "outputs" / profile / source.name
        subprocess.run([str(apps[variant]), str(source), str(work), profile], check=True)
        result = json.loads((work / "measurement.json").read_text())
        for flag in ["dimensions_equal", "format_equal", "icc_equal", "orientation_equal", "source_unchanged"]:
            assert result[flag], (variant, source, flag)
        floor = {"maximum": 16, "web": 20, "conservative": 30, "lossless": 99}[profile]
        assert result["min_rgb_ssim_db"] >= floor, result
        assert result["bytes"] <= source.stat().st_size
        return {**result, "variant": variant}

    for variant in apps: run(variant, inputs[0])
    for repeat in range(args.repetitions):
        order = list(inputs); random.Random(20261023 + repeat).shuffle(order)
        for i, source in enumerate(order):
            variants = ["baseline", "candidate"] if (repeat+i) % 2 == 0 else ["candidate", "baseline"]
            for variant in variants: measurements.append({**run(variant, source), "repetition": repeat})
            comparison.write_json(out / "measurements.json", measurements)
            print(repeat + 1, source.name, flush=True)
    rows = []
    for source in inputs:
        row = dict(name=source.name, original_bytes=source.stat().st_size)
        for variant in apps:
            selected = [x for x in measurements if x["name"] == source.name and x["variant"] == variant]
            assert len({x["sha256"] for x in selected}) == 1
            row[variant] = {**selected[0], "samples_ms": [x["milliseconds"] for x in selected],
                            "median_ms": statistics.median(x["milliseconds"] for x in selected)}
        row["size_change_percent"] = 100 * (row["candidate"]["bytes"] / row["baseline"]["bytes"] - 1)
        row["time_change_percent"] = 100 * (row["candidate"]["median_ms"] / row["baseline"]["median_ms"] - 1)
        rows.append(row)
    controls = []
    for source in inputs:
        if source.name.startswith(("holdout-", "large-")): continue
        for profile in ["lossless", "conservative", "web"]:
            a, b = run("baseline", source, profile), run("candidate", source, profile)
            assert a["sha256"] == b["sha256"], (source, profile)
            controls.append(dict(name=source.name, profile=profile, identical=True))
    totals = {}
    for group, selected in {
        "original_corpus": [x for x in rows if not x["name"].startswith(("holdout-", "large-"))],
        "holdout": [x for x in rows if x["name"].startswith("holdout-")],
        "large": [x for x in rows if x["name"].startswith("large-")],
        "all": rows,
    }.items():
        if not selected: continue
        total = {variant: {"bytes": sum(x[variant]["bytes"] for x in selected),
                           "sum_median_ms": sum(x[variant]["median_ms"] for x in selected)} for variant in apps}
        total["size_change_percent"] = 100 * (total["candidate"]["bytes"] / total["baseline"]["bytes"] - 1)
        total["time_change_percent"] = 100 * (total["candidate"]["sum_median_ms"] / total["baseline"]["sum_median_ms"] - 1)
        total["files"] = len(selected); totals[group] = total
    assert {p.name: comparison.sha(p) for p in inputs} == hashes
    comparison.write_json(out / "results.json", dict(rows=rows, totals=totals, controls=controls))
    print(json.dumps(totals, indent=2))


if __name__ == "__main__":
    main()
