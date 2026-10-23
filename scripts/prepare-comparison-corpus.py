#!/usr/bin/env python3
"""Prepare public Kodak photographs plus local safety/UI fixtures for comparison.

Needs Pillow. Downloads six unmodified PNGs to a new local directory, then creates
JPEG quality 95/85 derivatives and authored text/gradient artwork. Never reads
personal photographs. Kodak source/usage context: https://r0k.us/graphics/kodak/
"""
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import shutil
import urllib.request
from PIL import Image, ImageDraw, ImageFont, __version__ as pillow_version

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = [
    "rgba.png", "rgb16.png", "palette.png", "fine-lines.png", "landscape.png",
    "photo-ijg.jpg", "photo-quality100.jpg", "icc-444.jpg", "grayscale.jpg",
    "progressive.jpg", "orientation-gps.jpg", "already-compressed.jpg",
    "gif-static.gif", "gif-animated.gif", "gif-opaque-delta.gif",
    "svg-icon.svg", "svg-references.svg",
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=False)
    numbers = [1, 3, 5, 8, 15, 23]

    def download(number):
        path = folder / f"kodim{number:02}.png"
        urllib.request.urlretrieve(f"https://r0k.us/graphics/kodak/kodak/{path.name}", path)
        return path

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        photos = list(pool.map(download, numbers))
    for photo in photos:
        image = Image.open(photo).convert("RGB")
        for quality in [95, 85]:
            image.save(folder / (photo.stem + f"-q{quality}.jpg"), quality=quality,
                       subsampling=2, optimize=False, progressive=False)
    for name in FIXTURES:
        shutil.copyfile(ROOT / "ResimTests/Fixtures" / name, folder / name)
    shutil.copyfile(ROOT / "ResimTests/Fixtures/IJG-README.txt", folder / "IJG-README.txt")
    image = Image.new("RGB", (1440, 900), "#f5f5f1")
    draw = ImageDraw.Draw(image)
    for y in range(250):
        t = y / 249
        draw.line((35, y+35, 1405, y+35), fill=(int(20+180*t), int(50+80*t), int(150-100*t)))
    for index, size in enumerate([14, 18, 24, 36, 50]):
        draw.text((45, 320+index*80), "Resim / Texto, detalle y compresion - Aa Bb 0123456789",
                  font=ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", size), fill="#102045")
    for x in range(45, 1390, 4):
        draw.line((x, 755, x, 865), fill="#ef1260" if x % 8 else "#125ff0")
    image.save(folder / "ui-text-gradient.png")
    image.save(folder / "ui-text-gradient-q95.jpg", quality=95, subsampling=0)
    manifest = {"pillow_version": pillow_version, "kodak_source": "https://r0k.us/graphics/kodak/",
                "files": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted(folder.iterdir()) if p.suffix.lower() in [".png", ".jpg", ".gif", ".svg"]}}
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(folder)


if __name__ == "__main__":
    main()
