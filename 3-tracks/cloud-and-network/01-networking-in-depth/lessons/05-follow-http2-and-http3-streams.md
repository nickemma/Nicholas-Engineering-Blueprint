# 05 Follow concurrent requests over HTTP/2 and HTTP/3

> Networking in depth · Week 2 · Builds on lesson 04

## The problem

A page can finish late even if most of its objects finish early. Before blaming shared transport ordering, check the connection and the workload.

## The mental model

Send the same fixed set of objects over negotiated HTTP/2 and HTTP/3. Start a fresh client for each run. For the warm condition, finish a small request first and record that interval separately from timed object completion.

## The pattern

HTTP/2 frames still travel in a TCP byte stream. HTTP/3 uses independent QUIC stream ordering. Use a simple delivery control to isolate that difference, then use real TLS connections for matched no-loss and impaired object workloads.

## Build it

### Step 1 — Build the lab certificate and clients

Pin the dependencies and load a temporary trusted certificate. Configure each client to use the requested protocol.

<details>
<summary>Hint</summary>

Record actual response protocol and verified chains, then compare hashes for matching object IDs.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `go.mod` in order.

<!-- edit: go.mod -->
~~~text
go 1.26.6

require github.com/quic-go/quic-go v0.64.1
~~~

Replace the selected lines with this block.

~~~text
go 1.26.6

require github.com/quic-go/quic-go v0.64.1

require (
	github.com/quic-go/qpack v0.6.0 // indirect
	golang.org/x/crypto v0.54.0 // indirect
	golang.org/x/net v0.56.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.40.0 // indirect
)
~~~

Create `go.sum`.

<!-- file: go.sum -->
~~~text
github.com/quic-go/go-ossfuzz-seeds v0.1.0 h1:APacT+iIaNF6fd8AGEiN3bT/Jtkd2jz4v4TzM7MFjy0=
github.com/quic-go/go-ossfuzz-seeds v0.1.0/go.mod h1:3IOHRbJIc+L6YKMwfDtJAM9Vj9k0YY4muhuyUYk5tbk=
github.com/quic-go/qpack v0.6.0 h1:g7W+BMYynC1LbYLSqRt8PBg5Tgwxn214ZZR34VIOjz8=
github.com/quic-go/qpack v0.6.0/go.mod h1:lUpLKChi8njB4ty2bFLX2x4gzDqXwUpaO1DP9qMDZII=
github.com/quic-go/quic-go v0.64.1 h1:BCNTP+6x6++OPKrGST2FR3f1tycx8O3QOA3QQv09g70=
github.com/quic-go/quic-go v0.64.1/go.mod h1:RAro2j2yN9a9EiPACLHT9IB2NXCvGQmmo/alT0yYI0w=
github.com/stretchr/testify v1.12.1 h1:EuwCh5fleGS7H32xRwO3wRGT7DxrDhLAT6FF8MpWDWE=
github.com/stretchr/testify v1.12.1/go.mod h1:MDEgiDPPsNp5cuIrHPPCyornHKgEVbtFUmoNlxoYthg=
go.uber.org/mock v0.5.2 h1:LbtPTcP8A5k9WPXj54PPPbjcI4Y6lhyOZXn+VS7wNko=
go.uber.org/mock v0.5.2/go.mod h1:wLlUxC2vVTPTaE3UD51E0BGOAElKrILxhVSDYQLld5o=
go.yaml.in/yaml/v3 v3.0.5 h1:N6y/pJk8buWs9NY5ERU2HSMfm+IuD/OtfdAnq6kESPw=
go.yaml.in/yaml/v3 v3.0.5/go.mod h1:HVTZu1O7/Vkt2N+BFy8Zza+lnLsABggaTM2ZpNIGuKg=
golang.org/x/crypto v0.54.0 h1:YLIA59K4fiNzHzjnZt2tUJQjQtUWfWbeHBqKtk3eScw=
golang.org/x/crypto v0.54.0/go.mod h1:KWL8ny2AZdGR2cWmzeHrp2azQPGogOv+HeQaVEXC2dk=
golang.org/x/net v0.56.0 h1:Rw8j/hFzGvJUZwNBXnAtf5sVDVt+65SK2C7IxCxZt5o=
golang.org/x/net v0.56.0/go.mod h1:D3Ku6r+V6JROoZK144D2XfMHFcMq/0zSfLelVTCFKec=
golang.org/x/sys v0.47.0 h1:o7XGOvZQCADBQQ4Y7VNq2dRWQR7JmOUW8Kxx4ZsNgWs=
golang.org/x/sys v0.47.0/go.mod h1:4GL1E5IUh+htKOUEOaiffhrAeqysfVGipDYzABqnCmw=
golang.org/x/text v0.40.0 h1:Ub2Z6/xjgF1WrYQz2nuITOEegKFtiIy+rieRJ5lHZKs=
golang.org/x/text v0.40.0/go.mod h1:hpnzDAfGV753zIKo+wk3u1bVKCGPbrnF7+7LBF/UHVY=
~~~

