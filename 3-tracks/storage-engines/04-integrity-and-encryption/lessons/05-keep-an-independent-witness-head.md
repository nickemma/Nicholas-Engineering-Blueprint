# 05 Carry the last checkpoint forward with a witness

> Integrity and encryption · Week 2 · Builds on lesson 04

## The problem

A signed checkpoint says what a signer attested to. A verifier relying on the writer alone can discover two signed heads for the same size, or be shown an older signed view.

## The mental model

The witness pins the latest accepted head in its own directory. For a larger candidate it checks a proof relating the same old size and root to the proposed new head. It publishes the new receipt atomically and returns it after sync.

## The pattern

A consistency proof verifies that a later tree starts with the previous tree. The same size and root can be accepted again. The witness refuses a smaller size and conflicting roots. A receipt includes a signature from the independently configured witness key.

## Build it

### Step 1 — Draw the acceptance cases

List the initial trust decision, exact replay, equal-size conflict, rollback, valid extension, and rewritten prefix.

<details>
<summary>Hint</summary>

Bootstrap uses the configured signer and origin. Every later comparison starts from persisted state.

</details>

### Step 2 — Verify and publish under one lock

Keep a sidecar lock while reading the trusted head, checking the proof, and replacing the state file. Sync the receipt and directory before returning it.

<details>
<summary>Hint</summary>

The lock must survive replacement of the state file itself.

</details>

<details>
<summary>Implementation</summary>

Create `audit/internal/audit/witness.go`.

<!-- file: audit/internal/audit/witness.go -->
~~~go
package audit

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"golang.org/x/mod/sumdb/tlog"
)

const witnessDomain = "switchyard/audit/witness/v1"

type Receipt struct {
	Point Checkpoint `json:"checkpoint"`
	Seal  []byte     `json:"witness_signature"`
}

func (receipt Receipt) Verify(origin string, signer, witness ed25519.PublicKey) error {
	if err := receipt.Point.Verify(origin, signer); err != nil {
		return err
	}
	if len(witness) != ed25519.PublicKeySize ||
		!ed25519.Verify(witness, signedBytes(witnessDomain, receipt.Point), receipt.Seal) {
		return errors.New("invalid witness signature")
	}
	return nil
}

type Witness struct {
	Path   string
	Origin string
	Signer ed25519.PublicKey
	Key    ed25519.PrivateKey
}

// ReadJSON accepts one bounded document with the expected fields.
func ReadJSON(path string, target any) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if info.Size() > 16<<10 {
		return errors.New("statement exceeds size limit")
	}
	dec := json.NewDecoder(io.LimitReader(file, 16<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(target); err != nil {
		return err
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return errors.New("unexpected data after statement")
	}
	return nil
}

// Advance serializes read, verification, and publication under a sidecar
// lock that remains in place when the receipt file is replaced.
func (w Witness) Advance(next Checkpoint, prove func(Head) (tlog.TreeProof, error)) (Receipt, error) {
	if len(w.Key) != ed25519.PrivateKeySize {
		return Receipt{}, errors.New("invalid witness key")
	}
	if err := next.Verify(w.Origin, w.Signer); err != nil {
		return Receipt{}, err
	}
	lock, err := os.OpenFile(w.Path+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return Receipt{}, err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return Receipt{}, err
	}

	var previous Receipt
	err = ReadJSON(w.Path, &previous)
	switch {
	case errors.Is(err, os.ErrNotExist):
		// Bootstrap trusts the configured signer and origin.
	case err != nil:
		return Receipt{}, err
	default:
		if err := previous.Verify(w.Origin, w.Signer, w.Key.Public().(ed25519.PublicKey)); err != nil {
			return Receipt{}, err
		}
		old := previous.Point.Head
		switch {
		case next.Head.Size < old.Size:
			return Receipt{}, errors.New("checkpoint rollback")
		case next.Head.Size == old.Size:
			if next.Head.Root != old.Root {
				return Receipt{}, errors.New("conflicting checkpoint at the same size")
			}
			return previous, nil
		case old.Size > 0:
			proof, err := prove(old)
			if err != nil {
				return Receipt{}, err
			}
			if err := tlog.CheckTree(proof, next.Head.Size, next.Head.Root, old.Size, old.Root); err != nil {
				return Receipt{}, fmt.Errorf("audit prefix changed: %w", err)
			}
		}
	}

	receipt := Receipt{Point: next, Seal: ed25519.Sign(w.Key, signedBytes(witnessDomain, next))}
	if err := publish(w.Path, receipt); err != nil {
		return Receipt{}, err
	}
	return receipt, nil
}

func publish(path string, receipt Receipt) error {
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, ".head-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if err := json.NewEncoder(file).Encode(receipt); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(file.Name(), path); err != nil {
		return err
	}
	directory, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
~~~

</details>

### Step 3 — Wire the local commands

Generate independent signing and witness keys. Add commands that sign a checkpoint, verify inclusion, and supply a consistency proof to the witness.

<details>
<summary>Hint</summary>

Store the witness state outside the writer’s directory and provide the expected log identity separately.

</details>

<details>
<summary>Implementation</summary>

Create `audit/cmd/auditctl/main.go`.

<!-- file: audit/cmd/auditctl/main.go -->
~~~go
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"

	"golang.org/x/mod/sumdb/tlog"

	"switchyard/streams/internal/audit"
)

