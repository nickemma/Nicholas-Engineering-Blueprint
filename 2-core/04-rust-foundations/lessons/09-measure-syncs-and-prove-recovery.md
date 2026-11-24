# 09 Measure syncs and prove recovery

> About 5 hours · Work in the same `klog` package throughout the module.

## The problem

The application can acknowledge a record after synchronizing it. If many records arrive at once, synchronization may dominate the total time. Measure it separately and keep the recovery checks repeatable.

## The mental model

Both experiments encode and write exactly the same records. One issues 250 syncs and the other issues 10. The grouped experiment would acknowledge a group only after its final sync. The benchmark uses elapsed monotonic time.

## The pattern

Change one setting, alternate the run order, and preserve the individual timings. Prove the CLI's correctness with process and byte-level faults. Keep correctness checks independent of any latency threshold.

## Build it

### Step 1. Write the two benchmark cases

Use fresh files so a previous trial cannot change the starting state. Both cases include header creation, writing, and sync. Creating the file happens before the clock starts, and the benchmark measures file syncs. The production append path also synchronizes the directory before acknowledging the first record through a handle.

Create `src/bin/log-bench.rs`.

<!-- file: src/bin/log-bench.rs -->
~~~rust
use std::fs::OpenOptions;
use std::io::{self, Write};
use std::path::Path;
use std::time::{Duration, Instant};

use klog::record::encode_header;

const RECORDS: usize = 250;

fn measure(path: &Path, batch: usize) -> io::Result<Duration> {
    let payload = [b'x'; 256];
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    let start = Instant::now();
    for number in 1..=RECORDS {
        let header = encode_header(&payload).expect("fixed payload fits");
        file.write_all(&header)?;
        file.write_all(&payload)?;
        if number.is_multiple_of(batch) || number == RECORDS {
            file.sync_all()?;
        }
    }
    Ok(start.elapsed())
}

fn millis(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

fn main() -> io::Result<()> {
    let directory = std::env::args_os().nth(1).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: log-bench EMPTY_DIRECTORY",
        )
    })?;
    let directory = Path::new(&directory);
    let mut each = Vec::new();
    let mut batches = Vec::new();
    println!("{RECORDS} records per run, 256 payload bytes per record");
    for run in 1..=5 {
        let order = if run % 2 == 0 { [25, 1] } else { [1, 25] };
        for batch in order {
            let path = directory.join(format!("run-{run}-batch-{batch}"));
            let elapsed = measure(&path, batch)?;
            println!("run {run}, sync every {batch:2}: {:.3} ms", millis(elapsed));
            match batch {
                1 => each.push(elapsed),
                _ => batches.push(elapsed),
            }
        }
    }
    each.sort_unstable();
    batches.sort_unstable();
    println!("median, sync each: {:.3} ms", millis(each[2]));
    println!("median, groups of 25: {:.3} ms", millis(batches[2]));
    Ok(())
}
~~~

### Step 2. Run five trials per case

Run the benchmark on the filesystem you want to measure. A process working on a memory-backed filesystem can see very different times from a persistent volume.

~~~bash
work=$(mktemp -d)
cargo run --quiet --release --bin log-bench -- "$work"
rm -rf "$work"
~~~

~~~text
filesystem: ext2/ext3
rustc 1.94.1 (e408947bf 2026-03-25)
250 records per run, 256 payload bytes per record
run 1, sync every  1: 774.729 ms
run 1, sync every 25: 32.931 ms
run 2, sync every 25: 33.809 ms
run 2, sync every  1: 811.879 ms
run 3, sync every  1: 910.443 ms
run 3, sync every 25: 41.664 ms
run 4, sync every 25: 47.496 ms
run 4, sync every  1: 997.718 ms
run 5, sync every  1: 1008.073 ms
run 5, sync every 25: 41.646 ms
median, sync each: 910.443 ms
median, groups of 25: 41.646 ms
~~~

### Step 3. Run the module gate

The gate checks the Rust build, then removes bytes at every incomplete cut of a frame, damages complete headers and payloads, checks locking, and kills a writer after it has written a known partial frame. The machine stays powered during the test. The drill exercises recovery after a process crash.

Run the [module gate](../gate/README.md) against your finished checkout.

~~~text
all 18 incomplete cuts preserved the committed prefix
complete header and payload damage was refused without changing any bytes
a competing writer could not append while the file was locked
SIGKILL left a torn append; reopening recovered it and accepted new data
~~~

<!-- run: bash "$BLUEPRINT_ROOT/2-core/04-rust-foundations/gate/run.sh" "$PWD" -->

## Check it

Explain when a grouped writer may tell each caller its record is durable. Remove the payload checksum comparison in a scratch copy and run the gate. Restore the comparison after you see the failure.

## If it goes wrong

If measurements swing between repeats, keep the raw runs and note filesystem activity. If the gate reports changed bytes after checksum failure, locate the branch that called `set_len` before validation finished.
