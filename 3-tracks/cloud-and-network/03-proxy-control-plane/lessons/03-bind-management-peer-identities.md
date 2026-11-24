# 03 Put mutual TLS on the management path

> The proxy’s control plane · Week 1 · Builds on lesson 02

## The problem

The sidecar has permission to publish routes. It needs to establish both that a peer belongs to the lab PKI and that the peer holds the controller role.

## The mental model

Trust the lab CA for certificate chain validation. Verify the expected role from a URI SAN and verify the sidecar hostname on the client. The loopback Unix socket is a separate local trust boundary protected by directory and socket permissions.

## The pattern

Terminate management HTTPS in the Go sidecar, require an authorized controller identity before handling a request, and forward only a bounded management command to the local socket. Use short deadlines on both hops.

## Build it

### Step 1 — Set the peer identities

Use distinct controller and sidecar identities and leaf usages. Keep the CA public certificate and combined leaf PEM in separate files.

<details>
<summary>Hint</summary>

The sidecar DNS SAN is sidecar.edge.invalid. The role URI is checked independently.

</details>

### Step 2 — Wire the TLS hop and command entry points

Connect the sidecar to Rust with the existing Unix transport. Add sidecar, status, and apply commands. Use the same ordered origin addresses for the controller and managed proxy.

<details>
<summary>Implementation</summary>

Create `control/management.go`.

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

func ServerTLS(ca, leaf string) (*tls.Config, error) {
	pool, err := roots(ca)
	if err != nil {
		return nil, err
	}
	pair, err := tls.LoadX509KeyPair(leaf, leaf)
	if err != nil {
		return nil, err
	}
	return &tls.Config{
		MinVersion: tls.VersionTLS13, ClientAuth: tls.RequireAndVerifyClientCert,
		ClientCAs: pool, VerifyConnection: peerRole(controllerRole),
		Certificates:           []tls.Certificate{pair},
		SessionTicketsDisabled: true,
	}, nil
}

func ClientTLS(ca, leaf string) (*tls.Config, error) {
	pool, err := roots(ca)
	if err != nil {
		return nil, err
	}
	pair, err := tls.LoadX509KeyPair(leaf, leaf)
	if err != nil {
		return nil, err
	}
	return &tls.Config{
		MinVersion: tls.VersionTLS13, RootCAs: pool, ServerName: sidecarName,
		VerifyConnection: peerRole(sidecarRole), Certificates: []tls.Certificate{pair},
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

Create `cmd/edge-control/main.go`.

<!-- file: cmd/edge-control/main.go -->
~~~go
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"time"

	"switchyard/edge/control"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		log.Fatal(err)
	}
}

func run(args []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	if len(args) == 5 && args[0] == "sidecar" {
		config, err := control.ServerTLS(args[3], args[4])
		if err != nil {
			return err
		}
		listener, err := net.Listen("tcp", args[1])
		if err != nil {
			return err
		}
		fmt.Println("listening", listener.Addr())
		return control.NewSidecar(config, args[2]).ServeTLS(listener, "", "")
	}
	if len(args) == 4 && args[0] == "status" || len(args) == 8 && args[0] == "apply" {
		config, err := control.ClientTLS(args[2], args[3])
		if err != nil {
			return err
		}
		send := control.HTTPS(args[1], config)
		if args[0] == "status" {
			ack, err := send(ctx, control.Command{Op: "status"})
			if err != nil {
				return err
			}
			return json.NewEncoder(os.Stdout).Encode(ack)
		}
		generation, err := strconv.ParseUint(args[6], 10, 64)
		if err != nil {
			return err
		}
		var order [2]int
		switch args[7] {
		case "0,1":
			order = [2]int{0, 1}
		case "1,0":
			order = [2]int{1, 0}
		default:
			return errors.New("order must be 0,1 or 1,0")
		}
		controller := control.Controller{Origins: [2]string{args[4], args[5]}, Send: send}
		ack, err := controller.Apply(ctx, control.NewSnapshot(generation, order))
		if err != nil {
			return err
		}
		if err := json.NewEncoder(os.Stdout).Encode(ack); err != nil {
			return err
		}
		if ack.Result != "applied" && ack.Result != "unchanged" {
			return fmt.Errorf("route update: %s", ack.Result)
		}
		return nil
	}
	return errors.New("usage: sidecar LISTEN SOCKET CA LEAF | status URL CA LEAF | apply URL CA LEAF ORIGIN0 ORIGIN1 GENERATION ORDER")
}
~~~