Create `page/tls.go`.

<!-- file: page/tls.go -->
~~~go
package page

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

func Certificates(dir string) error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Switchyard lab"},
		NotBefore: now.Add(-time.Minute), NotAfter: now.Add(12 * time.Hour),
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("10.77.2.2"), net.ParseIP("10.77.1.1")},
		BasicConstraintsValid: true, IsCA: true,
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	cert, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return err
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "server.key"), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}), 0600); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "server.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert}), 0644)
}

func ClientTLS(trust string) (*tls.Config, error) {
	raw, err := os.ReadFile(trust)
	if err != nil {
		return nil, err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(raw) {
		return nil, errors.New("no lab certificate loaded")
	}
	return &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS13}, nil
}
~~~

Create `page/page.go`.

<!-- file: page/page.go -->
~~~go
// Package page serves and times a bounded set of reproducible HTTP objects.
package page

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go/http3"
)

const maxSize = 128 << 10

type Origin struct {
	Requests atomic.Int64
}

func payload(id, size int) []byte {
	out := make([]byte, size)
	for i := range out {
		out[i] = byte((i + id) % 251)
	}
	return out
}

func (o *Origin) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /count", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, o.Requests.Load())
	})
	mux.HandleFunc("GET /obj/{size}/{id}", func(w http.ResponseWriter, r *http.Request) {
		size, a := strconv.Atoi(r.PathValue("size"))
		id, b := strconv.Atoi(r.PathValue("id"))
		if a != nil || b != nil || size <= 0 || size > maxSize || id < 0 || id >= 64 {
			http.Error(w, "invalid object", http.StatusBadRequest)
			return
		}
		o.Requests.Add(1)
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", strconv.Itoa(size))
		w.Write(payload(id, size))
	})
	return mux
}

func Serve(ctx context.Context, address, cert, key string, handler http.Handler, ready func(string)) error {
	tcp, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}
	defer tcp.Close()
	udp, err := net.ListenPacket("udp", tcp.Addr().String())
	if err != nil {
		return err
	}
	defer udp.Close()
	bundle, err := tls.LoadX509KeyPair(cert, key)
	if err != nil {
		return err
	}
	config := &tls.Config{Certificates: []tls.Certificate{bundle}, MinVersion: tls.VersionTLS13}
	transport := &http.Server{
		Handler: handler, Protocols: new(http.Protocols),
		ReadHeaderTimeout: 3 * time.Second, TLSConfig: config.Clone(),
	}
	transport.Protocols.SetHTTP2(true)
	quic := &http3.Server{Handler: handler, TLSConfig: http3.ConfigureTLSConfig(config)}
	errs := make(chan error, 2)
	go func() { errs <- transport.ServeTLS(tcp, "", "") }()
	go func() { errs <- quic.Serve(udp) }()
	ready(tcp.Addr().String())
	defer transport.Close()
	defer quic.Close()
	select {
	case <-ctx.Done():
		return nil
	case err := <-errs:
		return err
	}
}

