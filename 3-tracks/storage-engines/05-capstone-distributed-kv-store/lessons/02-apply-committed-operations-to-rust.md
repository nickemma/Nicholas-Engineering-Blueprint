# 02 Apply committed operations to Rust

> Distributed KV capstone · Week 1 · Builds on lesson 01

## The problem

After a peer stops, its local LSM view may be between two committed operations. The next process needs an unambiguous source of truth before it serves reads.

## The mental model

The Go peer owns the ordered Raft history. Its Rust child owns an LSM view of that committed history. A snapshot carries the ciphertext image and receipts. Open a fresh view, populate it from the image, and apply the committed suffix in order.

## The pattern

A peer replies only after quorum commit and local application. Reads stay in the Raft log and run through the Rust view. Application uses a bounded pipe protocol with a local deadline. An application error stops the peer, so it has to reopen and rebuild.

## Build it

### Step 1 — Reuse envelope validation

Let the Rust child seal and open a value using the same exact physical key as associated data.

<details>
<summary>Hint</summary>

The Go API already computed that key. The public service is the only trusted caller of the child.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `storage/src/encrypted.rs` in order.

<!-- edit: storage/src/encrypted.rs -->
~~~rust
        Ok(Self { active, keys })
    }

    fn seal(&self, physical: &[u8], value: &[u8]) -> io::Result<Vec<u8>> {
        if value.len() > 32 * 1024 - HEADER - NONCE - TAG {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
~~~

Replace the selected lines with this block.

~~~rust
        Ok(Self { active, keys })
    }

    pub fn seal(&self, physical: &[u8], value: &[u8]) -> io::Result<Vec<u8>> {
        if value.len() > 32 * 1024 - HEADER - NONCE - TAG {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
~~~

<!-- edit: storage/src/encrypted.rs -->
~~~rust
        Ok(out)
    }

    fn open(&self, physical: &[u8], encrypted: &[u8]) -> io::Result<Vec<u8>> {
        if encrypted.len() < HEADER + NONCE + TAG || encrypted[0] != VERSION {
            return Err(invalid("unsupported or truncated value envelope"));
        }
~~~

Replace the selected lines with this block.

~~~rust
        Ok(out)
    }

    pub fn open(&self, physical: &[u8], encrypted: &[u8]) -> io::Result<Vec<u8>> {
        if encrypted.len() < HEADER + NONCE + TAG || encrypted[0] != VERSION {
            return Err(invalid("unsupported or truncated value envelope"));
        }
~~~

</details>

### Step 2 — Give the child a bounded protocol

Implement reset, seal, get, put, and delete. Use hex on the private pipe and compare a singleton range with a point lookup.

<details>
<summary>Hint</summary>

The half-open interval ending at key plus a zero byte contains exactly the original key.

</details>

<details>
<summary>Implementation</summary>

Create `storage/src/bin/kv-project.rs`.

<!-- file: storage/src/bin/kv-project.rs -->
~~~rust
use std::{
    fmt::Write as _,
    fs,
    io::{self, BufRead, Read, Write},
    path::{Path, PathBuf},
    process::ExitCode,
};

use lsm::{Keyring, Store};

#[derive(Clone, Copy)]
enum ReadPath {
    Range,
    Point,
}

impl ReadPath {
    fn parse(arg: &str) -> io::Result<Self> {
        match arg {
            "range" => Ok(Self::Range),
            "point" => Ok(Self::Point),
            _ => Err(io::Error::other("read path must be range or point")),
        }
    }

    fn lookup(self, store: &Store, key: &[u8]) -> io::Result<Option<Vec<u8>>> {
        match self {
            Self::Point => store.get(key),
            Self::Range => {
                let mut after = key.to_vec();
                after.push(0);
                Ok(store.scan(key, &after)?.pop().map(|(_, value)| value))
            }
        }
    }
}

struct Projection {
    root: PathBuf,
    generation: u64,
    store: Store,
    keys: Keyring,
    read: ReadPath,
    changes: u64,
}

impl Projection {
    fn open(root: PathBuf, keys: Keyring, read: ReadPath) -> io::Result<Self> {
        let path = root.join("0");
        fs::create_dir(&path)?;
        let store = Store::open(&path)?;
        Ok(Self {
            root,
            generation: 0,
            store,
            keys,
            read,
            changes: 0,
        })
    }

    fn reset(&mut self) -> io::Result<()> {
        let next = self
            .generation
            .checked_add(1)
            .ok_or_else(|| io::Error::other("too many resets"))?;
        let path = self.root.join(next.to_string());
        fs::create_dir(&path)?;
        self.store = Store::open(&path)?;
        fs::remove_dir_all(self.root.join(self.generation.to_string()))?;
        self.generation = next;
        self.changes = 0;
        Ok(())
    }

    fn changed(&mut self) -> io::Result<()> {
        self.changes += 1;
        if self.changes.is_multiple_of(8) {
            self.store.flush()?;
        }
        if self.changes.is_multiple_of(64) {
            self.store.compact()?;
        }
        Ok(())
    }

    fn run(&mut self, fields: &[&str]) -> io::Result<String> {
        match fields {
            ["reset"] => self.reset()?,
            ["seal", key, plaintext] => {
                let envelope = self.keys.seal(&decode(key)?, &decode(plaintext)?)?;
                return Ok(encode(&envelope));
            }
            ["put", key, envelope] => {
                self.store.put(&decode(key)?, &decode(envelope)?)?;
                self.changed()?;
            }
            ["delete", key] => {
                self.store.delete(&decode(key)?)?;
                self.changed()?;
            }
            ["get", key] => {
                let key = decode(key)?;
                return match self.read.lookup(&self.store, &key)? {
                    Some(envelope) => Ok(format!(
                        "value {}",
                        encode(&self.keys.open(&key, &envelope)?)
                    )),
                    None => Ok("missing".into()),
                };
            }
            _ => return Err(io::Error::other("invalid projection command")),
        }
        Ok("ok".into())
    }
}

fn decode(hex: &str) -> io::Result<Vec<u8>> {
    let invalid = || io::Error::other("invalid hex payload");
    if !hex.len().is_multiple_of(2) || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(invalid());
    }
    hex.as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| {
            let pair = std::str::from_utf8(pair).map_err(|_| invalid())?;
            u8::from_str_radix(pair, 16).map_err(|_| invalid())
        })
        .collect()
}

fn encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(out, "{byte:02x}").unwrap();
    }
    out
}

