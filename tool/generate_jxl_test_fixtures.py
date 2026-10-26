#!/usr/bin/env python3
"""Generate copyright-free test pictures; requires macOS sips and cjxl.

Not part of the app/build. Native runtime uses the bundled decoder, not cjxl.
"""
from pathlib import Path
import struct
import subprocess
import zlib
import random
import tempfile

root = Path(__file__).resolve().parents[1] / "test/fixtures/jxl"
root.mkdir(parents=True, exist_ok=True)
width, height = 32, 48


def chunk(name, data):
    return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))


pixels = bytearray()
for y in range(height):
    pixels.append(0)
    for x in range(width):
        pixels.extend(((x * 7) % 256, (y * 5) % 256, (x * 3 + y * 4) % 256, 128 if x < 8 else 255))
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
(root / "original.png").write_bytes(png)
subprocess.run(["sips", "-s", "format", "jpeg", str(root / "original.png"), "--out", str(root / "original.jpg")], check=True)
for source, output, options in [
    ("original.jpg", "reversible.jxl", ["--lossless_jpeg=1"]),
    ("original.png", "rgba.jxl", ["--distance=0"]),
]:
    subprocess.run(["cjxl", str(root / source), str(root / output), "--effort=3", "--quiet", *options], check=True)

# Force multiple JPEG output buffers, including an indivisible >64 KiB scan.
random_source = random.Random(420)
pixels = b"".join(b"\0" + random_source.randbytes(384 * 3) for _ in range(384))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 384, 384, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
with tempfile.TemporaryDirectory(prefix="reader-jxl-fixture-") as temp:
    source = Path(temp) / "noise.png"
    source.write_bytes(png)
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "95", str(source), "--out", str(root / "large-scan.jpg")], check=True)
subprocess.run(["cjxl", str(root / "large-scan.jpg"), str(root / "large-scan.jxl"), "--lossless_jpeg=1", "--effort=3", "--quiet"], check=True)
