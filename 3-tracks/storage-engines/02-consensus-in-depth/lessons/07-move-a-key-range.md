# 07 Move a key range between replica groups

> Consensus in depth · Week 4 · Builds on lesson 06

## The problem

Copying keys while the source still accepts writes can leave the destination with an out-of-date copy. A canceled mover also needs a way to resume after the source has already stopped taking writes.

## The mental model

Group A serves the range [m,n) at epoch 1. The freeze entry is ordered after earlier writes in A’s Raft log. Group B loads the frozen image at epoch 2. It starts serving once activation commits. A request already headed to A meets a replicated fence.

## The pattern

An epoch is a monotonically increasing routing version. The state machine checks it when applying requests, so in-flight work is ordered with the fence. The move carries cached mutation results as well as key values. This lab moves one bounded range between fixed groups with writes paused during handoff.

## Build it

### Step 1 — Fence the source and load the destination

Define the range states and the four commands. Work out which operations can be repeated safely after a process restart.

<details>
<summary>Hint 1</summary>

A repeated freeze returns the same immutable image.

</details>

<details>
<summary>Hint 2</summary>

After activation, the digest makes a duplicate import safe without replacing the destination’s newer values.

</details>

<details>
<summary>Implementation</summary>

Create `internal/metad/range.go`.

<!-- file: internal/metad/range.go -->
~~~go
package metad

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"

	"switchyard/metad/internal/raft"
)

const maxImage = 12 << 10

type rangeState struct {
	Phase  string
	Epoch  uint64
	Digest [32]byte
}

type rangeImage struct {
	Values  map[string]string
	Retries map[string]map[string]receipt
}

func inRange(key string) bool { return key >= "m" && key < "n" }

func movement(op string) bool {
	switch op {
	case "range_init", "range_freeze", "range_import", "range_activate":
		return true
	default:
		return false
	}
}

func validMove(c raft.Command) bool {
	switch c.Op {
	case "range_init":
		return c == (raft.Command{Op: c.Op, Epoch: 1, Value: "source"}) ||
			c == (raft.Command{Op: c.Op, Epoch: 1, Value: "destination"})
	case "range_import":
		return c == (raft.Command{Op: c.Op, Epoch: 2, Value: c.Value}) &&
			len(c.Value) > 0 && len(c.Value) <= maxImage
	default:
		return c == (raft.Command{Op: c.Op, Epoch: 2})
	}
}

func (s *state) move(c raft.Command) Result {
	switch c.Op {
	case "range_init":
		if s.span.Phase == "" {
			phase := "empty"
			if c.Value == "source" {
				for key := range s.leases {
					if inRange(key) {
						return Result{Error: "range contains a lease"}
					}
				}
				phase = "active"
			} else {
				for key := range s.values {
					if inRange(key) {
						return Result{Error: "destination range is populated"}
					}
				}
				for key := range s.retries {
					if inRange(key) {
						return Result{Error: "destination range has retry receipts"}
					}
				}
			}
			s.span = rangeState{Phase: phase, Epoch: c.Epoch}
			return Result{Found: true}
		}
	case "range_freeze":
		if s.span.Phase == "active" && s.span.Epoch == c.Epoch-1 {
			image := s.exportRange()
			if image.Error == "" {
				s.span = rangeState{Phase: "frozen", Epoch: c.Epoch}
			}
			return image
		}
		if s.span.Phase == "frozen" && s.span.Epoch == c.Epoch {
			return s.exportRange()
		}
	case "range_import":
		digest := sha256.Sum256([]byte(c.Value))
		if s.span.Phase == "empty" && s.span.Epoch == c.Epoch-1 {
			if s.importRange(c.Value) {
				s.span = rangeState{Phase: "loaded", Epoch: c.Epoch, Digest: digest}
				return Result{Found: true}
			}
		}
		if (s.span.Phase == "loaded" || s.span.Phase == "active") &&
			s.span.Epoch == c.Epoch && s.span.Digest == digest {
			return Result{Found: true}
		}
	case "range_activate":
		if s.span.Epoch == c.Epoch && (s.span.Phase == "loaded" || s.span.Phase == "active") {
			s.span.Phase = "active"
			return Result{Found: true}
		}
	}
	return Result{Error: "range transition refused"}
}

