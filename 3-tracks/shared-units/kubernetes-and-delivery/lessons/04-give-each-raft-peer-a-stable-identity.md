# 04 Give each Raft peer a stable identity

## The problem

A Raft peer must come back with the same ID and the same log. The Core 07 peer transport uses local Unix sockets. Pods need a network hop without exposing their local command API as Raft traffic.

## The mental model

~~~text
metad -> private Unix relay -> peer TLS listener -> destination metad Unix socket
client certificate -> metadata gateway in that Pod -> destination metad command socket
StatefulSet ordinal -> fixed voter ID -> that voter's PVC
~~~

Each bridge checks that a verified leaf's signed URI matches the request's sender ID and that the envelope targets the receiving voter. Its caller also checks the destination DNS name against the peer CA. The gateway uses the separate Core 08 client CA. The lab mounts peer credentials from one Secret and treats workloads in the voter StatefulSet as trusted members. Independent per-voter key delivery would be needed to isolate certificates within that trust group.

## Build it

### Step 1. Relay a single authenticated operation

Keep the Core 07 Go and Rust processes unchanged. Give each Pod outbound Unix socket routes and one inbound peer TLS listener. Check sender and destination before forwarding to the local Raft endpoint.

<details>
<summary>Hint</summary>

Cross-check the message identity against the verified leaf, and use a fixed downstream path.

</details>

<details>
<summary>Type-along files</summary>

Create `delivery/cmd/peer-bridge/main.go`.

<!-- file: delivery/cmd/peer-bridge/main.go -->
~~~go
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const maxBody = 256 << 10

type envelope struct{ From, To int }

func identity(id int) string { return fmt.Sprintf("urn:switchyard:peer:%d", id) }

func verified(c *tls.ConnectionState, id int) bool {
	if c == nil || len(c.VerifiedChains) == 0 || len(c.VerifiedChains[0]) == 0 {
		return false
	}
	uris := c.VerifiedChains[0][0].URIs
	return len(uris) == 1 && uris[0].String() == identity(id)
}

func relay(client *http.Client, endpoint string, sender, receiver int, remote bool) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /raft", func(w http.ResponseWriter, r *http.Request) {
		p, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
		var e envelope
		if err != nil || json.Unmarshal(p, &e) != nil || e.From < 1 || e.From > 3 ||
			e.From == e.To || e.To != receiver || (sender != 0 && sender != e.From) {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if remote && !verified(r.TLS, e.From) {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		q, err := http.NewRequestWithContext(r.Context(), http.MethodPost, endpoint, bytes.NewReader(p))
		if err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		q.Header.Set("Content-Type", "application/json")
		res, err := client.Do(q)
		if err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		defer res.Body.Close()
		io.Copy(io.Discard, io.LimitReader(res.Body, 4096))
		w.WriteHeader(res.StatusCode)
	})
	return mux
}

func client(transport *http.Transport) *http.Client {
	return &http.Client{Transport: transport, Timeout: 150 * time.Millisecond,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

func tlsConfigs(ca, cert, key string) (*tls.Config, *tls.Config, error) {
	raw, err := os.ReadFile(ca)
	if err != nil {
		return nil, nil, err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(raw) {
		return nil, nil, fmt.Errorf("no peer CA certificate")
	}
	leaf, err := tls.LoadX509KeyPair(cert, key)
	if err != nil {
		return nil, nil, err
	}
	cfg := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{leaf}}
	server, caller := cfg.Clone(), cfg.Clone()
	server.ClientAuth, server.ClientCAs = tls.RequireAndVerifyClientCert, roots
	caller.RootCAs = roots
	return server, caller, nil
}

func server(h http.Handler) *http.Server {
	return &http.Server{Handler: h, ReadTimeout: time.Second, WriteTimeout: time.Second, IdleTimeout: 5 * time.Second}
}

func listenUnix(path string, h http.Handler) error {
	// The Pod entrypoint owns this private directory and the socket path.
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return fmt.Errorf("%s is not a socket", path)
		}
		conn, err := net.DialTimeout("unix", path, 100*time.Millisecond)
		if err == nil {
			conn.Close()
			return fmt.Errorf("%s already has a listener", path)
		}
		if err := os.Remove(path); err != nil {
			return err
		}
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	go func() {
		if err := server(h).Serve(l); err != nil {
			log.Fatal(err)
		}
	}()
	return nil
}

func main() {
	id := flag.Int("id", 0, "fixed peer ID")
	dir := flag.String("dir", "", "private socket directory")
	routes := flag.String("routes", "", "comma-separated peer DNS names, in order")
	ca := flag.String("ca", "", "peer CA")
	cert := flag.String("cert", "", "peer leaf")
	key := flag.String("key", "", "peer key")
	addr := flag.String("listen", ":9443", "peer TLS listener")
	flag.Parse()
	dns := strings.Split(*routes, ",")
	if *id < 1 || *id > 3 || len(dns) != 3 || *dir == "" {
		log.Fatal("invalid peer configuration")
	}
	serverTLS, clientTLS, err := tlsConfigs(*ca, *cert, *key)
	if err != nil {
		log.Fatal(err)
	}
	local := client(&http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", filepath.Join(*dir, "local.sock"))
	}})
	caller := client(&http.Transport{TLSClientConfig: clientTLS, MaxIdleConnsPerHost: 2})
	for offset, host := range dns {
		dst := offset + 1
		if dst == *id {
			continue
		}
		endpoint := "https://" + net.JoinHostPort(host, "9443") + "/raft"
		if err := listenUnix(filepath.Join(*dir, fmt.Sprintf("to-%d.sock", dst)), relay(caller, endpoint, *id, dst, false)); err != nil {
			log.Fatal(err)
		}
	}
	l, err := tls.Listen("tcp", *addr, serverTLS)
	if err != nil {
		log.Fatal(err)
	}
	defer l.Close()
	log.Fatal(server(relay(local, "http://local/raft", 0, *id, true)).Serve(l))
}
~~~

