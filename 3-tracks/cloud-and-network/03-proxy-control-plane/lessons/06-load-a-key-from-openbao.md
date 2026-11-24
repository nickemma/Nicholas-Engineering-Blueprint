# 06 Load a signing key from OpenBao

> The proxy’s control plane · Week 2 · Builds on lesson 05

## The problem

The delivery process needs one signing key. A broad token makes that process a reader for unrelated secrets.

## The mental model

Use an operator token only for fixture setup. Issue a short-lived policy token scoped to the signing path. KV v2 returns the value and its version. Treat the key as an opaque byte string and use the version in the event envelope. [OpenBao KV v2 and path policy](https://openbao.org/docs/next/secrets/kv/kv-v2/)

## The pattern

Read one fixed endpoint with a bounded client. The test creates two fresh key versions and moves the receiver to the selected version. Print only policy outcomes and versions.

## Build it

### Step 1 — Read and validate the key response

Use the scoped token at the signing path and require a 32-byte key and a positive version.

<details>
<summary>Implementation</summary>

Create `control/bao.go`.

<!-- file: control/bao.go -->
~~~go
package control

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
)

func ReadSigningKey(ctx context.Context, address netip.AddrPort, token string) (SigningKey, error) {
	if !address.Addr().IsLoopback() || address.Port() == 0 || token == "" {
		return SigningKey{}, errors.New("invalid OpenBao endpoint or missing token")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"http://"+address.String()+"/v1/secret/data/edge-signing", nil)
	if err != nil {
		return SigningKey{}, err
	}
	request.Header.Set("X-Vault-Token", token)
	response, err := requestClient().Do(request)
	if err != nil {
		return SigningKey{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return SigningKey{}, fmt.Errorf("OpenBao signing key read: HTTP %d", response.StatusCode)
	}
	var envelope struct {
		Data struct {
			Data struct {
				Key string `json:"key"`
			} `json:"data"`
			Metadata struct {
				Version uint64 `json:"version"`
			} `json:"metadata"`
		} `json:"data"`
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 16385))
	if err != nil || len(body) > 16384 || json.Unmarshal(body, &envelope) != nil {
		return SigningKey{}, errors.New("invalid OpenBao key response")
	}
	key, err := hex.DecodeString(envelope.Data.Data.Key)
	if err != nil || len(key) != 32 || envelope.Data.Metadata.Version == 0 {
		return SigningKey{}, errors.New("invalid signing key")
	}
	return SigningKey{Version: envelope.Data.Metadata.Version, Secret: key}, nil
}
~~~

</details>

### Step 2 — Exercise the policy and rotation

Start a disposable loopback dev instance. Store one unrelated secret and require HTTP 403 with the delivery token. Send a valid event with each version and check that the retired version is refused.

<details>
<summary>Implementation</summary>

Create `control/bao_test.go`.

<!-- file: control/bao_test.go -->
~~~go
package control

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"sync/atomic"
	"testing"
	"time"
)

