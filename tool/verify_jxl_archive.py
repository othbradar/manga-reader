#!/usr/bin/env python3
"""Read-only archive verification against the official djxl reference decoder."""
import argparse
import ctypes
import hashlib
from pathlib import Path
import subprocess
import tempfile
import time
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("library", type=Path)
parser.add_argument("archive", type=Path)
args = parser.parse_args()
native = ctypes.CDLL(str(args.library.resolve()))
convert = native.reader_jxl_convert
convert.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t]
convert.restype = ctypes.c_int
before = hashlib.file_digest(args.archive.open("rb"), "sha256").hexdigest()
started = time.monotonic()
count = 0
with tempfile.TemporaryDirectory(prefix="reader-jxl-verify-") as temp:
    root = Path(temp)
    with zipfile.ZipFile(args.archive) as archive:
        for entry in archive.infolist():
            if entry.is_dir() or not entry.filename.lower().endswith(".jxl"):
                continue
            source, decoded, reference = root / "page.jxl", root / "page.jpg", root / "reference.jpg"
            source.write_bytes(archive.read(entry))
            error = ctypes.create_string_buffer(512)
            result = convert(str(source).encode(), str(decoded).encode(), error, len(error))
            if result != 1:
                raise RuntimeError(f"{entry.filename}: expected reversible JPEG; result={result}, error={error.value!r}")
            subprocess.run(["djxl", str(source), str(reference), "--quiet"], check=True)
            if decoded.read_bytes() != reference.read_bytes():
                raise RuntimeError(f"JPEG bytes differ: {entry.filename}")
            count += 1
after = hashlib.file_digest(args.archive.open("rb"), "sha256").hexdigest()
assert before == after, "Source archive unexpectedly changed"
print(f"Verified {count} JXL pages: native JPEG output is byte-identical to djxl")
print(f"Archive unchanged: SHA256 {before}")
print(f"Elapsed: {time.monotonic() - started:.2f}s")