fn serve(root: &Path, key_file: &Path, id: &str, path: &str) -> io::Result<()> {
    let active = id
        .parse()
        .map_err(|_| io::Error::other("invalid active key ID"))?;
    let mut view = Projection::open(
        root.to_owned(),
        Keyring::load(key_file, active)?,
        ReadPath::parse(path)?,
    )?;
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    writeln!(output, "ready")?;
    output.flush()?;
    let mut line = String::new();
    loop {
        line.clear();
        if input.by_ref().take(8193).read_line(&mut line)? == 0 {
            return Ok(());
        }
        let line = line
            .strip_suffix('\n')
            .filter(|line| line.len() <= 8192)
            .ok_or_else(|| io::Error::other("oversized or incomplete projection command"))?;
        let fields: Vec<_> = line.split('\t').collect();
        writeln!(output, "{}", view.run(&fields)?)?;
        output.flush()?;
    }
}

fn main() -> ExitCode {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [dir, keys, id, path] => serve(Path::new(dir), Path::new(keys), id, path),
        _ => Err(io::Error::other(
            "usage: kv-project DIR KEY_FILE ACTIVE_KEY_ID {range|point}",
        )),
    };
    if let Err(error) = result {
        eprintln!("{error}");
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}
~~~

Create `internal/metad/projection.go`.

<!-- file: internal/metad/projection.go -->
~~~go
package metad

