# 10 Expose the parser to Python

> About 6 hours · Continue the `klog` package.

## The problem

The Python measurement tool can reuse the Rust frame decoder. The boundary needs a clear lifetime for borrowed input and an error a Python caller can handle.

## The mental model

PyO3 exposes a native extension module. The wrapper borrows an input Python bytes object, checks its frame in Rust, and returns a new Python-owned bytes object.

## The pattern

Keep ownership local to each language. Translate structured errors at the boundary and test through a real import.

## Build it

### Step 1. Wrap the same decoder with PyO3

The wrapper uses the Python bytes object as the input buffer. The Rust slice is borrowed for the duration of the call. Constructing a new Python bytes result copies the returned payload into memory owned by Python.

Create `checks/python/Cargo.toml`.

<!-- file: checks/python/Cargo.toml -->
~~~toml
[package]
name = "switchyard-python"
version = "0.1.0"
edition = "2024"

[lib]
name = "switchyard_frames"
crate-type = ["cdylib"]

[dependencies]
klog = { path = "../.." }
pyo3 = { version = "=0.27.2", features = ["extension-module", "abi3-py39"] }
~~~

Create `checks/python/src/lib.rs`.

<!-- file: checks/python/src/lib.rs -->
~~~rust
use klog::frame_cursor::FrameCursor;
use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::PyBytes;

#[pyfunction]
fn decode_one<'py>(py: Python<'py>, input: &Bound<'py, PyBytes>) -> PyResult<Bound<'py, PyBytes>> {
    let mut cursor = FrameCursor::new(input.as_bytes());
    let payload = cursor
        .next_frame()
        .map_err(|error| PyValueError::new_err(error.to_string()))?
        .ok_or_else(|| PyValueError::new_err("incomplete frame"))?;
    if !cursor.remaining().is_empty() {
        return Err(PyValueError::new_err("extra bytes after frame"));
    }
    Ok(PyBytes::new(py, payload))
}

#[pymodule]
fn switchyard_frames(module: &Bound<'_, PyModule>) -> PyResult<()> {
    module.add_function(wrap_pyfunction!(decode_one, module)?)?;
    Ok(())
}
~~~

### Step 2. Load the extension and run its client-side checks

The contract accepts exactly one complete frame. A short frame, invalid checksum, or trailing bytes raises ValueError. The test imports the actual compiled shared library.

Create `checks/python/check.py`.

<!-- file: checks/python/check.py -->
~~~python
import importlib.util
from pathlib import Path
import sys

path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("switchyard_frames", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

frame = bytes.fromhex("03000000 117863d6 389d964c 6a6f62")
if module.decode_one(frame) != b"job":
    raise RuntimeError("valid frame returned the wrong payload")

for data, message in (
    (frame[:-1], "incomplete frame"),
    (frame[:-1] + b"x", "payload checksum mismatch"),
    (frame + b"x", "extra bytes after frame"),
):
    try:
        module.decode_one(data)
    except ValueError as error:
        if message not in str(error):
            raise
    else:
        raise RuntimeError(f"expected ValueError: {message}")
print("PyO3 returned b'job' and rejected three malformed inputs")
~~~

Create `scripts/check-integrations.sh`.

<!-- file: scripts/check-integrations.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail

cargo fmt --check --manifest-path checks/loom/Cargo.toml
cargo test --quiet --manifest-path checks/loom/Cargo.toml
cargo fmt --check --manifest-path checks/tokio/Cargo.toml
cargo test --quiet --manifest-path checks/tokio/Cargo.toml
cargo run --quiet --manifest-path checks/tokio/Cargo.toml
cargo fmt --check --manifest-path checks/python/Cargo.toml
export PYO3_PYTHON
PYO3_PYTHON=$(command -v python3)
cargo build --quiet --manifest-path checks/python/Cargo.toml
target=$(cargo metadata --no-deps --format-version 1 --manifest-path checks/python/Cargo.toml |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')
python3 checks/python/check.py "$target/debug/libswitchyard_frames.so"
~~~

~~~bash
bash scripts/check-integrations.sh
~~~

~~~text
PyO3 returned b'job' and rejected three malformed inputs
~~~

### Step 3. Run the module gate

The gate runs the native build and tests, then the integration and nightly checks when you select the full run. Use the separate tool results to diagnose failures.

Run the [module gate](../gate/README.md) from your finished checkout.

~~~text
native parser, FFI, executor, and ring checks passed
~~~

<!-- run: bash "$BLUEPRINT_ROOT/2-core/05-rust-for-systems/gate/run.sh" "$PWD" -->

## Check it

Explain where the wrapper borrows and where it allocates. Send an invalid header and confirm that the Python caller receives ValueError.

## If it goes wrong

If Python cannot import the library, check the exported module name and the interpreter used to build it. If a framed input is unexpectedly rejected, inspect the little-endian header and check that it contains one complete record.
