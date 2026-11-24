# 05 Deliver signed events to registered destinations

> The proxy’s control plane · Week 2 · Builds on lesson 04

## The problem

A receiver needs to authenticate the exact delivered event and handle a legitimate retry. The sender also needs a policy for where event deliveries can go.

## The mental model

An event carries its key version, timestamp, ID, and exact body. Check its freshness and MAC before touching receipt state. The destination alias is resolved from the trusted registry to a numeric loopback address and a fixed route.

## The pattern

Sign the envelope and compare the expected MAC in constant time. Refuse destinations outside the registry and stop at redirects. Store an event once by ID and body digest. In this lab the bounded inbox is in memory, so its deduplication lifetime is the receiver process lifetime.

## Build it

### Step 1 — Define the signed envelope and receipt rule

Decide how the receiver treats a matching duplicate, an expired request, and a duplicate ID carrying a different body.

<details>
<summary>Hint</summary>

Only verified requests can reach the receipt ledger.

</details>

<details>
<summary>Implementation</summary>

Create `control/webhook.go`.

<!-- file: control/webhook.go -->
~~~go
package control

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
)

const eventLimit = 8 * 1024

type SigningKey struct {
	Version uint64
	Secret  []byte
}

type Deliverer struct {
	Destinations map[string]netip.AddrPort
}

func validID(id string) bool {
	return len(id) > 0 && len(id) <= 64 && strings.IndexFunc(id, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-')
	}) == -1
}

func eventMAC(key []byte, version, timestamp, id string, body []byte) []byte {
	hash := hmac.New(sha256.New, key)
	fmt.Fprintf(hash, "%s\n%s\n%s\n", version, timestamp, id)
	hash.Write(body)
	return hash.Sum(nil)
}

func eventRequest(ctx context.Context, destination string, key SigningKey, now time.Time, id string, body []byte) (*http.Request, error) {
	if !validID(id) || key.Version == 0 || len(key.Secret) < 32 || len(body) > eventLimit {
		return nil, errors.New("invalid event or signing key")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, destination, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	version := strconv.FormatUint(key.Version, 10)
	timestamp := strconv.FormatInt(now.Unix(), 10)
	req.Header.Set("X-Event-ID", id)
	req.Header.Set("X-Event-Time", timestamp)
	req.Header.Set("X-Key-Version", version)
	req.Header.Set("X-Event-MAC", hex.EncodeToString(eventMAC(key.Secret, version, timestamp, id, body)))
	return req, nil
}

func (d Deliverer) Send(ctx context.Context, destination string, key SigningKey, now time.Time, id string, body []byte) error {
	address, found := d.Destinations[destination]
	if !found || !address.Addr().IsLoopback() || address.Port() == 0 {
		return errors.New("destination outside the configured allowlist")
	}
	req, err := eventRequest(ctx, "http://"+address.String()+"/events", key, now, id, body)
	if err != nil {
		return err
	}
	resp, err := requestClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("delivery refused: HTTP %d", resp.StatusCode)
	}
	return nil
}

type Inbox struct {
	mu   sync.Mutex
	seen map[string][32]byte
}

func (in *Inbox) Count() int {
	in.mu.Lock()
	defer in.mu.Unlock()
	return len(in.seen)
}