import (
	"bufio"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type Projection struct {
	mu      sync.Mutex
	child   *exec.Cmd
	in, out *os.File
	lines   *bufio.Reader
	dir     string
	failed  bool
}

func OpenProjection(binary, root, keys, active, read string) (*Projection, error) {
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	dir, err := os.MkdirTemp(root, "view-")
	if err != nil {
		return nil, err
	}
	p, err := startProjection(binary, dir, keys, active, read)
	if err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	if line, err := p.read(); err != nil || line != "ready" {
		p.Close()
		return nil, errors.New("Rust projection failed to start")
	}
	return p, nil
}

func startProjection(binary, dir, keys, active, read string) (*Projection, error) {
	stdin, in, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	defer stdin.Close()
	out, stdout, err := os.Pipe()
	if err != nil {
		in.Close()
		return nil, err
	}
	defer stdout.Close()
	child := exec.Command(binary, dir, keys, active, read)
	child.Stdin, child.Stdout, child.Stderr = stdin, stdout, os.Stderr
	if err := child.Start(); err != nil {
		in.Close()
		out.Close()
		return nil, err
	}
	return &Projection{child: child, in: in, out: out, lines: bufio.NewReaderSize(out, 8192), dir: dir}, nil
}

func (p *Projection) read() (string, error) {
	if err := p.out.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		return "", err
	}
	line, err := p.lines.ReadSlice('\n')
	if err != nil {
		return "", err
	}
	return string(line[:len(line)-1]), nil
}

func (p *Projection) call(fields ...string) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.failed {
		return "", errors.New("projection must be reopened")
	}
	p.failed = true
	if err := p.in.SetWriteDeadline(time.Now().Add(2 * time.Second)); err != nil {
		return "", err
	}
	if _, err := io.WriteString(p.in, strings.Join(fields, "\t")+"\n"); err != nil {
		return "", err
	}
	response, err := p.read()
	p.failed = err != nil
	return response, err
}

func (p *Projection) ack(fields ...string) error {
	if result, err := p.call(fields...); err != nil {
		return err
	} else if result != "ok" {
		return errors.New("invalid projection acknowledgment")
	}
	return nil
}

func (p *Projection) seal(key, value string) (string, error) {
	return p.call("seal", key, hex.EncodeToString([]byte(value)))
}

func (p *Projection) get(key string) (Result, error) {
	response, err := p.call("get", key)
	if err != nil || response == "missing" {
		return Result{}, err
	}
	value, ok := strings.CutPrefix(response, "value ")
	if !ok {
		return Result{}, errors.New("invalid projection read response")
	}
	decoded, err := hex.DecodeString(value)
	return Result{Found: true, Value: string(decoded)}, err
}

func (p *Projection) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.failed = true
	p.in.Close()
	p.out.Close()
	p.child.Process.Kill()
	p.child.Wait()
	os.RemoveAll(p.dir)
}
~~~

</details>

### Step 3 — Apply the ordered history

Record the latest mutation receipt for each client and key. Preserve encrypted values and receipts in snapshots. Rebuild before exposing the snapshot’s applied index.

<details>
<summary>Hint</summary>

The Rust storage sequence is independent of Raft’s index. Rebuilding discards the uncertain old view.

</details>

<details>
<summary>Implementation</summary>

Create `internal/metad/kv_apply.go`.

<!-- file: internal/metad/kv_apply.go -->
~~~go
package metad

import (
	"errors"
	"maps"
	"slices"

	"switchyard/metad/internal/raft"
)

type kvReceipt struct {
	Sequence uint64
	Op       string
}

func (r *Runtime) EnableKV(projection *Projection, tokensPath string) error {
	if projection == nil {
		return errors.New("projection is required")
	}
	tokens, err := loadClientTokens(tokensPath)
	if err != nil {
		return err
	}
	r.kv, r.project = &kvAPI{tenants: tokens, seal: projection.seal}, projection
	return nil
}

func (r *Runtime) rebuild(s *state) error {
	if r.project == nil {
		if len(s.kvValues) != 0 || len(s.kvReceipts) != 0 {
			return errors.New("snapshot requires a Rust projection")
		}
		return nil
	}
	if err := r.project.ack("reset"); err != nil {
		return err
	}
	for _, key := range slices.Sorted(maps.Keys(s.kvValues)) {
		if err := r.project.ack("put", key, s.kvValues[key]); err != nil {
			return err
		}
	}
	return nil
}