func TestOpenBao(t *testing.T) {
	root := os.Getenv("EDGE_BAO_ROOT")
	if root == "" {
		t.Skip("run the isolated OpenBao profile")
	}
	address, err := netip.ParseAddrPort(os.Getenv("EDGE_BAO_ADDRESS"))
	if err != nil || !address.Addr().IsLoopback() {
		t.Fatal("OpenBao fixture requires a loopback service")
	}
	api := func(method, path, token string, payload any, expected int) []byte {
		t.Helper()
		body, err := json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		request, err := http.NewRequestWithContext(t.Context(), method,
			"http://"+address.String()+"/v1/"+path, bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("X-Vault-Token", token)
		response, err := requestClient().Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		if response.StatusCode != expected {
			t.Fatalf("OpenBao %s %s: HTTP %d, expected %d", method, path, response.StatusCode, expected)
		}
		data, err := io.ReadAll(io.LimitReader(response.Body, 8192))
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	api("PUT", "sys/policies/acl/edge-signer", root,
		map[string]any{"policy": `path "secret/data/edge-signing" { capabilities = ["read"] }`}, 204)
	result := api("POST", "auth/token/create", root, map[string]any{
		"policies": []string{"edge-signer"}, "no_default_policy": true, "ttl": "5m",
	}, 200)
	var token struct {
		Auth struct {
			Token string `json:"client_token"`
		} `json:"auth"`
	}
	if err := json.Unmarshal(result, &token); err != nil || token.Auth.Token == "" {
		t.Fatal("OpenBao test token unavailable")
	}

	store := func(path string) {
		t.Helper()
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			t.Fatal(err)
		}
		api("POST", "secret/data/"+path, root,
			map[string]any{"data": map[string]string{"key": hex.EncodeToString(secret)}}, 200)
	}
	store("edge-signing")
	store("unrelated")
	api("GET", "secret/data/unrelated", token.Auth.Token, nil, 403)

	var current atomic.Pointer[SigningKey]
	inbox := &Inbox{}
	now := time.Now()
	fixture := httptest.NewServer(inbox.Handler(func(version uint64) []byte {
		key := current.Load()
		if key != nil && key.Version == version {
			return key.Secret
		}
		return nil
	}, func() time.Time { return now }))
	defer fixture.Close()
	destination := Deliverer{Destinations: map[string]netip.AddrPort{
		"jobs": netip.MustParseAddrPort(fixture.Listener.Addr().String()),
	}}
	deliver := func(version uint64, id string) SigningKey {
		t.Helper()
		key, err := ReadSigningKey(t.Context(), address, token.Auth.Token)
		if err != nil || key.Version != version {
			t.Fatalf("read version %d: got version %d, error %v", version, key.Version, err)
		}
		current.Store(&key)
		if err := destination.Send(t.Context(), "jobs", key, now, id, []byte("route changed")); err != nil {
			t.Fatal(err)
		}
		return key
	}
	first := deliver(1, "update-1")
	store("edge-signing")
	second := deliver(2, "update-2")
	if bytes.Equal(first.Secret, second.Secret) || inbox.Count() != 2 {
		t.Fatal("rotation or event receipt missing")
	}
	if err := destination.Send(t.Context(), "jobs", first, now, "retired", nil); err == nil || inbox.Count() != 2 {
		t.Fatal("retired version accepted")
	}
	t.Log("OpenBao allowed signing path, denied unrelated path, and deliveries used versions 1 then 2")
}
~~~

Create `lab/openbao.sh`.

<!-- file: lab/openbao.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail

token="$(openssl rand -hex 24)"
name="switchyard-bao-$(openssl rand -hex 6)"
image=openbao/openbao:2.7.1
docker run --detach --rm --name "$name" --publish 127.0.0.1::8200 \
    --env BAO_DEV_ROOT_TOKEN_ID="$token" "$image" server -dev -dev-listen-address=0.0.0.0:8200 >/dev/null
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
address="$(docker port "$name" 8200/tcp)"
for (( attempt=0; attempt<50; attempt++ )); do
    if curl --noproxy '*' -fsS --max-time 1 "http://$address/v1/sys/health" >/dev/null 2>&1; then
        EDGE_BAO_ROOT="$token" EDGE_BAO_ADDRESS="$address" go test -count=1 -v ./control -run '^TestOpenBao$'
        exit
    fi
    sleep 0.2
done
echo "OpenBao dev fixture did not become healthy" >&2
exit 1
~~~

</details>

## Check it

~~~bash
bash lab/openbao.sh
~~~

<!-- run: bash -n lab/openbao.sh && go test ./control -run "^TestOpenBao$" -->

The live fixture read the signing path, received HTTP 403 on the unrelated path, and delivered events with versions 1 and 2. [OpenBao capture](../evidence/openbao.txt)

## If it goes wrong

If the fixture cannot connect, check Docker and the mapped loopback port. If a key read returns 403, verify that the policy refers to the KV v2 data path.

Continue to [Count traffic from the kernel](07-count-traffic-at-xdp.md).
