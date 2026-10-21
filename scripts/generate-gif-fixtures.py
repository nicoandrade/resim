#!/usr/bin/env python3
"""Deterministic, locally authored GIF fixtures; no third-party image libraries.

Use a clear code before every sample. This deliberately poor, valid GIF LZW
stream gives the real optimizer work to do without coupling fixtures to it.
"""
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "ResimTests/Fixtures"


def u16(value):
    return struct.pack("<H", value)


def blocks(payload):
    return b"".join(bytes([len(payload[i:i + 255])]) + payload[i:i + 255]
                    for i in range(0, len(payload), 255)) + b"\0"


def extension(label, payload):
    return bytes([0x21, label]) + blocks(payload)


def application(identifier, payload):
    assert len(identifier) == 11
    return bytes([0x21, 0xFF, 11]) + identifier + blocks(payload)


PALETTE = bytes([0, 0, 0, 250, 110, 70, 70, 170, 230, 255, 220, 130])


def frame(width, height, pixels, *, delay=7, disposal=1, transparent=False):
    assert len(pixels) == width * height
    codes = [code for sample in pixels for code in (4, sample)] + [5]
    packed, accumulator, available = bytearray(), 0, 0
    for code in codes:
        accumulator |= code << available
        available += 3
        while available >= 8:
            packed.append(accumulator & 255)
            accumulator >>= 8
            available -= 8
    if available:
        packed.append(accumulator & 255)
    graphic_control = bytes([0x21, 0xF9, 4, (disposal << 2) | int(transparent)])
    graphic_control += u16(delay) + b"\0\0"
    descriptor = b"," + u16(0) * 2 + u16(width) + u16(height) + b"\0"
    return graphic_control + descriptor + b"\x02" + blocks(bytes(packed))


def gif(width, height, frames, *, loop=None, metadata=False):
    result = b"GIF89a" + u16(width) + u16(height) + bytes([0xF1, 0, 0]) + PALETTE
    if loop is not None:
        result += application(b"NETSCAPE2.0", b"\x01" + u16(loop))
    if metadata:
        result += extension(0xFE, b"Author: local fixture; private comment. " * 12)
        result += extension(0xCE, b"Private image name")
        result += application(b"RESIMTEST01", b"Opaque application bytes: \x00\xFF\x80; preserve exactly")
        result += application(b"ICCRGBG1012", (OUT / "sRGB.icc").read_bytes())
        # A valid Adobe XMP payload ends with the prescribed 258-byte magic trailer.
        xmp = b'<x:xmpmeta xmlns:x="adobe:ns:meta/">Local GIF fixture</x:xmpmeta>'
        result += application(b"XMP DataXMP", xmp + b"\x01" + bytes(range(255, -1, -1)) + b"\0")
    return result + b"".join(frames) + b";"


def main():
    width, height = 128, 96
    static = [(x // 16 + y // 16) % 4 for y in range(height) for x in range(width)]
    (OUT / "gif-static.gif").write_bytes(gif(width, height, [frame(width, height, static)], metadata=True))

    width, height = 64, 48
    frames = []
    previous = None
    for index, (delay, disposal) in enumerate([(0, 1), (1, 2), (2, 3), (7, 1), (20, 1), (7, 1)]):
        def painted(x, y):
            if index == 0:
                return 4 <= x < 60 and 4 <= y < 44
            if index == 1:
                return 12 <= x < 40 and 12 <= y < 36
            if index == 2:
                return 4 <= x < 28 and 8 <= y < 40
            if index == 3:
                return 36 <= x < 60 and 4 <= y < 24
            return 16 <= x < 48 and 16 <= y < 44

        # Sparse overlays make both background/previous disposal affect pixels;
        # comparing standalone rectangles cannot validate this animation.
        pixels = [1 + ((x // 8 + y // 8 + index) % 3) if painted(x, y) else 0
                  for y in range(height) for x in range(width)]
        if index == 5:
            pixels = previous  # An identical frame still has a meaningful delay.
        previous = pixels
        frames.append(frame(width, height, pixels, delay=delay, disposal=disposal, transparent=True))
    (OUT / "gif-animated.gif").write_bytes(gif(width, height, frames, loop=3, metadata=True))
    (OUT / "gif-loop-infinite.gif").write_bytes(gif(width, height, frames[:2], loop=0))
    (OUT / "gif-no-loop.gif").write_bytes(gif(width, height, frames[:2]))

    # Both the logical canvas and frame rectangles must be admitted safely.
    oversized = bytearray(gif(1, 1, [frame(1, 1, [1])]))
    oversized[6:10] = u16(65535) * 2
    (OUT / "gif-oversized.gif").write_bytes(oversized)
    many_frames = gif(1, 1, [frame(1, 1, [1])] * 1001)
    (OUT / "gif-too-many-frames.gif").write_bytes(many_frames)
    # Each rectangle is under 40 MP but their accumulated decode work is not.
    cumulative = gif(4000, 4000, [frame(1, 1, [1])] * 3)
    descriptor = b"," + u16(0) * 2 + u16(1) * 2 + b"\0"
    cumulative = cumulative.replace(descriptor, b"," + u16(0) * 2 + u16(4000) * 2 + b"\0")
    (OUT / "gif-cumulative-pixels.gif").write_bytes(cumulative)
    print("Generated GIF fixtures:")
    for path in sorted(OUT.glob("gif-*.gif")):
        print(f"  {path.name}: {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
