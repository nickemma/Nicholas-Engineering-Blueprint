# 04 Rotate the management certificates

> The proxy’s control plane · Week 2 · Builds on lesson 03

## The problem

A process that loads its leaf at startup keeps serving it after the certificate file changes. An existing TLS connection can also hide whether a rotation took effect.

## The mental model

The lab keeps a stable CA and issues overlapping leaves. Fresh handshakes select a current leaf. Certificate validity windows define the overlap while both leaves remain valid.

## The pattern

Write the replacement leaf and key as a single private PEM bundle and rename it atomically in the same directory. Read the bundle once in the handshake callback. Observe both certificate serials on fresh connections, then publish and read back another route generation.

## Build it

### Step 1 — Load leaves on a handshake

Keep the shared CA and role checks. Use the Go TLS callbacks to load a complete leaf bundle for each new handshake.

<details>
<summary>Implementation</summary>

Replace `control/management.go`.

<!-- file: control/management.go -->
~~~go
package control

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	controllerRole = "urn:switchyard:controller"
	sidecarRole    = "urn:switchyard:sidecar"
	sidecarName    = "sidecar.edge.invalid"
)

func peerRole(role string) func(tls.ConnectionState) error {
	return func(state tls.ConnectionState) error {
		if len(state.VerifiedChains) == 0 || len(state.PeerCertificates) == 0 {
			return errors.New("unverified peer")
		}
		for _, name := range state.PeerCertificates[0].URIs {
			if name.String() == role {
				return nil
			}
		}
		return errors.New("unexpected peer identity")
	}
}

func roots(path string) (*x509.CertPool, error) {
	pem, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, errors.New("invalid CA PEM")
	}
	return pool, nil
}

func readLeaf(path string) (*tls.Certificate, error) {
	bundle, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pair, err := tls.X509KeyPair(bundle, bundle)
	return &pair, err
}

func ServerTLS(ca, leaf string) (*tls.Config, error) {
	pool, err := roots(ca)
	if err != nil {
		return nil, err
	}
	if _, err := readLeaf(leaf); err != nil {
		return nil, err
	}
	return &tls.Config{
		MinVersion: tls.VersionTLS13, ClientAuth: tls.RequireAndVerifyClientCert,
		ClientCAs: pool, VerifyConnection: peerRole(controllerRole),
		GetCertificate:         func(*tls.ClientHelloInfo) (*tls.Certificate, error) { return readLeaf(leaf) },
		SessionTicketsDisabled: true,
	}, nil
}

func ClientTLS(ca, leaf string) (*tls.Config, error) {
	pool, err := roots(ca)
	if err != nil {
		return nil, err
	}
	if _, err := readLeaf(leaf); err != nil {
		return nil, err
	}
	return &tls.Config{
		MinVersion: tls.VersionTLS13, RootCAs: pool, ServerName: sidecarName,
		VerifyConnection:     peerRole(sidecarRole),
		GetClientCertificate: func(*tls.CertificateRequestInfo) (*tls.Certificate, error) { return readLeaf(leaf) },
	}, nil
}

func Handler(send Send) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/admin", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxFrame-1))
		var command Command
		if err != nil || json.Unmarshal(body, &command) != nil {
			http.Error(w, "invalid admin request", http.StatusBadRequest)
			return
		}
		switch {
		case command.Op == "status" && command.Snapshot == nil,
			command.Op == "apply" && command.Snapshot != nil:
		default:
			http.Error(w, "unsupported admin request", http.StatusBadRequest)
			return
		}
		ack, err := send(r.Context(), command)
		if err != nil {
			http.Error(w, "local admin unavailable", http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(ack)
	})
	return mux
}

func NewSidecar(config *tls.Config, socket string) *http.Server {
	return &http.Server{
		TLSConfig: config, Handler: Handler(Unix(socket)),
		ReadTimeout: 2 * time.Second, WriteTimeout: 3 * time.Second,
		ReadHeaderTimeout: time.Second, IdleTimeout: 5 * time.Second,
	}
}

func HTTPS(base string, config *tls.Config) Send {
	client := requestClient()
	client.Transport.(*http.Transport).TLSClientConfig = config
	return func(ctx context.Context, command Command) (Ack, error) {
		if !strings.HasPrefix(base, "https://") {
			return Ack{}, errors.New("management endpoint must use HTTPS")
		}
		body, err := json.Marshal(command)
		if err != nil {
			return Ack{}, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost,
			strings.TrimRight(base, "/")+"/v1/admin", bytes.NewReader(body))
		if err != nil {
			return Ack{}, err
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return Ack{}, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return Ack{}, fmt.Errorf("management response: HTTP %d", resp.StatusCode)
		}
		data, err := io.ReadAll(io.LimitReader(resp.Body, maxFrame+1))
		if err != nil {
			return Ack{}, err
		}
		if len(data) > maxFrame {
			return Ack{}, errors.New("management response too large")
		}
		var ack Ack
		err = json.Unmarshal(data, &ack)
		return ack, err
	}
}
~~~

