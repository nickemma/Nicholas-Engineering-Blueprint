# 03 Rotate signing keys with overlap

> Tenancy and abuse control · Week 1

## The problem

Switching signing keys can interrupt healthy callers. An API needs the public key before the issuer starts signing with it. Callers holding unexpired tokens also need the old key to stay available.

## The mental model

~~~text
issuer:    stage next ── publish both ── activate next ── wait ── retire old
verifier:  trust old ─── trust both ────────────────────────────── trust next
~~~

## The pattern

Stage and publish the next key first. Refresh the verifier's trusted public snapshot before activation. Keep the old public key until the last token signed with it expires. Use a controlled clock in the gate so you can prove both the overlap and the retirement condition without sleeping.

## Build it

### Test the trust and rotation boundaries

Read the key snapshots through the JWKS handler, issue tokens on both keys, and measure behavior before and after retirement.

Create `internal/identity/identity_test.go`.

<!-- file: internal/identity/identity_test.go -->
~~~go
package identity

import (
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestTokenBoundary(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	issuer := newSigner(t)
	verifier := trusted(t, issuer, "jobs")
	wrongIssuer := NewVerifier("another-issuer", "jobs")
	refresh(t, wrongIssuer, issuer)
	principal := Principal{"client", "acme", "reader"}
	secret := "test-only-generated-client-credential"
	routes := issuer.Routes(map[string]Credential{
		"client": {Secret: sha256.Sum256([]byte(secret)), Principal: principal},
	}, func() time.Time { return now })

	tokenFrom := func(password string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/token", nil)
		req.SetBasicAuth("client", password)
		recorder := httptest.NewRecorder()
		routes.ServeHTTP(recorder, req)
		return recorder
	}
	if got := tokenFrom("unrecognized-secret"); got.Code != 401 {
		t.Fatalf("unrecognized credentials: %d", got.Code)
	}
	response := tokenFrom(secret)
	var body struct {
		Token string `json:"access_token"`
	}
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &body) != nil {
		t.Fatal("token endpoint did not issue a token")
	}
	if got, err := verifier.Verify(body.Token, now); err != nil || got != principal {
		t.Fatalf("verified = %+v, %v", got, err)
	}

	for _, check := range []struct {
		name   string
		verify *Verifier
		at     time.Time
		token  string
	}{
		{"wrong-issuer", wrongIssuer, now, body.Token},
		{"wrong-audience", trusted(t, issuer, "reports"), now, body.Token},
		{"expired", verifier, now.Add(Lifetime), body.Token},
		{"malformed", verifier, now, "malformed"},
		{"different-key", trusted(t, newSigner(t), "jobs"), now, body.Token},
	} {
		t.Run(check.name, func(t *testing.T) {
			if _, err := check.verify.Verify(check.token, check.at); err == nil {
				t.Fatal("accepted an invalid token")
			}
		})
	}
	t.Log("credential, issuer, audience, expiry, and signature boundaries enforced")
}

func TestKeyRotation(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	issuer := newSigner(t)
	verifier := trusted(t, issuer, "jobs")
	p := Principal{"client", "acme", "reader"}
	old, err := issuer.Issue(p, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := issuer.Stage("next"); err != nil {
		t.Fatal(err)
	}
	refresh(t, verifier, issuer)
	if err := issuer.Activate("next"); err != nil {
		t.Fatal(err)
	}
	newTime := now.Add(time.Minute)
	next, err := issuer.Issue(p, newTime)
	if err != nil {
		t.Fatal(err)
	}
	for _, token := range []string{old, next} {
		if _, err := verifier.Verify(token, newTime); err != nil {
			t.Fatal(err)
		}
	}
	if err := issuer.Retire("first", newTime); err == nil {
		t.Fatal("retired a key with live tokens")
	}
	after := now.Add(Lifetime)
	if err := issuer.Retire("first", after); err != nil {
		t.Fatal(err)
	}
	refresh(t, verifier, issuer)
	if _, err := verifier.Verify(next, after); err != nil {
		t.Fatal(err)
	}
	if _, err := verifier.Verify(old, newTime); err == nil {
		t.Fatal("retired key was accepted by the refreshed verifier")
	}
	t.Log("overlap accepted both keys; retirement waited for the old token lifetime")
}

func newSigner(t *testing.T) *Issuer {
	t.Helper()
	issuer := NewIssuer("trainer", "jobs")
	if err := issuer.Stage("first"); err != nil {
		t.Fatal(err)
	}
	if err := issuer.Activate("first"); err != nil {
		t.Fatal(err)
	}
	return issuer
}

func trusted(t *testing.T, issuer *Issuer, audience string) *Verifier {
	t.Helper()
	v := NewVerifier("trainer", audience)
	refresh(t, v, issuer)
	return v
}

func refresh(t *testing.T, verifier *Verifier, issuer *Issuer) {
	t.Helper()
	routes := issuer.Routes(nil, time.Now)
	response := httptest.NewRecorder()
	routes.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/jwks.json", nil))
	if response.Code != 200 {
		t.Fatalf("JWKS response = %d", response.Code)
	}
	if err := verifier.ReplaceJWKS(response.Body.Bytes()); err != nil {
		t.Fatal(err)
	}
}
~~~

## Check it

~~~bash
go test -race -count=1 -v ./internal/identity
~~~

<!-- run: go test -race -count=1 -v ./internal/identity -->

Look for `overlap accepted both keys; retirement waited for the old token lifetime`. The tests model a coordinated refresh. The small local CLI creates an ephemeral key at startup, and this lab keeps signing keys and snapshots in memory.