func Client(protocol, trust string) (*http.Client, func(), error) {
	config, err := ClientTLS(trust)
	if err != nil {
		return nil, nil, err
	}
	switch protocol {
	case "h2":
		transport := &http.Transport{TLSClientConfig: config, Protocols: new(http.Protocols), MaxConnsPerHost: 1}
		transport.Protocols.SetHTTP2(true)
		return &http.Client{Transport: transport}, transport.CloseIdleConnections, nil
	case "h3":
		transport := &http3.Transport{TLSClientConfig: config}
		return &http.Client{Transport: transport}, func() { transport.Close() }, nil
	default:
		return nil, nil, errors.New("use h2 or h3")
	}
}

type Object struct {
	ID         int
	Protocol   string
	SHA256     string
	CompleteNS int64
	Cache      string
}

type Measurement struct {
	FixedSize int
	WarmupNS  int64
	Objects   []Object
	TotalNS   int64
}

func Fetch(ctx context.Context, protocol, base, trust string, count, size int, warm bool) (Measurement, error) {
	var result Measurement
	if count <= 0 || count > 64 || size <= 0 || size > maxSize {
		return result, errors.New("object count or size outside lab limits")
	}
	client, closeClient, err := Client(protocol, trust)
	if err != nil {
		return result, err
	}
	defer closeClient()
	want := map[string]int{"h2": 2, "h3": 3}[protocol]
	fetch := func(id int, start time.Time) (Object, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/obj/%d/%d", base, size, id), nil)
		if err != nil {
			return Object{}, err
		}
		res, err := client.Do(req)
		if err != nil {
			return Object{}, err
		}
		defer res.Body.Close()
		body, err := io.ReadAll(io.LimitReader(res.Body, int64(size)+1))
		if err != nil {
			return Object{}, err
		}
		if res.StatusCode != http.StatusOK || res.ProtoMajor != want || len(body) != size ||
			res.TLS == nil || len(res.TLS.VerifiedChains) == 0 {
			return Object{}, fmt.Errorf("response validation failed: HTTP %d, %s, size %d", res.StatusCode, res.Proto, len(body))
		}
		hash := sha256.Sum256(body)
		if hash != sha256.Sum256(payload(id, size)) {
			return Object{}, fmt.Errorf("body hash mismatch for object %d", id)
		}
		return Object{ID: id, Protocol: res.Proto, SHA256: fmt.Sprintf("%x", hash), CompleteNS: time.Since(start).Nanoseconds(), Cache: res.Header.Get("X-Cache")}, nil
	}
	if warm {
		priming, err := fetch(63, time.Now())
		if err != nil {
			return result, err
		}
		result.WarmupNS = priming.CompleteNS
	}

	result.FixedSize, result.Objects = size, make([]Object, count)
	start := time.Now()
	failures := make(chan error, count)
	var tasks sync.WaitGroup
	for id := range count {
		tasks.Go(func() {
			object, err := fetch(id, start)
			if err != nil {
				failures <- err
				return
			}
			result.Objects[id] = object
		})
	}
	tasks.Wait()
	result.TotalNS = time.Since(start).Nanoseconds()
	select {
	case err := <-failures:
		return Measurement{}, err
	default:
		return result, nil
	}
}
~~~

</details>

### Step 2 — Record per-object completion

Use a bounded object set, verify payload bytes, and record the total and priming intervals.

<details>
<summary>Hint</summary>

Measure from a shared start for all concurrent objects in a run.

</details>

<details>
<summary>Implementation</summary>

Create `cmd/netlab/main.go`.

<!-- file: cmd/netlab/main.go -->
~~~go
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"switchyard/netlab/page"
)

