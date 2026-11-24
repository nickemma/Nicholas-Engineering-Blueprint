# 04 Check a record against a signed Merkle root

> Integrity and encryption · Week 2 · Builds on lesson 03

## The problem

A framed file can pass a checksum check after a whole record is replaced. A verifier needs a commitment to the exact earlier bytes and their order.

## The mental model

Hash a leaf with its leaf tag followed by the canonical record bytes. Hash a branch with a different tag followed by its two child hashes. The recipe for an uneven tree splits at the largest power of two below its size. A signature commits to the log identity, the size, and the root.

## The pattern

A Merkle inclusion proof carries the sibling hashes needed to rebuild a checkpoint root from one leaf. Verify the signature and expected log identity first. Use independent Rust and Go implementations to compare root results for the same record bytes.

## Build it

### Step 1 — Trace an uneven tree

Draw trees of sizes three and five. Predict which subtree is full and which hashes an inclusion proof for the last leaf needs.

<details>
<summary>Hint</summary>

Domain tags distinguish record bytes from pairs of child hashes.

</details>

### Step 2 — Hash the Rust log

Add a SHA-256 dependency and a root command that reads verified `klog` records.

<details>
<summary>Hint</summary>

Hash the stored bytes directly. Re-encoding a decoded record can change the signed bytes.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `storage/Cargo.toml` in order.

<!-- edit: storage/Cargo.toml -->
~~~toml
klog = { path = "klog" }
aes-gcm = "=0.10.3"
getrandom = "=0.3.4"

[features]
fault-injection = []
~~~

Replace the selected lines with this block.

~~~toml
klog = { path = "klog" }
aes-gcm = "=0.10.3"
getrandom = "=0.3.4"
sha2 = "=0.10.9"

[features]
fault-injection = []
~~~

Find these regions in `storage/Cargo.lock` in order.

<!-- edit: storage/Cargo.lock -->
~~~text
 "ctr",
 "ghash",
 "subtle",
]

[[package]]
~~~

Replace the selected lines with this block.

~~~text
 "ctr",
 "ghash",
 "subtle",
]

[[package]]
name = "block-buffer"
version = "0.10.4"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "3078c7629b62d3f0439517fa394996acacc5cbc91c5a20d8c658e77abd503a71"
dependencies = [
 "generic-array",
]

[[package]]
~~~

<!-- edit: storage/Cargo.lock -->
~~~text
checksum = "0369ee1ad671834580515889b80f2ea915f23b8be8d0daa4bbaf2ac5c7590835"
dependencies = [
 "cipher",
]

[[package]]
~~~

Replace the selected lines with this block.

~~~text
checksum = "0369ee1ad671834580515889b80f2ea915f23b8be8d0daa4bbaf2ac5c7590835"
dependencies = [
 "cipher",
]

[[package]]
name = "digest"
version = "0.10.7"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "9ed9a281f7bc9b7576e61468ba615a66a5c8cfdff42420a70aa82701a3b1e292"
dependencies = [
 "block-buffer",
 "crypto-common",
]

[[package]]
~~~

<!-- edit: storage/Cargo.lock -->
~~~text
 "aes-gcm",
 "getrandom 0.3.4",
 "klog",
]

[[package]]
~~~

Replace the selected lines with this block.

~~~text
 "aes-gcm",
 "getrandom 0.3.4",
 "klog",
 "sha2",
]

[[package]]
~~~

<!-- edit: storage/Cargo.lock -->
~~~text
checksum = "ec0be4795e2f6a28069bec0b5ff3e2ac9bafc99e6a9a7dc3547996c5c816922c"
dependencies = [
 "getrandom 0.2.17",
]

[[package]]
~~~

Replace the selected lines with this block.

~~~text
checksum = "ec0be4795e2f6a28069bec0b5ff3e2ac9bafc99e6a9a7dc3547996c5c816922c"
dependencies = [
 "getrandom 0.2.17",
]

[[package]]
name = "sha2"
version = "0.10.9"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "a7507d819769d01a365ab707794a4084392c824f54a7a6a7862f8c3d0892b283"
dependencies = [
 "cfg-if",
 "cpufeatures",
 "digest",
]

[[package]]
~~~

Find these regions in `storage/src/bin/audit-writer.rs` in order.

<!-- edit: storage/src/bin/audit-writer.rs -->
~~~rust
};

use klog::log::{Log, visit_records};

const MAX_EVENT: u64 = 4096;
~~~

Replace the selected lines with this block.

~~~rust
};

use klog::log::{Log, visit_records};
use sha2::{Digest, Sha256};

const MAX_EVENT: u64 = 4096;
~~~