</details>

### Step 3 — Assert the authorization boundary

Use test leaves from the same CA. Show an authorized controller can apply a route and that an observer identity leaves the active generation at zero.

<details>
<summary>Implementation</summary>

Create `control/management_test.go`.

<!-- file: control/management_test.go -->
~~~go
package control

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type authority struct {
	cert *x509.Certificate
	key  ed25519.PrivateKey
	path string
}

func testCA(t *testing.T) authority {
	t.Helper()
	public, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Edge lab CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, public, key)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	return authority{cert, key, path}
}

func (a authority) issue(t *testing.T, path, role string, serial int64, usage x509.ExtKeyUsage) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	uri, err := url.Parse(role)
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{
		SerialNumber: big.NewInt(serial), NotBefore: time.Now().Add(-time.Hour),
		NotAfter: time.Now().Add(time.Hour), ExtKeyUsage: []x509.ExtKeyUsage{usage},
		URIs: []*url.URL{uri}, KeyUsage: x509.KeyUsageDigitalSignature,
	}
	if usage == x509.ExtKeyUsageServerAuth {
		cert.DNSNames = []string{sidecarName}
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, a.cert, public, a.key)
	if err != nil {
		t.Fatal(err)
	}
	key, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		t.Fatal(err)
	}
	bundle := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	bundle = append(bundle, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})...)
	if err := os.WriteFile(path, bundle, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestManagement(t *testing.T) {
	lab := startLab(t)
	ca := testCA(t)
	dir := t.TempDir()
	serverLeaf := filepath.Join(dir, "sidecar.pem")
	clientLeaf := filepath.Join(dir, "controller.pem")
	otherLeaf := filepath.Join(dir, "other.pem")
	ca.issue(t, serverLeaf, sidecarRole, 2, x509.ExtKeyUsageServerAuth)
	ca.issue(t, clientLeaf, controllerRole, 3, x509.ExtKeyUsageClientAuth)
	ca.issue(t, otherLeaf, "urn:switchyard:observer", 4, x509.ExtKeyUsageClientAuth)
	server, err := ServerTLS(ca.path, serverLeaf)
	if err != nil {
		t.Fatal(err)
	}
	sidecar := NewSidecar(server, lab.socket)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go sidecar.ServeTLS(listener, "", "")
	t.Cleanup(func() { sidecar.Close() })
	base := "https://" + listener.Addr().String()
	client, err := ClientTLS(ca.path, clientLeaf)
	if err != nil {
		t.Fatal(err)
	}
	other, err := ClientTLS(ca.path, otherLeaf)
	if err != nil {
		t.Fatal(err)
	}

	bad := NewSnapshot(99, [2]int{1, 0})
	if _, err := HTTPS(base, other)(t.Context(), Command{Op: "apply", Snapshot: &bad}); err == nil {
		t.Fatal("wrong peer role accepted")
	}
	routeScenarios(t, lab, HTTPS(base, client))
	t.Log("wrong-role peer left generation unchanged")
}
~~~

</details>

## Check it

~~~bash
cargo build --locked --target-dir target
EDGE_BIN="$PWD/target/debug/switchyard-edge" go test -count=1 -v ./control -run '^TestManagement$'
~~~

<!-- run: cargo build --locked --target-dir target && EDGE_BIN="$PWD/target/debug/switchyard-edge" go test -count=1 -v ./control -run '^TestManagement$' -->

The allowed controller applied and read back its snapshots. The observer certificate produced an unexpected-peer-identity error, and generation zero remained active until an authorized update. [Portable gate capture](../evidence/portable.txt)

## If it goes wrong

For a failed handshake, check the CA chain, leaf usage, DNS SAN, and URI SAN. The lab writes short-lived keys into temporary private directories.

Continue to [Rotate the management certificates](04-rotate-management-certificates.md).