func (in *Inbox) Handler(lookup func(uint64) []byte, clock func() time.Time) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /events", func(w http.ResponseWriter, r *http.Request) {
		id, timestamp, version := r.Header.Get("X-Event-ID"), r.Header.Get("X-Event-Time"), r.Header.Get("X-Key-Version")
		seconds, timeErr := strconv.ParseInt(timestamp, 10, 64)
		keyVersion, versionErr := strconv.ParseUint(version, 10, 64)
		signature, macErr := hex.DecodeString(r.Header.Get("X-Event-MAC"))
		now := clock()
		date := time.Unix(seconds, 0)
		if !validID(id) || timeErr != nil || versionErr != nil || macErr != nil ||
			date.Before(now.Add(-time.Minute)) || date.After(now.Add(5*time.Second)) {
			http.Error(w, "event rejected", http.StatusUnauthorized)
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, eventLimit))
		secret := lookup(keyVersion)
		if err != nil || len(secret) < 32 ||
			!hmac.Equal(signature, eventMAC(secret, version, timestamp, id, body)) {
			http.Error(w, "event rejected", http.StatusUnauthorized)
			return
		}

		digest := sha256.Sum256(body)
		in.mu.Lock()
		defer in.mu.Unlock()
		if in.seen == nil {
			in.seen = make(map[string][32]byte)
		}
		if existing, seen := in.seen[id]; seen {
			if existing != digest {
				http.Error(w, "event identity conflict", http.StatusConflict)
				return
			}
		} else {
			if len(in.seen) >= 1024 {
				http.Error(w, "inbox full", http.StatusServiceUnavailable)
				return
			}
			in.seen[id] = digest
		}
		w.WriteHeader(http.StatusNoContent)
	})
	return mux
}
~~~

</details>

### Step 2 — Check the sender and receiver together

Use a controlled clock and a local receiver. Verify one receipt for two valid sends, and leave the receipt count fixed for invalid, expired, or disallowed deliveries.

<details>
<summary>Implementation</summary>

Create `control/webhook_test.go`.

<!-- file: control/webhook_test.go -->
~~~go
package control

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
	"time"
)

func TestEvents(t *testing.T) {
	now := time.Unix(1700000000, 0)
	key := SigningKey{1, bytes.Repeat([]byte("a"), 32)}
	inbox := &Inbox{}
	receiver := httptest.NewServer(inbox.Handler(func(v uint64) []byte {
		if v == key.Version {
			return key.Secret
		}
		return nil
	}, func() time.Time { return now }))
	defer receiver.Close()
	delivery := Deliverer{Destinations: map[string]netip.AddrPort{
		"jobs": netip.MustParseAddrPort(receiver.Listener.Addr().String()),
	}}
	for range 2 {
		if err := delivery.Send(t.Context(), "jobs", key, now, "job-1", []byte("completed")); err != nil {
			t.Fatal(err)
		}
	}
	cases := []struct {
		name string
		key  SigningKey
		time time.Time
	}{
		{"wrong signature", SigningKey{1, bytes.Repeat([]byte("b"), 32)}, now},
		{"expired", key, now.Add(-2 * time.Minute)},
	}
	for _, c := range cases {
		if err := delivery.Send(t.Context(), "jobs", c.key, c.time, "job-2", nil); err == nil {
			t.Fatalf("%s accepted", c.name)
		}
	}
	if err := delivery.Send(t.Context(), "unknown", key, now, "job-2", nil); err == nil {
		t.Fatal("unregistered destination accepted")
	}
	if err := delivery.Send(t.Context(), "jobs", key, now, "job-1", []byte("changed")); err == nil {
		t.Fatal("conflicting duplicate accepted")
	}
	if inbox.Count() != 1 {
		t.Fatalf("recipient stored %d events", inbox.Count())
	}
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, receiver.URL+"/events", http.StatusTemporaryRedirect)
	}))
	defer redirect.Close()
	delivery.Destinations["redirect"] = netip.MustParseAddrPort(redirect.Listener.Addr().String())
	if err := delivery.Send(t.Context(), "redirect", key, now, "job-3", nil); err == nil || inbox.Count() != 1 {
		t.Fatal("outbound redirect followed")
	}
	t.Log("signed event stored once; invalid, expired, conflicting, unregistered, and redirected delivery refused")
}
~~~

</details>

## Check it

~~~bash
go test -count=1 -v ./control -run '^TestEvents$'
~~~

<!-- run: go test -count=1 -v ./control -run '^TestEvents$' -->

The receiver recorded one event after two valid sends. The defensive checks refused the invalid signature, expired event, conflicting ID, unknown destination, and redirect. [Portable gate capture](../evidence/portable.txt)

## If it goes wrong

If valid delivery is rejected, compare the header strings and exact body bytes before hashing. Check the key version and clock window independently.

Continue to [Load a signing key from OpenBao](06-load-a-key-from-openbao.md).