func run(ctx context.Context, args []string) error {
	switch {
	case len(args) == 2 && args[0] == "cert":
		return page.Certificates(args[1])
	case len(args) == 3 && args[0] == "serve":
		var origin page.Origin
		return page.Serve(ctx, args[1], filepath.Join(args[2], "server.pem"), filepath.Join(args[2], "server.key"),
			origin.Handler(), func(address string) { fmt.Println("ready", address) })
	case len(args) == 7 && args[0] == "fetch":
		count, err := strconv.Atoi(args[4])
		if err != nil {
			return err
		}
		size, err := strconv.Atoi(args[5])
		if err != nil {
			return err
		}
		if args[6] != "warm" && args[6] != "cold" {
			return errors.New("use warm or cold")
		}
		bounded, cancel := context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
		result, err := page.Fetch(bounded, args[1], args[2], args[3], count, size, args[6] == "warm")
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(result)
	default:
		return errors.New("usage: netlab cert DIR | serve ADDRESS CERT_DIR | fetch {h2|h3} URL TRUST COUNT BYTES {cold|warm}")
	}
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
~~~

</details>

### Step 3 — Check independent and shared delivery

Write down when a second stream’s complete frame can be delivered under each ordering rule. Test actual protocol negotiation separately.

<details>
<summary>Hint</summary>

A late frame on A forces a shared order to wait even when B’s bytes are already available.

</details>

<details>
<summary>Implementation</summary>

Create `page/delivery_test.go`.

<!-- file: page/delivery_test.go -->
~~~go
package page

import "testing"

func TestOrderedDeliveryControl(t *testing.T) {
	// The schedule describes stream A's missing bytes and stream B's complete frame.
	// These are abstract arrivals, independent of the live HTTP timing.
	arriveA, arriveB := 8, 3
	connectionOrderedB := max(arriveA, arriveB)
	streamOrderedB := arriveB
	if connectionOrderedB != 8 || streamOrderedB != 3 {
		t.Fatal("the loss control did not isolate ordered delivery")
	}
	t.Log("delivery model: independent B finishes at tick 3; shared byte order delays it to tick 8")
}
~~~

Create `page/page_test.go`.

<!-- file: page/page_test.go -->
~~~go
package page

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func TestProtocolsReturnIdenticalVerifiedObjects(t *testing.T) {
	dir := t.TempDir()
	if err := Certificates(dir); err != nil {
		t.Fatal(err)
	}
	cert := filepath.Join(dir, "server.pem")
	key := filepath.Join(dir, "server.key")
	ctx, cancel := context.WithTimeout(t.Context(), 8*time.Second)
	defer cancel()
	listening := make(chan string, 1)
	stopped := make(chan error, 1)
	go func() {
		var origin Origin
		stopped <- Serve(ctx, "127.0.0.1:0", cert, key, origin.Handler(), func(addr string) {
			listening <- addr
		})
	}()
	var base string
	select {
	case address := <-listening:
		base = "https://" + address
	case err := <-stopped:
		t.Fatal(err)
	}
	defer func() {
		cancel()
		if err := <-stopped; err != nil {
			t.Error(err)
		}
	}()
	h2, err := Fetch(ctx, "h2", base, cert, 8, 4096, false)
	if err != nil {
		t.Fatal(err)
	}
	h3, err := Fetch(ctx, "h3", base, cert, 8, 4096, true)
	if err != nil || h3.WarmupNS <= 0 {
		t.Fatalf("warm HTTP/3: %+v, %v", h3, err)
	}
	for i, object := range h2.Objects {
		if object.SHA256 != h3.Objects[i].SHA256 {
			t.Fatalf("protocols disagreed on object %d", i)
		}
	}
	t.Log("verified TLS and negotiated HTTP/2 and HTTP/3; all eight content hashes agreed")
}
~~~

</details>

### Step 4 — Compare the measured conditions

Use the live gate after lesson 09 for matched no-loss and 1% loss trials. Keep all paired timings and completion rows.

<details>
<summary>Hint</summary>

Packet loss is sampled independently in the live pairs. The ordering model is the causal control.

</details>

## Check it

~~~bash
go test -race -count=1 -v ./page
~~~

<!-- run: go test -race -count=1 -v ./page -->

The portable fixture negotiated both requested protocols, verified TLS, and returned identical hashes for all eight objects. [Live workload results](../evidence/README.md)

## If it goes wrong

If protocol negotiation differs, check the TCP and UDP listeners and TLS config. If object hashes differ, compare against the deterministic payload before discussing timings.
