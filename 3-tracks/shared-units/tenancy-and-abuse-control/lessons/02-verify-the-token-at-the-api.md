# 02 Verify the token at the API boundary

> Tenancy and abuse control · Week 1

## The problem

A string that looks like a token is still untrusted at the API. Even a valid signature can belong to the wrong issuer or intended service.

## The mental model

~~~text
configured issuer trust channel → public key snapshot
request token → pinned algorithm and key ID → signature → claims → principal
~~~

## The pattern

Validate the asymmetric algorithm, access-token type, key ID, signature, issuer, audience, expiry, issue time, and principal fields. The key ID selects a key already in the configured snapshot. Treat unfamiliar keys as a refusal. Configure the trust channel independently of requests. [JWT Best Current Practices](https://www.rfc-editor.org/rfc/rfc8725.html)

## Build it

### Load public keys and verify claims

Validate a whole replacement snapshot before swapping it in. Take the previous snapshot out of use in one step.

Create `internal/identity/verifier.go`.

<!-- file: internal/identity/verifier.go -->
~~~go
package identity

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type Verifier struct {
	name, audience string
	mu             sync.RWMutex
	keys           map[string]ed25519.PublicKey
}

func NewVerifier(name, audience string) *Verifier {
	return &Verifier{name: name, audience: audience}
}

// ReplaceJWKS accepts a public snapshot obtained through the configured
// issuer trust channel. Invalid snapshots leave the previous keys intact.
func (v *Verifier) ReplaceJWKS(raw []byte) error {
	var set keySet
	if len(raw) > 4096 || json.Unmarshal(raw, &set) != nil || len(set.Keys) < 1 || len(set.Keys) > 4 {
		return errors.New("invalid public key set")
	}
	next := make(map[string]ed25519.PublicKey, len(set.Keys))
	for _, key := range set.Keys {
		pub, err := base64.RawURLEncoding.DecodeString(key.X)
		if !ValidID(key.ID) || key.Type != "OKP" || key.Curve != "Ed25519" ||
			key.Use != "sig" || key.Alg != "EdDSA" || err != nil || len(pub) != ed25519.PublicKeySize {
			return errors.New("invalid public key")
		}
		if _, exists := next[key.ID]; exists {
			return errors.New("duplicate public key ID")
		}
		next[key.ID] = ed25519.PublicKey(pub)
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	v.keys = next
	return nil
}

func (v *Verifier) Verify(raw string, now time.Time) (Principal, error) {
	if len(raw) > 4096 {
		return Principal{}, errors.New("token exceeds size limit")
	}
	var claims Claims
	_, err := jwt.ParseWithClaims(raw, &claims, func(t *jwt.Token) (any, error) {
		id, valid := t.Header["kid"].(string)
		if !valid || t.Header["typ"] != "at+jwt" {
			return nil, errors.New("invalid access token header")
		}
		v.mu.RLock()
		defer v.mu.RUnlock()
		key, ok := v.keys[id]
		if !ok {
			return nil, errors.New("unknown key ID")
		}
		return key, nil
	}, jwt.WithValidMethods([]string{"EdDSA"}), jwt.WithIssuer(v.name), jwt.WithAudience(v.audience),
		jwt.WithExpirationRequired(), jwt.WithIssuedAt(), jwt.WithStrictDecoding(), jwt.WithTimeFunc(func() time.Time { return now }))
	if err != nil {
		return Principal{}, err
	}
	if claims.IssuedAt == nil || claims.ExpiresAt == nil || !claims.ExpiresAt.After(claims.IssuedAt.Time) ||
		claims.ExpiresAt.Sub(claims.IssuedAt.Time) > Lifetime {
		return Principal{}, errors.New("invalid token lifetime")
	}
	principal := Principal{claims.Subject, claims.Tenant, claims.Role}
	if !principal.Valid() {
		return Principal{}, errors.New("invalid token principal")
	}
	return principal, nil
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


The identity tests in the next lesson verify a valid token and reject wrong issuer, wrong audience, expiration, malformed input, and a signature from a different key.
