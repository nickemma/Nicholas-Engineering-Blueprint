# 08 Kill a writer during a partition

> Core 07 · About 7 hours · Builds on the preceding lesson

## The problem

Killing a peer after it acknowledged a request tests failover. To test a torn write, the experiment must stop the writer after part of a record enters the file and before the durable acknowledgment.

## The mental model

~~~text
A | B <--> C                  A isolated from both B and C
A writer: writes header → signals barrier → gate sends SIGKILL
B and C: elect, commit, and acknowledge
A restarts isolated → repair → heal links → catch up
~~~

The gate's Unix-socket proxies control which directed peer messages reach the next process. Client requests use a direct socket. Build the Rust writer with the test feature so the gate can arm the next append. The signal comes from the actual append path after writing the header.

## The pattern

Check client outcomes, election history, committed entries, and disk integrity independently. Leave the isolated peer's client API reachable so the gate can detect a mistaken success. A higher-term leader in the connected pair and an isolated old leader can coexist briefly. A correct history has one winner per term and agreement on every applied index.

## Build it

### Step 1. Place a barrier on the write path

Keep the normal `append` as the entry point for regular callers. In the feature build, let a callback run at `write header → /* TODO */ → write payload`.

<details>
<summary>Hint 1</summary>

The hook must see a real partial record.

</details>

<details>
<summary>Hint 2</summary>

Invoke the hook immediately after the header, while the file stays locked and before sync or ACK.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- edit: klog/Cargo.toml -->
~~~toml
edition = "2024"
rust-version = "1.89"
default-run = "klog"
~~~

~~~toml
edition = "2024"
rust-version = "1.89"
default-run = "klog"

[features]
fault-injection = []
~~~

<!-- edit: klog/src/log.rs -->
~~~rust
    }

    pub fn append(&mut self, payload: &[u8]) -> Result<u64, LogError> {
        if self.failed {
            return Err(LogError::WriterFailed);
        }
~~~

~~~rust
    }

    pub fn append(&mut self, payload: &[u8]) -> Result<u64, LogError> {
        self.append_inner(payload, || Ok(()))
    }

    #[cfg(feature = "fault-injection")]
    pub fn append_with_barrier(
        &mut self,
        payload: &[u8],
        after_header: impl FnOnce() -> io::Result<()>,
    ) -> Result<u64, LogError> {
        self.append_inner(payload, after_header)
    }

    fn append_inner(
        &mut self,
        payload: &[u8],
        after_header: impl FnOnce() -> io::Result<()>,
    ) -> Result<u64, LogError> {
        if self.failed {
            return Err(LogError::WriterFailed);
        }
~~~

<!-- edit: klog/src/log.rs -->
~~~rust
        // Refuse further writes through this handle until it is reopened.
        self.failed = true;
        self.file.write_all(&header)?;
        self.file.write_all(payload)?;
        self.file.sync_all()?;
        if !self.parent_synced {
~~~

~~~rust
        // Refuse further writes through this handle until it is reopened.
        self.failed = true;
        self.file.write_all(&header)?;
        after_header()?;
        self.file.write_all(payload)?;
        self.file.sync_all()?;
        if !self.parent_synced {
~~~

<!-- edit: klog/src/bin/metad-wal.rs -->
~~~rust
    out.flush()?;

    while let Some(payload) = read_record(&mut input)? {
        log.append(&payload)?;
        out.write_all(&[1])?;
        out.flush()?;
    }
    Ok(())
}
~~~

~~~rust
    out.flush()?;

    while let Some(payload) = read_record(&mut input)? {
        append(&mut log, &payload)?;
        out.write_all(&[1])?;
        out.flush()?;
    }
    Ok(())
}

#[cfg(not(feature = "fault-injection"))]
fn append(log: &mut Log, payload: &[u8]) -> Result<u64, klog::log::LogError> {
    log.append(payload)
}

#[cfg(feature = "fault-injection")]
fn append(log: &mut Log, payload: &[u8]) -> Result<u64, klog::log::LogError> {
    let Some(path) = std::env::var_os("METAD_GATE_ARM") else {
        return log.append(payload);
    };
    let path = std::path::PathBuf::from(path);
    log.append_with_barrier(payload, || {
        match std::fs::remove_file(&path) {
            Ok(()) => (),
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error),
        }
        // The header is in the file. No payload or ACK exists yet.
        std::fs::write(path.with_extension("ready"), b"header written")?;
        loop {
            std::thread::park();
        }
    })
}
~~~

</details>

### Step 2. Check what the crash left

Watch the barrier marker, check the byte count on disk, and kill the test-created process group. Decide whether a connection loss counts as client success.

<details>
<summary>Hint 1</summary>

The Go node and its Rust child have separate process IDs.

</details>

<details>
<summary>Hint 2</summary>

The gate owns their group. Only HTTP 200 is a successful proposal.

</details>

### Step 3. Heal and compare evidence

Wait for the majority to acknowledge another write, then restart the old peer with its original log. Check the trimmed byte count before reconnecting it. Read both committed values through the client API and compare applied entries by index.

<details>
<summary>Hint 1</summary>

The interrupted command never made it into the committed history.

</details>

<details>
<summary>Hint 2</summary>

Check its key is absent after healing. Run Rust's integrity check on the stopped peer files.

</details>

### Step 4. Let the minority finish locally

The companion scenario allows a full append before the deadline. The gate compiles a disposable Go overlay that sends success after local save. Predict which assertion will fail on that build.

<details>
<summary>Hint 1</summary>

A test that always kills the writer before its ACK would miss this bug.

</details>

<details>
<summary>Hint 2</summary>

The companion sees an HTTP 200 without a quorum and exits with its specific failure status.

</details>

## Check it

~~~bash
cargo clippy --quiet --manifest-path klog/Cargo.toml --all-targets --all-features -- -D warnings && bash "$blueprint/2-core/07-distributed-systems-fundamentals/gate/run.sh" "$PWD"
~~~

<!-- run: cargo clippy --quiet --manifest-path klog/Cargo.toml --all-targets --all-features -- -D warnings && bash "$BLUEPRINT_ROOT/2-core/07-distributed-systems-fundamentals/gate/run.sh" "$PWD" -->

~~~text
isolation: local append completed, but the client timed out without success
SIGKILL: interrupted append left a 12-byte header and no client success
partition: the connected pair elected a higher-term leader and committed a write
heal: trimmed the torn header, preserved the prefix, and agreed on elections and applied entries
client reads: both acknowledged writes survived and the interrupted key is absent
disk: all three peer logs passed the Rust integrity check
corruption: startup refused a complete damaged frame and preserved its bytes
FAIL isolated leader acknowledged after local append
negative control: caught acknowledgment before quorum commit
~~~

The FAIL line is from the deliberately broken binary. The gate exits successfully after it verifies that failure. The machine stays powered throughout the drill.

Full captures are in [08-gate.txt](../evidence/lessons/08-gate.txt).

## If it goes wrong

| Symptom | What to inspect |
|---|---|
| No header marker appears | Build with the fault-injection feature and keep the target peer alive until it reaches the barrier. |
| Recovery reports zero bytes | Check the old leader's disk path and verify that it was killed after the marker. |
| The broken build passes too | Confirm the minority scenario kept the client reachable while blocking both peer directions. |

## Explain it

1. Why are the torn-write run and the completed-local-write run both needed?
2. Which observations show agreement across the restarted peer and its survivors?