func (s *state) exportRange() Result {
	image := rangeImage{
		Values: make(map[string]string), Retries: make(map[string]map[string]receipt),
	}
	for key, value := range s.values {
		if inRange(key) {
			image.Values[key] = value
		}
	}
	for key, clients := range s.retries {
		if inRange(key) {
			image.Retries[key] = clients
		}
	}
	body, err := json.Marshal(image)
	if err != nil || base64.StdEncoding.EncodedLen(len(body)) > maxImage {
		return Result{Error: "range image exceeds lab limit"}
	}
	return Result{Found: true, Value: base64.StdEncoding.EncodeToString(body)}
}

func (s *state) importRange(encoded string) bool {
	body, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return false
	}
	var image rangeImage
	if json.Unmarshal(body, &image) != nil || image.Values == nil || image.Retries == nil {
		return false
	}
	for key := range image.Values {
		if !inRange(key) {
			return false
		}
	}
	for key, clients := range image.Retries {
		if !inRange(key) {
			return false
		}
		for client, retry := range clients {
			c := retry.Command
			if client == "" || c.Client != client || c.Key != key || c.Sequence == 0 ||
				(c.Op != "put" && c.Op != "cas") || !validCommand(c) || c.Epoch != 0 {
				return false
			}
		}
	}
	for key, value := range image.Values {
		s.values[key] = value
	}
	for key, clients := range image.Retries {
		s.retries[key] = clients
	}
	return true
}
~~~

Find these blocks in `internal/raft/replication.go` in order.