Create `delivery/cmd/peer-bridge/main_test.go`.

<!-- file: delivery/cmd/peer-bridge/main_test.go -->
~~~go
package main

import (
	"crypto/tls"
	"crypto/x509"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

type fakeTransport func(*http.Request) (*http.Response, error)

func (f fakeTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestVerifiedIdentityAndTarget(t *testing.T) {
	n := 0
	up := &http.Client{Transport: fakeTransport(func(*http.Request) (*http.Response, error) {
		n++
		return &http.Response{StatusCode: 204, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	h := relay(up, "http://local", 0, 2, true)
	for _, c := range []struct {
		cert   string
		msg    string
		status int
	}{
		{"", `{"From":1,"To":2}`, 403},
		{identity(3), `{"From":1,"To":2}`, 403},
		{identity(1), `{"From":1,"To":3}`, 400},
		{identity(1), `{"From":1,"To":2}`, 204},
	} {
		req := httptest.NewRequest("POST", "/raft", strings.NewReader(c.msg))
		if c.cert != "" {
			uri, err := url.Parse(c.cert)
			if err != nil {
				t.Fatal(err)
			}
			req.TLS = &tls.ConnectionState{VerifiedChains: [][]*x509.Certificate{{{URIs: []*url.URL{uri}}}}}
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != c.status {
			t.Fatalf("got %d, want %d", w.Code, c.status)
		}
	}
	if n != 1 {
		t.Fatal("non-member traffic reached local socket", n)
	}
	t.Log("only the verified sender and expected destination reached the local relay")
}
~~~

</details>
### Step 2. Attach network identity and storage

Deploy three parallel voters. Give Pods stable DNS names before readiness and a distinct Rust log claim for each ordinal. Mount a private socket directory shared by the local containers.

<details>
<summary>Hint</summary>

An ordered start can deadlock if the first Pod waits for a majority. Check reachability and election separately.

</details>

<details>
<summary>Type-along files</summary>

Create `chart/templates/metadata.yaml`.

<!-- file: chart/templates/metadata.yaml -->
~~~yaml
{{- if .Values.metadata.enabled }}
apiVersion: v1
kind: Service
metadata: {name: metadata}
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector: {app: metadata}
  ports: [{name: raft, port: 9443, targetPort: raft}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: metadata}
spec:
  serviceName: metadata
  replicas: 3
  podManagementPolicy: Parallel
  selector: {matchLabels: {app: metadata}}
  template:
    metadata: {labels: {app: metadata}}
    spec:
      automountServiceAccountToken: false
      securityContext: {{- include "delivery.podSecurity" . | nindent 8 }}
      initContainers:
      - name: private-directory
        image: {{ .Values.image | quote }}
        imagePullPolicy: IfNotPresent
        securityContext: {{- include "delivery.security" . | nindent 10 }}
        command: [/bin/sh, -ec, 'umask 077; mkdir -p /run/meta/private; chmod 700 /run/meta/private']
        volumeMounts: [{name: sockets, mountPath: /run/meta}]
      containers:
      - name: metad
        image: {{ .Values.image | quote }}
        imagePullPolicy: IfNotPresent
        securityContext: {{- include "delivery.security" . | nindent 10 }}
        command: [/bin/sh, -ec]
        args:
        - |
          dir=/run/meta/private
          id=$((${HOSTNAME##*-} + 1))
          rm -f -- "$dir/local.sock"
          exec /app/metad -id "$id" -listen "$dir/local.sock" \
            -peers "$dir/to-1.sock,$dir/to-2.sock,$dir/to-3.sock" \
            -wal /data/raft.klog -writer /app/metad-wal
        volumeMounts:
        - {name: sockets, mountPath: /run/meta}
        - {name: wal, mountPath: /data}
        resources:
          requests: {cpu: 15m, memory: 24Mi}
          limits: {memory: 128Mi}
      - name: peer-bridge
        image: {{ .Values.image | quote }}
        imagePullPolicy: IfNotPresent
        securityContext: {{- include "delivery.security" . | nindent 10 }}
        command: [/bin/sh, -ec]
        args:
        - |
          i=${HOSTNAME##*-}
          domain=metadata.{{ .Release.Namespace }}.svc.{{ .Values.metadata.domain }}
          exec /app/peer-bridge -id "$((i + 1))" -dir /run/meta/private \
            -routes "metadata-0.$domain,metadata-1.$domain,metadata-2.$domain" \
            -ca /peer/ca.crt -cert "/peer/$i.crt" -key "/peer/$i.key"
        ports: [{name: raft, containerPort: 9443}]
        readinessProbe:
          tcpSocket: {port: raft}
          periodSeconds: 2
        volumeMounts:
        - {name: sockets, mountPath: /run/meta}
        - {name: peers, mountPath: /peer, readOnly: true}
        resources:
          requests: {cpu: 10m, memory: 16Mi}
          limits: {memory: 96Mi}
      - name: gateway
        image: {{ .Values.image | quote }}
        imagePullPolicy: IfNotPresent
        securityContext: {{- include "delivery.security" . | nindent 10 }}
        command: [/bin/sh, -ec]
        args:
        - |
          umask 077
          dir=/run/meta/private
          cp /gateway/gateway.key "$dir/gateway.key"
          chmod 600 "$dir/gateway.key"
          exec /app/ship-gateway -listen :8443 -upstream "$dir/local.sock" \
            -ca /gateway/ca.crt -cert /gateway/gateway.crt -key "$dir/gateway.key"
        ports: [{name: https, containerPort: 8443}]
        readinessProbe:
          tcpSocket: {port: https}
          periodSeconds: 2
        volumeMounts:
        - {name: sockets, mountPath: /run/meta}
        - {name: gateway, mountPath: /gateway, readOnly: true}
        resources:
          requests: {cpu: 10m, memory: 16Mi}
          limits: {memory: 96Mi}
      volumes:
      - {name: sockets, emptyDir: {}}
      - name: peers
        secret: {secretName: {{ .Values.metadata.peerSecret }}, defaultMode: 288}
      - name: gateway
        secret: {secretName: {{ .Values.metadata.gatewaySecret }}, defaultMode: 288}
  volumeClaimTemplates:
  - metadata: {name: wal}
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests: {storage: 128Mi}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: metadata}
spec:
  minAvailable: 2
  selector: {matchLabels: {app: metadata}}
{{- end }}
~~~

</details>

## Check it

~~~bash
(cd delivery && go test -race -count=1 -v ./cmd/peer-bridge) && helm lint chart --set metadata.enabled=true
~~~

<!-- run: (cd delivery && go test -race -count=1 -v ./cmd/peer-bridge) && helm lint chart --set metadata.enabled=true -->

The relay unit check observes verified identity, correct destination, and one forward. [Captured Go checks](../evidence/unit-tests.txt)

## Run locally

Build and load a new tag using the metadata image stage. Upgrade to that tag with `--set metadata.enabled=true`. Inspect `kubectl -n delivery-steps get statefulset,pvc,pods`. Port-forward one Pod's gateway port 8443 at a time and use the `reader` or `writer` leaf under `.lab/step-secrets/gateway`. Try the current leader for client operations. A TCP-ready endpoint says the listener exists. A successful quorum-backed read gives stronger evidence. The live gate replaces one voter and compares its claim UID and applied index. [StatefulSet identity and storage](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
