# 01 Define the replicated client contract

> Distributed KV capstone · Week 1 · Builds on lesson 00

## The problem

Two tenants can use the same logical key. A client can lose a response and retry the write on a different leader. The API must keep the tenants separate and give the retry a stable identity.

## The mental model

Authenticate the request, encode the tenant and key into one ordered key, seal a put’s value, and submit the ciphertext command to Raft. The caller uses the same client ID and sequence if a reply is indeterminate.

## The pattern

The capstone uses temporary bearer credentials on a loopback listener. The accepted token determines the tenant. The client supplies the key and request identity. The transport prepares the command before the runtime sees it.

## Build it

### Step 1 — Specify success and uncertainty

List responses for a missing value, a stale sequence, a follower, and a timeout. A successful put or delete returns a receipt without its plaintext.

<details>
<summary>Hint</summary>

A timeout can occur after commit. Keep the mutation identity across retries.

</details>

### Step 2 — Scope and seal proposals

Use the same length-prefixed tenant encoding as the storage lesson. Pass the composite key into the sealer and retain only ciphertext in the Raft command.

<details>
<summary>Hint</summary>

The public body never selects the tenant, and Raft sees a prepared command.

</details>

<details>
<summary>Implementation</summary>

Create `internal/metad/kv_api.go`.

<!-- file: internal/metad/kv_api.go -->
~~~go
package metad

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"

	"switchyard/metad/internal/raft"
)

var identifier = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)

type kvAPI struct {
	tenants map[[32]byte]string
	seal    func(string, string) (string, error)
}

type ClientCommand struct {
	Op       string `json:"op"`
	Key      string `json:"key"`
	Value    string `json:"value,omitempty"`
	Client   string `json:"client,omitempty"`
	Sequence uint64 `json:"sequence,omitempty"`
}

func loadClientTokens(path string) (map[[32]byte]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	var input map[string]string
	decoder := json.NewDecoder(io.LimitReader(file, 16<<10))
	if err := decoder.Decode(&input); err != nil || decoder.Decode(new(any)) != io.EOF || len(input) == 0 {
		return nil, errors.New("invalid tenant token file")
	}
	tokens := make(map[[32]byte]string, len(input))
	for tenant, token := range input {
		digest := sha256.Sum256([]byte(token))
		if !identifier.MatchString(tenant) || len(token) < 16 || len(token) > 256 ||
			strings.ContainsAny(token, " \t\r\n") || tokens[digest] != "" {
			return nil, errors.New("invalid or duplicate tenant credentials")
		}
		tokens[digest] = tenant
	}
	return tokens, nil
}

func encodeTenantKey(tenant, key string) string {
	bytes := []byte{0, byte(len(tenant))}
	bytes = append(bytes, tenant...)
	return hex.EncodeToString(append(bytes, key...))
}

func (api *kvAPI) proposal(tenant string, req ClientCommand) (raft.Command, int) {
	if len(req.Key) > 192 || len(req.Value) > 512 {
		return raft.Command{}, http.StatusBadRequest
	}
	command := raft.Command{Key: encodeTenantKey(tenant, req.Key)}
	switch {
	case req.Op == "get" && req.Client == "" && req.Sequence == 0 && req.Value == "":
		command.Op = "kv_get"
	case (req.Op == "put" || req.Op == "delete") && identifier.MatchString(req.Client) && req.Sequence > 0:
		command.Op, command.Client, command.Sequence = "kv_"+req.Op, req.Client, req.Sequence
		if req.Op == "delete" {
			if req.Value != "" {
				return raft.Command{}, http.StatusBadRequest
			}
		} else {
			sealed, err := api.seal(command.Key, req.Value)
			if err != nil {
				return raft.Command{}, http.StatusServiceUnavailable
			}
			command.Value = sealed
		}
	default:
		return raft.Command{}, http.StatusBadRequest
	}
	return command, http.StatusOK
}

func (r *Runtime) ClientHandler() http.Handler {
	mux := http.NewServeMux()
	if r.kv != nil {
		mux.HandleFunc("POST /kv", r.clientCommand)
		mux.HandleFunc("GET /status", r.getStatus)
	}
	return mux
}