<!-- edit: internal/raft/replication.go -->
~~~go
type Command struct {
	Op, Key, Value string
	Client         string `json:",omitempty"`
	Sequence       uint64 `json:",omitempty"`
	Expect         string `json:",omitempty"`
	Owner          string `json:",omitempty"`
~~~

Replace it with this version.

~~~go
type Command struct {
	Op, Key, Value string
	Client         string `json:",omitempty"`
	Epoch          uint64 `json:",omitempty"`
	Sequence       uint64 `json:",omitempty"`
	Expect         string `json:",omitempty"`
	Owner          string `json:",omitempty"`
~~~

Find these blocks in `internal/metad/state.go` in order.

<!-- edit: internal/metad/state.go -->
~~~go
	retries map[string]map[string]receipt
	leases  map[string]lease
	now     int64
}

func newState() *state {
~~~

Replace it with this version.

~~~go
	retries map[string]map[string]receipt
	leases  map[string]lease
	now     int64
	span    rangeState
}

func newState() *state {
~~~

<!-- edit: internal/metad/state.go -->
~~~go

func (s *state) apply(entry raft.Applied) Result {
	command := entry.Command
	switch command.Op {
	case "put", "cas":
		return s.mutate(command)
~~~

Replace it with this version.

~~~go

func (s *state) apply(entry raft.Applied) Result {
	command := entry.Command
	if movement(command.Op) {
		return s.move(command)
	}
	if command.Op != "" && inRange(command.Key) && s.span.Phase != "" {
		if s.span.Phase != "active" || command.Epoch != s.span.Epoch ||
			(leaseOperation(command.Op)) {
			return Result{Error: "range unavailable at this epoch"}
		}
	}
	switch command.Op {
	case "put", "cas":
		return s.mutate(command)
~~~

</details>

### Step 2 — Carry the fence and the receipts

Store the epoch in snapshots. Keep it out of the mutation identity so a valid retry can follow the range to a new owner.

<details>
<summary>Hint 1</summary>

An old route needs rejection even if it supplies a known client sequence.

</details>

<details>
<summary>Hint 2</summary>

Check both the routing epoch and the current range phase before touching a value.

</details>

<details>
<summary>Implementation</summary>

Find these blocks in `internal/metad/kv.go` in order.

<!-- edit: internal/metad/kv.go -->
~~~go
}

func (s *state) mutate(command raft.Command) Result {
	clients := s.retries[command.Key]
	if previous, exists := clients[command.Client]; exists {
		switch {
~~~

Replace it with this version.

~~~go
}

func (s *state) mutate(command raft.Command) Result {
	// Epoch belongs to routing, so a retry after a move keeps its identity.
	command.Epoch = 0
	clients := s.retries[command.Key]
	if previous, exists := clients[command.Client]; exists {
		switch {
~~~

Find these blocks in `internal/metad/snapshot_state.go` in order.

<!-- edit: internal/metad/snapshot_state.go -->
~~~go
	Retries map[string]map[string]receipt
	Leases  map[string]leaseRecord
	Now     int64
}

func (s *state) encode() (string, error) {
	snapshot := snapshotState{
		Version: 1, Values: s.values, Retries: s.retries, Now: s.now,
		Leases: make(map[string]leaseRecord, len(s.leases)),
	}
	for key, l := range s.leases {
~~~

Replace it with this version.

~~~go
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
	for key, l := range s.leases {
~~~

<!-- edit: internal/metad/snapshot_state.go -->
~~~go
		return nil, errors.New("invalid snapshot version or missing state")
	}
	s := newState()
	s.values, s.retries, s.now = snapshot.Values, snapshot.Retries, snapshot.Now
	for key, l := range snapshot.Leases {
		s.leases[key] = lease{owner: l.Owner, token: l.Token, expires: l.Expires}
	}
~~~

Replace it with this version.

~~~go
		return nil, errors.New("invalid snapshot version or missing state")
	}
	s := newState()
	s.values, s.retries, s.now, s.span = snapshot.Values, snapshot.Retries, snapshot.Now, snapshot.Range
	for key, l := range snapshot.Leases {
		s.leases[key] = lease{owner: l.Owner, token: l.Token, expires: l.Expires}
	}
~~~

</details>

### Step 3 — Drive two real groups

Enable the range commands on disposable peers with `-range-lab`. Restart a source peer after the fence and reconstruct the image from a replicated request.

<details>
<summary>Hint 1</summary>

Test the old route and a destination request before activation.

</details>

<details>
<summary>Hint 2</summary>

After cutover, retry both a successful and an unsuccessful CAS and read the current values.

</details>

<details>
<summary>Implementation</summary>

Find these blocks in `internal/metad/http.go` in order.

<!-- edit: internal/metad/http.go -->
~~~go

func (r *Runtime) command(w http.ResponseWriter, req *http.Request) {
	var command raft.Command
	if !decode(w, req, 8<<10, &command) || !validCommand(command) {
		http.Error(w, "invalid command", http.StatusBadRequest)
		return
	}
~~~

Replace it with this version.

~~~go

func (r *Runtime) command(w http.ResponseWriter, req *http.Request) {
	var command raft.Command
	if !decode(w, req, 16<<10, &command) {
		http.Error(w, "invalid command", http.StatusBadRequest)
		return
	}
	valid := validCommand(command) && (command.Epoch == 0 || r.rangeLab)
	if movement(command.Op) {
		valid = r.rangeLab && validMove(command)
	}
	if !valid {
		http.Error(w, "invalid command", http.StatusBadRequest)
		return
	}
~~~

Find these blocks in `internal/metad/runtime.go` in order.

<!-- edit: internal/metad/runtime.go -->
~~~go
}

type Runtime struct {
	id       int
	members  int
	node     *raft.Node
~~~

Replace it with this version.

~~~go
}

type Runtime struct {
	rangeLab bool
	id       int
	members  int
	node     *raft.Node
~~~

<!-- edit: internal/metad/runtime.go -->
~~~go
		status: make(chan chan Status),
	}
}

func (r *Runtime) Run(ctx context.Context, routes []string) error {
	wire := newTransport(ctx, r.id, routes)
~~~

Replace it with this version.

~~~go
		status: make(chan chan Status),
	}
}

// EnableRangeLab configures a disposable peer before it starts serving.
func (r *Runtime) EnableRangeLab() { r.rangeLab = true }

func (r *Runtime) Run(ctx context.Context, routes []string) error {
	wire := newTransport(ctx, r.id, routes)
~~~

Find these blocks in `cmd/metad/main.go` in order.

<!-- edit: cmd/metad/main.go -->
~~~go
	routes := flag.String("peers", "", "comma-separated Unix socket paths in ID order")
	path := flag.String("wal", "", "path to this peer's klog")
	writer := flag.String("writer", "", "path to the metad-wal executable")
	flag.Parse()

	peers := strings.Split(*routes, ",")
~~~

Replace it with this version.

~~~go
	routes := flag.String("peers", "", "comma-separated Unix socket paths in ID order")
	path := flag.String("wal", "", "path to this peer's klog")
	writer := flag.String("writer", "", "path to the metad-wal executable")
	rangeLab := flag.Bool("range-lab", false, "enable the local range-movement exercise")
	flag.Parse()

	peers := strings.Split(*routes, ",")
~~~

<!-- edit: cmd/metad/main.go -->
~~~go
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	node := metad.New(*id, len(peers), time.Now().UnixNano(), stable, disk)
	server := &http.Server{
		Handler: node.Handler(), ReadTimeout: time.Second, WriteTimeout: 2 * time.Second,
		IdleTimeout: 3 * time.Second,
~~~

Replace it with this version.

~~~go
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	node := metad.New(*id, len(peers), time.Now().UnixNano(), stable, disk)
	if *rangeLab {
		node.EnableRangeLab()
	}
	server := &http.Server{
		Handler: node.Handler(), ReadTimeout: time.Second, WriteTimeout: 2 * time.Second,
		IdleTimeout: 3 * time.Second,
~~~

Find these blocks in `lab/consensus.py` in order.

<!-- edit: lab/consensus.py -->
~~~python
core_gate = Path(os.environ["BLUEPRINT_ROOT"]) / "2-core/07-distributed-systems-fundamentals/gate"
sys.path.insert(0, str(core_gate))
from verify import Cluster, until  # noqa: E402


def result(cluster, peer, op, key="", value="", **fields):
~~~

Replace it with this version.

~~~python
core_gate = Path(os.environ["BLUEPRINT_ROOT"]) / "2-core/07-distributed-systems-fundamentals/gate"
sys.path.insert(0, str(core_gate))
from verify import Cluster, until  # noqa: E402


class RangeCluster(Cluster):
    def args(self, peer, wal=None):
        return [*super().args(peer, wal), "-range-lab"]


def result(cluster, peer, op, key="", value="", **fields):
~~~

<!-- edit: lab/consensus.py -->
~~~python
    check_files(checker, directory, rows)


def main(metad, writer, checker, output):
    with tempfile.TemporaryDirectory(prefix="st02-", dir="/tmp") as temporary:
        with Cluster(Path(temporary), metad, writer) as cluster:
            recover(cluster, checker, output)


if __name__ == "__main__":
    phase, *paths = sys.argv[1:]
    if phase != "recovery":
        raise ValueError(f"unknown live check {phase}")
    main(*(Path(arg) for arg in paths))
~~~

Replace it with this version.

~~~python
    check_files(checker, directory, rows)


def move(source, dest):
    a, b = source.leader()["ID"], dest.leader()["ID"]
    assert result(source, a, "range_init", value="source", Epoch=1)["found"]
    assert result(dest, b, "range_init", value="destination", Epoch=1)["found"]
    swap = {"Expect": "queued", "Client": "worker", "Sequence": 1}
    assert result(source, a, "put", "m/job", "queued", Epoch=1)["found"]
    receipt = result(source, a, "cas", "m/job", "running", Epoch=1, **swap)
    assert receipt["swapped"]
    assert result(source, a, "put", "m/job", "done", Epoch=1)["found"]
    assert result(source, a, "put", "m/second", "kept", Epoch=1)["found"]
    missing = result(source, a, "cas", "m/missing", "created", Epoch=1, **swap)
    assert missing == {"found": False}
    assert result(source, a, "put", "m/missing", "queued", Epoch=1)["found"]
    source.write(a, "outside", "stays")
    frozen = result(source, a, "range_freeze", Epoch=2)
    assert frozen["found"]
    source.stop(a, force=True)
    source.start(a)
    del frozen  # A restarted mover has to recover the image from a committed transition.
    new_a = source.leader()["ID"]
    assert "error" in result(source, new_a, "put", "m/job", "stale", Epoch=1)
    assert "error" in result(dest, b, "put", "m/job", "early", Epoch=2)
    image = result(source, new_a, "range_freeze", Epoch=2)["value"]
    assert result(dest, b, "range_import", value=image, Epoch=2)["found"]
    assert "error" in result(dest, b, "get", "m/job", Epoch=2)
    assert result(dest, b, "range_import", value=image, Epoch=2)["found"]
    assert result(dest, b, "range_activate", Epoch=2)["found"]
    assert "error" in result(dest, b, "get", "m/job", Epoch=1)
    assert result(dest, b, "cas", "m/job", "running", Epoch=2, **swap) == receipt
    assert result(dest, b, "cas", "m/missing", "created", Epoch=2, **swap) == missing
    assert result(dest, b, "get", "m/job", Epoch=2)["value"] == "done"
    assert result(dest, b, "get", "m/second", Epoch=2)["value"] == "kept"
    assert result(dest, b, "get", "m/missing", Epoch=2)["value"] == "queued"
    assert result(source, new_a, "get", "outside")["value"] == "stays"
    assert not result(dest, b, "get", "outside")["found"]
    assert "error" in result(source, new_a, "put", "m/job", "wrong group", Epoch=2)
    assert result(dest, b, "put", "m/job", "new owner", Epoch=2)["found"]
    source.check_history()
    dest.check_history()
    print("range [m,n): epoch 1 fenced, epoch 2 activated, three values and two retry receipts preserved")


def main(mode, metad, writer, checker, output):
    with tempfile.TemporaryDirectory(prefix="st02-", dir="/tmp") as temporary:
        root = Path(temporary)
        if mode == "recovery":
            with Cluster(root, metad, writer) as cluster:
                recover(cluster, checker, output)
        elif mode == "range":
            (root / "a").mkdir()
            (root / "b").mkdir()
            with RangeCluster(root / "a", metad, writer) as source, RangeCluster(root / "b", metad, writer) as dest:
                move(source, dest)
        else:
            raise ValueError(f"unknown live check {mode}")


if __name__ == "__main__":
    mode, metad, writer, checker, output = sys.argv[1:]
    main(mode, Path(metad), Path(writer), Path(checker), Path(output))
~~~

</details>

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/02-consensus-in-depth/gate/run.sh" "$PWD" range
~~~

<!-- run: test -z "$(gofmt -l cmd internal)" && go vet ./... && go test -race -count=1 ./... -->

The gate reported `epoch 1 fenced, epoch 2 activated, three values and two retry receipts preserved`. The lab uses a trusted local coordinator to relay the frozen image and activate the destination.

## If it goes wrong

If the stale route still writes, check the state-machine guard. If a replayed CAS changes the value, check that the image includes its receipt and that its command identity is independent of the epoch.
