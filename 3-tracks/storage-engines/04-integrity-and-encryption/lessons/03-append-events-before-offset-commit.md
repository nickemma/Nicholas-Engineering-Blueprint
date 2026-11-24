# 03 Append job events before committing offsets

> Integrity and encryption · Week 1 · Builds on lesson 02

## The problem

The group offset records progress independently of the audit log. If the offset advances while the event is still buffered, the next consumer skips a record that never made it to disk.

## The mental model

Kafka record → Go event decoder → bounded record on child stdin → Rust WAL sync → child acknowledgment → Kafka group commit. A process stop between the last two steps leaves a durable record and an offset that still points to it.

## The pattern

Apply durable work before committing the offset. Persist the stable event ID and the partition position so you can distinguish replay from a separate event. Keep an explicit allowlist of audit fields and reuse the shared unit’s event validation and consumer.

## Build it

### Step 1 — Project the event fields

Pick the identifiers, kind, version, and stream position. Decide what should happen to extra input metadata.

<details>
<summary>Hint</summary>

Build a new value from known fields instead of copying the arbitrary incoming JSON.

</details>

### Step 2 — Write the Rust protocol

Read one bounded record, append it with `klog`, and report success after synchronization. Add a dump command for inspection.

<details>
<summary>Hint</summary>

A log reader can verify frames when the writer’s lock is free.

</details>

<details>
<summary>Implementation</summary>

Create `storage/src/bin/audit-writer.rs`.

<!-- file: storage/src/bin/audit-writer.rs -->
~~~rust
use std::{
    io::{self, Read, Write},
    path::Path,
    process::ExitCode,
};

use klog::log::{Log, visit_records};

const MAX_EVENT: u64 = 4096;

fn run() -> io::Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    match args.as_slice() {
        [op, path] if op == "append" => {
            let mut bytes = Vec::new();
            io::stdin().take(MAX_EVENT + 1).read_to_end(&mut bytes)?;
            if bytes.is_empty() || bytes.len() as u64 > MAX_EVENT || bytes.contains(&b'\n') {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "invalid audit event",
                ));
            }
            let mut log = Log::open(Path::new(path)).map_err(io::Error::other)?;
            log.append(&bytes).map_err(io::Error::other)?;
            println!("ok");
        }
        [op, path] if op == "dump" => {
            let mut output = io::stdout().lock();
            visit_records(Path::new(path), |event| {
                output.write_all(event)?;
                output.write_all(b"\n")
            })
            .map_err(io::Error::other)?;
        }
        _ => return Err(io::Error::other("usage: audit-writer {append|dump} LOG")),
    }
    Ok(())
}

fn main() -> ExitCode {
    if let Err(error) = run() {
        eprintln!("{error}");
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}
~~~

</details>

### Step 3 — Reuse the existing commit driver

Create an apply callback that starts the writer, waits for its exit and exact response, and returns success to the consumer.

<details>
<summary>Hint</summary>

A failed or timed-out writer must cause the callback to fail before the driver commits.

</details>

<details>
<summary>Implementation</summary>

Create `audit/internal/auditfeed/feed.go`.

<!-- file: audit/internal/auditfeed/feed.go -->
~~~go
// Package auditfeed projects validated events into a durable Rust log.
package auditfeed

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"

	"github.com/twmb/franz-go/pkg/kgo"

	"switchyard/streams/internal/event"
)

type Entry struct {
	ID        string `json:"id"`
	Job       string `json:"job"`
	Kind      string `json:"kind"`
	Version   int    `json:"version"`
	Topic     string `json:"topic"`
	Partition int32  `json:"partition"`
	Offset    int64  `json:"offset"`
}

// Append is an apply callback for stream.ConsumeOne. That driver commits
// the partition offset only when this callback returns success.
func Append(ctx context.Context, writer, log string, record *kgo.Record, pause func(string)) error {
	decoded, err := event.Decode(record.Key, record.Value)
	if err != nil {
		return err
	}
	// Encode only these fields. Unknown metadata stays outside the audit log.
	body, err := json.Marshal(Entry{
		ID: decoded.ID, Job: decoded.Job, Kind: decoded.Kind, Version: decoded.Version,
		Topic: record.Topic, Partition: record.Partition, Offset: record.Offset,
	})
	if err != nil {
		return err
	}
	pause("before-append")
	child := exec.CommandContext(ctx, writer, "append", log)
	child.Stdin = bytes.NewReader(body)
	out, err := child.Output()
	if err != nil {
		return fmt.Errorf("audit writer: %w", err)
	}
	if !bytes.Equal(out, []byte("ok\n")) {
		return fmt.Errorf("audit writer returned no durable acknowledgement")
	}
	pause("before-commit")
	return nil
}
~~~

Create `audit/cmd/auditfeed/main.go`.

<!-- file: audit/cmd/auditfeed/main.go -->
~~~go
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"

	"switchyard/streams/internal/auditfeed"
	"switchyard/streams/internal/event"
	"switchyard/streams/internal/stream"
)