func (r *Runtime) apply(s *state, entry raft.Applied) (Result, error) {
	command := entry.Command
	switch command.Op {
	case "kv_get", "kv_put", "kv_delete":
		if r.project == nil {
			return Result{}, errors.New("entry requires a Rust projection")
		}
	default:
		return s.apply(entry), nil
	}
	if command.Op == "kv_get" {
		return r.project.get(command.Key)
	}
	receipts := s.kvReceipts[command.Key]
	old := receipts[command.Client]
	if old.Sequence == command.Sequence && old.Op == command.Op {
		return Result{Found: true}, nil
	}
	if old.Sequence >= command.Sequence {
		return Result{Error: "stale or reused operation sequence"}, nil
	}

	if command.Op == "kv_put" {
		if err := r.project.ack("put", command.Key, command.Value); err != nil {
			return Result{}, err
		}
		s.kvValues[command.Key] = command.Value
	} else {
		if err := r.project.ack("delete", command.Key); err != nil {
			return Result{}, err
		}
		delete(s.kvValues, command.Key)
	}
	if receipts == nil {
		receipts = make(map[string]kvReceipt)
		s.kvReceipts[command.Key] = receipts
	}
	receipts[command.Client] = kvReceipt{Sequence: command.Sequence, Op: command.Op}
	return Result{Found: true}, nil
}
~~~

Find these regions in `internal/metad/state.go` in order.

<!-- edit: internal/metad/state.go -->
~~~go
}

type state struct {
	values  map[string]string
	retries map[string]map[string]receipt
	leases  map[string]lease
	now     int64
	span    rangeState
}

func newState() *state {
	return &state{values: make(map[string]string), leases: make(map[string]lease), retries: make(map[string]map[string]receipt)}
}

func (s *state) apply(entry raft.Applied) Result {
~~~

Replace the selected lines with this block.

~~~go
}

type state struct {
	kvValues   map[string]string
	kvReceipts map[string]map[string]kvReceipt
	values     map[string]string
	retries    map[string]map[string]receipt
	leases     map[string]lease
	now        int64
	span       rangeState
}

func newState() *state {
	return &state{kvValues: make(map[string]string), kvReceipts: make(map[string]map[string]kvReceipt), values: make(map[string]string), leases: make(map[string]lease), retries: make(map[string]map[string]receipt)}
}

func (s *state) apply(entry raft.Applied) Result {
~~~

Find these regions in `internal/metad/snapshot_state.go` in order.

<!-- edit: internal/metad/snapshot_state.go -->
~~~go
}

type snapshotState struct {
	Version int
	Values  map[string]string
	Retries map[string]map[string]receipt
	Leases  map[string]leaseRecord
	Now     int64
	Range   rangeState
}

func (s *state) encode() (string, error) {
	snapshot := snapshotState{
		Version: 1, Values: s.values, Retries: s.retries, Now: s.now, Range: s.span,
		Leases: make(map[string]leaseRecord, len(s.leases)),
	}
~~~

Replace the selected lines with this block.

~~~go
}

type snapshotState struct {
	KVValues   map[string]string               `json:",omitempty"`
	KVReceipts map[string]map[string]kvReceipt `json:",omitempty"`
	Version    int
	Values     map[string]string
	Retries    map[string]map[string]receipt
	Leases     map[string]leaseRecord
	Now        int64
	Range      rangeState
}