</details>

### Step 2 — Make rotation observable

Rotate the sidecar leaf first, observe the old controller with the new sidecar, then rotate the controller and observe the new pair. Verify an update on the rotated connection.

<details>
<summary>Implementation</summary>

Find these regions in `control/management_test.go` in order.

<!-- edit: control/management_test.go -->
~~~go
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
~~~

Replace the selected lines with this block.

~~~go
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
~~~

<!-- edit: control/management_test.go -->
~~~go
	"os"
	"path/filepath"
	"testing"
	"time"
~~~

Replace the selected lines with this block.

~~~go
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
~~~

<!-- edit: control/management_test.go -->
~~~go
		t.Fatal(err)
	}
	sidecar := NewSidecar(server, lab.socket)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
~~~

Replace the selected lines with this block.

~~~go
		t.Fatal(err)
	}
	var seenController atomic.Int64
	verifyController := server.VerifyConnection
	server.VerifyConnection = func(state tls.ConnectionState) error {
		if err := verifyController(state); err != nil {
			return err
		}
		seenController.Store(state.PeerCertificates[0].SerialNumber.Int64())
		return nil
	}
	sidecar := NewSidecar(server, lab.socket)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
~~~

<!-- edit: control/management_test.go -->
~~~go
	routeScenarios(t, lab, HTTPS(base, client))
	t.Log("wrong-role peer left generation unchanged")
}
~~~

Replace the selected lines with this block.

~~~go
	routeScenarios(t, lab, HTTPS(base, client))
	t.Log("wrong-role peer left generation unchanged")
	var seenSidecar atomic.Int64
	verifySidecar := client.VerifyConnection
	client.VerifyConnection = func(state tls.ConnectionState) error {
		if err := verifySidecar(state); err != nil {
			return err
		}
		seenSidecar.Store(state.PeerCertificates[0].SerialNumber.Int64())
		return nil
	}
	send := HTTPS(base, client)
	status := Command{Op: "status"}
	checkSerials := func(controller, sidecar int64) {
		t.Helper()
		ack, err := send(t.Context(), status)
		if err != nil || ack.Snapshot.Generation != 2 ||
			seenController.Load() != controller || seenSidecar.Load() != sidecar {
			t.Fatalf("rotation readback: %+v controller=%d sidecar=%d error=%v",
				ack, seenController.Load(), seenSidecar.Load(), err)
		}
	}
	replace := func(path, role string, serial int64, usage x509.ExtKeyUsage) {
		t.Helper()
		ca.issue(t, path+".new", role, serial, usage)
		if err := os.Rename(path+".new", path); err != nil {
			t.Fatal(err)
		}
	}
	checkSerials(3, 2)
	replace(serverLeaf, sidecarRole, 5, x509.ExtKeyUsageServerAuth)
	checkSerials(3, 5)
	replace(clientLeaf, controllerRole, 6, x509.ExtKeyUsageClientAuth)
	checkSerials(6, 5)
	next := NewSnapshot(3, [2]int{1, 0})
	ack, err := (Controller{Origins: lab.origins, Send: send}).Apply(t.Context(), next)
	if err != nil || ack.Result != "applied" || ack.Snapshot != next {
		t.Fatalf("apply after rotation: %+v %v", ack, err)
	}
	ack, err = send(t.Context(), status)
	if err != nil || ack.Snapshot != next {
		t.Fatalf("readback after rotation: %+v %v", ack, err)
	}
	t.Log("fresh TLS handshakes observed serial pairs 3/2, 3/5, 6/5; generation 3 read back")
}
~~~

</details>

## Check it

~~~bash
cargo build --locked --target-dir target
EDGE_BIN="$PWD/target/debug/switchyard-edge" go test -count=1 -v ./control -run '^TestManagement$'
~~~

<!-- run: cargo build --locked --target-dir target && EDGE_BIN="$PWD/target/debug/switchyard-edge" go test -count=1 -v ./control -run '^TestManagement$' -->

The test observed controller/sidecar serial pairs 3/2, 3/5, and 6/5, then read back generation 3. [Portable gate capture](../evidence/portable.txt)

## If it goes wrong

If the serial never changes, create a fresh connection and check whether the process is using the replacement path. If rotation breaks TLS, verify that the entire replacement bundle has the same role, expected usage, and a valid chain.

Continue to [Deliver signed events to registered destinations](05-deliver-signed-events.md).
