#!/usr/bin/env python3
"""Build and test only Git-eligible source in a new, isolated directory.

Works before the first commit. Does not stage files, create commits, or use a
remote. Local logs and a source manifest remain under .build/clean-source.*.
"""

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


def digest(root, relative):
    path = root / relative
    if path.is_symlink():
        return {"symlink": os.readlink(path)}
    return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            # Compare the content Git would publish, including .gitattributes
            # normalization. Upstream notices may use CRLF before a checkout.
            "git_blob": subprocess.check_output(
                ["git", "hash-object", "--path=" + str(relative), str(relative)], cwd=root,
                stderr=subprocess.DEVNULL,
            ).decode().strip(),
            "executable": bool(path.stat().st_mode & 0o111)}


def main():
    if sys.platform != "darwin":
        sys.exit("Clean builds require macOS and full Xcode.")
    required = ("git", "xcodebuild", "xcrun", "cmake", "nasm", "cargo", "rustup", "node", "npm")
    missing = [tool for tool in required if not shutil.which(tool)]
    if missing:
        sys.exit("Missing build tools: " + ", ".join(missing) + ". See README.md.")
    subprocess.run([sys.executable, "scripts/check-public-repo.py"], cwd=ROOT, check=True)
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT,
    ).split(b"\0")
    files = sorted({pathlib.Path(os.fsdecode(name)) for name in names if name})
    manifest = {str(path): digest(ROOT, path) for path in files}
    (ROOT / ".build").mkdir(exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix="clean-source.", dir=ROOT / ".build"))
    source = work / "source"
    source.mkdir()
    print(f"Clean source verification: {work.relative_to(ROOT)}", flush=True)
    for path in files:
        target = source / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / path, target, follow_symlinks=False)
    # The publication scanner needs Git metadata, but no snapshot commit is needed.
    subprocess.run(["git", "init", "--quiet", "--initial-branch=main", str(source)], check=True)
    (work / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    report = {"source_files": len(files), "kind": "uncommitted-source-snapshot",
              "checks": [], "passed": False}
    env = os.environ.copy()
    # Never inherit a target directory or compiler cache containing built codecs.
    for key in ("CARGO_TARGET_DIR", "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER"):
        env.pop(key, None)
    commands = [
        ("publication-before", [sys.executable, "scripts/check-public-repo.py"]),
        ("build", ["bash", "scripts/build.sh"]),
        ("smoke", ["bash", "scripts/smoke.sh"]),
        ("tests", ["bash", "scripts/test.sh"]),
        ("publication-after", [sys.executable, "scripts/check-public-repo.py"]),
    ]
    try:
        for label, command in commands:
            print(f"Running {label}; log: {label}.log", flush=True)
            began = time.monotonic()
            with (work / f"{label}.log").open("w") as log:
                result = subprocess.run(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT)
            report["checks"].append({"name": label, "exit_code": result.returncode,
                                     "seconds": round(time.monotonic() - began, 2)})
            if result.returncode:
                sys.exit(f"{label} failed. Inspect {work.relative_to(ROOT)}/{label}.log.")
        changed = []
        normalized = []
        for name, expected in manifest.items():
            path = source / name
            if not path.exists() and not path.is_symlink():
                changed.append(name)
                continue
            actual = digest(source, pathlib.Path(name))
            if actual == expected:
                continue
            if {k: v for k, v in actual.items() if k != "sha256"} == {k: v for k, v in expected.items() if k != "sha256"}:
                normalized.append(name)
            else:
                changed.append(name)
        after = subprocess.check_output(
            ["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=source,
        ).split(b"\0")
        added = sorted({os.fsdecode(name) for name in after if name} - manifest.keys())
        report.update(changed_source=changed, added_source=added, normalized_source=normalized)
        if changed or added:
            sys.exit("The clean build changed public source files. Inspect verification.json.")
        report["passed"] = True
        print("Clean-source Release build, smoke launch, tests and publication checks passed.", flush=True)
    finally:
        (work / "verification.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
