# 03 Profile the parser in isolation

> Inference gateway capstone · Week 1

## The problem

A whole-model benchmark can hide a CPU hotspot in the gateway. Isolate the code under suspicion before drawing a performance conclusion.

## The mental model

~~~text
identical framed workload → eager tree parse, copy, serialize → CPU stacks
                         └→ typed decode and reuse valid JSON → CPU stacks
~~~

## The pattern

Build two release variants from the same locked crate. Replay the identical bytes through framing and semantic validation. Sample CPU stacks while profiling, and run a separate unprofiled timing comparison. Compare stack widths within each flame graph and retain the sample totals. [pprof-rs](https://github.com/tikv/pprof-rs) · [How to read flame graphs](https://www.brendangregg.com/flamegraphs.html)

## Build it

### Replay and profile a fixed stream

Fragment a fixed 16-output stream into 137-byte chunks and use the real decoder and completion checker.

Create or update `src/bin/sse-profile.rs`.

<!-- file: src/bin/sse-profile.rs -->
~~~rust
use std::{env, fs::File, hint::black_box, time::Instant};

use serde_json::json;
use switchyard_inference::{
    protocol::{Completion, Delivered},
    sse::Decoder,
};

const OUTPUTS: u32 = 16;

fn input() -> Vec<u8> {
    let mut wire = String::new();
    for n in 0..OUTPUTS {
        let value = json!({
            "id":"chatcmpl-profile", "created":1_700_000_000, "model":"switchyard",
            "object":"chat.completion.chunk", "system_fingerprint":"fixture",
            "choices":[{"index":0,"delta":{"content":format!(" sample-{n:02}")},"finish_reason":null}],
            "usage":null,
        });
        wire.push_str(&format!("data: {value}\r\n\r\n"));
    }
    wire.push_str(
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":16}}\n\n\
         data: [DONE]\n\n",
    );
    wire.into_bytes()
}

fn decode(wire: &[u8]) {
    let mut decoder = Decoder::default();
    let mut chat = Completion::new(20, OUTPUTS);
    let mut complete = false;
    let mut items = 0;
    for mut bytes in wire.chunks(137) {
        while let Some(frame) = decoder.next(&mut bytes).unwrap() {
            match chat.accept(frame).unwrap() {
                Delivered::Item { json, .. } => {
                    black_box(json);
                    items += 1;
                }
                Delivered::Done => complete = true,
            }
        }
    }
    assert!(complete && items == OUTPUTS + 1);
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args().skip(1);
    let count: u32 = args.next().ok_or("missing replay count")?.parse()?;
    let destination = args.next().ok_or("missing flame graph destination")?;
    if count == 0 || args.next().is_some() {
        return Err("usage: sse-profile COUNT OUTPUT.svg (or - for a timer only)".into());
    }
    let wire = input();
    for _ in 0..100 {
        decode(&wire);
    }
    let profiler = if destination == "-" {
        None
    } else {
        Some(
            pprof::ProfilerGuardBuilder::default()
                .frequency(499)
                .blocklist(&["libc", "libgcc", "pthread", "vdso"])
                .build()?,
        )
    };
    let start = Instant::now();
    for _ in 0..count {
        decode(black_box(&wire));
    }
    let elapsed = start.elapsed();
    let samples = if let Some(guard) = profiler {
        let report = guard.report().build()?;
        let samples = report.data.values().sum::<isize>();
        if samples <= 0 {
            return Err("profiler collected no stacks".into());
        }
        report.flamegraph(File::create(destination)?)?;
        samples
    } else {
        0
    };
    println!(
        "{}",
        json!({
            "variant": if cfg!(feature = "eager-json") { "eager" } else { "typed" },
            "streams": count, "updates_per_stream": OUTPUTS, "chunk_bytes": 137,
            "elapsed_ms": elapsed.as_secs_f64()*1000.0, "cpu_samples": samples,
        })
    );
    Ok(())
}
~~~

### Produce comparable release binaries

Build and preserve both executables and both profile drivers.

Create or update `bench/build.sh`.

<!-- file: bench/build.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
work=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$work"
out=$(python3 -c 'import sys; from pathlib import Path; print(Path(sys.argv[1]).resolve())' "$1")
target=$(python3 -c 'import sys; from pathlib import Path; print(Path(sys.argv[1]).resolve())' "${CARGO_TARGET_DIR:-target}")
mkdir -p "$out"
for variant in eager typed; do
  features=profiling
  if [[ "$variant" == eager ]]; then
    features+=,eager-json
  fi
  cargo build --locked --release --features "$features" --bins
  cp "$target/release/switchyard-inference" "$out/gateway-$variant"
  cp "$target/release/sse-profile" "$out/profile-$variant"
done
~~~

## Check it

~~~bash
cargo check --locked --features profiling --bin sse-profile
~~~

<!-- run: cargo check --locked --features profiling --bin sse-profile -->

Read the [before and after profiles](../evidence/README.md) for the sampled CPU paths. The reference also timed two unprofiled blocks per parser variant.
