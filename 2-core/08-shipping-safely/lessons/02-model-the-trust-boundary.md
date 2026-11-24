# 02 Model the trust boundary

## The problem

Switchyard's metadata peers assume a local caller that already has socket access. The gateway gives authors of metadata and authorized readers different capabilities. Decide which authority travels across each boundary before writing the handler.

~~~text
client key + cert ── mTLS ── gateway
                               ├── coarse status log
                               └── owner-only directory ── metad /command ── klog
CA signer ── issues certificates, with the signing key stored outside the serving process
~~~

| Boundary | Data crossing | Rule |
|---|---|---|
| Client → gateway | Certificate identity, operation, key, optional value | Verify the certificate and authorize the decoded operation. |
| Gateway → peer | Canonical, bounded metadata read or write | Use a configured socket and the single allowed upstream path. |
| Gateway → log | HTTP outcome code | Keep request fields and keys out of the log. |
| Peer → disk | Replicated command and state | Access to the service and its private files carries trust. |

The lab assumes a dedicated account controls the private socket directory. Other code running as that account shares the local trust boundary. A client certificate proves identity. The policy maps the signed identity to an allowed operation. A reader can get, a writer can get or put, and unknown identities have no grant.

## Threats and checks

Use STRIDE as a prompt to consider spoofing, tampering, repudiation, information disclosure, denial of service, and elevation of privilege. Record the assumption each control relies on and the observation that would show it working.

| Threat | Control and evidence |
|---|---|
| An unknown client claims a reader identity | The gateway verifies the certificate chain. The live check uses a separately issued laboratory certificate and observes a TLS rejection. |
| A reader tries to change metadata | Authorize the decoded operation before forwarding. Check HTTP 403 and verify that the peer received no request in the handler test. |
| Diagnostics disclose request data | The gateway emits only the outcome code for a command. Repeat a synthetic request and scan the captured outputs. |
| A dead upstream makes client commands unavailable | Bound the request and make the external probe count the failure. Record a game-day recovery. |
| An operator needs an audit trail | The lab retains outcome and incident timestamps. A deployment that needs attribution would also need a durable audit design with an explicit data-retention policy. |

## Build it

### Step 1. Define supported operations

Sketch a decoder that reads one JSON object, validates it, and yields a canonical command.

<details>
<summary>Hint</summary>

Use an explicit allowlist and check that input ends after decoding the object.

</details>

<details>
<summary>Completed files</summary>

Create `internal/edge/policy.go`.

<!-- file: internal/edge/policy.go -->
~~~go
// Package edge implements the metadata gateway's client boundary.
package edge

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
)

const CommandLimit = 4096

type Command struct {
	Op, Key, Value string
}

func Principal(state *tls.ConnectionState) string {
	if state == nil || len(state.VerifiedChains) == 0 || len(state.VerifiedChains[0]) == 0 {
		return ""
	}
	names := state.VerifiedChains[0][0].URIs
	if len(names) != 1 {
		return ""
	}
	return names[0].String()
}

func allowed(identity, operation string) bool {
	switch identity {
	case "urn:switchyard:reader":
		return operation == "get"
	case "urn:switchyard:writer":
		return operation == "get" || operation == "put"
	default:
		return false
	}
}

func Decode(input io.Reader) (Command, error) {
	var c Command
	d := json.NewDecoder(input)
	d.DisallowUnknownFields()
	if err := d.Decode(&c); err != nil {
		return Command{}, err
	}
	if d.Decode(&struct{}{}) != io.EOF {
		return Command{}, errors.New("expected a single JSON object")
	}
	if c.Key == "" || len(c.Key) > 128 || len(c.Value) > 512 ||
		(c.Op != "get" && c.Op != "put") || (c.Op == "get" && c.Value != "") {
		return Command{}, errors.New("unsupported metadata command")
	}
	return c, nil
}
~~~

</details>
### Step 2. Test the policy table

For each known identity, test a permitted and a denied operation. Add an unknown identity and check that the certificate mapping depends on a verified leaf.

<details>
<summary>Hint</summary>

Include the reader-to-put case. Its absence would let an overly permissive policy survive.

</details>

<details>
<summary>Completed files</summary>

Create `internal/edge/policy_test.go`.

<!-- file: internal/edge/policy_test.go -->
~~~go
package edge

import (
	"crypto/tls"
	"crypto/x509"
	"net/url"
	"strings"
	"testing"
)

func TestPolicy(t *testing.T) {
	for _, x := range []struct {
		role, operation string
		want            bool
	}{
		{"reader", "get", true}, {"reader", "put", false},
		{"writer", "get", true}, {"writer", "put", true},
		{"writer", "renew", false}, {"unknown", "get", false},
	} {
		if got := allowed("urn:switchyard:"+x.role, x.operation); got != x.want {
			t.Errorf("%s %s = %t; want %t", x.role, x.operation, got, x.want)
		}
	}
}

func TestIdentityRequiresAVerifiedLeaf(t *testing.T) {
	name, err := url.Parse("urn:switchyard:reader")
	if err != nil {
		t.Fatal(err)
	}
	leaf := &x509.Certificate{URIs: []*url.URL{name}}
	state := &tls.ConnectionState{PeerCertificates: []*x509.Certificate{leaf}}
	if Principal(state) != "" {
		t.Fatal("used an unverified leaf")
	}
	state.VerifiedChains = [][]*x509.Certificate{{leaf}}
	if Principal(state) != name.String() {
		t.Fatal("verified identity was ignored")
	}
	leaf.URIs = append(leaf.URIs, name)
	if Principal(state) != "" {
		t.Fatal("accepted ambiguous identity")
	}
}

func TestDecode(t *testing.T) {
	for _, invalid := range []string{
		"", "null", "{", "{\"Op\":\"renew\",\"Key\":\"x\"}",
		"{\"Op\":\"get\",\"Key\":\"x\",\"Value\":\"ignored\"}",
		"{\"Op\":\"put\",\"Key\":\"x\",\"Owner\":\"ignored\"}",
		"{\"Op\":\"get\",\"Key\":\"x\"} {}",
	} {
		if _, err := Decode(strings.NewReader(invalid)); err == nil {
			t.Errorf("accepted %q", invalid)
		}
	}
	if _, err := Decode(strings.NewReader("{\"Op\":\"get\",\"Key\":\"x\"}")); err != nil {
		t.Fatal(err)
	}
}
~~~

</details>

## Check it

~~~bash
go test -race -count=1 -v ./internal/edge
~~~

<!-- run: go test -race -count=1 -v ./internal/edge -->

~~~text
=== RUN   TestPolicy
--- PASS: TestPolicy (0.00s)
=== RUN   TestIdentityRequiresAVerifiedLeaf
--- PASS: TestIdentityRequiresAVerifiedLeaf (0.00s)
=== RUN   TestDecode
--- PASS: TestDecode (0.00s)
PASS
ok  	switchyard/metad/internal/edge	1.021s
~~~

These tests check the policy and the representation of verification state. Lesson 07 checks real handshakes.

[Captured output](../evidence/02-policy.txt)

## Explain it

Where should the check for a reader's proposed write happen, and why?