<!-- edit: storage/src/bin/audit-writer.rs -->
~~~rust
            })
            .map_err(io::Error::other)?;
        }
        _ => return Err(io::Error::other("usage: audit-writer {append|dump} LOG")),
    }
    Ok(())
}

fn main() -> ExitCode {
~~~

Replace the selected lines with this block.

~~~rust
            })
            .map_err(io::Error::other)?;
        }
        [op, path, count] if op == "root" => {
            let count: usize = count
                .to_str()
                .and_then(|n| n.parse().ok())
                .ok_or_else(|| io::Error::other("invalid record count"))?;
            let mut leaves = Vec::new();
            visit_records(Path::new(path), |event| {
                if leaves.len() < count {
                    let mut hash = Sha256::new();
                    hash.update([0]);
                    hash.update(event);
                    leaves.push(hash.finalize().into());
                }
                Ok(())
            })
            .map_err(io::Error::other)?;
            if leaves.len() != count {
                return Err(io::Error::other("requested root exceeds log size"));
            }
            for byte in root(&leaves) {
                print!("{byte:02x}");
            }
            println!();
        }
        _ => {
            return Err(io::Error::other(
                "usage: audit-writer {append|dump} LOG, or root LOG COUNT",
            ));
        }
    }
    Ok(())
}

type Hash = [u8; 32];

fn root(leaves: &[Hash]) -> Hash {
    match leaves.len() {
        0 => Sha256::digest([]).into(),
        1 => leaves[0],
        n => {
            let split = 1 << (usize::BITS - 1 - (n - 1).leading_zeros());
            let mut hash = Sha256::new();
            hash.update([1]);
            hash.update(root(&leaves[..split]));
            hash.update(root(&leaves[split..]));
            hash.finalize().into()
        }
    }
}

fn main() -> ExitCode {
~~~

</details>

### Step 3 — Build the Go verifier

Use the checksum-log library for Merkle proofs. Read and check the current 12-byte frame header and payload from the Rust log.

<details>
<summary>Hint</summary>

A complete CRC check is independent of proving history. A torn frame makes the verifier fail until the writer repairs the tail.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `audit/go.mod` in order.

<!-- edit: audit/go.mod -->
~~~text
	github.com/jackc/pgx/v5 v5.11.0
	github.com/twmb/franz-go v1.22.1
	github.com/twmb/franz-go/pkg/kadm v1.19.0
)

require (
~~~

Replace the selected lines with this block.

~~~text
	github.com/jackc/pgx/v5 v5.11.0
	github.com/twmb/franz-go v1.22.1
	github.com/twmb/franz-go/pkg/kadm v1.19.0
	golang.org/x/mod v0.42.0
)

