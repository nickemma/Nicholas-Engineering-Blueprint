"""Compare both FFI programs with known fixture checksums."""

import subprocess
import sys
import tempfile
from pathlib import Path

FIXTURES = {
    "empty": (b"", "cbf29ce484222325"),
    "embedded-zero": (b"A\x00B", "fb029919a1274bf2"),
    "all-bytes": (bytes(range(256)) * 3, "4f33c513c2e95c25"),
}


def main():
    rust, c = map(Path, sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix="bytes-") as directory:
        for name, (data, expected) in FIXTURES.items():
            path = Path(directory) / name
            path.write_bytes(data)
            a = subprocess.check_output([rust.resolve(), path], text=True).strip()
            b = subprocess.check_output([c.resolve(), path], text=True).strip()
            if a != expected or b != expected:
                print(f"FAIL {name}: Rust calling C={a}, C calling Rust={b}, expected={expected}")
                return 42
            print(f"{name}: both callers produced {expected} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
