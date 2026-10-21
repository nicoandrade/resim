#!/usr/bin/env python3
"""Bundle the exact Cargo.lock dependency licenses used by the pinned Oxipng build."""
import json
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--manifest-path", str(root / "vendor/src/oxipng-9.1.5/Cargo.toml"),
    "--locked", "--format-version", "1"
]))
destination = root / "Resim/Resources/Licenses/Oxipng-dependencies"
destination.mkdir(parents=True, exist_ok=True)
notices = ["# Oxipng 9.1.5 dependency notices", "", "Versions are from the bundled Cargo.lock. License files are reproduced verbatim.", ""]
for package in sorted(metadata["packages"], key=lambda item: (item["name"], item["version"])):
    base = pathlib.Path(package["manifest_path"]).parent
    label = f'{package["name"]}-{package["version"]}'
    notices.append(f'- {label}: {package.get("license") or "see included license"}')
    license_paths = [p for p in base.rglob("*")
                     if p.is_file() and (p.name.lower().startswith(("license", "copying", "copyright", "notice"))
                                        or p.name == "UNLICENSE")
                     and "target" not in p.relative_to(base).parts
                     and p.stat().st_size < 1_000_000]
    if package.get("license_file"):
        license_paths.append(base / package["license_file"])
    for source in set(license_paths):
        if not source.is_file():
            continue
        target = destination / label / source.relative_to(base)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
(root / "Resim/Resources/Licenses/Oxipng-dependencies.md").write_text("\n".join(notices) + "\n")