func (s *state) encode() (string, error) {
	snapshot := snapshotState{
		KVValues: s.kvValues, KVReceipts: s.kvReceipts,
		Version: 1, Values: s.values, Retries: s.retries, Now: s.now, Range: s.span,
		Leases: make(map[string]leaseRecord, len(s.leases)),
	}
~~~

<!-- edit: internal/metad/snapshot_state.go -->
~~~go
		return nil, errors.New("invalid snapshot version or missing state")
	}
	s := newState()
	s.values, s.retries, s.now, s.span = snapshot.Values, snapshot.Retries, snapshot.Now, snapshot.Range
	for key, l := range snapshot.Leases {
		s.leases[key] = lease{owner: l.Owner, token: l.Token, expires: l.Expires}
~~~

Replace the selected lines with this block.

~~~go
		return nil, errors.New("invalid snapshot version or missing state")
	}
	s := newState()
	if snapshot.KVValues != nil {
		s.kvValues = snapshot.KVValues
	}
	if snapshot.KVReceipts != nil {
		s.kvReceipts = snapshot.KVReceipts
	}
	s.values, s.retries, s.now, s.span = snapshot.Values, snapshot.Retries, snapshot.Now, snapshot.Range
	for key, l := range snapshot.Leases {
		s.leases[key] = lease{owner: l.Owner, token: l.Token, expires: l.Expires}
~~~

Find these regions in `internal/metad/runtime.go` in order.

<!-- edit: internal/metad/runtime.go -->
~~~go
type Runtime struct {
	rangeLab bool
	kv       *kvAPI
	id       int
	members  int
	node     *raft.Node
~~~

Replace the selected lines with this block.

~~~go
type Runtime struct {
	rangeLab bool
	kv       *kvAPI
	project  *Projection
	id       int
	members  int
	node     *raft.Node
~~~

<!-- edit: internal/metad/runtime.go -->
~~~go
		if err != nil {
			return fmt.Errorf("restore state at index %d: %w", snapshot.Index, err)
		}
	}
	status := Status{
		ID: r.id, Applied: snapshot.Index, Snapshot: snapshot.Index,
~~~

Replace the selected lines with this block.

~~~go
		if err != nil {
			return fmt.Errorf("restore state at index %d: %w", snapshot.Index, err)
		}
	}
	if err := r.rebuild(store); err != nil {
		return fmt.Errorf("rebuild projection: %w", err)
	}
	status := Status{
		ID: r.id, Applied: snapshot.Index, Snapshot: snapshot.Index,
~~~

<!-- edit: internal/metad/runtime.go -->
~~~go
			return fmt.Errorf("persist before sending: %w", err)
		}
		if installed != nil {
			store = installed
			status.Applied = ready.Save.Snapshot.Index
			status.Snapshot = status.Applied
~~~

Replace the selected lines with this block.

~~~go
			return fmt.Errorf("persist before sending: %w", err)
		}
		if installed != nil {
			if err := r.rebuild(installed); err != nil {
				return fmt.Errorf("install projection: %w", err)
			}
			store = installed
			status.Applied = ready.Save.Snapshot.Index
			status.Snapshot = status.Applied
~~~

<!-- edit: internal/metad/runtime.go -->
~~~go
			wire.send(message)
		}
		for _, entry := range ready.Applied {
			value := store.apply(entry)
			status.Applied = entry.Index
			payload, _ := json.Marshal(entry.Entry) // Entry has only JSON scalar fields.
			log.Printf("applied peer=%d index=%d term=%d digest=%x", r.id, entry.Index, entry.Term, sha256.Sum256(payload))
~~~

Replace the selected lines with this block.

~~~go
			wire.send(message)
		}
		for _, entry := range ready.Applied {
			value, err := r.apply(store, entry)
			if err != nil {
				return fmt.Errorf("apply at index %d: %w", entry.Index, err)
			}
			status.Applied = entry.Index
			payload, _ := json.Marshal(entry.Entry) // Entry has only JSON scalar fields.
			log.Printf("applied peer=%d index=%d term=%d digest=%x", r.id, entry.Index, entry.Term, sha256.Sum256(payload))
~~~

</details>

### Step 4 — Start the public endpoint

Add the engine, keyring, projection, and client flags to the existing Raft peer. Try the same exact lookup with both modes.

<details>
<summary>Hint</summary>

Test a present empty value and its next key. Reset should erase their local view.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `cmd/metad/main.go` in order.

<!-- edit: cmd/metad/main.go -->
~~~go
	routes := flag.String("peers", "", "comma-separated Unix socket paths in ID order")
	path := flag.String("wal", "", "path to this peer's klog")
	writer := flag.String("writer", "", "path to the metad-wal executable")
	rangeLab := flag.Bool("range-lab", false, "enable the local range-movement exercise")
	flag.Parse()
~~~

Replace the selected lines with this block.

~~~go
	routes := flag.String("peers", "", "comma-separated Unix socket paths in ID order")
	path := flag.String("wal", "", "path to this peer's klog")
	writer := flag.String("writer", "", "path to the metad-wal executable")
	clientAddr := flag.String("client", "", "loopback TCP address for the KV API")
	engine := flag.String("engine", "", "Rust projection executable")
	directory := flag.String("projection-root", "", "private projection directory")
	keys := flag.String("keyring", "", "external encryption keys")
	active := flag.String("active-key", "1", "active encryption key ID")
	tokens := flag.String("tenant-tokens", "", "local fixture credentials file")
	readPath := flag.String("read-path", "point", "point or range")
	rangeLab := flag.Bool("range-lab", false, "enable the local range-movement exercise")
	flag.Parse()
~~~

<!-- edit: cmd/metad/main.go -->
~~~go
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	node := metad.New(*id, len(peers), time.Now().UnixNano(), stable, disk)
	if *rangeLab {
		node.EnableRangeLab()
	}
	server := &http.Server{
~~~

Replace the selected lines with this block.

~~~go
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	node := metad.New(*id, len(peers), time.Now().UnixNano(), stable, disk)
	if *clientAddr != "" {
		host, _, err := net.SplitHostPort(*clientAddr)
		if err != nil || !net.ParseIP(host).IsLoopback() || *engine == "" ||
			*directory == "" || *keys == "" || *tokens == "" || *rangeLab {
			return errors.New("KV mode requires localhost, a projection, credentials, and keys")
		}
		project, err := metad.OpenProjection(*engine, *directory, *keys, *active, *readPath)
		if err != nil {
			return err
		}
		defer project.Close()
		if err := node.EnableKV(project, *tokens); err != nil {
			return err
		}
		clientListener, err := net.Listen("tcp", *clientAddr)
		if err != nil {
			return err
		}
		defer clientListener.Close()
		client := &http.Server{
			Handler: node.ClientHandler(), ReadTimeout: time.Second, WriteTimeout: 2 * time.Second,
		}
		defer client.Close()
		go func() { client.Serve(clientListener); stop() }()
		log.Printf("kv client=%s", clientListener.Addr())
	} else if *rangeLab {
		node.EnableRangeLab()
	}
	server := &http.Server{
~~~

Create `internal/metad/projection_test.go`.

<!-- file: internal/metad/projection_test.go -->
~~~go
package metad

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProjectionReadPathsAgree(t *testing.T) {
	engine := os.Getenv("KV_ENGINE")
	if engine == "" {
		t.Skip("build kv-project and set KV_ENGINE")
	}
	dir := t.TempDir()
	keyring := filepath.Join(dir, "keys")
	if err := os.WriteFile(keyring, []byte("1:"+strings.Repeat("34", 32)+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	key := encodeTenantKey("a", "job")
	neighbor := encodeTenantKey("a", "job\x00")
	for _, mode := range []string{"range", "point"} {
		t.Run(mode, func(t *testing.T) {
			p, err := OpenProjection(engine, dir, keyring, "1", mode)
			if err != nil {
				t.Fatal(err)
			}
			defer p.Close()
			for key, value := range map[string]string{key: "", neighbor: "next"} {
				cipher, err := p.seal(key, value)
				if err != nil {
					t.Fatal(err)
				}
				if err := p.ack("put", key, cipher); err != nil {
					t.Fatal(err)
				}
			}
			if got, err := p.get(key); err != nil || !got.Found || got.Value != "" {
				t.Fatalf("exact lookup returned %+v: %v", got, err)
			}
			if err := p.ack("delete", key); err != nil {
				t.Fatal(err)
			}
			if got, err := p.get(key); err != nil || got.Found {
				t.Fatalf("neighbor appeared in exact lookup: %+v: %v", got, err)
			}
			if err := p.ack("reset"); err != nil {
				t.Fatal(err)
			}
			if got, err := p.get(neighbor); err != nil || got.Found {
				t.Fatalf("old generation was still visible: %+v: %v", got, err)
			}
		})
	}
	t.Log("both modes distinguished a present empty value, its next key, and a fresh projection")
}
~~~

</details>

## Check it

~~~bash
cargo build --locked --quiet --manifest-path storage/Cargo.toml --bin kv-project
target=$(cargo metadata --manifest-path storage/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')
KV_ENGINE="$target/debug/kv-project" go test -race -count=1 -v ./internal/metad -run TestProjectionReadPathsAgree
~~~

<!-- run: cargo build --locked --quiet --manifest-path storage/Cargo.toml --bin kv-project && target=$(cargo metadata --manifest-path storage/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])') && KV_ENGINE="$target/debug/kv-project" go test -race -count=1 -v ./internal/metad -run TestProjectionReadPathsAgree -->

Both modes distinguished a present empty value, its immediate successor key, and a fresh projection.

## If it goes wrong

If copies diverge after restart, compare the snapshot image and applied suffix. If a client gets a reply before the Rust operation finishes, check the runtime’s pending-reply branch.
