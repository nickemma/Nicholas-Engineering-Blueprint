# 06 Run the tenant, encryption, and audit gate

> Integrity and encryption · Week 2 · Builds on lesson 05

## The problem

A successful read and a valid signature show only part of the system’s behavior. A complete check needs evidence of process recovery, tenant bounds, and continuity from the last trusted checkpoint.

## The mental model

Record three views of the fixture. Read the physical WAL and table bytes, inspect the Kafka offsets and durable event IDs, and compare new checkpoint receipts with the witness’s saved head.

## The pattern

Use isolated fixture state and deterministic controls. The namespace control changes one scan endpoint in a disposable source copy. The Kafka gate runs the same feed on a fresh topic and interrupts its consumer before and after durable append.

## Build it

### Step 1 — Predict the offsets

Write down the expected audit IDs and committed offset after each recovery run. In the second run, the first event is already on disk when the process stops.

<details>
<summary>Hint</summary>

A Kafka commit stores the next offset. Reprocessing offset zero can duplicate an event ID without omitting a later event.

</details>

### Step 2 — Run the two broker schedules

Use a fresh topic and separate groups. Check the actual broker offset after the process stop, then compare durable IDs after the same group resumes.

<details>
<summary>Hint</summary>

Set the broker address as described in the gate guide. The test stops only the child feed it starts.

</details>

<details>
<summary>Implementation</summary>

Create `audit/internal/auditfeed/kafka_test.go`.

<!-- file: audit/internal/auditfeed/kafka_test.go -->
~~~go
package auditfeed

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"

	"switchyard/streams/internal/event"
	"switchyard/streams/internal/stream"
)

func TestKafkaReplayAtDurabilityBoundaries(t *testing.T) {
	seeds := os.Getenv("INTEGRITY_KAFKA_BROKERS")
	feed, writer := os.Getenv("AUDIT_FEED"), os.Getenv("AUDIT_WRITER")
	if seeds == "" || feed == "" || writer == "" {
		t.Skip("set INTEGRITY_KAFKA_BROKERS and build the gate binaries")
	}
	ctx, stop := context.WithTimeout(t.Context(), 2*time.Minute)
	defer stop()
	producer, err := stream.Producer(strings.Split(seeds, ","))
	if err != nil {
		t.Fatal(err)
	}
	defer producer.Close()
	admin := kadm.NewClient(producer)
	topic := fmt.Sprintf("sy-integrity-%d", time.Now().UnixNano())
	if _, err := admin.CreateTopic(ctx, 1, 1, nil, topic); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		admin.DeleteTopics(cleanup, topic)
	}()

	for i := range 2 {
		message, err := event.New(fmt.Sprintf("event-%d", i+1), "job")
		if err != nil {
			t.Fatal(err)
		}
		data, err := json.Marshal(message)
		if err != nil {
			t.Fatal(err)
		}
		if err := producer.ProduceSync(ctx, &kgo.Record{Topic: topic, Key: []byte("job"), Value: data}).FirstErr(); err != nil {
			t.Fatal(err)
		}
	}

	for _, phase := range []string{"before-append", "before-commit"} {
		t.Run(phase, func(t *testing.T) {
			group := topic + "-" + phase
			path := filepath.Join(t.TempDir(), "audit")
			execute := func(count string, stopAt string) ([]byte, error) {
				child := exec.CommandContext(ctx, feed,
					"-brokers", seeds, "-topic", topic, "-group", group,
					"-writer", writer, "-log", path, "-count", count)
				child.Env = append(os.Environ(), "AUDIT_GATE_STOP="+stopAt)
				return child.CombinedOutput()
			}
			out, err := execute("1", phase)
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 73 ||
				string(out) != "stopped "+phase+"\n" {
				t.Fatalf("expected the fixture stop, got %s: %v", out, err)
			}
			offsets, err := admin.FetchOffsets(ctx, group)
			if err != nil && !errors.Is(err, kerr.GroupIDNotFound) {
				t.Fatal(err)
			}
			if offset, ok := offsets.Lookup(topic, 0); ok && offset.At >= 0 {
				t.Fatalf("offset advanced after interrupted feed: %+v", offset)
			}
			want := []string{"event-1", "event-2"}
			appended := entries(t, writer, path)
			if phase == "before-commit" {
				if len(appended) != 1 || appended[0].ID != "event-1" || appended[0].Offset != 0 {
					t.Fatalf("expected one durable event before commit: %+v", appended)
				}
				want = []string{"event-1", "event-1", "event-2"}
			} else if len(appended) != 0 {
				t.Fatal("the event was appended before the append boundary")
			}

			if out, err := execute("2", ""); err != nil {
				t.Fatalf("restart: %s: %v", out, err)
			}
			var got []string
			for _, entry := range entries(t, writer, path) {
				got = append(got, entry.ID)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("durable event IDs: got %v, want %v", got, want)
			}
			offsets, err = admin.FetchOffsets(ctx, group)
			if err != nil {
				t.Fatal(err)
			}
			if offset, ok := offsets.Lookup(topic, 0); !ok || offset.At != 2 || offset.Err != nil {
				t.Fatalf("expected next Kafka offset 2: %+v", offset)
			}
			t.Logf("%s: durable event IDs %v; next committed offset 2", phase, got)
			admin.DeleteGroups(ctx, group)
		})
	}
}
~~~

</details>

### Step 3 — Check identical keys in two tenants

Run the same isolation assertion on the reference build and on the control with an unbounded tenant scan.

<details>
<summary>Hint</summary>

The reference must pass. The control must reach the same test and fail its namespace assertion.

</details>

### Step 4 — Read the witness verdicts

Explain which component rejects each of the validly signed conflicting candidates. Verify that the rejected heads left the stored receipt unchanged.

<details>
<summary>Hint</summary>

CRC validation only evaluates record framing. Consistency is checked against a previously trusted root.

</details>

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/04-integrity-and-encryption/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/04-integrity-and-encryption/gate/run.sh" "$PWD" -->

After the pre-append stop, Kafka replay produced `[event-1 event-2]`. After the pre-commit stop, it produced `[event-1 event-1 event-2]`. Both groups committed next offset 2 after recovery. The weakened scan failed. [Gate evidence](../evidence/README.md)

## If it goes wrong

If the broker check skips, provide a reachable lab broker. If it hangs after abrupt exit, check the consumer session timeout and broker-advertised address. See the [gate guide](../gate/README.md).