func readKey(path string, length int) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, int64(length)+1))
	if err != nil {
		return nil, err
	}
	if len(data) != length {
		return nil, errors.New("invalid key length")
	}
	return data, nil
}

func createKey(path string) error {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	for _, item := range []struct {
		suffix string
		data   []byte
	}{{".key", private}, {".pub", public}} {
		file, err := os.OpenFile(path+item.suffix, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		_, writeErr := file.Write(item.data)
		if err := errors.Join(writeErr, file.Sync(), file.Close()); err != nil {
			return err
		}
	}
	return nil
}

func load(path string) (*audit.Tree, [][]byte, error) {
	records, err := audit.ReadLog(path)
	if err != nil {
		return nil, nil, err
	}
	tree, err := audit.TreeOf(records)
	return tree, records, err
}

func run(args []string) error {
	out := json.NewEncoder(os.Stdout)
	if len(args) == 2 && args[0] == "keygen" {
		return createKey(args[1])
	}
	if len(args) == 4 && args[0] == "checkpoint" {
		tree, _, err := load(args[1])
		if err != nil {
			return err
		}
		key, err := readKey(args[3], ed25519.PrivateKeySize)
		if err != nil {
			return err
		}
		point, err := audit.Sign(args[2], tree, key)
		if err != nil {
			return err
		}
		return out.Encode(point)
	}
	if len(args) >= 6 && (args[0] == "include" || args[0] == "witness") {
		tree, records, err := load(args[1])
		if err != nil {
			return err
		}
		var point audit.Checkpoint
		if err := audit.ReadJSON(args[3], &point); err != nil {
			return err
		}
		if point.Head.Size < 0 || point.Head.Size > tree.Size() {
			return errors.New("checkpoint size outside available log")
		}
		public, err := readKey(args[4], ed25519.PublicKeySize)
		if err != nil {
			return err
		}
		switch {
		case args[0] == "include" && len(args) == 6:
			index, err := strconv.ParseInt(args[5], 10, 64)
			if err != nil || index < 0 || index >= point.Head.Size {
				return errors.New("invalid record index")
			}
			proof, err := tree.ProveRecord(index, point.Head.Size)
			if err != nil {
				return err
			}
			if err := audit.VerifyInclusion(point, args[2], public, index, records[index], proof); err != nil {
				return err
			}
			fmt.Println("inclusion verified")
			return nil
		case args[0] == "witness" && len(args) == 7:
			root, err := tree.Root(point.Head.Size)
			if err != nil {
				return err
			}
			if root != point.Head.Root {
				return errors.New("log does not match candidate root")
			}
			key, err := readKey(args[6], ed25519.PrivateKeySize)
			if err != nil {
				return err
			}
			witness := audit.Witness{Path: args[5], Origin: args[2], Signer: public, Key: key}
			receipt, err := witness.Advance(point, func(old audit.Head) (tlog.TreeProof, error) {
				return tree.ProveTree(old.Size, point.Head.Size)
			})
			if err != nil {
				return err
			}
			return out.Encode(receipt)
		}
	}
	return errors.New("usage: auditctl keygen PREFIX | checkpoint LOG ORIGIN SIGNER_KEY | include LOG ORIGIN CHECKPOINT SIGNER_PUB INDEX | witness LOG ORIGIN CHECKPOINT SIGNER_PUB STATE WITNESS_KEY")
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
~~~

</details>

### Step 4 — Restart and check three conflicts

Reopen the witness using its state file. Extend from size 3 to 5 and submit three different signed negative fixtures.

<details>
<summary>Hint</summary>

Check that each negative fixture has a valid writer signature and that refusing it preserves the accepted head.

</details>

<details>
<summary>Implementation</summary>

Create `audit/internal/audit/witness_test.go`.

<!-- file: audit/internal/audit/witness_test.go -->
~~~go
package audit

import (
	"crypto/ed25519"
	"crypto/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/mod/sumdb/tlog"
)

func TestWitnessRejectsSignedRewriteAndRollback(t *testing.T) {
	writer := os.Getenv("AUDIT_WRITER")
	if writer == "" {
		t.Skip("build audit-writer and set AUDIT_WRITER")
	}
	dir := t.TempDir()
	logPub, logKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	witnessPub, witnessKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	w := Witness{Path: filepath.Join(dir, "last.json"), Origin: "jobs", Signer: logPub, Key: witnessKey}
	accept := func(name string, values ...string) (Checkpoint, Receipt, error) {
		t.Helper()
		path := filepath.Join(dir, name)
		for _, value := range values {
			cmd := exec.Command(writer, "append", path)
			cmd.Stdin = strings.NewReader(value)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("append: %s: %v", out, err)
			}
		}
		records, err := ReadLog(path)
		if err != nil {
			t.Fatalf("fixture must pass CRC validation: %v", err)
		}
		tree, err := TreeOf(records)
		if err != nil {
			t.Fatal(err)
		}
		point, err := Sign("jobs", tree, logKey)
		if err != nil {
			t.Fatal(err)
		}
		receipt, err := w.Advance(point, func(old Head) (tlog.TreeProof, error) {
			return tree.ProveTree(old.Size, point.Head.Size)
		})
		return point, receipt, err
	}

	_, receipt, err := accept("first", "event-1", "event-2", "event-3")
	if err != nil || receipt.Verify("jobs", logPub, witnessPub) != nil {
		t.Fatalf("could not bootstrap: %v", err)
	}
	// A new witness object starts from disk, with no in-memory head.
	w = Witness{Path: w.Path, Origin: "jobs", Signer: logPub, Key: witnessKey}
	_, receipt, err = accept("continue", "event-1", "event-2", "event-3", "event-4", "event-5")
	if err != nil || receipt.Point.Head.Size != 5 || receipt.Verify("jobs", logPub, witnessPub) != nil {
		t.Fatalf("could not advance witness after reopen: %v", err)
	}
	for _, check := range []struct {
		name string
		want string
		data []string
	}{
		{"rollback", "checkpoint rollback", []string{"event-1", "event-2", "event-3"}},
		{"same-size", "conflicting checkpoint", []string{"event-1", "replacement", "event-3", "event-4", "event-5"}},
		{"extension", "audit prefix changed", []string{"event-1", "replacement", "event-3", "event-4", "event-5", "event-6"}},
	} {
		point, _, err := accept(check.name, check.data...)
		if point.Verify("jobs", logPub) != nil || err == nil || !strings.Contains(err.Error(), check.want) {
			t.Fatalf("%s: expected %s on a signed checkpoint, got %v", check.name, check.want, err)
		}
	}
	var saved Receipt
	if err := ReadJSON(w.Path, &saved); err != nil || saved.Point.Head != receipt.Point.Head {
		t.Fatalf("negative control changed witness state: %v", err)
	}
	t.Log("witness advanced 3 -> 5 after restart; refused signed rollback, same-size conflict, and changed prefix")
}
~~~

</details>

## Check it

~~~bash
cargo build --locked --quiet --manifest-path storage/Cargo.toml --bin audit-writer
export AUDIT_WRITER="$(cargo metadata --manifest-path storage/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')/debug/audit-writer"
(cd audit && go test -race -count=1 -v ./internal/audit -run TestWitnessRejectsSignedRewriteAndRollback)
~~~

<!-- run: cargo build --locked --quiet --manifest-path storage/Cargo.toml --bin audit-writer && export AUDIT_WRITER="$(cargo metadata --manifest-path storage/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')/debug/audit-writer" && (cd audit && go test -race -count=1 -v ./internal/audit -run TestWitnessRejectsSignedRewriteAndRollback) -->

The reopened witness advanced from size 3 to 5. It refused a signed rollback, a different root at size 5, and a signed larger tree with a changed prefix.

## If it goes wrong

If a rollback passes, check where the witness state is stored and verify that the restarted process still opens it. If growth fails, compare the old size and root in the proof with the persisted receipt.