func (r *Runtime) clientCommand(w http.ResponseWriter, req *http.Request) {
	token, ok := strings.CutPrefix(req.Header.Get("Authorization"), "Bearer ")
	tenant := r.kv.tenants[sha256.Sum256([]byte(token))]
	if !ok || tenant == "" {
		http.Error(w, "invalid credentials", http.StatusUnauthorized)
		return
	}
	var input ClientCommand
	if !decode(w, req, 4<<10, &input) {
		http.Error(w, "invalid command", http.StatusBadRequest)
		return
	}
	command, status := r.kv.proposal(tenant, input)
	if status != http.StatusOK {
		w.WriteHeader(status)
		return
	}
	r.submit(w, req.Context(), command)
}
~~~

</details>

### Step 3 — Separate the public and peer listeners

Register the public API on its own listener. Keep the raw command handler available for the old lab and disable it in KV mode.

<details>
<summary>Hint</summary>

A public request must enter through the authorization wrapper.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `internal/metad/http.go` in order.

<!-- edit: internal/metad/http.go -->
~~~go
func (r *Runtime) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /raft", r.receive)
	mux.HandleFunc("POST /command", r.command)
	mux.HandleFunc("GET /status", r.getStatus)
	return mux
}
~~~

Replace the selected lines with this block.

~~~go
func (r *Runtime) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /raft", r.receive)
	if r.kv == nil {
		mux.HandleFunc("POST /command", r.command)
	}
	mux.HandleFunc("GET /status", r.getStatus)
	return mux
}
~~~

<!-- edit: internal/metad/http.go -->
~~~go
		http.Error(w, "invalid command", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), 900*time.Millisecond)
	defer cancel()
	p := proposal{ctx: ctx, command: command, reply: make(chan outcome, 1)}
	select {
~~~

Replace the selected lines with this block.

~~~go
		http.Error(w, "invalid command", http.StatusBadRequest)
		return
	}
	r.submit(w, req.Context(), command)
}

func (r *Runtime) submit(w http.ResponseWriter, request context.Context, command raft.Command) {
	ctx, cancel := context.WithTimeout(request, 900*time.Millisecond)
	defer cancel()
	p := proposal{ctx: ctx, command: command, reply: make(chan outcome, 1)}
	select {
~~~

Find these regions in `internal/metad/runtime.go` in order.

<!-- edit: internal/metad/runtime.go -->
~~~go

type Runtime struct {
	rangeLab bool
	id       int
	members  int
	node     *raft.Node
~~~

Replace the selected lines with this block.

~~~go

type Runtime struct {
	rangeLab bool
	kv       *kvAPI
	id       int
	members  int
	node     *raft.Node
~~~

</details>

### Step 4 — Check the boundary before networking

Use a fixture sealer to inspect the completed proposal. Verify that missing credentials get 401.

<details>
<summary>Hint</summary>

Two differently split tenant-and-key pairs must still produce different physical keys.

</details>

<details>
<summary>Implementation</summary>

Create `internal/metad/kv_api_test.go`.

<!-- file: internal/metad/kv_api_test.go -->
~~~go
package metad

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCapstoneProposalSealsBeforeRaft(t *testing.T) {
	api := &kvAPI{seal: func(key, value string) (string, error) {
		if key != "0001616a6f62" || value != "private" {
			t.Fatalf("sealer received %q and %q", key, value)
		}
		return "fixture-ciphertext", nil
	}}
	command, status := api.proposal("a", ClientCommand{
		Op: "put", Key: "job", Value: "private", Client: "client", Sequence: 1,
	})
	if status != http.StatusOK || command.Value != "fixture-ciphertext" || command.Sequence != 1 {
		t.Fatalf("unexpected proposal %+v, %d", command, status)
	}
	if encodeTenantKey("a", "bc") == encodeTenantKey("ab", "c") {
		t.Fatal("tenant encoding collided")
	}
	runtime := &Runtime{kv: api}
	response := httptest.NewRecorder()
	runtime.ClientHandler().ServeHTTP(response, httptest.NewRequest("POST", "/kv", nil))
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated request got %d", response.Code)
	}
	t.Log("authenticated put carries ciphertext and a tenant-scoped key")
}
~~~

</details>

## Check it

~~~bash
go test -race -count=1 -v ./internal/metad -run TestCapstoneProposal
~~~

<!-- run: go test -race -count=1 -v ./internal/metad -run TestCapstoneProposal -->

The test reports that the authenticated put carries ciphertext and a tenant-scoped key.

## If it goes wrong

If the command contains the supplied plaintext, move sealing before proposal construction. If a request has no tenant, verify its token lookup before decoding the body.
