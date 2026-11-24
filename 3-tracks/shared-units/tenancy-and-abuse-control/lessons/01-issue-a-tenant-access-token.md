# 01 Issue a tenant access token

> Tenancy and abuse control · Week 1

## The problem

A caller asks to read a job. The service needs a trustworthy way to know which client is calling and which tenant that client belongs to.

## The mental model

~~~text
client ID + secret → issuer's provisioned client record
                     → subject, tenant, role → sign with private key
~~~

## The pattern

The issuer authenticates a provisioned client and signs a short-lived JWT. The HTTP handler gets the claims from its own client registry. Keep the Ed25519 private key with the issuer and publish the public keys as a JWKS. The lab uses a fixed issuer and one intended resource audience. [JWT Best Current Practices](https://www.rfc-editor.org/rfc/rfc8725.html)

## Build it

### Pin the libraries

Use a JWT library for signature and claim handling, pgx for the job store, and go-redis and x/time for the quotas.

Create `go.mod`.

<!-- file: go.mod -->
~~~text
module switchyard/tenantlab

go 1.26.6

require (
	github.com/golang-jwt/jwt/v5 v5.3.1
	github.com/jackc/pgx/v5 v5.11.0
	github.com/redis/go-redis/v9 v9.22.0
	golang.org/x/time v0.15.0
)

require (
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	go.uber.org/atomic v1.11.0 // indirect
	golang.org/x/sync v0.17.0 // indirect
	golang.org/x/sys v0.48.0 // indirect
	golang.org/x/text v0.29.0 // indirect
)
~~~

### Keep the pinned dependency checksums

Record the hashes next to the module file.

Create `go.sum`.

<!-- file: go.sum -->
~~~text
github.com/bsm/ginkgo/v2 v2.12.0 h1:Ny8MWAHyOepLGlLKYmXG4IEkioBysk6GpaRTLC8zwWs=
github.com/bsm/ginkgo/v2 v2.12.0/go.mod h1:SwYbGRRDovPVboqFv0tPTcG1sN61LM1Z4ARdbAV9g4c=
github.com/bsm/gomega v1.27.10 h1:yeMWxP2pV2fG3FgAODIY8EiRE3dy0aeFYt4l7wh6yKA=
github.com/bsm/gomega v1.27.10/go.mod h1:JyEr/xRbxbtgWNi8tIEVPUYZ5Dzef52k01W3YH0H+O0=
github.com/cespare/xxhash/v2 v2.3.0 h1:UL815xU9SqsFlibzuggzjXhog7bL6oX9BbNZnL2UFvs=
github.com/cespare/xxhash/v2 v2.3.0/go.mod h1:VGX0DQ3Q6kWi7AoAeZDth3/j3BFtOZR5XLFGgcrjCOs=
github.com/davecgh/go-spew v1.1.0/go.mod h1:J7Y8YcW2NihsgmVo/mv3lAwl/skON4iLHjSsI+c5H38=
github.com/davecgh/go-spew v1.1.1 h1:vj9j/u1bqnvCEfJOwUhtlOARqs3+rkHYY13jYWTU97c=
github.com/davecgh/go-spew v1.1.1/go.mod h1:J7Y8YcW2NihsgmVo/mv3lAwl/skON4iLHjSsI+c5H38=
github.com/golang-jwt/jwt/v5 v5.3.1 h1:kYf81DTWFe7t+1VvL7eS+jKFVWaUnK9cB1qbwn63YCY=
github.com/golang-jwt/jwt/v5 v5.3.1/go.mod h1:fxCRLWMO43lRc8nhHWY6LGqRcf+1gQWArsqaEUEa5bE=
github.com/jackc/pgpassfile v1.0.0 h1:/6Hmqy13Ss2zCq62VdNG8tM1wchn8zjSGOBJ6icpsIM=
github.com/jackc/pgpassfile v1.0.0/go.mod h1:CEx0iS5ambNFdcRtxPj5JhEz+xB6uRky5eyVu/W2HEg=
github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 h1:iCEnooe7UlwOQYpKFhBabPMi4aNAfoODPEFNiAnClxo=
github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761/go.mod h1:5TJZWKEWniPve33vlWYSoGYefn3gLQRzjfDlhSJ9ZKM=
github.com/jackc/pgx/v5 v5.11.0 h1:IzBBtyK9AHqf98cctWFifYSci2hgQR/cd56wB4p+ogg=
github.com/jackc/pgx/v5 v5.11.0/go.mod h1:mal1tBGAFfLHvZzaYh77YS/eC6IX9OWbRV1QIIM0Jn4=
github.com/jackc/puddle/v2 v2.2.2 h1:PR8nw+E/1w0GLuRFSmiioY6UooMp6KJv0/61nB7icHo=
github.com/jackc/puddle/v2 v2.2.2/go.mod h1:vriiEXHvEE654aYKXXjOvZM39qJ0q+azkZFrfEOc3H4=
github.com/klauspost/cpuid/v2 v2.2.10 h1:tBs3QSyvjDyFTq3uoc/9xFpCuOsJQFNPiAhYdw2skhE=
github.com/klauspost/cpuid/v2 v2.2.10/go.mod h1:hqwkgyIinND0mEev00jJYCxPNVRVXFQeu1XKlok6oO0=
github.com/pmezard/go-difflib v1.0.0 h1:4DBwDE0NGyQoBHbLQYPwSUPoCMWR5BEzIk/f1lZbAQM=
github.com/pmezard/go-difflib v1.0.0/go.mod h1:iKH77koFhYxTK1pcRnkKkqfTogsbg7gZNVY4sRDYZ/4=
github.com/redis/go-redis/v9 v9.22.0 h1:laDvpYXTJtZLloinw1fA5Kqd6HAEH2XKxOkG/PDq2F0=
github.com/redis/go-redis/v9 v9.22.0/go.mod h1:y2g0Wj8rQvuK0ELM+oxSudcLtC09JScs98I/X9gRWY4=
github.com/stretchr/objx v0.1.0/go.mod h1:HFkY916IF+rwdDfMAkV7OtwuqBVzrE8GR6GFx+wExME=
github.com/stretchr/testify v1.3.0/go.mod h1:M5WIy9Dh21IEIfnGCwXGc5bZfKNJtfHm1UVUgZn+9EI=
github.com/stretchr/testify v1.7.0/go.mod h1:6Fq8oRcR53rry900zMqJjRRixrwX3KX962/h/Wwjteg=
github.com/stretchr/testify v1.11.1 h1:7s2iGBzp5EwR7/aIZr8ao5+dra3wiQyKjjFuvgVKu7U=
github.com/stretchr/testify v1.11.1/go.mod h1:wZwfW3scLgRK+23gO65QZefKpKQRnfz6sD981Nm4B6U=
github.com/zeebo/xxh3 v1.1.0 h1:s7DLGDK45Dyfg7++yxI0khrfwq9661w9EN78eP/UZVs=
github.com/zeebo/xxh3 v1.1.0/go.mod h1:IisAie1LELR4xhVinxWS5+zf1lA4p0MW4T+w+W07F5s=
go.uber.org/atomic v1.11.0 h1:ZvwS0R+56ePWxUNi+Atn9dWONBPp/AUETXlHW0DxSjE=
go.uber.org/atomic v1.11.0/go.mod h1:LUxbIzbOniOlMKjJjyPfpl4v+PKK2cNJn91OQbhoJI0=
golang.org/x/sync v0.17.0 h1:l60nONMj9l5drqw6jlhIELNv9I0A4OFgRsG9k2oT9Ug=
golang.org/x/sync v0.17.0/go.mod h1:9KTHXmSnoGruLpwFjVSX0lNNA75CykiMECbovNTZqGI=
golang.org/x/sys v0.48.0 h1:bbX/i/6MgT9BVLM9RT1thmxL04yeTAhbEz4SyadbXoo=
golang.org/x/sys v0.48.0/go.mod h1:hNLxWAXmnKAxqDtdwIYC4bM9oQPEecfsnNMuSxOs3og=
golang.org/x/text v0.29.0 h1:1neNs90w9YzJ9BocxfsQNHKuAT4pkghyXc4nhZ6sJvk=
golang.org/x/text v0.29.0/go.mod h1:7MhJOA9CD2qZyOKYazxdYMF85OwPdEr9jTtBpO7ydH4=
golang.org/x/time v0.15.0 h1:bbrp8t3bGUeFOx08pvsMYRTCVSMk89u4tKbNOZbp88U=
golang.org/x/time v0.15.0/go.mod h1:Y4YMaQmXwGQZoFaVFk4YpCt4FLQMYKZe9oeV/f4MSno=
gopkg.in/check.v1 v0.0.0-20161208181325-20d25e280405/go.mod h1:Co6ibVJAznAaIkqp8huTwlJQCZ016jof/cbN4VW5Yz0=
gopkg.in/yaml.v3 v3.0.0-20200313102051-9f266ea9e77c/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
gopkg.in/yaml.v3 v3.0.1 h1:fxVm/GzAzEWqLHuvctI91KS9hhNmmWOoWu0XTYJS7CA=
gopkg.in/yaml.v3 v3.0.1/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
~~~

### Create the signing key ring

Mint a short-lived access token for a provisioned principal and serialize only public fields in the JWKS.

Create `internal/identity/issuer.go`.

<!-- file: internal/identity/issuer.go -->
~~~go
package identity

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"regexp"
	"sort"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const Lifetime = 5 * time.Minute

var identifier = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`)

func ValidID(value string) bool { return identifier.MatchString(value) }

type Principal struct {
	Subject string
	Tenant  string
	Role    string
}

func (p Principal) Valid() bool {
	return ValidID(p.Subject) && ValidID(p.Tenant) && (p.Role == "reader" || p.Role == "writer")
}

type Claims struct {
	Tenant string `json:"tenant"`
	Role   string `json:"role"`
	jwt.RegisteredClaims
}

type jwk struct {
	ID    string `json:"kid"`
	Type  string `json:"kty"`
	Curve string `json:"crv"`
	Use   string `json:"use"`
	Alg   string `json:"alg"`
	X     string `json:"x"`
}

type keySet struct {
	Keys []jwk `json:"keys"`
}

type signingKey struct {
	private   ed25519.PrivateKey
	latestExp time.Time
}

type Issuer struct {
	name, audience string
	mu             sync.Mutex
	keys           map[string]*signingKey
	active         string
}

func NewIssuer(name, audience string) *Issuer {
	return &Issuer{name: name, audience: audience, keys: make(map[string]*signingKey)}
}

// Stage adds a key to the public JWKS before it can sign any tokens.
func (i *Issuer) Stage(id string) error {
	if !ValidID(id) {
		return errors.New("invalid key ID")
	}
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if _, exists := i.keys[id]; exists || len(i.keys) == 4 {
		return errors.New("duplicate key ID or key set full")
	}
	i.keys[id] = &signingKey{private: private}
	return nil
}

func (i *Issuer) Activate(id string) error {
	i.mu.Lock()
	defer i.mu.Unlock()
	if _, ok := i.keys[id]; !ok {
		return errors.New("stage the key first")
	}
	i.active = id
	return nil
}

func (i *Issuer) Retire(id string, now time.Time) error {
	i.mu.Lock()
	defer i.mu.Unlock()
	key, ok := i.keys[id]
	if !ok || id == i.active || now.Before(key.latestExp) {
		return errors.New("key is missing, active, or still has unexpired tokens")
	}
	delete(i.keys, id)
	return nil
}

func (i *Issuer) Issue(p Principal, now time.Time) (string, error) {
	if !p.Valid() {
		return "", errors.New("invalid provisioned principal")
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	key, ok := i.keys[i.active]
	if !ok {
		return "", errors.New("no active signing key")
	}
	expires := jwt.NewNumericDate(now.Add(Lifetime))
	token := jwt.NewWithClaims(jwt.SigningMethodEdDSA, Claims{
		Tenant: p.Tenant, Role: p.Role,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer: i.name, Audience: jwt.ClaimStrings{i.audience}, Subject: p.Subject,
			IssuedAt: jwt.NewNumericDate(now), ExpiresAt: expires,
		},
	})
	token.Header["kid"] = i.active
	token.Header["typ"] = "at+jwt"
	signed, err := token.SignedString(key.private)
	if err == nil && expires.After(key.latestExp) {
		key.latestExp = expires.Time
	}
	return signed, err
}

func (i *Issuer) JWKS() ([]byte, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	keys := make([]jwk, 0, len(i.keys))
	for id, key := range i.keys {
		pub := key.private.Public().(ed25519.PublicKey)
		keys = append(keys, jwk{id, "OKP", "Ed25519", "sig", "EdDSA", base64.RawURLEncoding.EncodeToString(pub)})
	}
	sort.Slice(keys, func(a, b int) bool { return keys[a].ID < keys[b].ID })
	return json.Marshal(keySet{Keys: keys})
}
~~~

### Bind credentials to a principal

Accept fixture credentials through the loopback token endpoint. Set the token response to no-store. The request carries no tenant or role fields.

Create `internal/identity/http.go`.

<!-- file: internal/identity/http.go -->
~~~go
package identity

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"time"
)

type Credential struct {
	Secret    [sha256.Size]byte
	Principal Principal
}

// Routes binds client credentials to a provisioned principal.
func (i *Issuer) Routes(clients map[string]Credential, now func() time.Time) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /jwks.json", func(w http.ResponseWriter, r *http.Request) {
		keys, err := i.JWKS()
		if err != nil {
			http.Error(w, "key set unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(keys)
	})
	mux.HandleFunc("POST /token", func(w http.ResponseWriter, r *http.Request) {
		id, secret, present := r.BasicAuth()
		client, known := clients[id]
		hash := sha256.Sum256([]byte(secret))
		match := subtle.ConstantTimeCompare(hash[:], client.Secret[:]) == 1
		if !present || !known || !match {
			w.Header().Set("WWW-Authenticate", `Basic realm="switchyard-lab"`)
			http.Error(w, "client authentication required", http.StatusUnauthorized)
			return
		}
		token, err := i.Issue(client.Principal, now())
		if err != nil {
			http.Error(w, "token unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": token, "token_type": "Bearer", "expires_in": int(Lifetime.Seconds()),
		})
	})
	return mux
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


The local issuer generates its keys in memory. The token endpoint uses fixture client credentials as a small teaching interface. The unit runs on loopback with generated credentials. Use the Core 08 TLS lessons for transport protection across machines.