require (
~~~

Find these regions in `audit/go.sum` in order.

<!-- edit: audit/go.sum -->
~~~text
github.com/twmb/franz-go/pkg/kadm v1.19.0/go.mod h1:emmsx5J7YPU9A7UHcSoz0fBMYVmCcJO2etylJeU0VHU=
github.com/twmb/franz-go/pkg/kmsg v1.14.0 h1:gSxrBEKWl3qnsx3QKWol5OEVujuPmIoDkhMt3didFKM=
github.com/twmb/franz-go/pkg/kmsg v1.14.0/go.mod h1:+DPt4NC8RmI6hqb8G09+3giKObE6uD2Eya6CfqBpeJY=
golang.org/x/sync v0.17.0 h1:l60nONMj9l5drqw6jlhIELNv9I0A4OFgRsG9k2oT9Ug=
golang.org/x/sync v0.17.0/go.mod h1:9KTHXmSnoGruLpwFjVSX0lNNA75CykiMECbovNTZqGI=
golang.org/x/text v0.29.0 h1:1neNs90w9YzJ9BocxfsQNHKuAT4pkghyXc4nhZ6sJvk=
~~~

Replace the selected lines with this block.

~~~text
github.com/twmb/franz-go/pkg/kadm v1.19.0/go.mod h1:emmsx5J7YPU9A7UHcSoz0fBMYVmCcJO2etylJeU0VHU=
github.com/twmb/franz-go/pkg/kmsg v1.14.0 h1:gSxrBEKWl3qnsx3QKWol5OEVujuPmIoDkhMt3didFKM=
github.com/twmb/franz-go/pkg/kmsg v1.14.0/go.mod h1:+DPt4NC8RmI6hqb8G09+3giKObE6uD2Eya6CfqBpeJY=
golang.org/x/mod v0.42.0 h1:ICeL3t2L30ljSPHHxDnR4fqVcBt/zR2zJAb9juavmQg=
golang.org/x/mod v0.42.0/go.mod h1:u5fzIrRInkL8MaO1cbRkUHT64v303YIT5KEqpNr7jRs=
golang.org/x/sync v0.17.0 h1:l60nONMj9l5drqw6jlhIELNv9I0A4OFgRsG9k2oT9Ug=
golang.org/x/sync v0.17.0/go.mod h1:9KTHXmSnoGruLpwFjVSX0lNNA75CykiMECbovNTZqGI=
golang.org/x/text v0.29.0 h1:1neNs90w9YzJ9BocxfsQNHKuAT4pkghyXc4nhZ6sJvk=
~~~

Create `audit/internal/audit/tree.go`.

<!-- file: audit/internal/audit/tree.go -->
~~~go
package audit

import (
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"syscall"

	"golang.org/x/mod/sumdb/tlog"
)

// Tree stores the Go checksum log library’s Merkle hashes in memory.
type Tree struct {
	hashes []tlog.Hash
	size   int64
}

// Add appends a record.
func (t *Tree) Add(record []byte) error {
	hs, err := tlog.StoredHashes(t.size, record, t)
	if err != nil {
		return err
	}
	t.hashes = append(t.hashes, hs...)
	t.size++
	return nil
}

// Size is how many records the tree holds.
func (t *Tree) Size() int64 { return t.size }

// ReadHashes makes Tree a tlog.HashReader over its own stored hashes.
func (t *Tree) ReadHashes(indexes []int64) ([]tlog.Hash, error) {
	out := make([]tlog.Hash, len(indexes))
	for i, x := range indexes {
		if x < 0 || x >= int64(len(t.hashes)) {
			return nil, fmt.Errorf("no stored hash %d", x)
		}
		out[i] = t.hashes[x]
	}
	return out, nil
}

// Root is the root of the tree over the first n records.
func (t *Tree) Root(n int64) (tlog.Hash, error) { return tlog.TreeHash(n, t) }

// ProveRecord proves record i is among the first n.
func (t *Tree) ProveRecord(i, n int64) (tlog.RecordProof, error) { return tlog.ProveRecord(n, i, t) }

// ProveTree proves the first old records are a prefix of the first n.
func (t *Tree) ProveTree(old, n int64) (tlog.TreeProof, error) { return tlog.ProveTree(n, old, t) }

// ReadLog verifies current klog headers and payloads. Verification treats
// incomplete tails as errors; a klog writer can recover them under its lock.
func ReadLog(path string) ([][]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
		return nil, fmt.Errorf("lock audit log for verification: %w", err)
	}
	castagnoli := crc32.MakeTable(crc32.Castagnoli)
	var records [][]byte
	for {
		var header [12]byte
		_, err := io.ReadFull(file, header[:])
		if errors.Is(err, io.EOF) {
			return records, nil
		}
		if err != nil {
			return nil, fmt.Errorf("audit header: %w", err)
		}
		limit := binary.LittleEndian.Uint32(header[:4])
		if limit == 0 || limit > 4096 ||
			crc32.Checksum(header[:8], castagnoli) != binary.LittleEndian.Uint32(header[8:]) {
			return nil, fmt.Errorf("invalid audit frame header")
		}
		payload := make([]byte, limit)
		if _, err := io.ReadFull(file, payload); err != nil {
			return nil, fmt.Errorf("audit payload: %w", err)
		}
		if crc32.Checksum(payload, castagnoli) != binary.LittleEndian.Uint32(header[4:8]) {
			return nil, fmt.Errorf("invalid audit payload checksum")
		}
		records = append(records, payload)
	}
}

func TreeOf(records [][]byte) (*Tree, error) {
	tree := &Tree{}
	for _, record := range records {
		if err := tree.Add(record); err != nil {
			return nil, err
		}
	}
	return tree, nil
}
~~~

</details>

### Step 4 — Sign and test inclusion

Bind the expected origin and exact size to the signed root. Check matching roots for several sizes, and verify a proof for each fielded record.

<details>
<summary>Hint</summary>

Verify inclusion with a record hash and an index. Changing either changes what the proof must show.

</details>

<details>
<summary>Implementation</summary>

Create `audit/internal/audit/checkpoint.go`.

<!-- file: audit/internal/audit/checkpoint.go -->
~~~go
package audit

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"errors"

	"golang.org/x/mod/sumdb/tlog"
)

type Head struct {
	Origin string    `json:"origin"`
	Size   int64     `json:"size"`
	Root   tlog.Hash `json:"root"`
}

type Checkpoint struct {
	Head      Head   `json:"head"`
	Signature []byte `json:"signature"`
}

func signedBytes(domain string, value any) []byte {
	// The callers pass fixed structs containing strings, numbers, and bytes.
	body, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return append([]byte(domain+"\x00"), body...)
}

const checkpointDomain = "switchyard/audit/checkpoint/v1"

