#!/bin/bash
# Finder layout is written directly; packaging needs no GUI or Apple Events access.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 2 ]] || { echo 'Usage: create-dmg.sh Resim.app output.dmg' >&2; exit 1; }
tools="$PWD/.build/dmg-tools"
requirements="$PWD/scripts/dmg-requirements.txt"
if [[ ! -x "$tools/bin/python" ]]; then python3 -m venv "$tools"; fi
if ! cmp -s "$requirements" "$tools/installed-requirements.txt"; then
  "$tools/bin/python" -m pip install --disable-pip-version-check -r "$requirements"
  cp "$requirements" "$tools/installed-requirements.txt"
fi
swift scripts/generate-dmg-background.swift \
  resources/dmg/sunset-landscape.webp .build/dmg-background.tiff
"$tools/bin/python" scripts/build-dmg.py "$1" "$2"
"$tools/bin/python" scripts/verify-dmg-layout.py "$2"
