#!/usr/bin/env python3
"""Build a local, reproducible visual comparison using Resim's production codecs."""
import argparse
import json
import pathlib
import platform
import plistlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def build(output):
    app = output / "ProfileComparison.app"
    executable = app / "Contents/MacOS/ProfileComparison"
    executable.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "ProfileComparison", "CFBundleIdentifier": "com.resim.qa.profiles",
        "CFBundlePackageType": "APPL",
    }))
    shutil.copytree(ROOT / "Resim/Resources/Codecs", app / "Contents/Resources/Codecs")
    objects = []
    for source in sorted((ROOT / "Resim/Native").glob("*.c")):
        obj = output / (source.stem + ".o")
        subprocess.run(["xcrun", "clang", "-Os", "-mmacosx-version-min=14.0", "-I",
                        str(ROOT / "vendor/build/include"), "-c", str(source), "-o", str(obj)], check=True)
        objects.append(str(obj))
    sources = [str(p) for folder in ("Models", "Optimizers") for p in sorted((ROOT / "Resim" / folder).glob("*.swift"))]
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "6", "-target",
                    platform.machine() + "-apple-macosx14.0", "-import-objc-header",
                    str(ROOT / "Resim/Native/Resim-Bridging-Header.h"), "-I", str(ROOT / "vendor/build/include"),
                    *sources, str(ROOT / "scripts/compare-profiles.swift"), *objects, "-L", str(ROOT / "vendor/build/lib"),
                    *["-l" + name for name in ("jpeg", "webpmux", "webpdemux", "webp", "sharpyuv", "avif", "aom", "c++", "z")],
                    "-o", str(executable)], check=True)
    helper = executable.parent / "encode-rgba"
    subprocess.run(["xcrun", "clang", "-Os", "-I", str(ROOT / "vendor/build/include"),
                    str(ROOT / "scripts/qa-encode-rgba.c"), "-L", str(ROOT / "vendor/build/lib"),
                    "-lwebp", "-lsharpyuv", "-lavif", "-laom", "-lc++", "-o", str(helper)], check=True)
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True, help="New directory for copies, previews and report")
    parser.add_argument("--inputs", type=pathlib.Path, help="Optional directory of local static JPG/PNG/WebP/AVIF/HEIC images")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    executable = build(output)
    inputs = args.inputs.resolve() if args.inputs else output / "inputs"
    subprocess.run([str(executable), str(inputs), str(output), str(ROOT / "ResimTests/Fixtures")], check=True)
    shutil.copyfile(ROOT / "ResimTests/Fixtures/IJG-README.txt", output / "IJG-README.txt")
    report = json.loads((output / "results.json").read_text())
    # Inline JSON works over file://; no server, external fonts, scripts or uploads.
    template = (ROOT / "scripts/profile-comparison.html").read_text()
    data = json.dumps(report, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    (output / "index.html").write_text(template.replace("/* REPORT */", data))
    print(output / "index.html")


if __name__ == "__main__":
    main()