func Sign(origin string, tree *Tree, private ed25519.PrivateKey) (Checkpoint, error) {
	if len(origin) == 0 || len(origin) > 128 || len(private) != ed25519.PrivateKeySize {
		return Checkpoint{}, errors.New("invalid log identity or signing key")
	}
	root, err := tree.Root(tree.Size())
	if err != nil {
		return Checkpoint{}, err
	}
	head := Head{Origin: origin, Size: tree.Size(), Root: root}
	return Checkpoint{Head: head, Signature: ed25519.Sign(private, signedBytes(checkpointDomain, head))}, nil
}

func (point Checkpoint) Verify(origin string, public ed25519.PublicKey) error {
	if point.Head.Origin != origin || len(origin) == 0 || len(origin) > 128 || point.Head.Size < 0 ||
		(point.Head.Size == 0 && point.Head.Root != sha256.Sum256(nil)) ||
		len(public) != ed25519.PublicKeySize ||
		!ed25519.Verify(public, signedBytes(checkpointDomain, point.Head), point.Signature) {
		return errors.New("invalid audit checkpoint signature or identity")
	}
	return nil
}

func VerifyInclusion(point Checkpoint, origin string, public ed25519.PublicKey, index int64, record []byte, proof tlog.RecordProof) error {
	if err := point.Verify(origin, public); err != nil {
		return err
	}
	return tlog.CheckRecord(proof, point.Head.Size, point.Head.Root, index, tlog.RecordHash(record))
}
~~~

Create `audit/internal/audit/tree_test.go`.

<!-- file: audit/internal/audit/tree_test.go -->
~~~go
package audit

import (
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestCrossLanguageRootsAndSignedInclusion(t *testing.T) {
	writer := os.Getenv("AUDIT_WRITER")
	if writer == "" {
		t.Skip("build audit-writer and set AUDIT_WRITER")
	}
	path := filepath.Join(t.TempDir(), "klog")
	for i := range 7 {
		record := fmt.Sprintf(`{"id":"event-%d","job":"one","kind":"job-recorded","version":1,"topic":"jobs","partition":0,"offset":%d}`, i, i)
		cmd := exec.Command(writer, "append", path)
		cmd.Stdin = strings.NewReader(record)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("append: %s: %v", out, err)
		}
	}
	records, err := ReadLog(path)
	if err != nil {
		t.Fatal(err)
	}
	tree, err := TreeOf(records)
	if err != nil {
		t.Fatal(err)
	}
	for _, size := range []int64{0, 1, 2, 3, 5, 7} {
		root, err := tree.Root(size)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := exec.Command(writer, "root", path, strconv.FormatInt(size, 10)).Output()
		if err != nil {
			t.Fatal(err)
		}
		if strings.TrimSpace(string(raw)) != fmt.Sprintf("%x", root[:]) {
			t.Fatalf("root disagreement at size %d", size)
		}
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	point, err := Sign("jobs", tree, private)
	if err != nil {
		t.Fatal(err)
	}
	for index, record := range records {
		proof, err := tree.ProveRecord(int64(index), point.Head.Size)
		if err != nil {
			t.Fatal(err)
		}
		if err := VerifyInclusion(point, "jobs", public, int64(index), record, proof); err != nil {
			t.Fatal(err)
		}
		if err := VerifyInclusion(point, "jobs", public, int64(index), []byte("other"), proof); err == nil {
			t.Fatal("accepted mismatched record")
		}
	}
	if err := point.Verify("other", public); err == nil {
		t.Fatal("accepted a checkpoint for another log")
	}
	t.Log("Rust and Go agreed at sizes 0, 1, 2, 3, 5, and 7; signed inclusion verified for every record")
}
~~~

</details>

## Check it

~~~bash
cargo build --locked --quiet --manifest-path storage/Cargo.toml --bin audit-writer
export AUDIT_WRITER="$(cargo metadata --manifest-path storage/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')/debug/audit-writer"
(cd audit && go test -race -count=1 -v ./internal/audit -run TestCrossLanguageRootsAndSignedInclusion)
~~~

<!-- run: cargo build --locked --quiet --manifest-path storage/Cargo.toml --bin audit-writer && export AUDIT_WRITER="$(cargo metadata --manifest-path storage/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')/debug/audit-writer" && (cd audit && go test -race -count=1 -v ./internal/audit -run TestCrossLanguageRootsAndSignedInclusion) -->

Rust and Go agreed at sizes 0, 1, 2, 3, 5, and 7. Every record had a valid inclusion proof, and the verifier refused a different record under the same proof.

## If it goes wrong

If roots disagree for only uneven sizes, check the split and operand order. If the proof passes for another origin, inspect which expected identity the verifier checked.