func run(ctx context.Context) error {
	brokers := flag.String("brokers", "", "comma-separated Kafka seed brokers")
	topic := flag.String("topic", "", "job event topic")
	group := flag.String("group", "", "consumer group")
	writer := flag.String("writer", "", "path to audit-writer")
	log := flag.String("log", "", "separate audit file")
	count := flag.Int("count", 1, "records to consume")
	flag.Parse()
	if *brokers == "" || !event.ValidName(*topic) || !event.ValidName(*group) ||
		*writer == "" || *log == "" || *count < 1 {
		return errors.New("provide brokers, topic, group, writer, log, and a positive count")
	}
	client, err := stream.Consumer(strings.Split(*brokers, ","), *topic, *group)
	if err != nil {
		return err
	}
	defer client.Close()
	for range *count {
		attempt, cancel := context.WithTimeout(ctx, 30*time.Second)
		err := stream.ConsumeOne(attempt, client, func(ctx context.Context, record *kgo.Record) error {
			return auditfeed.Append(ctx, *writer, *log, record, boundary)
		})
		cancel()
		if err != nil {
			return err
		}
	}
	return nil
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	if err := run(ctx); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
~~~

</details>

### Step 4 — Place the interruption hooks

Make the gate build able to stop the feed immediately before append and before commit. Exercise the protocol against the actual Rust child before adding a broker.

<details>
<summary>Hint</summary>

Use the hooks in the gate build. Keep the ordinary feed build free of stop controls.

</details>

<details>
<summary>Implementation</summary>

Create `audit/cmd/auditfeed/boundary.go`.

<!-- file: audit/cmd/auditfeed/boundary.go -->
~~~go
//go:build !integritygate

package main

func boundary(string) {}
~~~

Create `audit/cmd/auditfeed/boundary_gate.go`.

<!-- file: audit/cmd/auditfeed/boundary_gate.go -->
~~~go
//go:build integritygate

package main

import (
	"fmt"
	"os"
)

func boundary(label string) {
	if os.Getenv("AUDIT_GATE_STOP") == label {
		fmt.Println("stopped", label)
		// Skip cleanup and offset commits, as on a hard process stop.
		os.Exit(73)
	}
}
~~~

Create `audit/internal/auditfeed/feed_test.go`.

<!-- file: audit/internal/auditfeed/feed_test.go -->
~~~go
package auditfeed

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/twmb/franz-go/pkg/kgo"
)

func entries(t *testing.T, writer, path string) []Entry {
	t.Helper()
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil
	}
	bytes, err := exec.Command(writer, "dump", path).Output()
	if err != nil {
		t.Fatal(err)
	}
	var result []Entry
	for _, line := range strings.Split(strings.TrimSpace(string(bytes)), "\n") {
		if line == "" {
			continue
		}
		var entry Entry
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatal(err)
		}
		result = append(result, entry)
	}
	return result
}

func TestApplyWaitsForDurableAcknowledgement(t *testing.T) {
	writer := os.Getenv("AUDIT_WRITER")
	if writer == "" {
		t.Skip("build audit-writer and set AUDIT_WRITER")
	}
	record := &kgo.Record{
		Topic: "jobs", Partition: 2, Offset: 12, Key: []byte("one"),
		Value: []byte(`{"id":"event-1","job":"one","kind":"job-recorded","version":1,"private":"canary"}`),
	}
	path := filepath.Join(t.TempDir(), "audit")
	var phases []string
	if err := Append(context.Background(), writer, path, record, func(label string) {
		phases = append(phases, label)
		if label == "before-append" && len(entries(t, writer, path)) != 0 {
			t.Fatal("record appeared before append")
		}
		if label == "before-commit" {
			records := entries(t, writer, path)
			if len(records) != 1 || records[0].ID != "event-1" || records[0].Offset != 12 {
				t.Fatalf("bad durable record before commit: %+v", records)
			}
		}
	}); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(phases, []string{"before-append", "before-commit"}) {
		t.Fatalf("wrong boundary order: %v", phases)
	}
	raw, err := os.ReadFile(path)
	if err != nil || strings.Contains(string(raw), "canary") {
		t.Fatalf("unexpected audit data: %v", err)
	}
	if err := Append(context.Background(), "/bin/false", path, record, func(label string) {
		if label == "before-commit" {
			t.Fatal("failed writer reached commit")
		}
	}); err == nil {
		t.Fatal("writer failure was accepted")
	}
	t.Log("audit record durable before commit boundary; unlisted fields omitted")
}
~~~

</details>

## Check it

~~~bash
cargo build --locked --quiet --manifest-path storage/Cargo.toml --bin audit-writer
export AUDIT_WRITER="$(cargo metadata --manifest-path storage/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')/debug/audit-writer"
(cd audit && go test -race -count=1 -v ./internal/auditfeed -run TestApplyWaitsForDurableAcknowledgement)
~~~

<!-- run: cargo build --locked --quiet --manifest-path storage/Cargo.toml --bin audit-writer && export AUDIT_WRITER="$(cargo metadata --manifest-path storage/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')/debug/audit-writer" && (cd audit && go test -race -count=1 -v ./internal/auditfeed -run TestApplyWaitsForDurableAcknowledgement) -->

The protocol test saw the expected event on disk before the commit boundary, and the private input canary was absent. Lesson 06 connects the same driver to Kafka and checks its stored offsets.

## If it goes wrong

If the Rust child reports success early, put the acknowledgment after the sync. If any event with a writer error is committed, check that the callback returns the error to the consumer.
