# Phase 6 teaching: secure it

At the end of Phase 5, Runway runs on Kubernetes, rolls out without dropping requests, traces every job, pages when users hurt, and scales itself. Anyone can use it. Literally anyone: there are no identities, so any caller can create, read and cancel any job. Inside the cluster it's the same. Every Pod can reach the database, the broker, Redis and `metad`, and the application logs in to PostgreSQL as a superuser.

This phase makes Runway something you could let strangers use, and let several customers share. It doesn't add security as a layer on top. It starts by writing down what could go wrong, and then each step removes one way it could. The last step attacks the result and records what still gets through.

**The goal:** every request carries a token Runway's own identity provider signed, and every handler asks one policy point whether it's allowed. Each customer (a **tenant**) sees only its own jobs, down to row-level security in PostgreSQL, and one tenant can't starve the rest. Webhooks to customers are signed. Every connection between services is mutual TLS from a certificate authority you write, including Redis, which never learns about it. Database logins come from OpenBao, last minutes, and belong to one Pod. The audit log is a Merkle tree whose rewrites a witness detects. Personal data stays out of logs and traces, and the cross-tenant statistics resist differencing. The cluster runs restricted Pods behind default-deny network policies. A game day then checks each of these against a threat model written before any of them existed.

**Time:** about 10 weeks. **Before you start:** finish Phase 5, and keep its kind cluster. Install:
- `openssl`, `jq`, and `curl` 7.58 or newer (for `--resolve`);
- the Rust toolchain from the Rust Bridge (step 10 extends `klog`);
- `uv`, for kload (step 5).

Everything runs locally. OpenBao (step 9) runs as a container in Compose and as a StatefulSet on kind, so it needs no install.

## How this guide works

The same as Phase 5: type everything, file by file, and run the checks at the end of each step. Most steps have three parts: the code, checked by the tests; a **Run it** on the cluster, with the output it produced on my machine; and a **Break it**, which removes the control and shows the attack it was stopping. Do the break. A control you've never seen fail is a control you're taking on trust.

Your output will differ in its names and numbers: Pod names, job IDs, client secrets, key IDs and timings are all your own. The tokens and certificates in this guide were made on my cluster and are long expired, so don't copy them; make your own with the commands shown.

**Security code fails quietly.** A missing check doesn't crash. The request still succeeds, just for someone it shouldn't. So most tests in this phase are *negative*: they prove something is refused. When you write one, break the code it protects and watch the test fail, as the guide does. Several bugs in this phase were found that way, in code that passed every positive test.

| Step | What you add |
|---|---|
| 1 | A threat model: data flows, trust boundaries, STRIDE, and evidence of today's exposure |
| 2 | Tokens: an identity provider of your own (JWT, JWKS, key rotation) and verification in the API |
| 3 | Authorization: one policy decision point, called by every HTTP and gRPC handler, failing closed |
| 4 | Tenants: the tenant from the token, carried through the outbox, the bus and the workers; row-level security |
| 5 | Rate limiting: a token bucket per tenant, then shared through Redis; a noisy-neighbour experiment |
| 6 | Signed webhooks: HMAC with timestamps, replay protection, secret rotation, and SSRF defences |
| 7 | TLS and your own certificate authority: mutual TLS for the API, the gateway and `metad`; rotation without restarts |
| 8 | A sidecar proxy that gives Redis mutual TLS without changing it; what it costs |
| 9 | Secrets: OpenBao, dynamic database logins, least-privilege roles, encryption with a key nobody holds |
| 10 | A tamper-evident audit log: a Merkle tree, signed checkpoints, and a witness |
| 11 | Privacy: redaction, retention, and statistics that don't give individuals away |
| 12 | Cluster hardening: network policies, Pod Security, service-account tokens, and fuzzing the parsers |
| 13 | A security game day against the threat model, and the findings report |

## Setup

Start from your finished Phase 5 code. From the repository root:

~~~bash
cd lessons/06-safe-shared-queries
cp -r ../05-constrained-operations/practice practice
rm -rf practice/audit/target
cd practice
go test ./...
~~~

<!-- continue: ../05-constrained-operations/TEACHING.md -->

Keep the Phase 5 variables (`RUNWAY_DATABASE_URL` and the rest) exported, the Compose services running, and the kind cluster up. If the machine restarts, `docker start runway-control-plane runway-worker runway-worker2` brings the cluster back, and `docker compose up -d` the rest.

**Raise the inotify limit now.** Every container on a kind node holds inotify instances, and this phase adds many. With the default of 128 per user, a restart left two of my nodes without `kube-proxy` ("fsnotify watcher init: too many open files"), and every Service on them stopped working:

~~~bash
sudo sysctl -w fs.inotify.max_user_instances=512
echo 'fs.inotify.max_user_instances=512' | sudo tee /etc/sysctl.d/99-inotify.conf
~~~

---
## Step 1: A threat model

**The problem.** "Make it secure" isn't a task. Secure against whom, protecting what, at what cost? Without answers you add controls in the order they occur to you, and stop when you're tired. The usual result is strong locks on the doors you thought of and none on the ones you didn't. Before writing any security code, write down what you're protecting and from whom, and how it could go wrong *today*, with evidence.

**New ideas.**

- **Threat modelling** answers four questions (Adam Shostack's framing): *What are we building? What can go wrong? What are we going to do about it? Did we do a good job?* This step answers the first two and plans the third. Step 13 answers the fourth.
- **A data-flow diagram** shows the processes, the stores, and the arrows between them. Draw **trust boundaries** across it: lines where the trust of what's on each side changes, such as the internet and the cluster, or one tenant and another. Most threats live where an arrow crosses a boundary.
- **Assets** are what an attacker wants, or what you can't afford to lose: data, the truth of records, credentials, capacity.
- **Actors** are who might act against them, each with the trust they should have, and what they can actually do now.
- **STRIDE** is a checklist for each element, each letter the violation of one property. **S**poofing violates authenticity (pretending to be someone else). **T**ampering violates integrity. **R**epudiation violates non-repudiation ("I never did that", and you can't prove otherwise). **I**nformation disclosure violates confidentiality. **D**enial of service violates availability. **E**levation of privilege violates authorization.
- **Evidence.** Each threat gets one command that shows it's real *now*. "We probably don't check that" isn't a finding; `201` from a request with no credentials is. The same commands, run again in step 13, show whether each fix held.
- **Non-goals** say what the model deliberately doesn't cover, so nobody assumes it does.

### Look at what you have

Run these against the Phase 5 cluster. Each one tests something a careful reviewer would ask about:

~~~bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8080/jobs -H "Content-Type: application/json" -d '{"description":"no credentials","duration_ms":10}'
kubectl get networkpolicies -A
kubectl get namespace runway -o jsonpath="{.metadata.labels}"; echo
kubectl -n runway exec postgres-0 -- psql -U runway -tAc "SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
kubectl -n runway get pod -l app=api -o jsonpath="{.items[0].spec.automountServiceAccountToken} {.items[0].spec.serviceAccountName}"; echo
kubectl -n observability get deploy grafana -o json | jq -r '.spec.template.spec.containers[0].env[] | "\(.name)=\(.value)"'
~~~

~~~text
201
No resources found
{"kubernetes.io/metadata.name":"runway"}
runway|t|t
 default
GF_AUTH_ANONYMOUS_ENABLED=true
GF_AUTH_ANONYMOUS_ORG_ROLE=Admin
GF_AUTH_DISABLE_LOGIN_FORM=true
~~~

Read each line as an attacker would:
- **`201`**: a job created by nobody. There's no identity, so there can't be authorization, tenants or per-customer limits either. Everything else depends on fixing this first.
- **No network policies**: any Pod, including a compromised dependency in someone else's namespace, can open a connection to PostgreSQL, RabbitMQ, Redis and `metad`.
- **No Pod Security labels**: nothing stops someone who can create Pods here from creating a privileged one, which can reach the node itself.
- **`runway|t|t`**: the application's database login is a superuser that bypasses row-level security. Whoever gets the API's password owns the database, and any per-tenant policy you add would simply not apply to it.
- **An empty `automountServiceAccountToken`** means the default: every API Pod holds a token for the Kubernetes API that it never uses. Steal the Pod, and you have the token.
- **Grafana's anonymous visitors are administrators**: they can add data sources, read every metric, and change dashboards.

### Write the model

Create `docs/security/threat-model.md`:

<!-- file: docs/security/threat-model.md -->
````markdown
# Runway threat model

Written at the start of Phase 6, before adding any security control, and updated as each step lands. A threat model answers four questions (Shostack): what are we building, what can go wrong, what are we going to do about it, and did we do a good job?

## 1. What we're building

Runway accepts jobs over HTTP and gRPC, stores them in PostgreSQL with an outbox, runs them on workers through RabbitMQ, streams changes to Kafka, caches reads in Redis, and keeps metadata in `metad`, a Raft cluster. It runs on Kubernetes, observed by an OpenTelemetry collector, Jaeger, Prometheus and Grafana.

### Data flows

~~~text
                       trust boundary: the internet / your network
  ───────────────────────────────────────────────────────────────────────────
   client ──HTTP──▶ gateway ──HTTP──▶ api ◀──gRPC── client
                                      │ ▲
                         SQL (pgx)    │ │ events (AMQP)
                                      ▼ │
   trust boundary: the cluster   postgres   rabbitmq ◀──AMQP──▶ worker
  ────────────────────────────    redis ×3   metad ×3 (HTTP)
                                  otel-collector ─▶ jaeger
                                  prometheus ─▶ (scrapes every Pod)  grafana
  ───────────────────────────────────────────────────────────────────────────
   operators: kubectl, Helm, CI (GitHub Actions), the AWS account (step 13)
~~~

### Assets

| Asset | Why it matters |
|---|---|
| Jobs and their descriptions | Customers' data; descriptions may hold personal data |
| Job state and history (`job_events`, the audit log) | Must be true: billing, disputes and debugging depend on it |
| Credentials: database, broker, cache, cloud | Each one opens a whole service |
| Capacity: API, workers, queue space | Shared by every user; exhausting it is an outage for all |
| Telemetry: logs, traces, metrics | Copies of the data above, in more places |
| The supply chain: source, images, the chart | Whoever controls it controls every Pod |

### Actors

| Actor | Trust | Today they can |
|---|---|---|
| A customer (tenant) | Their own jobs only | Do anything, to anyone's jobs: there are no identities |
| An anonymous caller | Nothing | The same as a customer |
| A compromised Pod | Its own job | Reach every service in the cluster |
| An operator | Administrative, audited | Everything, unaudited |

## 2. What can go wrong (STRIDE)

STRIDE names six kinds of threat, each the violation of one property: **S**poofing (authenticity), **T**ampering (integrity), **R**epudiation (non-repudiation), **I**nformation disclosure (confidentiality), **D**enial of service (availability), **E**levation of privilege (authorization).

| # | Element | STRIDE | Threat | Evidence today | Fixed in |
|---|---|---|---|---|---|
| T1 | API (HTTP and gRPC) | S, E | Anyone can create and read jobs; there is no identity at all | `POST /jobs` with no credentials returns 201 | Steps 2, 3 |
| T2 | API | I | Job IDs are sequential: any job can be read by guessing its number | `GET /jobs/1`, `/jobs/2`, ... | Steps 3, 4 |
| T3 | API, workers, database | I, T | No tenants: one customer's jobs are mixed with everyone's | One `jobs` table, no owner column | Step 4 |
| T4 | API, queue | D | One client can fill the commands queue and starve everyone else | Phase 5, step 11: a burst filled the queue in seconds | Step 5 |
| T5 | API | S, T | A captured request or token can be replayed | No expiry, no nonce | Steps 2, 6 |
| T6 | Network inside the cluster | S, T, I | Every Pod can reach every other: a compromised Pod can talk to the database, the broker, Redis and `metad` directly | `kubectl get networkpolicies -A`: none | Steps 7, 12 |
| T7 | Service-to-service traffic | S, I | Plain text, and nothing proves which service is calling | No TLS between services | Steps 7, 8 |
| T8 | Broker | S, T | Every service shares one broker credential; anything holding it can publish events the API will believe | One `RABBITMQ_DEFAULT_USER` in one Secret | Steps 7, 9, 12 |
| T9 | `metad` | S, T, E | Its HTTP API, including locks, has no authentication | `PUT /kv/{key}` needs nothing | Steps 7, 12 |
| T10 | Redis | I, T | No password; cached jobs are readable and writable by any Pod | No `requirepass` | Steps 9, 12 |
| T11 | Database | E | The application connects as a superuser that bypasses row-level security | `rolsuper = t`, `rolbypassrls = t` | Steps 4, 9 |
| T12 | Secrets | I | Kubernetes Secrets are base64, and every key reaches every service through `envFrom` | `deploy/k8s/config.yaml` | Step 9 |
| T13 | Pods | E | API Pods mount a service-account token they never use | `automountServiceAccountToken` unset | Step 12 |
| T14 | Namespace | E | No Pod Security standard is enforced: a privileged Pod could be created here | No `pod-security.kubernetes.io` labels | Step 12 |
| T15 | Audit trail | R | The audit log is append-only and checksummed, but anyone with write access can rewrite history undetected | Phase 3's log has no chaining | Step 10 |
| T16 | Telemetry | I | Job descriptions appear in logs, traces and the cache | Phase 5's traces and logs | Step 11 |
| T17 | Grafana | E, I | Anonymous visitors are administrators | `GF_AUTH_ANONYMOUS_ORG_ROLE=Admin` | Step 12 |
| T18 | Statistics | I | Per-tenant counts over small groups can reveal individuals | Not built yet; designed in step 11 | Step 11 |

## 3. What we're going to do

Defence in depth: no single control should be the only thing protecting an asset. The order of the steps follows the table: identity first (nothing else can be decided without it), then authorization, tenants and capacity, then the network and secrets underneath, then evidence (audit) and privacy, then hardening and an attack on our own work.

**Non-goals for this phase**, stated so nobody assumes them:
- protection from someone with administrative access to the cluster or the cloud account (that needs separation of duties and hardware roots of trust);
- a compliance certification (GDPR, SOC 2, HIPAA); this phase builds controls such work would examine, not the paperwork;
- Byzantine faults in `metad` (a member that lies is out of scope, as in Phase 4).

## 4. Did we do a good job?

Step 13 attacks the system using this table as the plan, and records what got through.
````

A few choices are worth arguing with:
- **Every threat names the step that fixes it.** The order of the steps follows from the table. Identity comes first, because authorization, tenants and per-tenant limits all need to know who is asking.
- **Several threats are fixed by more than one step.** That's **defence in depth**: T6, the flat network, is narrowed by mutual TLS (step 7: reaching a service isn't enough, you must prove who you are) *and* by network policy (step 12: you can't reach it at all). Either alone would be one mistake away from failing.
- **The operator is out of scope.** Someone who can `kubectl exec` into any Pod can read what that Pod reads. Defending against your own administrators needs separation of duties and hardware roots of trust, which is a different project. Saying so stops the model from claiming more than it delivers.

**Explain it:** why does identity have to come before authorization, tenants and rate limits? Pick three rows: what property does each violate, and what would an attacker do with it? What is a trust boundary, and where does Runway have one that the diagram doesn't draw?

**Read.** Adam Shostack, *Threat Modeling: Designing for Security*, Ch. 1–3 (the four questions, diagrams, STRIDE). Then the [OWASP API Security Top 10](https://owasp.org/API-Security/editions/2023/en/0x11-t10/) (2023): which of its ten does this table already cover, and which doesn't it?

---
## Step 2: Tokens

**The problem.** Runway can't tell callers apart (T1). Every later control needs to know *who is asking*: which tenant, which roles. So the first job is **authentication**: each request carries proof of its caller's identity, and the API checks it before doing anything else.

**New ideas.**

- **Authentication vs authorization.** Authentication answers *who are you?*; authorization (step 3) answers *may you do this?* Keep them apart. A request can be perfectly authenticated and still not allowed.
- **Bearer tokens.** The caller sends `Authorization: Bearer <token>`, and whoever holds the token is treated as its subject. That makes a token as good as a password while it lasts: keep it short-lived, send it only over TLS (step 7), and never log it.
- **OAuth 2.0's client-credentials grant** is how a *program* (a customer's CI job, another service) gets a token: it sends its client ID and secret to the issuer's `/token` endpoint and gets back a token that expires in minutes. People log in through other flows (authorization code with PKCE, in a browser); the token the API sees is the same kind either way.
- **OpenID Connect discovery.** An issuer publishes `/.well-known/openid-configuration`, a document saying where its token endpoint and its keys are. Verifiers configure themselves from that one URL.
- **A JWT** (JSON Web Token) is three base64url parts joined by dots: a **header** (how it's signed, and with which key), a **payload** of claims (who, for whom, until when), and a **signature** over the first two. Anyone can read a JWT. Only the issuer can make one that verifies.
- **Asymmetric signatures.** The issuer signs with a private key, and the API verifies with the matching public key, so the API can check tokens without being able to make them. This step uses **Ed25519** ("EdDSA" in JWT's terms): small keys, fast, deterministic, with no parameters to get wrong. The alternative, HMAC with a shared secret, would let every verifier forge tokens.
- **JWKS and key IDs.** The issuer publishes its public keys as a JSON Web Key Set. Each token's header names the key that signed it (`kid`), so keys can be **rotated**: add a new key, publish both, sign with the new one, and drop the old one once every token it signed has expired.
- **The checks a verifier must make**, in order: the algorithm is the one you expect; the key is one *you* fetched from the issuer; the signature is valid; the issuer and audience are yours; the token hasn't expired. Each skipped check is a known attack.
- **Fail closed.** If the API can't verify, it refuses. If its configuration is missing, it doesn't start, rather than starting open.

**Why write it yourself?** Production code uses a maintained library and a real identity provider (Dex, Keycloak, Auth0, Okta, Cognito). Here you write about 600 lines on top of Go's own `crypto/ed25519`, because seeing every check is the point. You never write the cryptography itself; only the protocol around it, the part where real systems get it wrong.

### The token format

Create `internal/auth/jwt.go`:

<!-- file: internal/auth/jwt.go -->
~~~go
// Package auth issues and verifies access tokens: JSON Web Tokens (JWTs)
// signed with Ed25519, the signature algorithm JOSE calls "EdDSA".
//
// A JWT is three base64url parts joined by dots: a header saying how it is
// signed, a payload of claims (who, for whom, until when), and a signature
// over the first two. Anyone can read the claims; only the holder of the
// private key can produce a valid signature, and anyone with the public key
// can check it.
//
// This package implements just enough of the standards (RFC 7515, 7519,
// 8037) to show every check a verifier must make. Production code should
// use a maintained library, configured to make the same checks.
package auth

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Claims are what a token says about its holder.
type Claims struct {
	Issuer    string   `json:"iss"`           // who issued it
	Subject   string   `json:"sub"`           // who it's about: a user or a client
	Audience  Audience `json:"aud"`           // which services should accept it
	Expiry    int64    `json:"exp"`           // not valid at or after this Unix time
	NotBefore int64    `json:"nbf,omitempty"` // not valid before this
	IssuedAt  int64    `json:"iat"`
	ID        string   `json:"jti"` // unique per token (step 6)

	Tenant string   `json:"tenant,omitempty"` // whose data it may touch (step 4)
	Roles  []string `json:"roles,omitempty"`  // what it may do (step 3)
}

type header struct {
	Alg string `json:"alg"`
	Typ string `json:"typ"`
	Kid string `json:"kid"` // which key signed it
}

// The only algorithm this package signs or accepts.
const algorithm = "EdDSA"

// Errors a verifier returns. Callers can tell them apart; clients are told
// only "invalid token".
var (
	ErrMalformed  = errors.New("malformed token")
	ErrAlgorithm  = errors.New("unexpected signing algorithm")
	ErrUnknownKey = errors.New("unknown signing key")
	ErrSignature  = errors.New("bad signature")
	ErrExpired    = errors.New("token expired")
	ErrNotYet     = errors.New("token not valid yet")
	ErrIssuer     = errors.New("wrong issuer")
	ErrAudience   = errors.New("wrong audience")
)

var b64 = base64.RawURLEncoding

// Sign makes a token from claims, signed by key.
func Sign(claims Claims, key SigningKey) (string, error) {
	h, err := json.Marshal(header{Alg: algorithm, Typ: "JWT", Kid: key.ID})
	if err != nil {
		return "", err
	}
	p, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	signed := b64.EncodeToString(h) + "." + b64.EncodeToString(p)
	sig := ed25519.Sign(key.Private, []byte(signed))
	return signed + "." + b64.EncodeToString(sig), nil
}

// parse splits a token and decodes its header, without trusting anything.
func parse(token string) (h header, payload []byte, signed string, sig []byte, err error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return h, nil, "", nil, ErrMalformed
	}
	rawHeader, err := b64.DecodeString(parts[0])
	if err != nil {
		return h, nil, "", nil, ErrMalformed
	}
	if err := json.Unmarshal(rawHeader, &h); err != nil {
		return h, nil, "", nil, ErrMalformed
	}
	if payload, err = b64.DecodeString(parts[1]); err != nil {
		return h, nil, "", nil, ErrMalformed
	}
	if sig, err = b64.DecodeString(parts[2]); err != nil {
		return h, nil, "", nil, ErrMalformed
	}
	return h, payload, parts[0] + "." + parts[1], sig, nil
}

// HasRole reports whether the claims grant role.
func (c Claims) HasRole(role string) bool {
	for _, r := range c.Roles {
		if r == role {
			return true
		}
	}
	return false
}

func (c Claims) String() string {
	return fmt.Sprintf("sub=%s tenant=%s roles=%v", c.Subject, c.Tenant, c.Roles)
}

// Audience is the "aud" claim. RFC 7519 allows one string or an array of
// them; providers differ, so accept both. It is always written as an array.
type Audience []string

func (a *Audience) UnmarshalJSON(data []byte) error {
	var one string
	if err := json.Unmarshal(data, &one); err == nil {
		*a = Audience{one}
		return nil
	}
	var many []string
	if err := json.Unmarshal(data, &many); err != nil {
		return err
	}
	*a = many
	return nil
}
~~~

`Sign` is only a few lines. `parse` decodes the header without trusting it: everything in a token is attacker-controlled until its signature has been checked. Note that `aud` may be a single string or a list (RFC 7519 allows both, and real providers differ), so `Audience` accepts either.

### Keys

Create `internal/auth/keys.go`:

<!-- file: internal/auth/keys.go -->
~~~go
package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// SigningKey is a private key and the ID tokens name it by.
type SigningKey struct {
	ID      string
	Private ed25519.PrivateKey
}

// NewSigningKey makes a fresh key. Its ID starts with the date, so IDs sort
// in the order keys were made.
func NewSigningKey(now time.Time) (SigningKey, error) {
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return SigningKey{}, err
	}
	return SigningKey{ID: now.UTC().Format("20060102T150405") + "-" + strings.ToLower(rand.Text()[:6]), Private: private}, nil
}

// JWK is one public key in JSON Web Key form (RFC 7517, 8037).
type JWK struct {
	KeyType string `json:"kty"` // "OKP": an elliptic-curve key pair of this kind
	Curve   string `json:"crv"` // "Ed25519"
	X       string `json:"x"`   // the public key, base64url
	ID      string `json:"kid"`
	Alg     string `json:"alg"`
	Use     string `json:"use"` // "sig": for verifying signatures
}

// JWKS is the set of public keys an issuer publishes, at
// /.well-known/jwks.json. Verifiers fetch it to check signatures.
type JWKS struct {
	Keys []JWK `json:"keys"`
}

// Public returns k's public half as a JWK.
func (k SigningKey) Public() JWK {
	return JWK{KeyType: "OKP", Curve: "Ed25519", X: b64.EncodeToString(k.Private.Public().(ed25519.PublicKey)),
		ID: k.ID, Alg: algorithm, Use: "sig"}
}

// Key finds a public key by ID.
func (s JWKS) Key(kid string) (ed25519.PublicKey, error) {
	for _, k := range s.Keys {
		if k.ID != kid {
			continue
		}
		if k.KeyType != "OKP" || k.Curve != "Ed25519" {
			return nil, fmt.Errorf("key %s: unsupported type %s/%s", kid, k.KeyType, k.Curve)
		}
		x, err := b64.DecodeString(k.X)
		if err != nil || len(x) != ed25519.PublicKeySize {
			return nil, fmt.Errorf("key %s: bad public key", kid)
		}
		return ed25519.PublicKey(x), nil
	}
	return nil, ErrUnknownKey
}

// KeyDir is a directory of signing keys, one file each, named KID.key and
// holding the private key's 32-byte seed in base64url.
//
// Rotation without breaking anyone: add a new key (it signs from then on),
// keep the old one published until every token it signed has expired, then
// delete it. Every key in the directory is published; the newest signs.
type KeyDir string

// Rotate adds a new key to the directory and returns it.
func (d KeyDir) Rotate(now time.Time) (SigningKey, error) {
	key, err := NewSigningKey(now)
	if err != nil {
		return SigningKey{}, err
	}
	if err := os.MkdirAll(string(d), 0o700); err != nil {
		return SigningKey{}, err
	}
	seed := b64.EncodeToString(key.Private.Seed())
	// 0600: readable by this user only. A private key is the whole of the
	// issuer's authority.
	return key, os.WriteFile(filepath.Join(string(d), key.ID+".key"), []byte(seed+"\n"), 0o600)
}

// Load reads every key, oldest first.
func (d KeyDir) Load() ([]SigningKey, error) {
	files, err := filepath.Glob(filepath.Join(string(d), "*.key"))
	if err != nil {
		return nil, err
	}
	slices.Sort(files) // IDs begin with their creation time
	var keys []SigningKey
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		seed, err := b64.DecodeString(strings.TrimSpace(string(data)))
		if err != nil || len(seed) != ed25519.SeedSize {
			return nil, fmt.Errorf("%s: not a key", f)
		}
		keys = append(keys, SigningKey{ID: strings.TrimSuffix(filepath.Base(f), ".key"), Private: ed25519.NewKeyFromSeed(seed)})
	}
	if len(keys) == 0 {
		return nil, errors.New("no keys in " + string(d) + ": run \"idp rotate\" first")
	}
	return keys, nil
}

// Publish returns the JWKS for keys.
func Publish(keys []SigningKey) JWKS {
	set := JWKS{Keys: []JWK{}}
	for _, k := range keys {
		set.Keys = append(set.Keys, k.Public())
	}
	return set
}
~~~

A key ID starts with the time it was made, so sorting the files sorts the keys, and "the newest signs" is the last one. The private key is written `0600`, readable by its owner alone: the whole of the issuer's authority is in that file.

### Verifying

Create `internal/auth/verifier.go`:

<!-- file: internal/auth/verifier.go -->
~~~go
package auth

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"sync"
	"time"
)

// KeySource finds the public key a token names.
type KeySource interface {
	Key(ctx context.Context, kid string) (ed25519.PublicKey, error)
}

// Verifier checks tokens from one issuer, for one audience.
type Verifier struct {
	Issuer   string
	Audience string
	Keys     KeySource
	// Leeway tolerates clocks that differ a little between machines.
	Leeway time.Duration
	Now    func() time.Time
}

// Verify returns the claims of a valid token, or an error saying why it is
// not. The order matters: nothing in the token is trusted until the
// signature has been checked with a key the verifier chose.
func (v Verifier) Verify(ctx context.Context, token string) (Claims, error) {
	h, payload, signed, sig, err := parse(token)
	if err != nil {
		return Claims{}, err
	}
	// 1. The algorithm. The header is chosen by whoever made the token, so
	//    it can't be allowed to choose how it is checked: a verifier that
	//    obeys "alg" accepts "none" (no signature at all), or checks an
	//    HMAC with the *public* key as the secret.
	if h.Alg != algorithm {
		return Claims{}, fmt.Errorf("%w: %q", ErrAlgorithm, h.Alg)
	}
	// 2. The key, looked up by ID among the issuer's published keys, never
	//    taken from the token itself.
	key, err := v.Keys.Key(ctx, h.Kid)
	if err != nil {
		return Claims{}, err
	}
	// 3. The signature, over exactly the bytes that were signed.
	if !ed25519.Verify(key, []byte(signed), sig) {
		return Claims{}, ErrSignature
	}
	// Only now are the claims worth reading.
	var c Claims
	if err := json.Unmarshal(payload, &c); err != nil {
		return Claims{}, ErrMalformed
	}
	// 4. Who issued it, and for whom. A valid token for another service,
	//    signed by the same issuer, must not work here.
	if c.Issuer != v.Issuer {
		return Claims{}, ErrIssuer
	}
	if !slices.Contains(c.Audience, v.Audience) {
		return Claims{}, ErrAudience
	}
	// 5. When. Expiry bounds how long a stolen token is useful.
	now := v.now()
	if c.Expiry == 0 || !now.Before(time.Unix(c.Expiry, 0).Add(v.Leeway)) {
		return Claims{}, ErrExpired
	}
	if c.NotBefore != 0 && now.Add(v.Leeway).Before(time.Unix(c.NotBefore, 0)) {
		return Claims{}, ErrNotYet
	}
	return c, nil
}

func (v Verifier) now() time.Time {
	if v.Now == nil {
		return time.Now()
	}
	return v.Now()
}

// StaticKeys is a fixed key set, for tests.
type StaticKeys JWKS

func (s StaticKeys) Key(_ context.Context, kid string) (ed25519.PublicKey, error) {
	return JWKS(s).Key(kid)
}

// RemoteJWKS fetches an issuer's keys over HTTP and caches them. A token
// signed by a key it hasn't seen makes it fetch again, so a new key works
// as soon as the issuer publishes it; but no more than once per MinRefresh,
// so tokens with made-up key IDs can't make it hammer the issuer.
type RemoteJWKS struct {
	URL        string
	Client     *http.Client
	MinRefresh time.Duration

	mu      sync.Mutex
	set     JWKS
	fetched time.Time
}

func (r *RemoteJWKS) Key(ctx context.Context, kid string) (ed25519.PublicKey, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	key, err := r.set.Key(kid)
	if !errors.Is(err, ErrUnknownKey) {
		return key, err
	}
	if !r.fetched.IsZero() && time.Since(r.fetched) < r.MinRefresh {
		return nil, ErrUnknownKey
	}
	if err := r.fetch(ctx); err != nil {
		return nil, err
	}
	return r.set.Key(kid)
}

func (r *RemoteJWKS) fetch(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, r.URL, nil)
	if err != nil {
		return err
	}
	client := r.Client
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("fetch keys: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("fetch keys: %s", resp.Status)
	}
	var set JWKS
	if err := json.NewDecoder(resp.Body).Decode(&set); err != nil {
		return fmt.Errorf("fetch keys: %w", err)
	}
	r.set, r.fetched = set, time.Now()
	return nil
}
~~~

Read `Verify` from the top: each numbered check stops a specific attack.
1. **The algorithm** is fixed by the verifier. The classic JWT vulnerabilities came from libraries that read `alg` from the token and obeyed it: `"none"` meant no signature at all, and `"HS256"` made the library check an HMAC using the *public* key as the secret, which anyone can compute.
2. **The key** is looked up among the issuer's published keys. A token can't bring its own key (JWT has header fields for that, `jwk` and `jku`, which a careless verifier would follow).
3. **The signature** covers exactly the header and payload as sent.
4. **Issuer and audience.** The same issuer signs tokens for other services. A token for "billing" must not work on "runway", or a compromised billing service could replay its callers' tokens here.
5. **Time.** `Leeway` allows for clocks that differ a little between machines (30 seconds here). It does not make tokens last longer in any useful sense.

`RemoteJWKS` fetches the keys and caches them. A token naming an unknown key makes it fetch again, which is how a newly rotated key starts working. But an attacker can send tokens with made-up key IDs, so it refetches at most once per `MinRefresh`; without that limit, every bogus token would make the API call the issuer.

### Issuing

Create `internal/auth/issuer.go`:

<!-- file: internal/auth/issuer.go -->
~~~go
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Client is a registered caller that may ask for tokens: a service, or a
// customer's integration. It proves who it is with a secret.
type Client struct {
	ID         string
	SecretHash [32]byte // SHA-256 of the secret; the secret itself is never stored
	Tenant     string
	Roles      []string
}

// ParseClients reads clients from "id:secret:tenant:role+role,..." entries
// separated by commas. Real identity providers keep clients in a database,
// with salted, slow hashes for anything a person chose; random secrets of
// 32 bytes or more, as here, are safe with a fast hash.
func ParseClients(spec string) (map[string]Client, error) {
	clients := map[string]Client{}
	for _, entry := range strings.Split(spec, ",") {
		if strings.TrimSpace(entry) == "" {
			continue
		}
		f := strings.Split(entry, ":")
		if len(f) != 4 || f[0] == "" || f[1] == "" || f[2] == "" {
			return nil, fmt.Errorf("client %q: want id:secret:tenant:roles", entry)
		}
		var roles []string
		if f[3] != "" {
			roles = strings.Split(f[3], "+")
		}
		clients[f[0]] = Client{ID: f[0], SecretHash: sha256.Sum256([]byte(f[1])), Tenant: f[2], Roles: roles}
	}
	if len(clients) == 0 {
		return nil, errors.New("no clients")
	}
	return clients, nil
}

// ErrBadClient means an unknown client or a wrong secret. The two aren't
// told apart, so a caller can't discover which client IDs exist.
var ErrBadClient = errors.New("invalid client")

// Issuer makes tokens for registered clients.
type Issuer struct {
	URL      string // its own public URL: the "iss" claim
	Audience string // the service its tokens are for
	Lifetime time.Duration
	Clients  map[string]Client
	Key      SigningKey // the newest key in the KeyDir
	Now      func() time.Time
}

// Token authenticates a client by its secret and returns a signed token.
func (is Issuer) Token(clientID, secret string) (string, Claims, error) {
	c, ok := is.Clients[clientID]
	got := sha256.Sum256([]byte(secret))
	// Compare in constant time: a comparison that stops at the first
	// differing byte leaks, through timing, how much of a guess was right.
	if !ok || subtle.ConstantTimeCompare(got[:], c.SecretHash[:]) != 1 {
		return "", Claims{}, ErrBadClient
	}
	now := time.Now()
	if is.Now != nil {
		now = is.Now()
	}
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return "", Claims{}, err
	}
	claims := Claims{
		Issuer:   is.URL,
		Subject:  c.ID,
		Audience: Audience{is.Audience},
		IssuedAt: now.Unix(),
		Expiry:   now.Add(is.Lifetime).Unix(),
		ID:       hex.EncodeToString(id),
		Tenant:   c.Tenant,
		Roles:    c.Roles,
	}
	token, err := Sign(claims, is.Key)
	return token, claims, err
}
~~~

Two details. The secret is stored as a hash, and compared in **constant time**: `bytes.Equal` returns at the first differing byte, and the time it takes tells an attacker how much of a guess was right. And an unknown client and a wrong secret return the same error, so `/token` can't be used to find out which client IDs exist.

### Requiring a token

Create `internal/auth/middleware.go`:

<!-- file: internal/auth/middleware.go -->
~~~go
package auth

import (
	"context"
	"log/slog"
	"net/http"
	"slices"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

type claimsKey struct{}

// WithClaims returns ctx carrying c.
func WithClaims(ctx context.Context, c Claims) context.Context {
	return context.WithValue(ctx, claimsKey{}, c)
}

// FromContext returns the verified claims of the request, if it had any.
func FromContext(ctx context.Context) (Claims, bool) {
	c, ok := ctx.Value(claimsKey{}).(Claims)
	return c, ok
}

// bearer returns the token in an "Authorization: Bearer ..." value.
func bearer(value string) (string, bool) {
	scheme, token, ok := strings.Cut(value, " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") || token == "" {
		return "", false
	}
	return strings.TrimSpace(token), true
}

// Require wraps an HTTP handler so every request must carry a valid token,
// except for the public paths (health checks and metrics). A request
// without one gets 401 and a WWW-Authenticate header saying what's needed;
// the precise reason is logged, not sent, so a probing client learns
// nothing about which check failed.
func Require(v Verifier, logger *slog.Logger, next http.Handler, public ...string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if slices.Contains(public, r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		token, ok := bearer(r.Header.Get("Authorization"))
		if !ok {
			unauthorized(w, `Bearer realm="runway"`)
			return
		}
		claims, err := v.Verify(r.Context(), token)
		if err != nil {
			logger.Warn("rejected token", "error", err, "path", r.URL.Path)
			unauthorized(w, `Bearer realm="runway", error="invalid_token"`)
			return
		}
		next.ServeHTTP(w, r.WithContext(WithClaims(r.Context(), claims)))
	})
}

func unauthorized(w http.ResponseWriter, challenge string) {
	w.Header().Set("WWW-Authenticate", challenge)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	_, _ = w.Write([]byte(`{"error":"authentication required"}` + "\n"))
}

// UnaryInterceptor is Require for gRPC: the token comes in the
// "authorization" metadata, and a bad one is codes.Unauthenticated.
// Reflection, which lists the API's methods, is left open to callers with a
// token only: it is a map for an attacker, too.
func UnaryInterceptor(v Verifier, logger *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		claims, err := fromMetadata(ctx, v)
		if err != nil {
			logger.Warn("rejected token", "error", err, "method", info.FullMethod)
			return nil, status.Error(codes.Unauthenticated, "authentication required")
		}
		return handler(WithClaims(ctx, claims), req)
	}
}

// StreamInterceptor guards streaming calls, reflection's among them.
func StreamInterceptor(v Verifier, logger *slog.Logger) grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if _, err := fromMetadata(ss.Context(), v); err != nil {
			logger.Warn("rejected token", "error", err, "method", info.FullMethod)
			return status.Error(codes.Unauthenticated, "authentication required")
		}
		return handler(srv, ss)
	}
}

func fromMetadata(ctx context.Context, v Verifier) (Claims, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	values := md.Get("authorization")
	if len(values) != 1 {
		return Claims{}, ErrMalformed
	}
	token, ok := bearer(values[0])
	if !ok {
		return Claims{}, ErrMalformed
	}
	return v.Verify(ctx, token)
}
~~~

A refused request gets `401` and a `WWW-Authenticate` header, as HTTP requires. The *reason* (expired, wrong audience, bad signature) goes to the log and never to the client: a precise error helps an attacker tune a forgery. gRPC gets the same checks as interceptors, and reflection, the service that lists the API's methods, now needs a token too.

### Test it

Create `internal/auth/auth_test.go`:

<!-- file: internal/auth/auth_test.go -->
~~~go
package auth

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

var t0 = time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)

func newKey(t *testing.T) SigningKey {
	t.Helper()
	k, err := NewSigningKey(t0)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func validClaims() Claims {
	return Claims{Issuer: "https://idp.test", Subject: "client-a", Audience: Audience{"runway"},
		IssuedAt: t0.Unix(), Expiry: t0.Add(5 * time.Minute).Unix(), ID: "1", Tenant: "acme", Roles: []string{"submitter"}}
}

func verifierFor(keys ...SigningKey) Verifier {
	return Verifier{Issuer: "https://idp.test", Audience: "runway", Keys: StaticKeys(Publish(keys)),
		Leeway: 30 * time.Second, Now: func() time.Time { return t0.Add(time.Minute) }}
}

func sign(t *testing.T, c Claims, k SigningKey) string {
	t.Helper()
	token, err := Sign(c, k)
	if err != nil {
		t.Fatal(err)
	}
	return token
}

func TestAValidTokenVerifies(t *testing.T) {
	k := newKey(t)
	got, err := verifierFor(k).Verify(context.Background(), sign(t, validClaims(), k))
	if err != nil || got.Tenant != "acme" || !got.HasRole("submitter") {
		t.Fatalf("Verify = %v, %v", got, err)
	}
}

// forge builds a token with any header and payload, and a signature of the
// caller's choosing: what an attacker can do.
func forge(header, payload map[string]any, sig string) string {
	h, _ := json.Marshal(header)
	p, _ := json.Marshal(payload)
	return b64.EncodeToString(h) + "." + b64.EncodeToString(p) + "." + sig
}

func TestRejected(t *testing.T) {
	k, other := newKey(t), newKey(t)
	v := verifierFor(k)
	claims := map[string]any{"iss": "https://idp.test", "aud": "runway", "exp": t0.Add(time.Hour).Unix(), "sub": "mallory"}
	valid := sign(t, validClaims(), k)
	parts := strings.Split(valid, ".")
	tampered := parts[0] + "." + b64.EncodeToString([]byte(`{"iss":"https://idp.test","aud":["runway"],"exp":9999999999,"sub":"mallory","roles":["admin"]}`)) + "." + parts[2]

	expired := validClaims()
	expired.Expiry = t0.Add(-time.Minute).Unix() // a minute before "now", beyond the 30 s leeway
	future := validClaims()
	future.NotBefore = t0.Add(10 * time.Minute).Unix()
	wrongIssuer := validClaims()
	wrongIssuer.Issuer = "https://evil.test"
	wrongAudience := validClaims()
	wrongAudience.Audience = Audience{"billing"}
	otherKeySameID := other
	otherKeySameID.ID = k.ID

	for name, tc := range map[string]struct {
		token string
		want  error
	}{
		"not a JWT":                        {"hello", ErrMalformed},
		`"alg": "none"`:                    {forge(map[string]any{"alg": "none", "kid": k.ID}, claims, ""), ErrAlgorithm},
		`"alg": "HS256"`:                   {forge(map[string]any{"alg": "HS256", "kid": k.ID}, claims, "c2lnbmVk"), ErrAlgorithm},
		"a changed payload":                {tampered, ErrSignature},
		"another key, same kid":            {sign(t, validClaims(), otherKeySameID), ErrSignature},
		"a key the issuer never published": {sign(t, validClaims(), other), ErrUnknownKey},
		"expired":                          {sign(t, expired, k), ErrExpired},
		"not valid yet":                    {sign(t, future, k), ErrNotYet},
		"another issuer":                   {sign(t, wrongIssuer, k), ErrIssuer},
		"for another service":              {sign(t, wrongAudience, k), ErrAudience},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := v.Verify(context.Background(), tc.token); !errors.Is(err, tc.want) {
				t.Fatalf("error = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestLeewayAllowsSmallClockDifferences(t *testing.T) {
	k := newKey(t)
	c := validClaims()
	c.Expiry = t0.Add(50 * time.Second).Unix() // "now" is t0+60s: 10 s late, within 30 s
	if _, err := verifierFor(k).Verify(context.Background(), sign(t, c, k)); err != nil {
		t.Fatalf("10 s past expiry with 30 s leeway: %v", err)
	}
}

func TestAudienceMayBeAString(t *testing.T) {
	var c Claims
	if err := json.Unmarshal([]byte(`{"aud":"runway"}`), &c); err != nil || len(c.Audience) != 1 || c.Audience[0] != "runway" {
		t.Fatalf("aud as a string: %v, %v", c.Audience, err)
	}
}

func TestKeyDirRotation(t *testing.T) {
	dir := KeyDir(t.TempDir())
	first, err := dir.Rotate(t0)
	if err != nil {
		t.Fatal(err)
	}
	second, err := dir.Rotate(t0.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	keys, err := dir.Load()
	if err != nil || len(keys) != 2 || keys[0].ID != first.ID || keys[1].ID != second.ID {
		t.Fatalf("Load = %v, %v; want [first second]", keys, err)
	}
	// A token from the old key still verifies while it is published.
	v := verifierFor(keys...)
	if _, err := v.Verify(context.Background(), sign(t, validClaims(), first)); err != nil {
		t.Fatalf("old key: %v", err)
	}
}

// The remote key set fetches again for an unknown key, but not more often
// than MinRefresh.
func TestRemoteJWKSRefetchesForNewKeysButNotTooOften(t *testing.T) {
	k1, k2 := newKey(t), newKey(t)
	var published atomic.Value
	published.Store(Publish([]SigningKey{k1}))
	var fetches atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fetches.Add(1)
		_ = json.NewEncoder(w).Encode(published.Load())
	}))
	defer server.Close()
	remote := &RemoteJWKS{URL: server.URL, MinRefresh: time.Hour}
	ctx := context.Background()

	if _, err := remote.Key(ctx, k1.ID); err != nil {
		t.Fatal(err)
	}
	for range 5 { // an attacker's made-up key IDs: one fetch at most
		_, _ = remote.Key(ctx, "made-up")
	}
	if n := fetches.Load(); n != 1 {
		t.Fatalf("%d fetches; unknown keys within MinRefresh must not refetch", n)
	}
	published.Store(Publish([]SigningKey{k1, k2}))
	remote.MinRefresh = 0
	if _, err := remote.Key(ctx, k2.ID); err != nil {
		t.Fatalf("a newly published key: %v", err)
	}
}

func TestIssuer(t *testing.T) {
	clients, err := ParseClients("acme-ci:s3cret:acme:submitter+reader,ops:0ps:runway:admin")
	if err != nil {
		t.Fatal(err)
	}
	k := newKey(t)
	is := Issuer{URL: "https://idp.test", Audience: "runway", Lifetime: 5 * time.Minute, Clients: clients, Key: k, Now: func() time.Time { return t0 }}
	token, claims, err := is.Token("acme-ci", "s3cret")
	if err != nil || claims.Tenant != "acme" || !claims.HasRole("reader") {
		t.Fatalf("Token = %v, %v", claims, err)
	}
	if _, err := verifierFor(k).Verify(context.Background(), token); err != nil {
		t.Fatalf("issued token: %v", err)
	}
	_, _, wrongSecret := is.Token("acme-ci", "guess")
	_, _, unknown := is.Token("nobody", "s3cret")
	if !errors.Is(wrongSecret, ErrBadClient) || !errors.Is(unknown, ErrBadClient) {
		t.Fatalf("wrong secret: %v; unknown client: %v; want the same error for both", wrongSecret, unknown)
	}
}

func TestRequire(t *testing.T) {
	k := newKey(t)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	var seen Claims
	handler := Require(verifierFor(k), logger, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen, _ = FromContext(r.Context())
	}), "/health")
	do := func(path, authorization string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, path, nil)
		if authorization != "" {
			r.Header.Set("Authorization", authorization)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	if w := do("/jobs/1", ""); w.Code != http.StatusUnauthorized || !strings.HasPrefix(w.Header().Get("WWW-Authenticate"), "Bearer") {
		t.Fatalf("no token: %d %q", w.Code, w.Header().Get("WWW-Authenticate"))
	}
	if w := do("/jobs/1", "Bearer not.a.token"); w.Code != http.StatusUnauthorized {
		t.Fatalf("bad token: %d", w.Code)
	}
	if w := do("/jobs/1", "Bearer "+sign(t, validClaims(), k)); w.Code != http.StatusOK || seen.Subject != "client-a" {
		t.Fatalf("good token: %d, claims %v", w.Code, seen)
	}
	if w := do("/health", ""); w.Code != http.StatusOK {
		t.Fatalf("a public path: %d", w.Code)
	}
}

func TestUnaryInterceptor(t *testing.T) {
	k := newKey(t)
	intercept := UnaryInterceptor(verifierFor(k), slog.New(slog.NewTextHandler(io.Discard, nil)))
	call := func(ctx context.Context) error {
		_, err := intercept(ctx, nil, &grpc.UnaryServerInfo{FullMethod: "/runway.jobs.v1.Jobs/GetJob"},
			func(ctx context.Context, req any) (any, error) {
				if _, ok := FromContext(ctx); !ok {
					t.Error("handler ran without claims")
				}
				return nil, nil
			})
		return err
	}
	if err := call(context.Background()); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("no token: %v", err)
	}
	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs("authorization", "Bearer "+sign(t, validClaims(), k)))
	if err := call(ctx); err != nil {
		t.Fatalf("good token: %v", err)
	}
}
~~~

`TestRejected` is the heart of this step: one valid-looking token per attack, each with the error it must produce. `forge` builds tokens the way an attacker would, with any header, any claims, and a signature of their choosing.

<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/auth/ && go test -race -count=1 ./internal/auth/ -->

**Break it.** Two experiments, each a one-line change to `Verify`; undo each afterwards.

First, delete the audience check (the `if !slices.Contains(c.Audience, v.Audience)` block) and run the tests:

~~~text
--- FAIL: TestRejected (0.00s)
    --- FAIL: TestRejected/for_another_service (0.00s)
        auth_test.go:104: error = <nil>, want wrong audience
~~~

A token issued for billing now works on Runway. Nothing else noticed: every other test passed.

Second, put the audience check back and delete the algorithm check instead (`if h.Alg != algorithm`):

~~~text
--- FAIL: TestRejected (0.00s)
    --- FAIL: TestRejected/"alg":_"HS256" (0.00s)
        auth_test.go:104: error = bad signature, want unexpected signing algorithm
    --- FAIL: TestRejected/"alg":_"none" (0.00s)
        auth_test.go:104: error = bad signature, want unexpected signing algorithm
~~~

The forged tokens are still refused, only for a different reason. This verifier knows one algorithm, so it checks an Ed25519 signature whatever the header says, and the forgeries have none. The attack needs a verifier that *dispatches* on `alg`, as general-purpose libraries do. So the check looks redundant here. Keep it anyway: it's what stops the attack the day someone adds a second algorithm, and the test is what tells you it's still there.

### Protecting the routes

The handler decides which routes are protected. In `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	ready          func(context.Context) error
}
~~~

to:

~~~go
	ready          func(context.Context) error
	authenticate   func(http.Handler) http.Handler
}
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	return func(c *config) { c.servedBy = name }
}
~~~

to:

~~~go
	return func(c *config) { c.servedBy = name }
}

// WithAuthentication wraps every route that touches jobs with authenticate
// (Phase 6), such as auth.Require. Health, readiness and metrics stay open.
// It wraps each route, not the whole router, so that logging and metrics
// still see the route the router matched.
func WithAuthentication(authenticate func(http.Handler) http.Handler) Option {
	return func(c *config) { c.authenticate = authenticate }
}
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	mux.Handle("POST /jobs", create)
	mux.HandleFunc("GET /jobs/{id}", h.getJob)
~~~

to:

~~~go
	protect := func(next http.Handler) http.Handler {
		if cfg.authenticate == nil {
			return next
		}
		return cfg.authenticate(next)
	}
	mux.Handle("POST /jobs", protect(create))
	mux.Handle("GET /jobs/{id}", protect(http.HandlerFunc(h.getJob)))
~~~


Each job route is wrapped, rather than the whole router, so that the metrics middleware still sees which route a refused request was for. Test it in `internal/httpapi/handler_test.go`:

Add this at the end of the file:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
// A stand-in for auth.Require: only requests carrying X-Test: ok get in.
func onlyIfOK(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Test") != "ok" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func TestAuthenticationGuardsJobRoutesOnly(t *testing.T) {
	metrics := NewMetrics()
	h := newTestHandler(WithAuthentication(onlyIfOK), WithMetrics(metrics))
	if got := do(t, h, http.MethodPost, "/jobs", `{"description":"x","duration_ms":1}`); got.Code != http.StatusUnauthorized {
		t.Fatalf("POST /jobs without credentials = %d, want 401", got.Code)
	}
	if got := do(t, h, http.MethodGet, "/health", ""); got.Code != http.StatusOK {
		t.Fatalf("GET /health = %d; health checks need no credentials", got.Code)
	}
	r := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(`{"description":"x","duration_ms":1}`))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Test", "ok")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusCreated {
		t.Fatalf("POST /jobs with credentials = %d, want 201", w.Code)
	}
	// The refusal is counted under its real route, not "unmatched".
	body := do(t, h, http.MethodGet, "/metrics", "").Body.String()
	if !strings.Contains(body, `http_requests_total{code="401",method="POST",route="POST /jobs"} 1`) {
		t.Fatalf("metrics don't count the 401 under its route:\n%s", body)
	}
}
~~~


The last check matters more than it looks: if the middleware wrapped the router, every 401 would be counted as `route="unmatched"`, and an attack would be invisible on the dashboard.

### The issuer

Create `cmd/idp/main.go`:

<!-- file: cmd/idp/main.go -->
~~~go
// Command idp is a small identity provider: it issues access tokens to
// registered clients with the OAuth 2.0 client-credentials grant, and
// publishes the keys to check them with, as an OpenID Connect provider
// does. Real deployments use a real provider (Dex, Keycloak, Auth0, Okta,
// Cognito); this one is small enough to read in one sitting.
//
//	idp                 serve
//	idp rotate DIR      add a new signing key to DIR
//
//	IDP_ISSUER          its public URL, the tokens' "iss" (required)
//	IDP_AUDIENCE        the tokens' "aud" (runway)
//	IDP_CLIENTS         id:secret:tenant:role+role,... (required)
//	IDP_KEYS            the key directory (required)
//	IDP_TOKEN_LIFETIME  how long tokens last (5m)
//	IDP_CREATE_KEY      true: make a key if IDP_KEYS has none (for Compose)
//	LISTEN_ADDR         where to listen (127.0.0.1:8081)
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"runway/internal/auth"
	"runway/internal/envconfig"
)

func main() {
	if len(os.Args) == 3 && os.Args[1] == "rotate" {
		key, err := auth.KeyDir(os.Args[2]).Rotate(time.Now())
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println("new signing key:", key.ID)
		return
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Getenv, os.Stdout, nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type config struct {
	Issuer, Audience, ListenAddr string
	Clients                      map[string]auth.Client
	Keys                         auth.KeyDir
	Lifetime                     time.Duration
}

func loadConfig(getenv envconfig.Getenv) (config, error) {
	cfg := config{Issuer: getenv("IDP_ISSUER"), Audience: getenv("IDP_AUDIENCE"), Keys: auth.KeyDir(getenv("IDP_KEYS"))}
	if cfg.Issuer == "" || cfg.Keys == "" {
		return config{}, errors.New("IDP_ISSUER and IDP_KEYS are required")
	}
	if cfg.Audience == "" {
		cfg.Audience = "runway"
	}
	var err error
	if cfg.Clients, err = auth.ParseClients(getenv("IDP_CLIENTS")); err != nil {
		return config{}, fmt.Errorf("IDP_CLIENTS: %w", err)
	}
	if cfg.Lifetime, err = envconfig.Duration(getenv, "IDP_TOKEN_LIFETIME", 5*time.Minute); err != nil {
		return config{}, err
	}
	if cfg.ListenAddr, err = envconfig.HostPort(getenv, "LISTEN_ADDR", "127.0.0.1:8081"); err != nil {
		return config{}, err
	}
	return cfg, nil
}

// keyring holds the keys, reloaded from disk so a rotation needs no
// restart: on Kubernetes the keys are a mounted Secret, which the kubelet
// updates in place.
type keyring struct {
	dir  auth.KeyDir
	mu   sync.RWMutex
	keys []auth.SigningKey
}

func (k *keyring) reload() error {
	keys, err := k.dir.Load()
	if err != nil {
		return err
	}
	k.mu.Lock()
	k.keys = keys
	k.mu.Unlock()
	return nil
}

func (k *keyring) get() []auth.SigningKey {
	k.mu.RLock()
	defer k.mu.RUnlock()
	return k.keys
}

func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer, ready func(addr string)) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
	ring := &keyring{dir: cfg.Keys}
	if getenv("IDP_CREATE_KEY") == "true" {
		if _, err := cfg.Keys.Load(); err != nil {
			if _, err := cfg.Keys.Rotate(time.Now()); err != nil {
				return err
			}
		}
	}
	if err := ring.reload(); err != nil {
		return err
	}
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-time.After(30 * time.Second):
				if err := ring.reload(); err != nil {
					logger.Warn("reloading keys failed; keeping the old ones", "error", err)
				}
			}
		}
	}()

	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}
	server := &http.Server{Handler: handler(cfg, ring, logger), ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = server.Serve(listener) }()
	keys := ring.get()
	logger.Info("idp listening", "addr", listener.Addr().String(), "issuer", cfg.Issuer, "clients", len(cfg.Clients),
		"keys", len(keys), "signing_key", keys[len(keys)-1].ID)
	if ready != nil {
		ready(listener.Addr().String())
	}
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return server.Shutdown(shutdown)
}

func handler(cfg config, ring *keyring, logger *slog.Logger) http.Handler {
	mux := http.NewServeMux()
	// Discovery: where everything else is. Clients and verifiers configure
	// themselves from this one URL.
	mux.HandleFunc("GET /.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"issuer":                                cfg.Issuer,
			"jwks_uri":                              cfg.Issuer + "/.well-known/jwks.json",
			"token_endpoint":                        cfg.Issuer + "/token",
			"grant_types_supported":                 []string{"client_credentials"},
			"token_endpoint_auth_methods_supported": []string{"client_secret_basic", "client_secret_post"},
			"id_token_signing_alg_values_supported": []string{"EdDSA"},
		})
	})
	mux.HandleFunc("GET /.well-known/jwks.json", func(w http.ResponseWriter, r *http.Request) {
		// Public keys may be cached, but not for long: a rotation must
		// reach verifiers before the new key signs anything they'd reject.
		w.Header().Set("Cache-Control", "public, max-age=60")
		writeJSON(w, http.StatusOK, auth.Publish(ring.get()))
	})
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("POST /token", func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil || r.PostForm.Get("grant_type") != "client_credentials" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported_grant_type"})
			return
		}
		// The client's ID and secret, in an HTTP Basic header or the form.
		id, secret, ok := r.BasicAuth()
		if !ok {
			id, secret = r.PostForm.Get("client_id"), r.PostForm.Get("client_secret")
		}
		keys := ring.get()
		issuer := auth.Issuer{URL: cfg.Issuer, Audience: cfg.Audience, Lifetime: cfg.Lifetime, Clients: cfg.Clients, Key: keys[len(keys)-1]}
		token, claims, err := issuer.Token(id, secret)
		if err != nil {
			logger.Warn("token refused", "client_id", id)
			w.Header().Set("WWW-Authenticate", `Basic realm="idp"`)
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid_client"})
			return
		}
		logger.Info("token issued", "client_id", id, "tenant", claims.Tenant, "jti", claims.ID)
		// Tokens must not be cached anywhere between here and the client.
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, map[string]any{
			"access_token": token, "token_type": "Bearer", "expires_in": int(cfg.Lifetime.Seconds()),
		})
	})
	return mux
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
~~~

It reloads its keys every 30 seconds, so a rotation needs no restart: on Kubernetes the keys are a mounted Secret, which the kubelet updates in place. Its responses say how they may be cached: the keys for a minute, tokens never (`no-store`).

Create `cmd/idp/main_test.go`:

<!-- file: cmd/idp/main_test.go -->
~~~go
package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"runway/internal/auth"
)

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

// start runs the real server on a random port and returns its URL.
func start(t *testing.T) string {
	t.Helper()
	keys := auth.KeyDir(t.TempDir())
	if _, err := keys.Rotate(time.Now()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	addr := make(chan string, 1)
	done := make(chan error, 1)
	vars := env(map[string]string{"IDP_ISSUER": "http://idp.test", "IDP_KEYS": string(keys),
		"IDP_CLIENTS": "acme-ci:s3cret:acme:submitter", "LISTEN_ADDR": "127.0.0.1:0"})
	go func() { done <- run(ctx, vars, io.Discard, func(a string) { addr <- a }) }()
	t.Cleanup(func() { cancel(); <-done })
	select {
	case a := <-addr:
		return "http://" + a
	case err := <-done:
		t.Fatal(err)
	}
	return ""
}

func TestIssuesTokensThatVerifyAgainstItsKeys(t *testing.T) {
	base := start(t)
	var discovery map[string]any
	resp, err := http.Get(base + "/.well-known/openid-configuration")
	if err != nil {
		t.Fatal(err)
	}
	_ = json.NewDecoder(resp.Body).Decode(&discovery)
	resp.Body.Close()
	if discovery["jwks_uri"] != "http://idp.test/.well-known/jwks.json" {
		t.Fatalf("discovery = %v", discovery)
	}

	// The secret in a Basic header (client_secret_basic).
	req, _ := http.NewRequest(http.MethodPost, base+"/token", strings.NewReader("grant_type=client_credentials"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.SetBasicAuth("acme-ci", "s3cret")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var body struct {
		AccessToken string `json:"access_token"`
		TokenType   string `json:"token_type"`
		ExpiresIn   int    `json:"expires_in"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || body.TokenType != "Bearer" || body.ExpiresIn != 300 || resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("token response: %d %+v %q", resp.StatusCode, body, resp.Header.Get("Cache-Control"))
	}

	// Verify it the way the API will: with keys fetched from the JWKS URL.
	v := auth.Verifier{Issuer: "http://idp.test", Audience: "runway", Keys: &auth.RemoteJWKS{URL: base + "/.well-known/jwks.json"}}
	claims, err := v.Verify(context.Background(), body.AccessToken)
	if err != nil || claims.Tenant != "acme" {
		t.Fatalf("verify: %v, %v", claims, err)
	}
}

func TestRefusesBadClients(t *testing.T) {
	base := start(t)
	for name, form := range map[string]url.Values{
		"a wrong secret":    {"grant_type": {"client_credentials"}, "client_id": {"acme-ci"}, "client_secret": {"guess"}},
		"an unknown client": {"grant_type": {"client_credentials"}, "client_id": {"nobody"}, "client_secret": {"s3cret"}},
	} {
		resp, err := http.PostForm(base+"/token", form)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s: %d, want 401", name, resp.StatusCode)
		}
	}
	resp, err := http.PostForm(base+"/token", url.Values{"grant_type": {"password"}})
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("another grant type: %d, want 400", resp.StatusCode)
	}
}

func TestConfigIsRequired(t *testing.T) {
	if _, err := loadConfig(env(nil)); err == nil {
		t.Fatal("no IDP_ISSUER or IDP_KEYS should be refused")
	}
}
~~~

### The API

The API needs to know which issuer to trust. In `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go

	"runway/internal/background"
~~~

to:

~~~go

	"runway/internal/auth"
	"runway/internal/background"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	ServedBy         string
}
~~~

to:

~~~go
	ServedBy         string
	// Phase 6: who may call. AuthOff only with AUTH_MODE=off, said out loud.
	AuthOff      bool
	AuthIssuer   string
	AuthAudience string
	AuthJWKSURL  string
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), SQSPrefix: getenv("SQS_QUEUE_PREFIX"), DatabaseURL: getenv("DATABASE_URL"), RedisURL: getenv("REDIS_URL"), ServedBy: getenv("SERVED_BY")}
	if cfg.AMQPURL != "" && cfg.SQSPrefix != "" {
~~~

to:

~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), SQSPrefix: getenv("SQS_QUEUE_PREFIX"), DatabaseURL: getenv("DATABASE_URL"), RedisURL: getenv("REDIS_URL"), ServedBy: getenv("SERVED_BY")}
	if err := loadAuth(&cfg, getenv); err != nil {
		return config{}, err
	}
	if cfg.AMQPURL != "" && cfg.SQSPrefix != "" {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	return cfg, nil
}
~~~

to:

~~~go
	return cfg, nil
}

// loadAuth reads the token settings. Authentication is on unless
// AUTH_MODE=off: a forgotten variable must not leave the API open, so a
// missing AUTH_ISSUER stops it from starting instead (fail closed).
func loadAuth(cfg *config, getenv envconfig.Getenv) error {
	cfg.AuthIssuer, cfg.AuthAudience, cfg.AuthJWKSURL = getenv("AUTH_ISSUER"), getenv("AUTH_AUDIENCE"), getenv("AUTH_JWKS_URL")
	switch getenv("AUTH_MODE") {
	case "off":
		cfg.AuthOff = true
		return nil
	case "", "required":
	default:
		return errors.New("AUTH_MODE must be required or off")
	}
	if cfg.AuthIssuer == "" {
		return errors.New("AUTH_ISSUER is required: the URL of the token issuer (AUTH_MODE=off turns authentication off, for local development only)")
	}
	if cfg.AuthAudience == "" {
		cfg.AuthAudience = "runway"
	}
	if cfg.AuthJWKSURL == "" {
		cfg.AuthJWKSURL = strings.TrimSuffix(cfg.AuthIssuer, "/") + "/.well-known/jwks.json"
	}
	return nil
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	var grpcOptions []grpc.ServerOption
~~~

to:

~~~go
	var unary []grpc.UnaryServerInterceptor
	var stream []grpc.StreamServerInterceptor
	if cfg.AuthOff {
		logger.Warn("authentication is off (AUTH_MODE=off): anyone can call this API")
	} else {
		verifier := auth.Verifier{
			Issuer:   cfg.AuthIssuer,
			Audience: cfg.AuthAudience,
			Keys:     &auth.RemoteJWKS{URL: cfg.AuthJWKSURL, MinRefresh: 30 * time.Second},
			Leeway:   30 * time.Second,
		}
		options = append(options, httpapi.WithAuthentication(func(next http.Handler) http.Handler {
			return auth.Require(verifier, logger, next)
		}))
		unary = append(unary, auth.UnaryInterceptor(verifier, logger))
		stream = append(stream, auth.StreamInterceptor(verifier, logger))
	}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		grpcOptions = append(grpcOptions, grpc.UnaryInterceptor(grpcapi.ServedBy(cfg.ServedBy)))
	}
	handler := httpapi.NewHandler(service, options...)
~~~

to:

~~~go
		unary = append(unary, grpcapi.ServedBy(cfg.ServedBy))
	}
	// Interceptors run in order: authentication first.
	grpcOptions := []grpc.ServerOption{grpc.ChainUnaryInterceptor(unary...), grpc.ChainStreamInterceptor(stream...)}
	handler := httpapi.NewHandler(service, options...)
~~~


`AUTH_MODE` is `required` unless it says `off`, and `required` with no `AUTH_ISSUER` stops the API from starting. The alternative, "no issuer configured, so authentication is off", is how APIs end up on the internet with no authentication: one missing variable in one environment.

In `cmd/api/main_test.go`, the existing tests are about jobs, not identity, so the test environment turns authentication off unless a test asks for it. Two new tests check both directions:

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go
	"net/http"
	"strings"
~~~

to:

~~~go
	"net/http"
	"net/http/httptest"
	"strings"
~~~

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go

	"runway/internal/pgstore/pgtest"
~~~

to:

~~~go

	"runway/internal/auth"
	"runway/internal/pgstore/pgtest"
~~~

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
~~~

to:

~~~go

// env serves values as environment variables. These tests are about jobs,
// not identity, so authentication is off unless a test sets AUTH_MODE;
// TestAuth... below test it on.
func env(values map[string]string) func(string) string {
	return func(key string) string {
		if v, ok := values[key]; ok {
			return v
		}
		if key == "AUTH_MODE" {
			return "off"
		}
		return ""
	}
~~~

Add this at the end of the file:

<!-- append: cmd/api/main_test.go -->
~~~go
func TestAuthIsRequiredByDefault(t *testing.T) {
	// A real environment: nothing set, not even AUTH_MODE.
	_, err := loadConfig(func(string) string { return "" })
	if err == nil || !strings.Contains(err.Error(), "AUTH_ISSUER is required") {
		t.Fatalf("error = %v; with no settings the API must refuse to start", err)
	}
	if _, err := loadConfig(env(map[string]string{"AUTH_MODE": "maybe"})); err == nil {
		t.Fatal("an unknown AUTH_MODE was accepted")
	}
}

// jwksServer publishes key's public half, as an issuer would.
func jwksServer(t *testing.T, key auth.SigningKey) string {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(auth.Publish([]auth.SigningKey{key}))
	}))
	t.Cleanup(server.Close)
	return server.URL
}

func TestAuthGuardsJobsButNotHealth(t *testing.T) {
	key, err := auth.NewSigningKey(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	base, _, _, _ := startServer(t, map[string]string{
		"AUTH_MODE": "required", "AUTH_ISSUER": "http://idp.test", "AUTH_JWKS_URL": jwksServer(t, key) + "/.well-known/jwks.json",
	})
	post := func(token string) int {
		req, _ := http.NewRequest(http.MethodPost, base+"/jobs", strings.NewReader(`{"description":"x","duration_ms":1}`))
		req.Header.Set("Content-Type", "application/json")
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if code := post(""); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d, want 401", code)
	}
	now := time.Now()
	token, err := auth.Sign(auth.Claims{Issuer: "http://idp.test", Subject: "t", Audience: auth.Audience{"runway"},
		IssuedAt: now.Unix(), Expiry: now.Add(time.Minute).Unix()}, key)
	if err != nil {
		t.Fatal(err)
	}
	if code := post(token); code != http.StatusCreated {
		t.Fatalf("a valid token: %d, want 201", code)
	}
	resp, err := http.Get(base + "/health")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/health without a token: %d, want 200", resp.StatusCode)
	}
}
~~~


`jobsctl` sends the token with every gRPC call. In `cmd/jobsctl/main.go`:

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
//	jobsctl spread N    make N calls and count which instance answered each
package main
~~~

to:

~~~go
//	jobsctl spread N    make N calls and count which instance answered each
//
// RUNWAY_TOKEN, if set, is sent with every call as a bearer token.
package main
~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
	conn, err := grpc.NewClient(addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
~~~

to:

~~~go
	opts := []grpc.DialOption{grpc.WithTransportCredentials(insecure.NewCredentials())}
	if token := os.Getenv("RUNWAY_TOKEN"); token != "" {
		opts = append(opts, grpc.WithPerRPCCredentials(bearer(token)))
	}
	conn, err := grpc.NewClient(addr, append(opts,
~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
	)
~~~

to:

~~~go
	)...)
~~~

Add this at the end of the file:

<!-- append: cmd/jobsctl/main.go -->
~~~go
// bearer sends a token in the "authorization" metadata of every call.
type bearer string

func (b bearer) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	return map[string]string{"authorization": "Bearer " + string(b)}, nil
}

// RequireTransportSecurity says whether the token may only travel over TLS.
// No, so that it works in Compose, which has no TLS. On the cluster the API
// refuses plain gRPC altogether (step 7), so there it always travels in TLS.
func (bearer) RequireTransportSecurity() bool { return false }
~~~


`RequireTransportSecurity` returns `false`, which lets the token travel over plain gRPC, as it must in Compose, where there's no TLS. On the cluster, step 7 makes the API refuse plain gRPC altogether.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/auth/... ./internal/httpapi/... ./cmd/api/... ./cmd/idp/... ./cmd/jobsctl/... -->

### Compose and the chart

In `compose.yaml`, add the issuer and point the API at it:

Change:

<!-- edit: compose.yaml -->
~~~yaml

  # Runway itself. These start only with --profile app, so a plain
~~~

to:

~~~yaml

  # The token issuer (Phase 6). Its keys are in memory (tmpfs): a restart
  # makes new ones, and tokens signed by the old ones stop working, which is
  # fine on a laptop. IDP_CREATE_KEY makes the first key, because the image
  # has no shell to run "idp rotate" in.
  idp:
    profiles: [app]
    image: runway:dev
    entrypoint: ["/usr/local/bin/idp"]
    environment:
      IDP_ISSUER: http://idp:8081
      IDP_KEYS: /keys
      IDP_CREATE_KEY: "true"
      IDP_CLIENTS: dev:dev-secret-change-me:dev:submitter+reader
      LISTEN_ADDR: 0.0.0.0:8081
    ports:
      - "8081:8081"
    tmpfs:
      - /keys:mode=1777
    healthcheck:
      test: ["CMD", "/usr/local/bin/probe", "http://127.0.0.1:8081/health"]
      interval: 2s
      timeout: 3s
      retries: 20

  # Runway itself. These start only with --profile app, so a plain
~~~

Change:

<!-- edit: compose.yaml -->
~~~yaml
      <<: *runway-env
    ports:
~~~

to:

~~~yaml
      <<: *runway-env
      AUTH_ISSUER: http://idp:8081
    ports:
~~~

Change:

<!-- edit: compose.yaml -->
~~~yaml
      redis-3: { condition: service_healthy }

~~~

to:

~~~yaml
      redis-3: { condition: service_healthy }
      idp: { condition: service_healthy }

~~~


In the chart, `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
existingSecret: runway

~~~

to:

~~~yaml
existingSecret: runway

# Who may call the API (Phase 6, step 2). With mode "required", every job
# request needs a token from this issuer; "off" is for local development
# only, and the chart refuses an empty issuer otherwise.
auth:
  mode: required
  issuer: http://idp.runway:8081 # the "iss" in its tokens, and where its keys are
  audience: runway
  idp:
    enabled: true
    keysSecret: idp-keys # files named KID.key, made by "idp rotate"
    clientsSecret: idp-clients # one key, IDP_CLIENTS
    tokenLifetime: 5m

~~~


The API's environment, in `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        - { name: SHUTDOWN_GRACE, value: "{{ $api.shutdownGraceSeconds }}s" }
        - name: GOMEMLIMIT
~~~

to:

~~~yaml
        - { name: SHUTDOWN_GRACE, value: "{{ $api.shutdownGraceSeconds }}s" }
        - { name: AUTH_MODE, value: {{ $root.Values.auth.mode | quote }} }
        - { name: AUTH_ISSUER, value: {{ $root.Values.auth.issuer | quote }} }
        - { name: AUTH_AUDIENCE, value: {{ $root.Values.auth.audience | quote }} }
        - name: GOMEMLIMIT
~~~


A guard in `deploy/helm/runway/templates/api.yaml`, so a release can't be installed with authentication on and nowhere to get keys:

Change:

<!-- edit: deploy/helm/runway/templates/api.yaml -->
~~~yaml
{{- $api := .Values.api -}}
{{- if le (int $api.terminationGracePeriodSeconds) (add $api.preStopSeconds $api.shutdownGraceSeconds | int) }}
~~~

to:

~~~yaml
{{- $api := .Values.api -}}
{{- if and (ne .Values.auth.mode "off") (not .Values.auth.issuer) }}
{{- fail "auth.issuer is required unless auth.mode is off: an API without an issuer would refuse every request, or with mode off accept every one" }}
{{- end }}
{{- if le (int $api.terminationGracePeriodSeconds) (add $api.preStopSeconds $api.shutdownGraceSeconds | int) }}
~~~


And the issuer itself. Create `deploy/helm/runway/templates/idp.yaml`:

<!-- file: deploy/helm/runway/templates/idp.yaml -->
~~~yaml
{{- if .Values.auth.idp.enabled }}
# The token issuer (Phase 6, step 2). Its keys and clients come from two
# Secrets you create (see the guide), not from values: a private key in
# values would end up in Helm's release history, readable by anyone who can
# read Secrets in the namespace and kept long after it's rotated away.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: idp
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  replicas: 2 # tokens can't be issued while it's down; the API keeps verifying from its cache
  selector:
    matchLabels: { app: idp }
  template:
    metadata:
      labels: { app: idp }
    spec:
      securityContext:
        runAsNonRoot: true
        # Mounted Secret files belong to root. fsGroup makes them belong to
        # the image's group (65532) too, so the mode below can let it read.
        fsGroup: 65532
      automountServiceAccountToken: false # it never calls the Kubernetes API
      containers:
        - name: idp
          image: {{ include "runway.image" (list $ .Values.image.tag) }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: ["/usr/local/bin/idp"]
          env:
            - { name: IDP_ISSUER, value: {{ .Values.auth.issuer | quote }} }
            - { name: IDP_KEYS, value: /keys }
            - { name: IDP_TOKEN_LIFETIME, value: {{ .Values.auth.idp.tokenLifetime | quote }} }
            - { name: LISTEN_ADDR, value: "0.0.0.0:8081" }
            - name: IDP_CLIENTS
              valueFrom:
                secretKeyRef: { name: {{ .Values.auth.idp.clientsSecret }}, key: IDP_CLIENTS }
          ports:
            - { name: http, containerPort: 8081 }
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { cpu: 200m, memory: 64Mi }
          volumeMounts:
            # The kubelet updates a mounted Secret in place when it changes;
            # the issuer re-reads the directory every 30 seconds.
            - { name: keys, mountPath: /keys, readOnly: true }
          {{- include "runway.containerSecurity" . | nindent 10 }}
      volumes:
        - name: keys
          secret:
            secretName: {{ .Values.auth.idp.keysSecret }}
            defaultMode: 0440 # readable by root and the issuer's group; nobody else
---
apiVersion: v1
kind: Service
metadata:
  name: idp
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  selector: { app: idp }
  ports:
    - { name: http, port: 8081, targetPort: http }
{{- end }}
~~~

The keys and the clients come from Secrets you create, never from values: anything in values is stored in Helm's release history. And look at the volume's `defaultMode: 0440` with `fsGroup: 65532`. My first version used `0400`, which is readable only by the file's owner. Mounted Secret files belong to root, so the issuer, running as 65532, got `permission denied`. `fsGroup` makes the files' group 65532, and `0440` lets that group read them.

The smoke test makes the key and a client on a new cluster, then gets a token. In `deploy/smoke.sh`:

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash

# install the first time, upgrade after that
~~~

to:

~~~bash

# The token issuer's key and a client, made once per cluster (Phase 6).
if ! kubectl -n runway get secret idp-keys >/dev/null 2>&1; then
  keys=$(mktemp -d)
  go run ./cmd/idp rotate "$keys"
  kubectl -n runway create secret generic idp-keys --from-file="$keys"
  rm -rf "$keys"
fi
if ! kubectl -n runway get secret idp-clients >/dev/null 2>&1; then
  kubectl -n runway create secret generic idp-clients \
    --from-literal=IDP_CLIENTS="smoke:$(openssl rand -hex 32):smoke:submitter+reader"
fi

# install the first time, upgrade after that
~~~

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash
created=$(curl -sf -X POST "$url/jobs" -H 'Content-Type: application/json' \
~~~

to:

~~~bash
# A token for the first client in the Secret, through a port-forward to
# the issuer. (Whoever runs this can read Secrets anyway.)
client=$(kubectl -n runway get secret idp-clients -o jsonpath='{.data.IDP_CLIENTS}' | base64 -d | cut -d, -f1)
kubectl -n runway port-forward svc/idp 18081:8081 >/dev/null 2>&1 &
forward=$!
trap 'kill $forward 2>/dev/null' EXIT
sleep 2
token=$(curl -sf -u "$(echo "$client" | cut -d: -f1):$(echo "$client" | cut -d: -f2)" \
  -d grant_type=client_credentials localhost:18081/token | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
auth="Authorization: Bearer $token"

created=$(curl -sf -X POST "$url/jobs" -H "$auth" -H 'Content-Type: application/json' \
~~~

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash
  job=$(curl -sf "$url/jobs/$id")
~~~

to:

~~~bash
  job=$(curl -sf -H "$auth" "$url/jobs/$id")
~~~


CI needs Go in the smoke job now, to run `idp rotate`. In `.github/workflows/ci.yml`:

Change:

<!-- edit: .github/workflows/ci.yml -->
~~~yaml
      - uses: azure/setup-helm@v5
      # The same kind.yaml as on your machine: same Kubernetes version,
~~~

to:

~~~yaml
      - uses: azure/setup-helm@v5
      - uses: actions/setup-go@v7 # the smoke test makes the issuer's key with "go run ./cmd/idp rotate"
        with:
          go-version-file: go.mod
      # The same kind.yaml as on your machine: same Kubernetes version,
~~~


<!-- run: helm lint deploy/helm/runway && ! helm template runway deploy/helm/runway --set auth.issuer= 2>/dev/null && helm template runway deploy/helm/runway | grep -q 'name: AUTH_ISSUER' -->

### Run it

Make a signing key and three clients, and keep their secrets in a directory only you can read. Each client gets a tenant and roles; steps 3 and 4 use them:

~~~bash
mkdir -p ~/.runway && chmod 700 ~/.runway
go run ./cmd/idp rotate ~/.runway/idp-keys
kubectl -n runway create secret generic idp-keys --from-file=$HOME/.runway/idp-keys
clients="acme-ci:$(openssl rand -hex 32):acme:submitter+reader,globex-ci:$(openssl rand -hex 32):globex:submitter+reader,ops:$(openssl rand -hex 32):runway:admin"
(umask 077; echo "$clients" > ~/.runway/idp-clients.txt)
kubectl -n runway create secret generic idp-clients --from-literal=IDP_CLIENTS="$clients"
~~~

Then rebuild and roll out. You'll do this after most steps, so here it is once:

~~~bash
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait
kubectl -n runway rollout restart deployment && kubectl -n runway rollout status deployment/api
~~~

The tag stays `dev`, so a change to the code alone doesn't change the Pod template, and nothing would roll without the restart. (`--reset-then-reuse-values` keeps your `--set` values but takes the chart's new defaults, such as `auth`; plain `--reuse-values` would drop them, as Phase 5 found.)

Now call the API without a token, get one, and call it again. A small helper reads a client's secret from the file:

~~~bash
secret() { tr ',' '\n' < ~/.runway/idp-clients.txt | grep "^$1:" | cut -d: -f2; }
kubectl -n runway port-forward svc/idp 8081:8081 >/dev/null & sleep 2
curl -si -X POST localhost:8080/jobs -H "Content-Type: application/json" -d '{"description":"who am I?","duration_ms":10}' | grep -iE "^HTTP|^www|error"
curl -s -u "acme-ci:$(secret acme-ci)" -d grant_type=client_credentials localhost:8081/token | jq -c '.access_token |= .[:24] + "..."'
TOKEN=$(curl -s -u "acme-ci:$(secret acme-ci)" -d grant_type=client_credentials localhost:8081/token | jq -r .access_token)
for part in $(echo "$TOKEN" | cut -d. -f1,2 | tr . ' '); do echo "$part" | tr '_-' '/+' | base64 -d 2>/dev/null; echo; done
curl -s -X POST localhost:8080/jobs -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"description":"with a token","duration_ms":10}'
~~~

~~~text
HTTP/1.1 401 Unauthorized
Www-Authenticate: Bearer realm="runway"
{"error":"authentication required"}
{"access_token":"eyJhbGciOiJFZERTQSIsInR5...","token_type":"Bearer","expires_in":300}
{"alg":"EdDSA","typ":"JWT","kid":"20261009T004423-jekxna"}
{"iss":"http://idp.runway:8081","sub":"acme-ci","aud":["runway"],"exp":1791527444,"iat":1791527144,"jti":"a0b1fe3d9bfd2e87010f0e982f5ca216","tenant":"acme","roles":["submitter","reader"]}
{"id":14351,"state":"queued","description":"with a token","duration_ms":10,"created_at":"2026-10-09T06:25:44.515426Z","updated_at":"2026-10-09T06:25:44.515426Z"}
~~~

(`base64 -d` may complain about missing padding, since base64url drops the `=`; the `2>/dev/null` hides that.) Everything in the token is readable by anyone who has it: tenant, roles, expiry. That's by design. A JWT is signed, not encrypted, so never put a secret in one.

And the failures:

~~~bash
curl -s -u acme-ci:wrong -d grant_type=client_credentials localhost:8081/token; echo
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8080/jobs -H "Authorization: Bearer not.a.token" -H "Content-Type: application/json" -d '{"description":"x","duration_ms":10}'
kubectl -n runway logs -l app=api --tail=20 | grep "rejected token" | tail -1
~~~

~~~text
{"error":"invalid_client"}
401
{"time":"2026-10-09T06:25:44.582785748Z","level":"WARN","msg":"rejected token","error":"malformed token","path":"/jobs"}
~~~

The client got `401`; the log got the reason.

**Break it: expiry, and a rotation.** Make tokens last 20 seconds, get one, and keep using it:

~~~bash
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --set auth.idp.tokenLifetime=20s --wait
# restart the port-forward (the idp Pods were replaced), get a token as above, then POST with it now, 25 s later, and 55 s later
~~~

~~~text
06:26:50 got a token; POST now: 201
06:27:15 25 s later (past expiry, within the 30 s leeway): 201
06:27:45 55 s later (past expiry + leeway): 401
06:27:45 API log: {"time":"2026-10-09T06:27:45.406137437Z","level":"WARN","msg":"rejected token","error":"token expired","path":"/jobs"}
~~~

Leeway is a real window: five seconds after "expiry", the token still worked. Count it when you decide how long a stolen token is useful.

Now set the lifetime back to `5m`, get a token, and rotate the key while it's still valid. Write the new key into the same directory and replace the Secret with the whole directory:

~~~bash
go run ./cmd/idp rotate ~/.runway/idp-keys
kubectl -n runway create secret generic idp-keys --from-file=$HOME/.runway/idp-keys --dry-run=client -o yaml | kubectl apply -f -
# poll /.well-known/jwks.json until it lists every key, then get a new token and use both
~~~

~~~text
06:28:00 token before rotation, kid 20261009T004423-jekxna: 201
new signing key: 20261009T062802-snrwj2
secret/idp-keys configured
06:29:24 the issuer publishes 3 keys, after 85 s
06:29:59 token after rotation, kid 20261009T062802-snrwj2: 201
06:29:59 the old token, still unexpired, kid 20261009T004423-jekxna: 201
~~~

(My directory held two keys before; yours will publish two.) It took 85 seconds for the new key to be published: up to a minute for the kubelet to update the mounted Secret, plus up to 30 seconds for the issuer's next reload. The old token kept working because its key was still published. Delete the old key file, and apply again, only after every token it signed has expired: five minutes, plus the leeway.

**Explain it:** why does the API verify with a public key, and what would a shared HMAC secret allow? What does each of the five checks in `Verify` stop? Why does `RemoteJWKS` limit refetches? What's the shortest safe time between publishing a new key and signing with it, and between the last signature by an old key and removing it?

**Read.** RFC 8725, *JSON Web Token Best Current Practices*: every attack it lists, and which line of `Verify` stops each. Then Tim McLean, *Critical vulnerabilities in JSON Web Token libraries* (2015), the post that found the `none` and HS256 attacks. Then RFC 6749 §4.4 (client credentials) and OpenID Connect Discovery §3. *Try it:* run [Dex](https://dexidp.io/) in Compose with a static client, point `AUTH_ISSUER` at it, and see what changes (its keys are RSA: what would `Verify` need?).

---
## Step 3: Authorization

**The problem.** Every request now says who sent it, but the API still lets any authenticated caller do anything. A token minted for a read-only dashboard can submit jobs. The token carries roles; nothing reads them.

**New ideas.**

- **Policy decision point and policy enforcement points.** One place *decides* (given this caller and this action: allow or deny, and why). Many places *enforce* (each handler asks before acting, and obeys). If the decisions are spread through handlers as `if` statements, nobody can read the whole policy, and the handler someone forgets has none. Systems such as Open Policy Agent, Cedar and Google's Zanzibar are all built on this split.
- **Role-based access control (RBAC).** Roles map to actions; callers have roles. Simple, and enough for Runway today. Attribute-based access control (rules over the caller, the resource and the context) and relationship-based access control (Zanzibar: "is this user an editor of this document's folder?") answer questions RBAC can't, at more cost.
- **Deny by default.** Anything not explicitly allowed is refused: a role nobody defined, an action nobody listed, a request with no identity at all.
- **Least privilege.** A client gets the roles its job needs and no more. A dashboard reads, so it gets `reader`, never `submitter`.
- **401 vs 403.** `401 Unauthorized` means "I don't know who you are" (despite the name); `403 Forbidden` means "I know, and no". gRPC's equivalents are `Unauthenticated` and `PermissionDenied`.
- **Log every denial.** A denial is either a bug (a client missing a role) or an attack (someone probing). You want to see both.

### The policy

Create `internal/authz/authz.go`:

<!-- file: internal/authz/authz.go -->
~~~go
// Package authz decides what an authenticated caller may do: the policy
// decision point. Handlers (the enforcement points) ask it about every
// action, and do what it says.
//
// Authentication answered "who is this?"; authorization answers "may they
// do this?". Keeping the answer in one place, rather than in "if" statements
// scattered through handlers, makes the policy something you can read,
// test and change in one place, and every decision something you can log.
package authz

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"runway/internal/auth"
)

// Action is something a caller can try to do.
type Action string

const (
	CreateJob Action = "jobs.create"
	ReadJob   Action = "jobs.read"
)

// Decision is an answer, with the reason for it.
type Decision struct {
	Allow  bool
	Reason string
}

// Policy maps each role to the actions it allows. Anything not listed is
// denied: an unknown role, an unknown action, a role added to a token by
// mistake. That's "deny by default".
type Policy map[string][]Action

// DefaultPolicy is Runway's. A submitter submits jobs and a reader reads
// them; most clients get both. An admin may do everything, but only in its
// own tenant: no role crosses tenants.
var DefaultPolicy = Policy{
	"submitter": {CreateJob},
	"reader":    {ReadJob},
	"admin":     {CreateJob, ReadJob},
}

// Decide answers whether the caller in ctx may perform action.
func (p Policy) Decide(ctx context.Context, action Action) Decision {
	claims, ok := auth.FromContext(ctx)
	if !ok {
		// No verified identity. This should never happen behind
		// auth.Require; if it does, deny, rather than guess (fail closed).
		return Decision{Reason: "no identity"}
	}
	for _, role := range claims.Roles {
		if slices.Contains(p[role], action) {
			return Decision{Allow: true, Reason: fmt.Sprintf("role %s allows %s", role, action)}
		}
	}
	return Decision{Reason: fmt.Sprintf("no role of %s allows %s", claims.Subject, action)}
}

// ErrDenied is returned by an Authorizer that says no.
var ErrDenied = errors.New("permission denied")

// Authorizer is what handlers call: nil means allowed.
type Authorizer func(ctx context.Context, action Action) error

// Enforce returns an Authorizer for policy that reports every denial to
// denied (for logging, and in step 10 the audit log).
func Enforce(policy Policy, denied func(ctx context.Context, action Action, reason string)) Authorizer {
	return func(ctx context.Context, action Action) error {
		d := policy.Decide(ctx, action)
		if d.Allow {
			return nil
		}
		if denied != nil {
			denied(ctx, action, d.Reason)
		}
		return fmt.Errorf("%w: %s", ErrDenied, d.Reason)
	}
}

// AllowAll allows everything. It exists for AUTH_MODE=off, where there are
// no identities to decide about, and nowhere else.
func AllowAll(context.Context, Action) error { return nil }
~~~

The whole policy is the three lines of `DefaultPolicy`. `Decide` returns a reason with every answer, which is what makes denials debuggable. `Enforce` turns the policy into the one function handlers call, an `Authorizer`, and reports each denial. `AllowAll` exists for `AUTH_MODE=off` only. Its name says what it does, so nobody wires it in by accident.

Test it with a table. Create `internal/authz/authz_test.go`:

<!-- file: internal/authz/authz_test.go -->
~~~go
package authz

import (
	"context"
	"errors"
	"testing"

	"runway/internal/auth"
)

func as(roles ...string) context.Context {
	return auth.WithClaims(context.Background(), auth.Claims{Subject: "client", Tenant: "acme", Roles: roles})
}

func TestDefaultPolicy(t *testing.T) {
	for _, tc := range []struct {
		name   string
		ctx    context.Context
		action Action
		allow  bool
	}{
		{"a submitter creates", as("submitter"), CreateJob, true},
		{"a submitter can't read", as("submitter"), ReadJob, false},
		{"a reader reads", as("reader"), ReadJob, true},
		{"a reader can't create", as("reader"), CreateJob, false},
		{"both roles: either", as("submitter", "reader"), ReadJob, true},
		{"an admin does both", as("admin"), CreateJob, true},
		{"no roles: nothing", as(), ReadJob, false},
		{"an unknown role: nothing", as("superuser"), CreateJob, false},
		{"an unknown action: denied", as("admin"), Action("jobs.delete"), false},
		{"no identity at all: denied", context.Background(), ReadJob, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := DefaultPolicy.Decide(tc.ctx, tc.action)
			if d.Allow != tc.allow || d.Reason == "" {
				t.Fatalf("Decide = %+v, want allow=%v with a reason", d, tc.allow)
			}
		})
	}
}

func TestEnforceReportsDenials(t *testing.T) {
	var reported []string
	authorize := Enforce(DefaultPolicy, func(_ context.Context, a Action, reason string) {
		reported = append(reported, string(a)+": "+reason)
	})
	if err := authorize(as("reader"), ReadJob); err != nil {
		t.Fatalf("allowed action: %v", err)
	}
	if err := authorize(as("reader"), CreateJob); !errors.Is(err, ErrDenied) {
		t.Fatalf("denied action: %v", err)
	}
	if len(reported) != 1 || reported[0] != "jobs.create: no role of client allows jobs.create" {
		t.Fatalf("reported = %q", reported)
	}
}
~~~

Count the rows: four allow, six deny. Most of a policy's tests should be refusals, because a missing refusal is the bug that matters, and it's silent.

<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/authz/ && go test -race -count=1 ./internal/authz/ -->

### Enforcing it over HTTP

In `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go

	"runway/internal/idempotency"
~~~

to:

~~~go

	"runway/internal/authz"
	"runway/internal/idempotency"
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	authenticate   func(http.Handler) http.Handler
}
~~~

to:

~~~go
	authenticate   func(http.Handler) http.Handler
	authorize      authz.Authorizer
}
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	return func(c *config) { c.authenticate = authenticate }
}
~~~

to:

~~~go
	return func(c *config) { c.authenticate = authenticate }
}

// WithAuthorizer asks authorize before every action on jobs, and answers
// 403 if it says no (Phase 6, step 3).
func WithAuthorizer(authorize authz.Authorizer) Option {
	return func(c *config) { c.authorize = authorize }
}
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	mux.Handle("POST /jobs", protect(create))
	mux.Handle("GET /jobs/{id}", protect(http.HandlerFunc(h.getJob)))
~~~

to:

~~~go
	// Authorization comes after authentication, which it needs, and before
	// everything else: a stored idempotent response must not reach someone
	// the policy would refuse.
	allow := func(action authz.Action, next http.Handler) http.Handler {
		if cfg.authorize == nil {
			return next
		}
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if err := cfg.authorize(r.Context(), action); err != nil {
				writeError(w, http.StatusForbidden, "permission denied")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
	mux.Handle("POST /jobs", protect(allow(authz.CreateJob, create)))
	mux.Handle("GET /jobs/{id}", protect(allow(authz.ReadJob, http.HandlerFunc(h.getJob))))
~~~


The order of the wrappers is deliberate: authentication, then authorization, then everything else, including the idempotency middleware of Phase 3. Put authorization after idempotency and a stored response would be replayed to anyone who sent the same `Idempotency-Key`, whether or not the policy would let them make the request.

The test that matters asks the question from the other side. Instead of checking each route, it installs an authorizer that refuses everything and records what it was asked. Any job route that doesn't ask shows up as a success. In `internal/httpapi/handler_test.go`:

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go

	"runway/internal/idempotency"
~~~

to:

~~~go

	"runway/internal/authz"
	"runway/internal/idempotency"
~~~

Add this at the end of the file:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
// Every route that touches jobs must ask the policy. A deny-everything
// authorizer finds any route that doesn't.
func TestEveryJobRouteIsAuthorized(t *testing.T) {
	asked := map[authz.Action]bool{}
	denyAll := func(_ context.Context, a authz.Action) error {
		asked[a] = true
		return authz.ErrDenied
	}
	h := newTestHandler(WithAuthorizer(denyAll), WithIdempotency(idempotency.NewStore(time.Hour, time.Now)))
	for _, route := range []struct{ method, path, body string }{
		{http.MethodPost, "/jobs", `{"description":"x","duration_ms":1}`},
		{http.MethodGet, "/jobs/1", ""},
	} {
		if got := do(t, h, route.method, route.path, route.body); got.Code != http.StatusForbidden {
			t.Errorf("%s %s = %d, want 403", route.method, route.path, got.Code)
		}
	}
	if !asked[authz.CreateJob] || !asked[authz.ReadJob] {
		t.Fatalf("actions asked about: %v", asked)
	}
	if got := do(t, h, http.MethodGet, "/health", ""); got.Code != http.StatusOK {
		t.Fatalf("/health = %d; it isn't an action on jobs", got.Code)
	}
}
~~~


### Enforcing it over gRPC

In `internal/grpcapi/server.go`, every method asks first:

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go

	"runway/internal/grpcapi/jobsv1"
~~~

to:

~~~go

	"runway/internal/authz"
	"runway/internal/grpcapi/jobsv1"
~~~

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
	jobs JobService
~~~

to:

~~~go
	jobs      JobService
	authorize authz.Authorizer
~~~

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
func New(service JobService) *Server {
	return &Server{jobs: service}
~~~

to:

~~~go
// New serves service. Calls are authorized with authorize; nil allows all,
// for tests and AUTH_MODE=off.
func New(service JobService, authorize authz.Authorizer) *Server {
	if authorize == nil {
		authorize = authz.AllowAll
	}
	return &Server{jobs: service, authorize: authorize}
}

// allowed is the enforcement point: every method calls it first.
func (s *Server) allowed(ctx context.Context, action authz.Action) error {
	if err := s.authorize(ctx, action); err != nil {
		return status.Error(codes.PermissionDenied, "permission denied")
	}
	return nil
~~~

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
func (s *Server) CreateJob(ctx context.Context, req *jobsv1.CreateJobRequest) (*jobsv1.Job, error) {
	job, err := s.jobs.Create(ctx, req.GetDescription(), time.Duration(req.GetDurationMs())*time.Millisecond)
~~~

to:

~~~go
func (s *Server) CreateJob(ctx context.Context, req *jobsv1.CreateJobRequest) (*jobsv1.Job, error) {
	if err := s.allowed(ctx, authz.CreateJob); err != nil {
		return nil, err
	}
	job, err := s.jobs.Create(ctx, req.GetDescription(), time.Duration(req.GetDurationMs())*time.Millisecond)
~~~

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
func (s *Server) GetJob(ctx context.Context, req *jobsv1.GetJobRequest) (*jobsv1.Job, error) {
	if req.GetId() <= 0 {
~~~

to:

~~~go
func (s *Server) GetJob(ctx context.Context, req *jobsv1.GetJobRequest) (*jobsv1.Job, error) {
	if err := s.allowed(ctx, authz.ReadJob); err != nil {
		return nil, err
	}
	if req.GetId() <= 0 {
~~~


`New` now takes the authorizer as an argument. A server can't be built without deciding about it, and `nil` (tests, `AUTH_MODE=off`) is turned into `AllowAll` in one visible place. In `internal/grpcapi/server_test.go`:

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go

	"runway/internal/grpcapi/jobsv1"
~~~

to:

~~~go

	"runway/internal/authz"
	"runway/internal/grpcapi/jobsv1"
~~~

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go
	jobsv1.RegisterJobsServer(server, New(jobs.NewService(memstore.New())))
~~~

to:

~~~go
	jobsv1.RegisterJobsServer(server, New(jobs.NewService(memstore.New()), nil))
~~~

Add this at the end of the file:

<!-- append: internal/grpcapi/server_test.go -->
~~~go
func TestMethodsAreAuthorized(t *testing.T) {
	denyAll := func(context.Context, authz.Action) error { return authz.ErrDenied }
	server := New(jobs.NewService(memstore.New()), denyAll)
	if _, err := server.CreateJob(context.Background(), &jobsv1.CreateJobRequest{Description: "x"}); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("CreateJob: %v, want PermissionDenied", err)
	}
	if _, err := server.GetJob(context.Background(), &jobsv1.GetJobRequest{Id: 1}); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("GetJob: %v, want PermissionDenied", err)
	}
}
~~~


### Wiring it

In `cmd/api/main.go`, the policy is enforced only when there are identities, and each denial is logged with who, what, and why:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/auth"
	"runway/internal/background"
~~~

to:

~~~go
	"runway/internal/auth"
	"runway/internal/authz"
	"runway/internal/background"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	var stream []grpc.StreamServerInterceptor
	if cfg.AuthOff {
~~~

to:

~~~go
	var stream []grpc.StreamServerInterceptor
	// Authorization (step 3): the policy decides, every handler enforces.
	// Without authentication there are no identities to decide about.
	authorize := authz.AllowAll
	if cfg.AuthOff {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	} else {
		verifier := auth.Verifier{
~~~

to:

~~~go
	} else {
		authorize = authz.Enforce(authz.DefaultPolicy, func(ctx context.Context, action authz.Action, reason string) {
			claims, _ := auth.FromContext(ctx)
			logger.Warn("denied", "subject", claims.Subject, "tenant", claims.Tenant, "action", action, "reason", reason)
		})
		verifier := auth.Verifier{
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	}
	if cfg.ServedBy != "" {
~~~

to:

~~~go
	}
	options = append(options, httpapi.WithAuthorizer(authorize))
	if cfg.ServedBy != "" {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	jobsv1.RegisterJobsServer(grpcServer, grpcapi.New(service))
~~~

to:

~~~go
	jobsv1.RegisterJobsServer(grpcServer, grpcapi.New(service, authorize))
~~~


The test's token now needs a role to create a job. In `cmd/api/main_test.go`:

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go
		IssuedAt: now.Unix(), Expiry: now.Add(time.Minute).Unix()}, key)
~~~

to:

~~~go
		IssuedAt: now.Unix(), Expiry: now.Add(time.Minute).Unix(), Roles: []string{"submitter"}}, key)
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/authz/... ./internal/httpapi/... ./internal/grpcapi/... ./cmd/api/... -->

**Break it.** Wire one route without the policy. In `handler.go`, change the `GET /jobs/{id}` line to `protect(http.HandlerFunc(h.getJob))`, and run the tests:

~~~text
--- FAIL: TestEveryJobRouteIsAuthorized (0.00s)
    handler_test.go:312: GET /jobs/1 = 404, want 403
    handler_test.go:316: actions asked about: map[jobs.create:true]
~~~

The route ran without asking (404: job 1 doesn't exist, but the handler looked). The next route anyone adds gets the same check for free, by adding one line to the test's list. Put the line back.

### Run it

Add a read-only client for a dashboard, update the Secret, and restart the issuer, which reads its clients from the environment at start:

~~~bash
clients="$(cat ~/.runway/idp-clients.txt),acme-dashboard:$(openssl rand -hex 32):acme:reader"
(umask 077; echo "$clients" > ~/.runway/idp-clients.txt)
kubectl -n runway create secret generic idp-clients --from-literal=IDP_CLIENTS="$clients" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n runway rollout restart deployment/idp
~~~

Then rebuild and roll out (step 2's three commands), and try both clients:

~~~bash
token() { curl -s -u "$1:$(secret $1)" -d grant_type=client_credentials localhost:8081/token | jq -r .access_token; }
CI=$(token acme-ci); DASH=$(token acme-dashboard)
curl -s -X POST localhost:8080/jobs -H "Authorization: Bearer $CI" -H "Content-Type: application/json" -d '{"description":"from CI","duration_ms":10}'; echo
curl -s -w "  (%{http_code})\n" -X POST localhost:8080/jobs -H "Authorization: Bearer $DASH" -H "Content-Type: application/json" -d '{"description":"from the dashboard","duration_ms":10}'
ID=$(curl -s -X POST localhost:8080/jobs -H "Authorization: Bearer $CI" -H "Content-Type: application/json" -d '{"description":"to read","duration_ms":10}' | jq .id)
curl -s -w "  (%{http_code})\n" localhost:8080/jobs/$ID -H "Authorization: Bearer $DASH"
kubectl -n runway logs -l app=api --tail=30 | grep '"msg":"denied"' | tail -1
~~~

~~~text
{"id":14357,"state":"queued","description":"from CI","duration_ms":10,"created_at":"2026-10-09T06:37:03.217054Z","updated_at":"2026-10-09T06:37:03.217054Z"}
{"error":"permission denied"}
  (403)
{"id":14358,"state":"queued","description":"to read","duration_ms":10,"created_at":"2026-10-09T06:37:03.367682Z","updated_at":"2026-10-09T06:37:03.367682Z"}
  (200)
{"time":"2026-10-09T06:37:03.306823391Z","level":"WARN","msg":"denied","subject":"acme-dashboard","tenant":"acme","action":"jobs.create","reason":"no role of acme-dashboard allows jobs.create"}
~~~

(Restart the `idp` port-forward first if the restart broke it.) The dashboard reads, and can't write; the log says exactly why.

Now try `globex-ci` reading job 14358, which acme created. It works: `200`. Authorization asked "may a reader read jobs?" and the answer is yes. It never asked *whose* job. That's the next step.

**Explain it:** what's the difference between the decision point and an enforcement point, and why keep one decision point? Why must authorization come before the idempotency middleware? Why does the route test use an authorizer that refuses everything? Why could globex read acme's job, and which question was missing?

**Read.** NIST SP 800-162 §1–3 (attribute-based access control, and why RBAC isn't always enough). Then Pang et al., *Zanzibar: Google's Consistent, Global Authorization System* (USENIX ATC 2019), sections 1–2: how would Runway's policy look as relations? Then OWASP API Security Top 10, API5:2023 (broken function level authorization).

---
## Step 4: Tenants

**The problem.** At the end of step 3, globex could read acme's jobs by guessing their numbers (T2). Both are allowed to read jobs; nothing says *whose*. This is the most common serious API vulnerability there is. OWASP ranks it first, as **BOLA**: broken object level authorization. And it isn't one bug in one handler. Every query, cache entry, message and log line that names a job by ID alone is a place where one tenant's data can reach another.

**New ideas.**

- **A tenant** is a customer: an organisation whose data must be invisible to every other. Runway's tenant comes from the verified token (step 2), at the edge, and nowhere else. A tenant ID in a request body or a header would be the caller's claim, not a fact.
- **Tenant context propagation.** Once set, the tenant travels with the work: in the request's context, into the database transaction, into the messages a job sends, through the worker, and back with its events. Code in the middle passes the tenant along and never chooses one.
- **Not found, not forbidden.** Another tenant's job answers `404`, exactly like a job that doesn't exist. A `403` would confirm that job 14359 exists and belongs to somebody.
- **Isolation models.** A database per tenant (strongest, and the most expensive to run), a schema per tenant, or shared tables with a tenant column. Runway uses shared tables, the common choice, and makes the database enforce the column.
- **Row-level security (RLS)** is PostgreSQL adding a condition to every query on a table: `USING (tenant = current_tenant())`. A query that forgets `WHERE tenant = ...` still sees only its own tenant's rows. It applies to roles that don't own the table and don't have `BYPASSRLS`, which is why the step's transactions switch to a role made for it.
- **Fail closed, again.** Work that arrives without a tenant is refused. Guessing one ("default", or the first tenant) is how one customer's data ends up in another's.

### Carrying the tenant

Create `internal/tenant/tenant.go`:

<!-- file: internal/tenant/tenant.go -->
~~~go
// Package tenant carries the tenant a piece of work belongs to through a
// context.Context. A tenant is a customer: everything Runway stores belongs
// to exactly one, and no tenant may see or change another's.
//
// The tenant comes from the caller's verified token (step 2), at the edge.
// After that it travels with the work: through the database transaction,
// into the messages a job sends, through the worker and back. Code in the
// middle never decides a tenant; it only passes one along.
package tenant

import (
	"context"
	"errors"
)

// ID names a tenant.
type ID string

// ErrMissing means work arrived without a tenant. It is refused, never
// guessed: guessing is how one customer's data ends up in another's.
var ErrMissing = errors.New("no tenant")

type key struct{}

// With returns ctx carrying tenant id.
func With(ctx context.Context, id ID) context.Context {
	return context.WithValue(ctx, key{}, id)
}

// From returns the tenant in ctx.
func From(ctx context.Context) (ID, bool) {
	id, ok := ctx.Value(key{}).(ID)
	return id, ok && id != ""
}

// Require returns the tenant in ctx, or ErrMissing.
func Require(ctx context.Context) (ID, error) {
	id, ok := From(ctx)
	if !ok {
		return "", ErrMissing
	}
	return id, nil
}
~~~

`From` treats an empty ID as no tenant at all, so `tenant.With(ctx, "")` can't smuggle in a blank one.

A job belongs to one tenant. In `internal/jobs/job.go`:

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
	"unicode/utf8"
)
~~~

to:

~~~go
	"unicode/utf8"

	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
	ID            ID
	Description   Description
~~~

to:

~~~go
	ID            ID
	Tenant        tenant.ID // whose job it is (Phase 6); set from the request, never changed
	Description   Description
~~~


The repository's contract now says what tenants mean. In `internal/jobs/repository.go`:

Change:

<!-- edit: internal/jobs/repository.go -->
~~~go
// Phase 3 adds PostgreSQL without changing this interface.
type Repository interface {
~~~

to:

~~~go
// Phase 3 adds PostgreSQL without changing this interface.
//
// Every method works within the tenant in ctx (Phase 6): a job belonging to
// another tenant is ErrNotFound, exactly as if it didn't exist, so a caller
// can't even learn that it does. A context with no tenant is refused with
// tenant.ErrMissing.
type Repository interface {
~~~


The service requires a tenant to create a job. The sweeper that fails abandoned jobs is different: it's a system task that looks across every tenant, so it learns each job's tenant from the database and changes the job within that tenant, like any other change. In `internal/jobs/service.go`:

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	"time"
)
~~~

to:

~~~go
	"time"

	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
func (s *Service) Create(ctx context.Context, description string, duration time.Duration) (Job, error) {
	d, err := NewDescription(description)
~~~

to:

~~~go
func (s *Service) Create(ctx context.Context, description string, duration time.Duration) (Job, error) {
	owner, err := tenant.Require(ctx)
	if err != nil {
		return Job{}, err
	}
	d, err := NewDescription(description)
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	}
	job, err = s.repo.Create(ctx, job)
~~~

to:

~~~go
	}
	job.Tenant = owner
	job, err = s.repo.Create(ctx, job)
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
// AbandonedFinder finds running jobs that haven't changed since before.
~~~

to:

~~~go
// Abandoned is a running job no worker has reported on, and its tenant.
type Abandoned struct {
	ID     ID
	Tenant tenant.ID
}

// AbandonedFinder finds running jobs that haven't changed since before, in
// every tenant: it is a system task, not a request.
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	Abandoned(ctx context.Context, before time.Time, limit int) ([]ID, error)
~~~

to:

~~~go
	Abandoned(ctx context.Context, before time.Time, limit int) ([]Abandoned, error)
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	ids, err := finder.Abandoned(ctx, s.now().Add(-after), 100)
~~~

to:

~~~go
	found, err := finder.Abandoned(ctx, s.now().Add(-after), 100)
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	for n, id := range ids {
		if err := s.MarkFailed(ctx, id, "abandoned: no worker reported back"); err != nil {
~~~

to:

~~~go
	for n, job := range found {
		// Each job is changed within its own tenant, like any other change.
		if err := s.MarkFailed(tenant.With(ctx, job.Tenant), job.ID, "abandoned: no worker reported back"); err != nil {
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	return len(ids), nil
~~~

to:

~~~go
	return len(found), nil
~~~


### The contract

Every repository (memory, PostgreSQL, the cache, the breaker) runs the same contract tests. Two new ones say what isolation means, so every store is held to it. In `internal/jobs/jobstest/contract.go`:

Change:

<!-- edit: internal/jobs/jobstest/contract.go -->
~~~go
	"runway/internal/jobs"
)

// t0 has nanoseconds on purpose: PostgreSQL keeps only microseconds, and
~~~

to:

~~~go
	"runway/internal/jobs"
	"runway/internal/tenant"
)

// acme is a request context for tenant "acme": every repository call
// needs a tenant (Phase 6).
var acme = tenant.With(context.Background(), "acme")

// t0 has nanoseconds on purpose: PostgreSQL keeps only microseconds, and
~~~

Change:

<!-- edit: internal/jobs/jobstest/contract.go -->
~~~go
	ctx := context.Background()
~~~

to:

~~~go
	ctx := acme
~~~

Change:

<!-- edit: internal/jobs/jobstest/contract.go -->
~~~go
	})
}
~~~

to:

~~~go
	})

	// Phase 6: tenants. A job belongs to the tenant that created it, and to
	// every other tenant it doesn't exist.
	t.Run("a job is invisible to other tenants", func(t *testing.T) {
		repo := newRepo(t)
		created, err := repo.Create(acme, newJob(t))
		if err != nil {
			t.Fatal(err)
		}
		if created.Tenant != "acme" {
			t.Fatalf("tenant = %q, want acme", created.Tenant)
		}
		globex := tenant.With(context.Background(), "globex")
		if _, err := repo.Get(globex, created.ID); !errors.Is(err, jobs.ErrNotFound) {
			t.Fatalf("another tenant's Get: %v, want ErrNotFound", err)
		}
		started := created
		if err := started.Start(t0); err != nil {
			t.Fatal(err)
		}
		if err := repo.Update(globex, started, jobs.StateQueued); !errors.Is(err, jobs.ErrNotFound) {
			t.Fatalf("another tenant's Update: %v, want ErrNotFound", err)
		}
		got, err := repo.Get(acme, created.ID)
		if err != nil || got.State != jobs.StateQueued || got.Tenant != "acme" {
			t.Fatalf("the owner's Get after the refused update: %+v, %v", got, err)
		}
	})

	t.Run("no tenant is refused", func(t *testing.T) {
		repo := newRepo(t)
		if _, err := repo.Create(context.Background(), newJob(t)); !errors.Is(err, tenant.ErrMissing) {
			t.Fatalf("Create without a tenant: %v, want tenant.ErrMissing", err)
		}
		created, err := repo.Create(acme, newJob(t))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := repo.Get(context.Background(), created.ID); !errors.Is(err, tenant.ErrMissing) {
			t.Fatalf("Get without a tenant: %v, want tenant.ErrMissing", err)
		}
	})
}
~~~


The refused update is checked from the owner's side too: globex's update must not have changed acme's job, whatever error it got.

The in-memory store keeps tenants apart by comparing them. In `internal/memstore/store.go`:

Change:

<!-- edit: internal/memstore/store.go -->
~~~go
	"runway/internal/jobs"
)
~~~

to:

~~~go
	"runway/internal/jobs"
	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/memstore/store.go -->
~~~go
		return jobs.Job{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
~~~

to:

~~~go
		return jobs.Job{}, err
	}
	owner, err := tenant.Require(ctx)
	if err != nil {
		return jobs.Job{}, err
	}
	job.Tenant = owner
	s.mu.Lock()
	defer s.mu.Unlock()
~~~

Change:

<!-- edit: internal/memstore/store.go -->
~~~go
	}
	s.mu.RLock()
~~~

to:

~~~go
	}
	owner, err := tenant.Require(ctx)
	if err != nil {
		return jobs.Job{}, err
	}
	s.mu.RLock()
~~~

Change:

<!-- edit: internal/memstore/store.go -->
~~~go
	job, ok := s.jobs[id]
	if !ok {
		return jobs.Job{}, jobs.ErrNotFound
~~~

to:

~~~go
	job, ok := s.jobs[id]
	if !ok || job.Tenant != owner {
		return jobs.Job{}, jobs.ErrNotFound
~~~

Change:

<!-- edit: internal/memstore/store.go -->
~~~go
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
~~~

to:

~~~go
		return err
	}
	owner, err := tenant.Require(ctx)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
~~~

Change:

<!-- edit: internal/memstore/store.go -->
~~~go
	current, ok := s.jobs[job.ID]
	if !ok {
		return jobs.ErrNotFound
	}
	if current.State != expected {
~~~

to:

~~~go
	current, ok := s.jobs[job.ID]
	if !ok || current.Tenant != owner {
		return jobs.ErrNotFound
	}
	job.Tenant = owner // a job never changes hands
	if current.State != expected {
~~~


Its tests, and the service's and the breaker's, now act for a tenant. In `internal/memstore/store_test.go`:

Change:

<!-- edit: internal/memstore/store_test.go -->
~~~go
	"runway/internal/jobs/jobstest"
)

func newJob(t *testing.T) jobs.Job {
~~~

to:

~~~go
	"runway/internal/jobs/jobstest"
	"runway/internal/tenant"
)

// acme is a request context for tenant "acme": every repository call
// needs a tenant (Phase 6).
var acme = tenant.With(context.Background(), "acme")

func newJob(t *testing.T) jobs.Job {
~~~

Change:

<!-- edit: internal/memstore/store_test.go -->
~~~go
func TestCreateAssignsIDsAndGetReturnsJob(t *testing.T) {
	store := New()
	ctx := context.Background()

	first, _ := store.Create(ctx, newJob(t))
~~~

to:

~~~go
func TestCreateAssignsIDsAndGetReturnsJob(t *testing.T) {
	store := New()
	ctx := acme

	first, _ := store.Create(ctx, newJob(t))
~~~

Change:

<!-- edit: internal/memstore/store_test.go -->
~~~go
	if _, err := New().Get(context.Background(), 42); !errors.Is(err, jobs.ErrNotFound) {
~~~

to:

~~~go
	if _, err := New().Get(acme, 42); !errors.Is(err, jobs.ErrNotFound) {
~~~

Change:

<!-- edit: internal/memstore/store_test.go -->
~~~go
	store := New()
	ctx := context.Background()
	job, _ := store.Create(ctx, newJob(t))
~~~

to:

~~~go
	store := New()
	ctx := acme
	job, _ := store.Create(ctx, newJob(t))
~~~

Change:

<!-- edit: internal/memstore/store_test.go -->
~~~go
	ctx, cancel := context.WithCancel(context.Background())
~~~

to:

~~~go
	ctx, cancel := context.WithCancel(acme)
~~~

Change:

<!-- edit: internal/memstore/store_test.go -->
~~~go
	store := New()
	ctx := context.Background()
	const n = 200
~~~

to:

~~~go
	store := New()
	ctx := acme
	const n = 200
~~~


In `internal/jobs/service_test.go`:

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	"runway/internal/memstore"
)

var fixedNow = time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
~~~

to:

~~~go
	"runway/internal/memstore"
	"runway/internal/tenant"
)

// acme is a request context for tenant "acme": every repository call
// needs a tenant (Phase 6).
var acme = tenant.With(context.Background(), "acme")

var fixedNow = time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	svc := jobs.NewService(memstore.New(), jobs.WithClock(fixedClock))
	ctx := context.Background()

~~~

to:

~~~go
	svc := jobs.NewService(memstore.New(), jobs.WithClock(fixedClock))
	ctx := acme

~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	svc := jobs.NewService(memstore.New(), jobs.WithDispatcher(failingDispatcher{full}))
	ctx := context.Background()

~~~

to:

~~~go
	svc := jobs.NewService(memstore.New(), jobs.WithDispatcher(failingDispatcher{full}))
	ctx := acme

~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
func TestEventsDriveTheLifecycleIdempotently(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)

~~~

to:

~~~go
func TestEventsDriveTheLifecycleIdempotently(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	ctx := acme
	job, _ := svc.Create(ctx, "resize", 0)

~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
func TestCompletionBeforeStartStillCompletes(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)

~~~

to:

~~~go
func TestCompletionBeforeStartStillCompletes(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	ctx := acme
	job, _ := svc.Create(ctx, "resize", 0)

~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	if err := svc.MarkStarted(context.Background(), 99); !errors.Is(err, jobs.ErrNotFound) {
~~~

to:

~~~go
	if err := svc.MarkStarted(acme, 99); !errors.Is(err, jobs.ErrNotFound) {
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	svc := jobs.NewService(slowGetRepository{counting})
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)
~~~

to:

~~~go
	svc := jobs.NewService(slowGetRepository{counting})
	ctx := acme
	job, _ := svc.Create(ctx, "resize", 0)
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
type finder []jobs.ID
~~~

to:

~~~go
type finder []jobs.Abandoned
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
func (f finder) Abandoned(context.Context, time.Time, int) ([]jobs.ID, error) { return f, nil }
~~~

to:

~~~go
func (f finder) Abandoned(context.Context, time.Time, int) ([]jobs.Abandoned, error) { return f, nil }
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
func TestFailAbandonedFailsOnlyUnfinishedJobs(t *testing.T) {
	ctx := context.Background()
	repo := memstore.New()
~~~

to:

~~~go
func TestFailAbandonedFailsOnlyUnfinishedJobs(t *testing.T) {
	ctx := acme
	repo := memstore.New()
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	n, err := svc.FailAbandoned(ctx, finder{stuck.ID, done.ID}, time.Minute)
~~~

to:

~~~go
	n, err := svc.FailAbandoned(ctx, finder{{ID: stuck.ID, Tenant: stuck.Tenant}, {ID: done.ID, Tenant: done.Tenant}}, time.Minute)
~~~


In `internal/breaker/repository_test.go`:

Change:

<!-- edit: internal/breaker/repository_test.go -->
~~~go
	"runway/internal/memstore"
)

// broken is a repository whose every call fails, and counts the calls.
~~~

to:

~~~go
	"runway/internal/memstore"
	"runway/internal/tenant"
)

// acme is a request context for tenant "acme": every repository call
// needs a tenant (Phase 6).
var acme = tenant.With(context.Background(), "acme")

// broken is a repository whose every call fails, and counts the calls.
~~~

Change:

<!-- edit: internal/breaker/repository_test.go -->
~~~go
		_, _ = repo.Get(context.Background(), 1)
~~~

to:

~~~go
		_, _ = repo.Get(acme, 1)
~~~

Change:

<!-- edit: internal/breaker/repository_test.go -->
~~~go
	if _, err := repo.Get(context.Background(), 1); !errors.Is(err, jobs.ErrUnavailable) {
~~~

to:

~~~go
	if _, err := repo.Get(acme, 1); !errors.Is(err, jobs.ErrUnavailable) {
~~~

Change:

<!-- edit: internal/breaker/repository_test.go -->
~~~go
		if _, err := repo.Get(context.Background(), 99); !errors.Is(err, jobs.ErrNotFound) {
~~~

to:

~~~go
		if _, err := repo.Get(acme, 99); !errors.Is(err, jobs.ErrNotFound) {
~~~


<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/tenant/ ./internal/jobs/... ./internal/memstore/ ./internal/breaker/ && go test -race -count=1 ./internal/jobs/... ./internal/memstore/ ./internal/breaker/ -->

### From the token to the request

The verified token's tenant becomes the request's tenant. In `internal/auth/middleware.go`:

Change:

<!-- edit: internal/auth/middleware.go -->
~~~go
	"google.golang.org/grpc/status"
)
~~~

to:

~~~go
	"google.golang.org/grpc/status"

	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/auth/middleware.go -->
~~~go
// WithClaims returns ctx carrying c.
~~~

to:

~~~go
// WithClaims returns ctx carrying c, and c's tenant (step 4): from here on,
// the work is that tenant's.
~~~

Change:

<!-- edit: internal/auth/middleware.go -->
~~~go
	return context.WithValue(ctx, claimsKey{}, c)
~~~

to:

~~~go
	ctx = context.WithValue(ctx, claimsKey{}, c)
	if c.Tenant != "" {
		ctx = tenant.With(ctx, tenant.ID(c.Tenant))
	}
	return ctx
~~~


A request without one is refused: `403`, or `PermissionDenied` over gRPC. In `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	"runway/internal/jobs"
)
~~~

to:

~~~go
	"runway/internal/jobs"
	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, jobs.ErrInvalidTransition), errors.Is(err, jobs.ErrConflict):
~~~

to:

~~~go
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, tenant.ErrMissing):
		writeError(w, http.StatusForbidden, "no tenant")
	case errors.Is(err, jobs.ErrInvalidTransition), errors.Is(err, jobs.ErrConflict):
~~~


In `internal/grpcapi/server.go`:

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
	"runway/internal/jobs"
)
~~~

to:

~~~go
	"runway/internal/jobs"
	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, jobs.ErrUnavailable):
~~~

to:

~~~go
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, tenant.ErrMissing):
		return status.Error(codes.PermissionDenied, "no tenant")
	case errors.Is(err, jobs.ErrUnavailable):
~~~


The handler's tests act for acme. In `internal/httpapi/handler_test.go`, which also gets a test for a hole you might not think of:

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	"runway/internal/memstore"
)
~~~

to:

~~~go
	"runway/internal/memstore"
	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	request := httptest.NewRequest(method, target, strings.NewReader(body))
	if body != "" {
~~~

to:

~~~go
	request := httptest.NewRequest(method, target, strings.NewReader(body))
	// Requests act for tenant "acme", as auth.Require would set from a
	// token (Phase 6).
	request = request.WithContext(tenant.With(request.Context(), "acme"))
	if body != "" {
~~~

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
			request := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(tt.body))
			request.Header.Set("Content-Type", tt.contentType)
~~~

to:

~~~go
			request := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(tt.body))
			request = request.WithContext(tenant.With(request.Context(), "acme"))
			request.Header.Set("Content-Type", tt.contentType)
~~~

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
		r := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(`{"description":"resize"}`))
		r.Header.Set("Content-Type", "application/json")
~~~

to:

~~~go
		r := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(`{"description":"resize"}`))
		r = r.WithContext(tenant.With(r.Context(), "acme"))
		r.Header.Set("Content-Type", "application/json")
~~~

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	r := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(`{"description":"x","duration_ms":1}`))
	r.Header.Set("Content-Type", "application/json")
~~~

to:

~~~go
	r := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(`{"description":"x","duration_ms":1}`))
	r = r.WithContext(tenant.With(r.Context(), "acme"))
	r.Header.Set("Content-Type", "application/json")
~~~

Add this at the end of the file:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
// Clients choose idempotency keys, so two tenants can choose the same one.
// Each must get its own job, not the other's stored response (Phase 6).
func TestIdempotencyKeysBelongToATenant(t *testing.T) {
	h := newTestHandler(WithIdempotency(idempotency.NewStore(time.Hour, time.Now)))
	send := func(owner tenant.ID) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(`{"description":"resize"}`))
		r = r.WithContext(tenant.With(r.Context(), owner))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Idempotency-Key", "order-42")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	acme, globex := send("acme"), send("globex")
	if acme.Code != http.StatusCreated || globex.Code != http.StatusCreated {
		t.Fatalf("acme %d, globex %d", acme.Code, globex.Code)
	}
	if a, g := decode(t, acme).ID, decode(t, globex).ID; a == g {
		t.Fatalf("both tenants got job %d: globex was handed acme's stored response", a)
	}
}
~~~


Clients choose their own idempotency keys (Phase 3). Two tenants can easily both choose `order-42`, and without the tenant in the key, the second would be handed the *first one's stored response*, including its job. The fix, in `internal/idempotency/idempotency.go`:

Change:

<!-- edit: internal/idempotency/idempotency.go -->
~~~go
	"time"
)
~~~

to:

~~~go
	"time"

	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/idempotency/idempotency.go -->
~~~go
			return
		}

		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
~~~

to:

~~~go
			return
		}
		// Keys belong to a tenant (Phase 6). Clients choose their keys, so
		// two tenants can choose the same one; unscoped, the second would
		// be handed the first one's stored response.
		if owner, ok := tenant.From(r.Context()); ok {
			key = string(owner) + "/" + key
		}

		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
~~~


In `internal/grpcapi/server_test.go`:

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go
	"runway/internal/memstore"
)
~~~

to:

~~~go
	"runway/internal/memstore"
	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go
	server := grpc.NewServer(opts...)
~~~

to:

~~~go
	// Calls act for tenant "acme", as if a token had said so (Phase 6).
	asAcme := func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		return handler(tenant.With(ctx, "acme"), req)
	}
	server := grpc.NewServer(append([]grpc.ServerOption{grpc.ChainUnaryInterceptor(asAcme)}, opts...)...)
~~~


### The cache

The cache is the sneakiest place for a tenant leak. It answers reads *without asking the database*, so row-level security can't help, and it's keyed by whatever you chose. In `internal/cache/cache.go`:

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
	"runway/internal/ring"
)
~~~

to:

~~~go
	"runway/internal/ring"
	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
func (r *Repository) key(id jobs.ID) string {
	return r.opts.Prefix + strconv.FormatInt(int64(id), 10)
~~~

to:

~~~go
// key names a job's cached copy. The tenant is part of it (Phase 6): a
// cache keyed by ID alone would hand one tenant's job to anyone who asked
// for its number, without the database ever being asked.
func (r *Repository) key(owner tenant.ID, id jobs.ID) string {
	return r.opts.Prefix + string(owner) + ":" + strconv.FormatInt(int64(id), 10)
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
		return err
	}
	_ = r.call(ctx, func(ctx context.Context) error {
		return r.client.Del(ctx, r.key(job.ID)).Err()
~~~

to:

~~~go
		return err
	}
	owner, _ := tenant.From(ctx) // the update above already required it
	_ = r.call(ctx, func(ctx context.Context) error {
		return r.client.Del(ctx, r.key(owner, job.ID)).Err()
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
	if job, ok := r.lookup(ctx, id); ok {
~~~

to:

~~~go
	owner, err := tenant.Require(ctx)
	if err != nil {
		return jobs.Job{}, err // no tenant: don't even look
	}
	if job, ok := r.lookup(ctx, owner, id); ok {
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
	loaded, err, _ := r.loads.Do(r.key(id), func() (any, error) {
~~~

to:

~~~go
	// The tenant is in the singleflight key too: two tenants asking for the
	// same ID at the same moment must not share one load.
	loaded, err, _ := r.loads.Do(r.key(owner, id), func() (any, error) {
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
		if job, ok, err := r.cached(ctx, id); err == nil && ok {
~~~

to:

~~~go
		if job, ok, err := r.cached(ctx, owner, id); err == nil && ok {
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
func (r *Repository) lookup(ctx context.Context, id jobs.ID) (jobs.Job, bool) {
	job, ok, err := r.cached(ctx, id)
~~~

to:

~~~go
func (r *Repository) lookup(ctx context.Context, owner tenant.ID, id jobs.ID) (jobs.Job, bool) {
	job, ok, err := r.cached(ctx, owner, id)
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
func (r *Repository) cached(ctx context.Context, id jobs.ID) (job jobs.Job, ok bool, err error) {
~~~

to:

~~~go
func (r *Repository) cached(ctx context.Context, owner tenant.ID, id jobs.ID) (job jobs.Job, ok bool, err error) {
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
		data, err = r.client.Get(ctx, r.key(id)).Bytes()
~~~

to:

~~~go
		data, err = r.client.Get(ctx, r.key(owner, id)).Bytes()
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
		return r.client.Set(ctx, r.key(job.ID), data, ttl).Err()
~~~

to:

~~~go
		return r.client.Set(ctx, r.key(job.Tenant, job.ID), data, ttl).Err()
~~~


The singleflight key gets the tenant too. Otherwise two tenants asking for job 7 at the same moment would share one load, and one of them would get the other's answer.

In `internal/cache/cache_test.go`, the tests act for acme, and one test reads as acme (so the job is cached) and then as globex:

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
	"crypto/rand"
	"os"
~~~

to:

~~~go
	"crypto/rand"
	"errors"
	"os"
~~~

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
	"runway/internal/memstore"
)

// counting wraps a repository and counts Gets, so tests can see how many
~~~

to:

~~~go
	"runway/internal/memstore"
	"runway/internal/tenant"
)

// acme is a request context for tenant "acme": every repository call
// needs a tenant (Phase 6).
var acme = tenant.With(context.Background(), "acme")

// counting wraps a repository and counts Gets, so tests can see how many
~~~

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
	job, err := repo.Create(context.Background(), job)
~~~

to:

~~~go
	job, err := repo.Create(acme, job)
~~~

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
	for range 3 {
		if _, err := repo.Get(context.Background(), job.ID); err != nil {
			t.Fatal(err)
~~~

to:

~~~go
	for range 3 {
		if _, err := repo.Get(acme, job.ID); err != nil {
			t.Fatal(err)
~~~

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
	ctx := context.Background()
~~~

to:

~~~go
	ctx := acme
~~~

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
		t.Fatalf("read %s after the update, want running", got.State)
	}
~~~

to:

~~~go
		t.Fatalf("read %s after the update, want running", got.State)
	}
}

// A cached copy belongs to its tenant (Phase 6). Keyed by ID alone, the
// cache would hand acme's job to globex without asking the database, whose
// row-level security would have refused.
func TestCachedCopiesBelongToATenant(t *testing.T) {
	repo := newCache(t, client(t), memstore.New())
	job := create(t, repo)
	if _, err := repo.Get(acme, job.ID); err != nil { // now cached
		t.Fatal(err)
	}
	globex := tenant.With(context.Background(), "globex")
	if got, err := repo.Get(globex, job.ID); !errors.Is(err, jobs.ErrNotFound) {
		t.Fatalf("globex read acme's job %d: %+v, %v; want ErrNotFound", job.ID, got, err)
	}
~~~

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
			if _, err := repo.Get(context.Background(), job.ID); err != nil {
~~~

to:

~~~go
			if _, err := repo.Get(acme, job.ID); err != nil {
~~~

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
	for range 5 {
		if _, err := repo.Get(context.Background(), job.ID); err != nil {
			t.Fatalf("read failed because the cache is down: %v", err)
~~~

to:

~~~go
	for range 5 {
		if _, err := repo.Get(acme, job.ID); err != nil {
			t.Fatalf("read failed because the cache is down: %v", err)
~~~

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
	if err := Ping(context.Background(), client); err != nil {
~~~

to:

~~~go
	if err := Ping(acme, client); err != nil {
~~~

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
		job := create(t, repo)
		if _, err := repo.Get(context.Background(), job.ID); err != nil {
			t.Fatal(err)
~~~

to:

~~~go
		job := create(t, repo)
		if _, err := repo.Get(acme, job.ID); err != nil {
			t.Fatal(err)
~~~

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
	err = client.(*redis.Ring).ForEachShard(context.Background(), func(ctx context.Context, shard *redis.Client) error {
~~~

to:

~~~go
	err = client.(*redis.Ring).ForEachShard(acme, func(ctx context.Context, shard *redis.Client) error {
~~~


I wrote that last test late. With the tenant removed from the key, every other test in the repository still passed, the contract's isolation test included: it asks as globex *before* anyone has cached the job, so the cache misses and the database refuses. A cache keyed by ID would have served acme's job to anyone who asked after acme did.

<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/auth/... ./internal/httpapi/... ./internal/grpcapi/... ./internal/idempotency/... ./internal/cache/... && go test -race -count=1 ./internal/auth/... ./internal/httpapi/... ./internal/grpcapi/... ./internal/idempotency/... ./internal/cache/... -->

### Through the bus

Messages carry the tenant in their envelope, beside the trace from Phase 5. In `internal/messages/messages.go`:

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
	Trace string `json:"trace,omitempty"`
}
~~~

to:

~~~go
	Trace string `json:"trace,omitempty"`
	// Tenant is whose work this is (Phase 6). Whoever handles the message
	// acts for this tenant, and only this tenant.
	Tenant string `json:"tenant,omitempty"`
}
~~~


The API stamps it on every message it sends, and the event handler acts for the tenant the event names. In `internal/eventing/eventing.go`:

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
	"runway/internal/outbox"
)
~~~

to:

~~~go
	"runway/internal/outbox"
	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
	return messages.New(messages.TypeRunJob, messages.RunJob{
~~~

to:

~~~go
	env, err := messages.New(messages.TypeRunJob, messages.RunJob{
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
	}, now)
}
~~~

to:

~~~go
	}, now)
	env.Tenant = string(job.Tenant)
	return env, err
}
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
				return nil, err
			}
			msgs = append(msgs, outbox.Message{
				Destination: messages.JobEventsTopic,
~~~

to:

~~~go
				return nil, err
			}
			env.Tenant = string(job.Tenant)
			msgs = append(msgs, outbox.Message{
				Destination: messages.JobEventsTopic,
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
		err := apply(ctx, updater, msg)
~~~

to:

~~~go
		// An event acts for the tenant it names, so the job it points to
		// must be that tenant's: an event naming another tenant's job finds
		// nothing (Phase 6). An event naming no tenant can never be applied.
		if msg.Tenant == "" {
			return bus.Permanent(fmt.Errorf("%w: event %s", tenant.ErrMissing, msg.ID))
		}
		err := apply(tenant.With(ctx, tenant.ID(msg.Tenant)), updater, msg)
~~~


An event with no tenant is `Permanent`: retrying can't add one, so it goes straight to the dead-letter queue. And an event naming globex but pointing at acme's job finds nothing, because the update runs as globex. The worker copies the command's tenant onto each event it sends. In `internal/worker/worker.go`:

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
	if err := w.emit(ctx, messages.TypeJobStarted, messages.JobStarted{JobID: cmd.JobID}); err != nil {
~~~

to:

~~~go
	// Every event this run sends belongs to the command's tenant (Phase 6).
	owner := msg.Tenant
	if err := w.emit(ctx, owner, messages.TypeJobStarted, messages.JobStarted{JobID: cmd.JobID}); err != nil {
~~~

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
		return w.emit(ctx, messages.TypeJobFailed, failed)
~~~

to:

~~~go
		return w.emit(ctx, owner, messages.TypeJobFailed, failed)
~~~

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
	return w.emit(ctx, messages.TypeJobCompleted, messages.JobCompleted{JobID: cmd.JobID})
~~~

to:

~~~go
	return w.emit(ctx, owner, messages.TypeJobCompleted, messages.JobCompleted{JobID: cmd.JobID})
~~~

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
func (w *Worker) emit(ctx context.Context, msgType string, payload any) error {
~~~

to:

~~~go
func (w *Worker) emit(ctx context.Context, owner, msgType string, payload any) error {
~~~

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
	}
	waiting := w.retry
~~~

to:

~~~go
	}
	msg.Tenant = owner
	waiting := w.retry
~~~


### Row-level security

Now the second wall. Create `internal/pgstore/migrations/0007_tenants.sql`:

<!-- file: internal/pgstore/migrations/0007_tenants.sql -->
~~~sql
-- Phase 6, step 4: every job belongs to a tenant, and PostgreSQL itself
-- keeps tenants apart, with row-level security (RLS).

-- +goose Up
-- Jobs from before tenants existed belong to "default". The default is
-- then dropped, so an INSERT that forgets the tenant fails loudly.
ALTER TABLE jobs ADD COLUMN tenant TEXT NOT NULL DEFAULT 'default';
ALTER TABLE jobs ALTER COLUMN tenant DROP DEFAULT;
ALTER TABLE job_events ADD COLUMN tenant TEXT NOT NULL DEFAULT 'default';
ALTER TABLE job_events ALTER COLUMN tenant DROP DEFAULT;

-- The role request transactions switch to. It can't log in, owns nothing,
-- and is subject to RLS. Roles belong to the whole server, not one schema,
-- so it may already exist.
-- +goose StatementBegin
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'runway_tenant') THEN
        CREATE ROLE runway_tenant NOLOGIN NOSUPERUSER NOBYPASSRLS;
    END IF;
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO runway_tenant', current_schema());
END
$$;
-- +goose StatementEnd
GRANT SELECT, INSERT, UPDATE ON jobs TO runway_tenant;
GRANT SELECT, INSERT ON job_events TO runway_tenant;
GRANT INSERT ON outbox TO runway_tenant;

-- The tenant this transaction acts for, or an error. A forgotten tenant must
-- fail, not quietly match nothing. current_setting('app.tenant') alone isn't
-- enough: on a pooled connection that once set it, it reads back as an empty
-- string after the transaction ends, and "tenant = ''" just matches no rows.
-- +goose StatementBegin
CREATE FUNCTION current_tenant() RETURNS TEXT
LANGUAGE plpgsql STABLE AS $$
DECLARE
    t TEXT := current_setting('app.tenant', true);
BEGIN
    IF t IS NULL OR t = '' THEN
        RAISE EXCEPTION 'app.tenant is not set: no tenant for this transaction';
    END IF;
    RETURN t;
END
$$;
-- +goose StatementEnd

-- A row is visible, and may be written, only when its tenant is the one the
-- transaction set in app.tenant.
ALTER TABLE jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON jobs
    USING (tenant = current_tenant())
    WITH CHECK (tenant = current_tenant());
ALTER TABLE job_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON job_events
    USING (tenant = current_tenant())
    WITH CHECK (tenant = current_tenant());

-- +goose Down
DROP POLICY tenant_isolation ON job_events;
ALTER TABLE job_events DISABLE ROW LEVEL SECURITY;
DROP POLICY tenant_isolation ON jobs;
ALTER TABLE jobs DISABLE ROW LEVEL SECURITY;
REVOKE ALL ON jobs, job_events, outbox FROM runway_tenant;
DROP FUNCTION current_tenant();
ALTER TABLE job_events DROP COLUMN tenant;
ALTER TABLE jobs DROP COLUMN tenant;
~~~

Three things in it took me more than one try:
- **`runway_tenant` is a role with no login.** Request transactions switch to it with `SET LOCAL ROLE`, and RLS applies to it because it neither owns the tables nor has `BYPASSRLS`. Roles belong to the whole server, not one database, so the `DO` block creates it only if it's missing (every test database runs this migration).
- **`current_tenant()` raises an error when no tenant is set.** My first version used `current_setting('app.tenant', true)` directly in the policy. On a fresh connection that's `NULL`, which matches nothing. But on a pooled connection that once ran `set_config('app.tenant', ..., true)`, the setting reads back as an *empty string* after the transaction ends, and `tenant = ''` also matches nothing. Either way, a transaction that forgot its tenant would quietly see zero rows. That's safe for reads, but it's silent: a bug that should crash looks like "no jobs yet". The test below found it.
- **Old jobs belong to `default`.** The column is added with a default, and the default is then dropped, so a future `INSERT` that forgets the tenant fails instead of quietly filing the job under `default`.

The store runs each request in a transaction that acts for its tenant. In `internal/pgstore/pgstore.go`:

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	"runway/internal/outbox"
)
~~~

to:

~~~go
	"runway/internal/outbox"
	"runway/internal/tenant"
)
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go

// Create stores the job and its first event in one transaction: both rows
~~~

to:

~~~go

// inTenant runs fn in a transaction that acts for the tenant in ctx, and
// only for it (Phase 6). It switches to runway_tenant, a role row-level
// security applies to, and sets app.tenant, which the policies compare every
// row with. Both last only until the transaction ends, so the pooled
// connection goes back clean. Without a tenant, nothing runs.
func (s *Store) inTenant(ctx context.Context, fn func(owner tenant.ID, tx pgx.Tx) error) error {
	owner, err := tenant.Require(ctx)
	if err != nil {
		return err
	}
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SET LOCAL ROLE runway_tenant`); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant', $1, true)`, string(owner)); err != nil {
			return err
		}
		return fn(owner, tx)
	})
}

// Create stores the job and its first event in one transaction: both rows
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
func (s *Store) Create(ctx context.Context, job jobs.Job) (jobs.Job, error) {
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			INSERT INTO jobs (description, duration_ms, state, failure_reason, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6)
~~~

to:

~~~go
func (s *Store) Create(ctx context.Context, job jobs.Job) (jobs.Job, error) {
	err := s.inTenant(ctx, func(owner tenant.ID, tx pgx.Tx) error {
		job.Tenant = owner
		err := tx.QueryRow(ctx, `
			INSERT INTO jobs (tenant, description, duration_ms, state, failure_reason, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7)
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
			job.Description, job.Duration.Milliseconds(), job.State, job.FailureReason, job.CreatedAt, job.UpdatedAt,
~~~

to:

~~~go
			owner, job.Description, job.Duration.Milliseconds(), job.State, job.FailureReason, job.CreatedAt, job.UpdatedAt,
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
		return s.record(ctx, tx, job)
	})
	if err != nil {
		return jobs.Job{}, fmt.Errorf("create job: %w", err)
~~~

to:

~~~go
		return s.record(ctx, tx, job)
	})
	if errors.Is(err, tenant.ErrMissing) {
		return jobs.Job{}, err
	}
	if err != nil {
		return jobs.Job{}, fmt.Errorf("create job: %w", err)
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go

func (s *Store) Get(ctx context.Context, id jobs.ID) (jobs.Job, error) {
	row := s.pool.QueryRow(ctx, `
		SELECT id, description, duration_ms, state, failure_reason, created_at, updated_at
		FROM jobs WHERE id = $1`, id)
	job, err := scanJob(row)
	if errors.Is(err, pgx.ErrNoRows) {
~~~

to:

~~~go

// Get reads one job. There is no "AND tenant = ..." here: row-level
// security adds it to every query the tenant role makes.
func (s *Store) Get(ctx context.Context, id jobs.ID) (jobs.Job, error) {
	var job jobs.Job
	err := s.inTenant(ctx, func(_ tenant.ID, tx pgx.Tx) error {
		var err error
		job, err = scanJob(tx.QueryRow(ctx, `
			SELECT id, tenant, description, duration_ms, state, failure_reason, created_at, updated_at
			FROM jobs WHERE id = $1`, id))
		return err
	})
	switch {
	case errors.Is(err, pgx.ErrNoRows):
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
		return jobs.Job{}, jobs.ErrNotFound
	}
	if err != nil {
		return jobs.Job{}, fmt.Errorf("get job %d: %w", id, err)
~~~

to:

~~~go
		return jobs.Job{}, jobs.ErrNotFound
	case errors.Is(err, tenant.ErrMissing):
		return jobs.Job{}, err
	case err != nil:
		return jobs.Job{}, fmt.Errorf("get job %d: %w", id, err)
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
func (s *Store) Update(ctx context.Context, job jobs.Job, expected jobs.State) error {
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
~~~

to:

~~~go
func (s *Store) Update(ctx context.Context, job jobs.Job, expected jobs.State) error {
	err := s.inTenant(ctx, func(owner tenant.ID, tx pgx.Tx) error {
		job.Tenant = owner
		tag, err := tx.Exec(ctx, `
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	if err != nil && !errors.Is(err, jobs.ErrNotFound) && !errors.Is(err, jobs.ErrConflict) {
~~~

to:

~~~go
	if err != nil && !errors.Is(err, jobs.ErrNotFound) && !errors.Is(err, jobs.ErrConflict) && !errors.Is(err, tenant.ErrMissing) {
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
		INSERT INTO job_events (job_id, state, reason, at) VALUES ($1, $2, $3, $4)`,
		event.JobID, event.State, event.Reason, event.At); err != nil {
~~~

to:

~~~go
		INSERT INTO job_events (job_id, tenant, state, reason, at) VALUES ($1, $2, $3, $4, $5)`,
		event.JobID, job.Tenant, event.State, event.Reason, event.At); err != nil {
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
// before, oldest first. The partial index jobs_running_updated_at answers
~~~

to:

~~~go
// before, oldest first, in every tenant. It is a system task, so it runs
// as the connection's own role, which owns the table and so isn't subject
// to row-level security. The partial index jobs_running_updated_at answers
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
func (s *Store) Abandoned(ctx context.Context, before time.Time, limit int) ([]jobs.ID, error) {
~~~

to:

~~~go
func (s *Store) Abandoned(ctx context.Context, before time.Time, limit int) ([]jobs.Abandoned, error) {
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
		SELECT id FROM jobs
~~~

to:

~~~go
		SELECT id, tenant FROM jobs
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	return pgx.CollectRows(rows, pgx.RowTo[jobs.ID])
~~~

to:

~~~go
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (jobs.Abandoned, error) {
		var a jobs.Abandoned
		err := row.Scan(&a.ID, &a.Tenant)
		return a, err
	})
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	rows, err := s.pool.Query(ctx, `
		SELECT job_id, state, reason, at FROM job_events WHERE job_id = $1 ORDER BY id`, id)
	if err != nil {
		return nil, fmt.Errorf("history of job %d: %w", id, err)
	}
	events, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (jobs.Event, error) {
		var e jobs.Event
		err := row.Scan(&e.JobID, &e.State, &e.Reason, &e.At)
		e.At = e.At.UTC()
		return e, err
~~~

to:

~~~go
	var events []jobs.Event
	err := s.inTenant(ctx, func(_ tenant.ID, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT job_id, state, reason, at FROM job_events WHERE job_id = $1 ORDER BY id`, id)
		if err != nil {
			return err
		}
		events, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (jobs.Event, error) {
			var e jobs.Event
			err := row.Scan(&e.JobID, &e.State, &e.Reason, &e.At)
			e.At = e.At.UTC()
			return e, err
		})
		return err
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	err := row.Scan(&job.ID, &job.Description, &durationMS, &job.State, &job.FailureReason, &job.CreatedAt, &job.UpdatedAt)
~~~

to:

~~~go
	err := row.Scan(&job.ID, &job.Tenant, &job.Description, &durationMS, &job.State, &job.FailureReason, &job.CreatedAt, &job.UpdatedAt)
~~~


`SET LOCAL` and `set_config(..., true)` last until the transaction ends, so the connection goes back to the pool clean. Look at `Get`: there's no `AND tenant = $2` in its SQL. The policy adds it. `Abandoned` is the exception: it runs as the connection's own role, which owns the table and so isn't subject to RLS, because it must see every tenant's running jobs.

Test the wall with a query that has no `WHERE` at all. In `internal/pgstore/pgstore_test.go`:

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	"slices"
	"testing"
	"time"

~~~

to:

~~~go
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	"runway/internal/pgstore/pgtest"
)

func TestContract(t *testing.T) {
~~~

to:

~~~go
	"runway/internal/pgstore/pgtest"
	"runway/internal/tenant"
)

// acme is a request context for tenant "acme": every repository call
// needs a tenant (Phase 6).
var acme = tenant.With(context.Background(), "acme")

func TestContract(t *testing.T) {
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
func TestHistoryRecordsEveryChange(t *testing.T) {
	ctx := context.Background()
	store := New(pgtest.Pool(t, Migrate))
~~~

to:

~~~go
func TestHistoryRecordsEveryChange(t *testing.T) {
	ctx := acme
	store := New(pgtest.Pool(t, Migrate))
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
func TestChangeAndEventCommitTogether(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.Pool(t, Migrate)
~~~

to:

~~~go
func TestChangeAndEventCommitTogether(t *testing.T) {
	ctx := acme
	pool := pgtest.Pool(t, Migrate)
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
func TestCreateSavesOutboxMessages(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.Pool(t, Migrate)
~~~

to:

~~~go
func TestCreateSavesOutboxMessages(t *testing.T) {
	ctx := acme
	pool := pgtest.Pool(t, Migrate)
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
func TestAbandonedFindsOnlyOldRunningJobs(t *testing.T) {
	ctx := context.Background()
	store := New(pgtest.Pool(t, Migrate))
~~~

to:

~~~go
func TestAbandonedFindsOnlyOldRunningJobs(t *testing.T) {
	ctx := acme
	store := New(pgtest.Pool(t, Migrate))
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	if !slices.Equal(ids, []jobs.ID{old}) {
		t.Fatalf("abandoned = %v, want [%d]", ids, old)
~~~

to:

~~~go
	if !slices.Equal(ids, []jobs.Abandoned{{ID: old, Tenant: "acme"}}) {
		t.Fatalf("abandoned = %v, want [{%d acme}]", ids, old)
~~~

Add this at the end of the file:

<!-- append: internal/pgstore/pgstore_test.go -->
~~~go
// The second wall (Phase 6): even a query that forgets the tenant filter
// can't see another tenant's rows, because PostgreSQL adds the filter. And
// a transaction that never says which tenant it acts for can't read at all.
func TestRowLevelSecurityKeepsTenantsApart(t *testing.T) {
	store := New(pgtest.Pool(t, Migrate))
	for _, owner := range []tenant.ID{"acme", "acme", "globex"} {
		job, _ := jobs.New("resize", time.Second, t0)
		if _, err := store.Create(tenant.With(context.Background(), owner), job); err != nil {
			t.Fatal(err)
		}
	}
	count := func(owner tenant.ID) (n int, err error) {
		err = store.inTenant(tenant.With(context.Background(), owner), func(_ tenant.ID, tx pgx.Tx) error {
			return tx.QueryRow(context.Background(), `SELECT count(*) FROM jobs`).Scan(&n) // no WHERE at all
		})
		return n, err
	}
	if n, err := count("acme"); err != nil || n != 2 {
		t.Fatalf("acme sees %d jobs, %v; want its 2", n, err)
	}
	if n, err := count("globex"); err != nil || n != 1 {
		t.Fatalf("globex sees %d jobs, %v; want its 1", n, err)
	}
	// As the tenant role, but with app.tenant never set: an error, not
	// "zero rows" and not "all rows".
	err := pgx.BeginFunc(context.Background(), store.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(context.Background(), `SET LOCAL ROLE runway_tenant`); err != nil {
			return err
		}
		var n int
		return tx.QueryRow(context.Background(), `SELECT count(*) FROM jobs`).Scan(&n)
	})
	if err == nil || !strings.Contains(err.Error(), "app.tenant") {
		t.Fatalf("no tenant set: %v, want an error about app.tenant", err)
	}
}
~~~


### The API

With authentication off, there are no tokens and so no tenants. Everything belongs to `dev`, rather than letting the "tenant required" rule bend. And the cache's key prefix moves to `v2`, so no copy cached under an old, tenant-less key is ever read again. In `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/telemetry"
	"runway/internal/worker"
~~~

to:

~~~go
	"runway/internal/telemetry"
	"runway/internal/tenant"
	"runway/internal/worker"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	return cfg, nil
}

// loadAuth reads the token settings. Authentication is on unless
~~~

to:

~~~go
	return cfg, nil
}

// devTenant owns everything when authentication is off.
const devTenant tenant.ID = "dev"

// loadAuth reads the token settings. Authentication is on unless
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		Prefix:      "runway:job:v1:",
~~~

to:

~~~go
		Prefix:      "runway:job:v2:", // v2: keys include the tenant (Phase 6)
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		logger.Warn("authentication is off (AUTH_MODE=off): anyone can call this API")
~~~

to:

~~~go
		// No identities, so no tenants either: everything is the "dev"
		// tenant's (step 4). Jobs still need one; that rule doesn't bend.
		logger.Warn("authentication is off (AUTH_MODE=off): anyone can call this API, as tenant dev")
		options = append(options, httpapi.WithAuthentication(func(next http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				next.ServeHTTP(w, r.WithContext(tenant.With(r.Context(), devTenant)))
			})
		}))
		unary = append(unary, func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
			return handler(tenant.With(ctx, devTenant), req)
		})
~~~


In `cmd/api/main_test.go`, the test token gets a tenant:

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go
		IssuedAt: now.Unix(), Expiry: now.Add(time.Minute).Unix(), Roles: []string{"submitter"}}, key)
~~~

to:

~~~go
		IssuedAt: now.Unix(), Expiry: now.Add(time.Minute).Unix(), Tenant: "acme", Roles: []string{"submitter"}}, key)
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

**Break it.** Three experiments; undo each.

1. In `0007_tenants.sql`, delete the `IF t IS NULL OR t = '' THEN ... END IF;` lines, so `current_tenant()` returns whatever the setting holds. Run `go test -count=1 -run TestRowLevelSecurity ./internal/pgstore/`:

   ~~~text
   --- FAIL: TestRowLevelSecurityKeepsTenantsApart (0.30s)
       pgstore_test.go:192: no tenant set: <nil>, want an error about app.tenant
   ~~~

   No error, and no rows: the quiet failure.

2. In `idempotency.go`, stop prefixing the key with the tenant (change `if owner, ok := tenant.From(r.Context()); ok {` to `...; ok && false {`):

   ~~~text
   handler_test.go:348: both tenants got job 1: globex was handed acme's stored response
   ~~~

3. In `cache.go`, drop `string(owner) + ":"` from `key`:

   ~~~text
   cache_test.go:130: globex read acme's job 1: {ID:1 Tenant:acme Description:resize Duration:1s State:queued FailureReason: CreatedAt:2026-10-16 13:19:11.815272635 +0000 UTC UpdatedAt:2026-10-16 13:19:11.815272635 +0000 UTC}, <nil>; want ErrNotFound
   ~~~

   The job even says `Tenant:acme`. Nothing checked it on the way out of the cache.

### Run it

Rebuild and roll out. The Helm upgrade runs migration 0007 in its hook, before the new Pods start. Then try globex against an acme job:

~~~bash
ACME=$(token acme-ci); GLOBEX=$(token globex-ci)
curl -s -X POST localhost:8080/jobs -H "Authorization: Bearer $ACME" -H "Content-Type: application/json" -d '{"description":"acme payroll run","duration_ms":10}'; echo
curl -s -w "  (%{http_code})\n" localhost:8080/jobs/14359 -H "Authorization: Bearer $GLOBEX"     # use your job's ID
curl -s -w "  (%{http_code})\n" localhost:8080/jobs/14359 -H "Authorization: Bearer $ACME"
curl -s -w "  (%{http_code})\n" localhost:8080/jobs/1 -H "Authorization: Bearer $ACME"         # an old job, from before tenants
kubectl -n runway exec postgres-0 -- psql -U runway -c "SELECT id, tenant, state FROM jobs ORDER BY id DESC LIMIT 2"
~~~

~~~text
{"id":14359,"state":"queued","description":"acme payroll run","duration_ms":10,"created_at":"2026-10-09T07:16:01.6718Z","updated_at":"2026-10-09T07:16:01.6718Z"}
{"error":"job not found"}
  (404)
{"id":14359,"state":"completed","description":"acme payroll run","duration_ms":10,"created_at":"2026-10-09T07:16:01.6718Z","updated_at":"2026-10-09T07:16:01.815947Z"}
  (200)
{"error":"job not found"}
  (404)
  id   | tenant  |   state   
-------+---------+-----------
 14359 | acme    | completed
 14358 | default | completed
(2 rows)
~~~

Globex gets `404`, as if the job didn't exist. Acme's job went through the outbox, RabbitMQ and a worker, and came back `completed`: the tenant made the whole round trip. Jobs from before this step belong to `default`, which no client is a member of. That's deliberate. Deciding who owns old data is a migration someone has to think about, not a default to guess.

One thing is still wrong, and the `psql` line shows it: you just ran it as `runway`, the API's own login, which is a superuser (step 1). RLS held because the store *chose* to `SET ROLE runway_tenant`. Anyone who steals the password chooses not to, and sees everything. Step 9 takes the superuser away.

**Explain it:** why does the tenant come from the token, and not from a header or the body? Why `404` rather than `403`? List every place a job's ID is used as a key in Runway, and say how each one is scoped. Why was the first `current_tenant()` "fail quiet", and why is that worse than an error? Why does the RLS hold even though the API logs in as a superuser, and why isn't that enough?

**Read.** OWASP API Security Top 10, API1:2023 (BOLA). Then the PostgreSQL documentation on [row security policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html), especially which roles they don't apply to. Then AWS's *SaaS Tenant Isolation Strategies* whitepaper: silo, bridge and pool models. Which is Runway, and what would moving one large tenant to its own database take?

---
## Step 5: Rate limiting

**The problem.** Tenants now can't see each other's jobs, but they still share everything else: the API, the queue, the workers. One tenant that submits jobs as fast as it can fills the queue, and every other tenant's jobs wait behind it (T4). Phase 5's autoscaler adds workers, up to its maximum, and then the queue just grows. This is the **noisy neighbour**, and in a multi-tenant system it's an outage for everyone caused by one customer, who may not even know they're doing it.

**New ideas.**

- **A token bucket** holds up to *burst* tokens and refills at *rate* tokens a second. Each request takes one; with none left, the request is refused. So a tenant can send a burst at once, then a steady rate forever. It needs no timer: store the token count and when it was last updated, and work out the refill when next asked.
- **429 Too Many Requests**, with **`Retry-After`** saying when to come back. A well-behaved client waits that long; a client that retries at once only burns its own budget. In gRPC it's `ResourceExhausted`, with a `RetryInfo` detail.
- **Local or shared.** Each API instance can keep its own buckets (fast, simple), but behind a load balancer with three instances a tenant then gets three budgets, and how much it actually gets depends on how its connections happen to be spread. A shared bucket in Redis gives one budget per tenant, at the cost of a round trip per request.
- **Atomicity.** Read the bucket, compute, write it back: two instances doing that at once can both see "one token left" and both take it. Redis runs a Lua script atomically, so the whole read-compute-write happens as one step.
- **Fail open, but not wide open.** If Redis is down, refusing every request would turn a cache outage into an API outage. So the limiter falls back to local buckets, which still limit each instance.
- **What to count.** Count only work the policy allowed. If refused requests (no permission) used up a tenant's budget, one misconfigured client could lock out its own colleagues.

### The bucket

Create `internal/ratelimit/ratelimit.go`:

<!-- file: internal/ratelimit/ratelimit.go -->
~~~go
// Package ratelimit gives each tenant a budget of requests, so one tenant
// can't take every worker for itself: the "noisy neighbour".
//
// The budget is a token bucket. A bucket holds up to Burst tokens and
// refills at Rate tokens a second. Each request takes one token; with none
// left, the request is refused and told when to come back. So a tenant can
// send Burst requests at once, then Rate a second for as long as it likes.
//
// Local keeps buckets in this process. Redis keeps them in Redis, so every
// API instance draws on the same bucket. Fallback uses Redis while it
// answers, and Local when it doesn't.
package ratelimit

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Limit is a bucket's size and refill rate.
type Limit struct {
	Rate  float64 // tokens added per second
	Burst int     // most tokens the bucket holds
}

func (l Limit) String() string {
	return fmt.Sprintf("%g/s burst %d", l.Rate, l.Burst)
}

// ParseLimit reads "RATE:BURST", such as "10:20".
func ParseLimit(s string) (Limit, error) {
	rate, burst, ok := strings.Cut(s, ":")
	if !ok {
		return Limit{}, fmt.Errorf("limit %q: want RATE:BURST, such as 10:20", s)
	}
	r, err := strconv.ParseFloat(rate, 64)
	if err != nil || r <= 0 || math.IsInf(r, 0) {
		return Limit{}, fmt.Errorf("limit %q: rate must be a positive number", s)
	}
	b, err := strconv.Atoi(burst)
	if err != nil || b < 1 {
		return Limit{}, fmt.Errorf("limit %q: burst must be at least 1", s)
	}
	return Limit{Rate: r, Burst: b}, nil
}

// Decision is a limiter's answer.
type Decision struct {
	Allowed    bool
	Remaining  int           // whole tokens left after this request
	RetryAfter time.Duration // when refused: how long until a token is back
}

// Limiter takes a token from the bucket named key, which limit governs.
type Limiter interface {
	Allow(ctx context.Context, key string, limit Limit) (Decision, error)
}

// bucket is a token bucket. It doesn't add tokens on a timer: it records
// when it was last used, and works out the refill when next asked.
type bucket struct {
	tokens float64
	at     time.Time
}

func (b *bucket) take(now time.Time, l Limit) Decision {
	elapsed := now.Sub(b.at).Seconds()
	if elapsed > 0 { // a clock that steps back adds nothing
		b.tokens = math.Min(float64(l.Burst), b.tokens+elapsed*l.Rate)
		b.at = now
	}
	if b.tokens >= 1 {
		b.tokens--
		return Decision{Allowed: true, Remaining: int(b.tokens)}
	}
	wait := (1 - b.tokens) / l.Rate
	return Decision{RetryAfter: time.Duration(math.Ceil(wait * float64(time.Second)))}
}

// full reports whether b has refilled by now; a full bucket is the same as
// no bucket, so it can be forgotten.
func (b *bucket) full(now time.Time, l Limit) bool {
	return b.tokens+now.Sub(b.at).Seconds()*l.Rate >= float64(l.Burst)
}

// maxBuckets is how many buckets Local keeps before it forgets the full
// ones. Without a bound, a client inventing new keys would grow the map
// until the process ran out of memory.
const maxBuckets = 10_000

// Local keeps buckets in memory. Each instance has its own, so with three
// API instances behind a load balancer a tenant gets three budgets.
type Local struct {
	Now func() time.Time

	mu      sync.Mutex
	buckets map[string]*bucket
	limits  map[string]Limit
}

func NewLocal() *Local {
	return &Local{Now: time.Now, buckets: map[string]*bucket{}, limits: map[string]Limit{}}
}

func (l *Local) Allow(_ context.Context, key string, limit Limit) (Decision, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.Now()
	b, ok := l.buckets[key]
	if !ok {
		if len(l.buckets) >= maxBuckets {
			l.sweep(now)
		}
		b = &bucket{tokens: float64(limit.Burst), at: now} // a new bucket starts full
		l.buckets[key] = b
	}
	l.limits[key] = limit
	return b.take(now, limit), nil
}

func (l *Local) sweep(now time.Time) {
	for key, b := range l.buckets {
		if b.full(now, l.limits[key]) {
			delete(l.buckets, key)
			delete(l.limits, key)
		}
	}
}

// Fallback asks Primary, and when Primary fails, Backup. A rate limiter
// that is down should not take the API down with it, so it fails open; but
// not wide open: Backup still limits each instance on its own.
type Fallback struct {
	Primary, Backup Limiter
	Failed          func(error) // told about each failure, to log or count it
}

func (f Fallback) Allow(ctx context.Context, key string, limit Limit) (Decision, error) {
	d, err := f.Primary.Allow(ctx, key, limit)
	if err == nil {
		return d, nil
	}
	if f.Failed != nil {
		f.Failed(err)
	}
	return f.Backup.Allow(ctx, key, limit)
}
~~~

Look at `take`. A clock that steps backwards adds no tokens, instead of a negative number of them. `RetryAfter` is the time until one whole token is back, rounded up. And `Local` forgets buckets once there are 10,000 of them, keeping the ones still refilling: a full bucket is the same as no bucket. Without that bound, a stream of made-up keys would grow the map until the process ran out of memory.

The same bucket in Lua, for Redis. Create `internal/ratelimit/bucket.lua`:

<!-- file: internal/ratelimit/bucket.lua -->
~~~
-- A token bucket, the same one as bucket.take in Go.
-- KEYS[1]: the bucket. ARGV[1]: rate (tokens a second). ARGV[2]: burst.
-- Returns {allowed (1 or 0), whole tokens left, microseconds to wait}.
local rate = tonumber(ARGV[1])
local burst = tonumber(ARGV[2])

-- The server's clock, in microseconds: every API instance sees the same one.
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000000 + tonumber(t[2])

local b = redis.call('HMGET', KEYS[1], 'tokens', 'at')
local tokens = tonumber(b[1]) or burst -- a new bucket starts full
local at = tonumber(b[2]) or now
if now > at then
  tokens = math.min(burst, tokens + (now - at) / 1000000 * rate)
  at = now
end

local allowed, wait = 0, 0
if tokens >= 1 then
  tokens = tokens - 1
  allowed = 1
else
  wait = math.ceil((1 - tokens) / rate * 1000000)
end

redis.call('HSET', KEYS[1], 'tokens', tokens, 'at', at)
-- Once it would be full again, the bucket is the same as no bucket: let
-- Redis delete it, so idle tenants cost nothing.
redis.call('PEXPIRE', KEYS[1], math.ceil(burst / rate * 1000) + 1000)
return {allowed, math.floor(tokens), wait}
~~~

Two details matter. The time comes from the Redis server (`TIME`), not from the API instances, whose clocks disagree slightly. And `PEXPIRE` lets Redis delete the bucket once it would have refilled, so idle tenants cost nothing.

Create `internal/ratelimit/redis.go`:

<!-- file: internal/ratelimit/redis.go -->
~~~go
package ratelimit

import (
	"context"
	_ "embed"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// bucketScript is the token bucket in Lua. Redis runs a script atomically,
// so two API instances can't both read "one token left" and both take it.
//
//go:embed bucket.lua
var bucketScript string

// Redis keeps buckets in Redis, shared by every API instance. Time comes
// from the Redis server, not the instances, whose clocks disagree a little.
type Redis struct {
	client  redis.UniversalClient
	prefix  string
	timeout time.Duration
	script  *redis.Script
}

// NewRedis stores buckets under prefix. Each call waits at most timeout:
// a limiter is on every request's path, so a slow Redis must not make
// every request slow; past the timeout, Fallback takes over.
func NewRedis(client redis.UniversalClient, prefix string, timeout time.Duration) *Redis {
	return &Redis{client: client, prefix: prefix, timeout: timeout, script: redis.NewScript(bucketScript)}
}

func (r *Redis) Allow(ctx context.Context, key string, limit Limit) (Decision, error) {
	ctx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()
	// Run sends EVALSHA, and the whole script only if Redis doesn't have it
	// yet. On a ring of servers, the key picks the server.
	res, err := r.script.Run(ctx, r.client, []string{r.prefix + key}, limit.Rate, limit.Burst).Int64Slice()
	if err != nil {
		return Decision{}, fmt.Errorf("rate limit %s: %w", key, err)
	}
	if len(res) != 3 {
		return Decision{}, fmt.Errorf("rate limit %s: script returned %d values", key, len(res))
	}
	return Decision{
		Allowed:    res[0] == 1,
		Remaining:  int(res[1]),
		RetryAfter: time.Duration(res[2]) * time.Microsecond,
	}, nil
}
~~~

`go:embed` puts the script in the binary. The 50 ms timeout is there because this call is on every job submission's path: a slow Redis must not make every request slow.

### Per tenant, as an answer from the policy

Where should the check go? Every route and RPC already asks an `Authorizer` before acting (step 3). "Not now" is one more answer to that question, so the limiter *wraps* the authorizer, and there's no new place a handler could forget. Create `internal/ratelimit/tenants.go`:

<!-- file: internal/ratelimit/tenants.go -->
~~~go
package ratelimit

import (
	"context"
	"fmt"
	"strings"
	"time"

	"runway/internal/authz"
	"runway/internal/tenant"
)

// Quotas are the limits per tenant: Default for most, and a different one
// for the tenants listed in Tenants (a bigger customer, a smaller plan).
type Quotas struct {
	Default Limit
	Tenants map[tenant.ID]Limit
}

func (q Quotas) For(id tenant.ID) Limit {
	if l, ok := q.Tenants[id]; ok {
		return l
	}
	return q.Default
}

// ParseQuotas reads a default limit ("10:20") and per-tenant ones
// ("acme=50:100,globex=2:5", or empty).
func ParseQuotas(def, tenants string) (Quotas, error) {
	d, err := ParseLimit(def)
	if err != nil {
		return Quotas{}, err
	}
	q := Quotas{Default: d, Tenants: map[tenant.ID]Limit{}}
	for entry := range strings.SplitSeq(tenants, ",") {
		if entry = strings.TrimSpace(entry); entry == "" {
			continue
		}
		name, limit, ok := strings.Cut(entry, "=")
		if !ok || name == "" {
			return Quotas{}, fmt.Errorf("tenant limit %q: want TENANT=RATE:BURST", entry)
		}
		l, err := ParseLimit(limit)
		if err != nil {
			return Quotas{}, err
		}
		q.Tenants[tenant.ID(name)] = l
	}
	return q, nil
}

// LimitedError is a refusal: the tenant has used its budget, and may try
// again after RetryAfter.
type LimitedError struct {
	Tenant     tenant.ID
	RetryAfter time.Duration
}

func (e *LimitedError) Error() string {
	return fmt.Sprintf("tenant %s is over its rate limit; retry after %s", e.Tenant, e.RetryAfter)
}

// Guard limits action, per tenant, behind next. Every route and RPC
// already asks an Authorizer before acting, so "not now" becomes one more
// answer to that question, with no new place to forget a check. Only
// requests next allows are counted: one client's refused attempts don't use
// up its tenant's budget.
//
// Work without a tenant passes through: there is no bucket to charge, and
// the jobs service refuses it anyway (step 4).
func Guard(next authz.Authorizer, limiter Limiter, quotas Quotas, action authz.Action, limited func(context.Context, *LimitedError)) authz.Authorizer {
	return func(ctx context.Context, a authz.Action) error {
		if err := next(ctx, a); err != nil {
			return err
		}
		owner, ok := tenant.From(ctx)
		if a != action || !ok {
			return nil
		}
		d, err := limiter.Allow(ctx, string(action)+":"+string(owner), quotas.For(owner))
		if err != nil {
			return nil // Fallback has already tried; fail open
		}
		if d.Allowed {
			return nil
		}
		e := &LimitedError{Tenant: owner, RetryAfter: d.RetryAfter}
		if limited != nil {
			limited(ctx, e)
		}
		return e
	}
}
~~~

`Guard` asks the policy first and charges the bucket only if the policy says yes. It limits one action (creating jobs, the expensive one), and if the limiter fails it lets the request through, since `Fallback` has already tried the backup.

Create `internal/ratelimit/ratelimit_test.go`:

<!-- file: internal/ratelimit/ratelimit_test.go -->
~~~go
package ratelimit

import (
	"context"
	"crypto/rand"
	"errors"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"

	"runway/internal/authz"
	"runway/internal/tenant"
)

// clock is a time that tests move by hand.
type clock struct{ now time.Time }

func (c *clock) Now() time.Time          { return c.now }
func (c *clock) Add(d time.Duration)     { c.now = c.now.Add(d) }
func newClock() *clock                   { return &clock{now: time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)} }
func allowed(d Decision, err error) bool { return err == nil && d.Allowed }

func TestABucketAllowsABurstThenTheRate(t *testing.T) {
	c := newClock()
	l := NewLocal()
	l.Now = c.Now
	limit := Limit{Rate: 2, Burst: 3}
	for i := range 3 {
		if d, err := l.Allow(t.Context(), "k", limit); !allowed(d, err) || d.Remaining != 2-i {
			t.Fatalf("request %d of the burst: %+v, %v", i+1, d, err)
		}
	}
	d, _ := l.Allow(t.Context(), "k", limit)
	if d.Allowed || d.RetryAfter != 500*time.Millisecond {
		t.Fatalf("after the burst: %+v, want refused with 500ms to wait", d)
	}
	c.Add(499 * time.Millisecond)
	if d, _ := l.Allow(t.Context(), "k", limit); d.Allowed {
		t.Fatal("allowed before a token was back")
	}
	c.Add(time.Millisecond)
	if d, _ := l.Allow(t.Context(), "k", limit); !d.Allowed {
		t.Fatal("refused once a token was back")
	}
	// A long rest refills the bucket, but only up to Burst.
	c.Add(time.Hour)
	n := 0
	for {
		if d, _ := l.Allow(t.Context(), "k", limit); !d.Allowed {
			break
		}
		n++
	}
	if n != 3 {
		t.Fatalf("after an hour's rest, allowed %d at once, want the burst, 3", n)
	}
}

func TestBucketsAreSeparate(t *testing.T) {
	l := NewLocal()
	limit := Limit{Rate: 1, Burst: 1}
	l.Allow(t.Context(), "acme", limit)
	if d, _ := l.Allow(t.Context(), "acme", limit); d.Allowed {
		t.Fatal("acme's second request allowed")
	}
	if d, _ := l.Allow(t.Context(), "globex", limit); !d.Allowed {
		t.Fatal("globex refused because of acme")
	}
}

func TestLocalForgetsFullBuckets(t *testing.T) {
	c := newClock()
	l := NewLocal()
	l.Now = c.Now
	limit := Limit{Rate: 1, Burst: 1}
	for i := range maxBuckets {
		l.Allow(t.Context(), "key"+strconv.Itoa(i), limit)
	}
	c.Add(time.Second) // all of them full again
	l.Allow(t.Context(), "one more", limit)
	if n := len(l.buckets); n != 1 {
		t.Fatalf("%d buckets kept, want 1", n)
	}
}

func TestParseQuotas(t *testing.T) {
	q, err := ParseQuotas("10:20", "acme=50:100, globex=0.5:1")
	if err != nil {
		t.Fatal(err)
	}
	for id, want := range map[tenant.ID]Limit{"acme": {50, 100}, "globex": {0.5, 1}, "initech": {10, 20}} {
		if got := q.For(id); got != want {
			t.Errorf("%s: %v, want %v", id, got, want)
		}
	}
	for _, bad := range [][2]string{{"10", ""}, {"0:5", ""}, {"10:0", ""}, {"-1:5", ""}, {"10:20", "acme"}, {"10:20", "=5:5"}, {"10:20", "acme=5"}} {
		if _, err := ParseQuotas(bad[0], bad[1]); err == nil {
			t.Errorf("ParseQuotas(%q, %q) accepted", bad[0], bad[1])
		}
	}
}

type failing struct{ calls atomic.Int32 }

func (f *failing) Allow(context.Context, string, Limit) (Decision, error) {
	f.calls.Add(1)
	return Decision{}, errors.New("redis: connection refused")
}

func TestFallbackStillLimitsWhenThePrimaryFails(t *testing.T) {
	var failures int
	f := Fallback{Primary: &failing{}, Backup: NewLocal(), Failed: func(error) { failures++ }}
	limit := Limit{Rate: 1, Burst: 2}
	got := []bool{}
	for range 3 {
		d, err := f.Allow(t.Context(), "k", limit)
		got = append(got, allowed(d, err))
	}
	if got[0] != true || got[1] != true || got[2] != false {
		t.Fatalf("allowed %v, want [true true false]: open, but not wide open", got)
	}
	if failures != 3 {
		t.Fatalf("%d failures reported, want 3", failures)
	}
}

// ctxFor is a context for tenant id, as auth.Require would make it.
func ctxFor(id tenant.ID) context.Context {
	return tenant.With(context.Background(), id)
}

func TestGuardLimitsOneActionPerTenant(t *testing.T) {
	quotas := Quotas{Default: Limit{Rate: 1, Burst: 2}, Tenants: map[tenant.ID]Limit{"globex": {Rate: 1, Burst: 1}}}
	var limited []tenant.ID
	limiter := NewLocal()
	limiter.Now = newClock().Now // time stands still
	authorize := Guard(authz.AllowAll, limiter, quotas, authz.CreateJob, func(_ context.Context, e *LimitedError) {
		limited = append(limited, e.Tenant)
	})
	acme, globex := ctxFor("acme"), ctxFor("globex")
	for range 2 {
		if err := authorize(acme, authz.CreateJob); err != nil {
			t.Fatal(err)
		}
	}
	err := authorize(acme, authz.CreateJob)
	if e, ok := errors.AsType[*LimitedError](err); !ok || e.RetryAfter != time.Second {
		t.Fatalf("acme's third create: %v, want limited for 1s", err)
	}
	if err := authorize(acme, authz.ReadJob); err != nil {
		t.Fatalf("a read was limited with creates: %v", err)
	}
	if err := authorize(globex, authz.CreateJob); err != nil {
		t.Fatalf("globex was limited by acme's use: %v", err)
	}
	if err := authorize(globex, authz.CreateJob); err == nil {
		t.Fatal("globex's own quota (burst 1) was not applied")
	}
	if len(limited) != 2 || limited[0] != "acme" || limited[1] != "globex" {
		t.Fatalf("reported %v, want [acme globex]", limited)
	}
}

func TestGuardCountsOnlyWhatThePolicyAllows(t *testing.T) {
	deny := func(context.Context, authz.Action) error { return authz.ErrDenied }
	limiter := NewLocal()
	authorize := Guard(deny, limiter, Quotas{Default: Limit{Rate: 1, Burst: 1}}, authz.CreateJob, nil)
	for range 5 {
		if err := authorize(ctxFor("acme"), authz.CreateJob); !errors.Is(err, authz.ErrDenied) {
			t.Fatalf("got %v, want the policy's denial", err)
		}
	}
	if d, _ := limiter.Allow(t.Context(), "jobs.create:acme", Limit{Rate: 1, Burst: 1}); !d.Allowed {
		t.Fatal("denied requests used up the tenant's budget")
	}
}

func TestGuardFailsOpenWhenTheLimiterFails(t *testing.T) {
	authorize := Guard(authz.AllowAll, &failing{}, Quotas{Default: Limit{Rate: 1, Burst: 1}}, authz.CreateJob, nil)
	for range 3 {
		if err := authorize(ctxFor("acme"), authz.CreateJob); err != nil {
			t.Fatal(err)
		}
	}
}

// redisClient connects to RUNWAY_REDIS_URL, or skips the test.
func redisClient(t *testing.T) *redis.Client {
	t.Helper()
	url := os.Getenv("RUNWAY_REDIS_URL")
	if url == "" {
		t.Skip("set RUNWAY_REDIS_URL to run Redis tests")
	}
	opts, err := redis.ParseURL(url)
	if err != nil {
		t.Fatal(err)
	}
	c := redis.NewClient(opts)
	t.Cleanup(func() { c.Close() })
	return c
}

func TestRedisBucket(t *testing.T) {
	c := redisClient(t)
	prefix := "test:" + strings.ToLower(rand.Text()) + ":"
	r := NewRedis(c, prefix, time.Second)
	// One a second: slow enough that a loaded machine can't refill a token
	// between two requests of the burst (at 10 a second, the full suite
	// once took over 100 ms between them).
	limit := Limit{Rate: 1, Burst: 3}
	for i := range 3 {
		if d, err := r.Allow(t.Context(), "k", limit); !allowed(d, err) || d.Remaining != 2-i {
			t.Fatalf("request %d of the burst: %+v, %v", i+1, d, err)
		}
	}
	d, err := r.Allow(t.Context(), "k", limit)
	if err != nil || d.Allowed || d.RetryAfter <= 0 || d.RetryAfter > time.Second {
		t.Fatalf("after the burst: %+v, %v; want refused, up to 1s to wait", d, err)
	}
	time.Sleep(d.RetryAfter)
	if d, err := r.Allow(t.Context(), "k", limit); !allowed(d, err) {
		t.Fatalf("after waiting RetryAfter: %+v, %v", d, err)
	}
	// Redis deletes the bucket once it would be full again.
	ttl := c.PTTL(t.Context(), prefix+"k").Val()
	if ttl <= 3*time.Second || ttl > 4*time.Second {
		t.Fatalf("bucket expires in %v, want just over the 3s it takes to refill", ttl)
	}
}

// The point of keeping buckets in Redis: many instances, one budget.
func TestRedisIsOneBucketForManyInstances(t *testing.T) {
	c := redisClient(t)
	prefix := "test:" + strings.ToLower(rand.Text()) + ":"
	limit := Limit{Rate: 0.001, Burst: 20} // no refill during the test
	var wg sync.WaitGroup
	var granted atomic.Int32
	for range 3 { // three API instances...
		r := NewRedis(c, prefix, time.Second)
		for range 20 { // ...each sending 20 requests at once
			wg.Go(func() {
				if d, err := r.Allow(t.Context(), "acme", limit); allowed(d, err) {
					granted.Add(1)
				}
			})
		}
	}
	wg.Wait()
	if n := granted.Load(); n != 20 {
		t.Fatalf("%d of 60 allowed, want exactly the burst, 20", n)
	}
}

func TestRedisTimesOut(t *testing.T) {
	c := redis.NewClient(&redis.Options{Addr: "10.255.255.1:6379", DialTimeout: time.Minute}) // nothing answers
	defer c.Close()
	r := NewRedis(c, "test:", 50*time.Millisecond)
	start := time.Now()
	if _, err := r.Allow(t.Context(), "k", Limit{Rate: 1, Burst: 1}); err == nil {
		t.Fatal("no error from a Redis that isn't there")
	}
	if waited := time.Since(start); waited > time.Second {
		t.Fatalf("waited %v; the timeout is 50ms", waited)
	}
}
~~~

The Redis tests run against Phase 3's Compose Redis (they skip without `RUNWAY_REDIS_URL`). `TestRedisIsOneBucketForManyInstances` is the claim that matters: two limiters, standing in for two API Pods, draw on one bucket.

<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/ratelimit/ && go test -race -count=1 ./internal/ratelimit/ -->

**Break it.** In `Guard`, charge the bucket *before* asking the policy (move the `limiter.Allow` call above `next(ctx, a)`) and run the tests:

~~~text
--- FAIL: TestGuardCountsOnlyWhatThePolicyAllows (0.00s)
    ratelimit_test.go:180: denied requests used up the tenant's budget
~~~

Five refused requests emptied acme's bucket, so acme's legitimate requests would now get 429. Put it back.

### 429 over HTTP and gRPC

In `internal/httpapi/handler.go`, a `LimitedError` becomes `429` with `Retry-After` in whole seconds, rounded up (the header takes no fractions):

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	"log/slog"
	"net/http"
~~~

to:

~~~go
	"log/slog"
	"math"
	"net/http"
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	"runway/internal/jobs"
	"runway/internal/tenant"
~~~

to:

~~~go
	"runway/internal/jobs"
	"runway/internal/ratelimit"
	"runway/internal/tenant"
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
// 403 if it says no (Phase 6, step 3).
~~~

to:

~~~go
// 403 if it says no (Phase 6, step 3), or 429 if the answer is "not now"
// (a *ratelimit.LimitedError, step 5).
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
			if err := cfg.authorize(r.Context(), action); err != nil {
~~~

to:

~~~go
			err := cfg.authorize(r.Context(), action)
			if limited, ok := errors.AsType[*ratelimit.LimitedError](err); ok {
				// Over the tenant's rate limit (step 5): 429, and when to
				// come back, in whole seconds, rounded up.
				w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(limited.RetryAfter.Seconds()))))
				writeError(w, http.StatusTooManyRequests, "rate limit exceeded")
				return
			}
			if err != nil {
~~~


In `internal/httpapi/handler_test.go`:

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	"runway/internal/memstore"
	"runway/internal/tenant"
~~~

to:

~~~go
	"runway/internal/memstore"
	"runway/internal/ratelimit"
	"runway/internal/tenant"
~~~

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go

// Clients choose idempotency keys, so two tenants can choose the same one.
~~~

to:

~~~go

// A tenant over its rate limit gets 429 and a Retry-After header in whole
// seconds, rounded up: "0" would invite an immediate retry (step 5).
func TestRateLimitedRequestsGet429(t *testing.T) {
	limited := func(_ context.Context, a authz.Action) error {
		return &ratelimit.LimitedError{Tenant: "acme", RetryAfter: 1200 * time.Millisecond}
	}
	h := newTestHandler(WithAuthorizer(limited))
	got := do(t, h, http.MethodPost, "/jobs", `{"description":"x"}`)
	if got.Code != http.StatusTooManyRequests || got.Header().Get("Retry-After") != "2" {
		t.Fatalf("got %d, Retry-After %q; want 429, 2", got.Code, got.Header().Get("Retry-After"))
	}
}

// Clients choose idempotency keys, so two tenants can choose the same one.
~~~


In `internal/grpcapi/server.go`:

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

~~~

to:

~~~go

	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/durationpb"

~~~

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
	"runway/internal/jobs"
	"runway/internal/tenant"
~~~

to:

~~~go
	"runway/internal/jobs"
	"runway/internal/ratelimit"
	"runway/internal/tenant"
~~~

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
	if err := s.authorize(ctx, action); err != nil {
~~~

to:

~~~go
	err := s.authorize(ctx, action)
	if limited, ok := errors.AsType[*ratelimit.LimitedError](err); ok {
		// Over the tenant's rate limit (step 5). RetryInfo tells a client
		// how long to wait, the way Retry-After does in HTTP.
		st, _ := status.New(codes.ResourceExhausted, "rate limit exceeded").
			WithDetails(&errdetails.RetryInfo{RetryDelay: durationpb.New(limited.RetryAfter)})
		return st.Err()
	}
	if err != nil {
~~~


In `internal/grpcapi/server_test.go`:

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go

	"google.golang.org/grpc"
~~~

to:

~~~go

	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
~~~

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go
	"runway/internal/memstore"
	"runway/internal/tenant"
~~~

to:

~~~go
	"runway/internal/memstore"
	"runway/internal/ratelimit"
	"runway/internal/tenant"
~~~

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go

func TestMethodsAreAuthorized(t *testing.T) {
~~~

to:

~~~go

func TestRateLimitedCallsAreResourceExhausted(t *testing.T) {
	limited := func(context.Context, authz.Action) error {
		return &ratelimit.LimitedError{Tenant: "acme", RetryAfter: 1200 * time.Millisecond}
	}
	server := New(jobs.NewService(memstore.New()), limited)
	_, err := server.CreateJob(context.Background(), &jobsv1.CreateJobRequest{Description: "x"})
	st := status.Convert(err)
	if st.Code() != codes.ResourceExhausted {
		t.Fatalf("CreateJob: %v, want ResourceExhausted", err)
	}
	details := st.Details()
	if len(details) != 1 {
		t.Fatalf("details %v, want one RetryInfo", details)
	}
	info, ok := details[0].(*errdetails.RetryInfo)
	if !ok || info.GetRetryDelay().AsDuration() != 1200*time.Millisecond {
		t.Fatalf("details %v, want RetryInfo of 1.2s", details)
	}
}

func TestMethodsAreAuthorized(t *testing.T) {
~~~


### Wiring it

In `cmd/api/main.go`, the limit is on unless `RATE_LIMIT=off`: 20 jobs a second, 40 at once, per tenant, with exceptions in `RATE_LIMIT_TENANTS`. The Redis client is now shared by the cache and the limiter, so it's made once:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"github.com/prometheus/client_golang/prometheus"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
~~~

to:

~~~go
	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/rabbit"
	"runway/internal/sqsbus"
~~~

to:

~~~go
	"runway/internal/rabbit"
	"runway/internal/ratelimit"
	"runway/internal/sqsbus"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	AuthJWKSURL  string
}
~~~

to:

~~~go
	AuthJWKSURL  string
	// Step 5: how many jobs each tenant may create. Nil with RATE_LIMIT=off.
	RateLimit *ratelimit.Quotas
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	if err := loadAuth(&cfg, getenv); err != nil {
		return config{}, err
	}
	if cfg.AMQPURL != "" && cfg.SQSPrefix != "" {
~~~

to:

~~~go
	if err := loadAuth(&cfg, getenv); err != nil {
		return config{}, err
	}
	limit := getenv("RATE_LIMIT")
	if limit == "" {
		limit = "20:40" // per tenant: 20 jobs a second, 40 at once
	}
	if limit != "off" {
		quotas, err := ratelimit.ParseQuotas(limit, getenv("RATE_LIMIT_TENANTS"))
		if err != nil {
			return config{}, fmt.Errorf("RATE_LIMIT: %w", err)
		}
		cfg.RateLimit = &quotas
	}
	if cfg.AMQPURL != "" && cfg.SQSPrefix != "" {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
// withCache puts a Redis cache in front of repo when REDIS_URL is set
// (one server, or several separated by commas). It returns a function that
// closes the Redis client.
func withCache(ctx context.Context, cfg config, repo jobs.Repository, metrics *httpapi.Metrics) (jobs.Repository, func(), error) {
~~~

to:

~~~go
// connectRedis connects to REDIS_URL (one server, or several separated by
// commas), or returns nil when it isn't set. The cache and, from Phase 6,
// the rate limiter share the client.
func connectRedis(ctx context.Context, cfg config) (redis.UniversalClient, error) {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		return repo, func() {}, nil
~~~

to:

~~~go
		return nil, nil
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	if err != nil {
		return nil, nil, err
	}
~~~

to:

~~~go
	if err != nil {
		return nil, err
	}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		client.Close()
		return nil, nil, err
	}
~~~

to:

~~~go
		client.Close()
		return nil, err
	}
	return client, nil
}

// withCache puts a Redis cache in front of repo when there is a Redis.
func withCache(cfg config, client redis.UniversalClient, repo jobs.Repository, metrics *httpapi.Metrics) jobs.Repository {
	if client == nil {
		return repo
	}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	return cached, func() { client.Close() }, nil
~~~

to:

~~~go
	return cached
}

// rateLimited limits how fast each tenant may create jobs (step 5), behind
// authorize. With Redis, every instance shares one bucket per tenant; when
// Redis fails, each instance limits on its own until it is back.
func rateLimited(authorize authz.Authorizer, quotas ratelimit.Quotas, client redis.UniversalClient, logger *slog.Logger, metrics *httpapi.Metrics) authz.Authorizer {
	// One series per tenant. Fine for tens or hundreds of customers; with
	// many thousands, count them in logs instead.
	rejected := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "rate_limited_total",
		Help: "Requests refused because their tenant was over its rate limit.",
	}, []string{"tenant", "action"})
	failures := prometheus.NewCounter(prometheus.CounterOpts{
		Name: "rate_limiter_errors_total",
		Help: "Rate limiter calls to Redis that failed; each instance limited on its own instead.",
	})
	metrics.MustRegister(rejected, failures)
	var limiter ratelimit.Limiter = ratelimit.NewLocal()
	if client != nil {
		limiter = ratelimit.Fallback{
			Primary: ratelimit.NewRedis(client, "runway:ratelimit:", 50*time.Millisecond),
			Backup:  limiter,
			Failed:  func(error) { failures.Inc() },
		}
	}
	logger.Info("rate limiting job creation", "default", quotas.Default.String(), "tenants", len(quotas.Tenants))
	return ratelimit.Guard(authorize, limiter, quotas, authz.CreateJob, func(_ context.Context, e *ratelimit.LimitedError) {
		// Counted, not logged: a flood of refusals would be a flood of logs.
		rejected.WithLabelValues(string(e.Tenant), string(authz.CreateJob)).Inc()
	})
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	}
	var service *jobs.Service
~~~

to:

~~~go
	}
	redisClient, err := connectRedis(ctx, cfg)
	if err != nil {
		return err
	}
	if redisClient != nil {
		defer redisClient.Close()
	}
	var service *jobs.Service
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		repo, closeCache, err := withCache(ctx, cfg, guarded, metrics)
		if err != nil {
			return err
		}
		defer closeCache()
		service = jobs.NewService(repo)
~~~

to:

~~~go
		service = jobs.NewService(withCache(cfg, redisClient, guarded, metrics))
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		stream = append(stream, auth.StreamInterceptor(verifier, logger))
	}
~~~

to:

~~~go
		stream = append(stream, auth.StreamInterceptor(verifier, logger))
	}
	if cfg.RateLimit != nil {
		authorize = rateLimited(authorize, *cfg.RateLimit, redisClient, logger, metrics)
	}
~~~


Refusals are counted per tenant in `rate_limited_total`, not logged: a flood of refusals would otherwise become a flood of log lines, which is a denial of service on your logging. In `cmd/api/main_test.go`:

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go
	"net/http/httptest"
	"strings"
~~~

to:

~~~go
	"net/http/httptest"
	"slices"
	"strings"
~~~

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go
	"runway/internal/pgstore/pgtest"
)
~~~

to:

~~~go
	"runway/internal/pgstore/pgtest"
	"runway/internal/ratelimit"
)
~~~

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go

func TestRunFailsOnBadConfig(t *testing.T) {
~~~

to:

~~~go

func TestRateLimitConfig(t *testing.T) {
	cfg, err := loadConfig(env(nil))
	if err != nil || cfg.RateLimit == nil || cfg.RateLimit.Default != (ratelimit.Limit{Rate: 20, Burst: 40}) {
		t.Fatalf("default: %+v, %v; want on, 20/s burst 40", cfg.RateLimit, err)
	}
	cfg, err = loadConfig(env(map[string]string{"RATE_LIMIT": "off"}))
	if err != nil || cfg.RateLimit != nil {
		t.Fatalf("RATE_LIMIT=off: %+v, %v", cfg.RateLimit, err)
	}
	for _, bad := range []map[string]string{{"RATE_LIMIT": "fast"}, {"RATE_LIMIT_TENANTS": "acme"}} {
		if _, err := loadConfig(env(bad)); err == nil || !strings.Contains(err.Error(), "RATE_LIMIT") {
			t.Errorf("%v: %v, want a RATE_LIMIT error", bad, err)
		}
	}
}

// With authentication off, everything is tenant "dev", which has a budget
// like any other.
func TestJobCreationIsRateLimited(t *testing.T) {
	base, _, _, _ := startServer(t, map[string]string{"RATE_LIMIT": "0.1:2"})
	codes := []int{}
	var retryAfter string
	for range 3 {
		resp, err := http.Post(base+"/jobs", "application/json", strings.NewReader(`{"description":"x"}`))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		codes = append(codes, resp.StatusCode)
		retryAfter = resp.Header.Get("Retry-After")
	}
	if !slices.Equal(codes, []int{201, 201, 429}) || retryAfter != "10" {
		t.Fatalf("got %v, Retry-After %q; want [201 201 429], 10", codes, retryAfter)
	}
	resp, err := http.Get(base + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if want := `rate_limited_total{action="jobs.create",tenant="dev"} 1`; !strings.Contains(string(body), want) {
		t.Fatalf("metrics lack %s", want)
	}
}

func TestRunFailsOnBadConfig(t *testing.T) {
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/ratelimit/... ./internal/httpapi/... ./internal/grpcapi/... ./cmd/api/... -->

And the chart. In `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
    tokenLifetime: 5m

~~~

to:

~~~yaml
    tokenLifetime: 5m

# How fast each tenant may create jobs (Phase 6, step 5), as RATE:BURST:
# RATE jobs a second, BURST at once. "off" turns limiting off.
rateLimit:
  default: "20:40"
  tenants: {} # a different limit for some tenants, such as { acme: "50:100" }

~~~


In `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        - { name: AUTH_AUDIENCE, value: {{ $root.Values.auth.audience | quote }} }
        - name: GOMEMLIMIT
~~~

to:

~~~yaml
        - { name: AUTH_AUDIENCE, value: {{ $root.Values.auth.audience | quote }} }
        - { name: RATE_LIMIT, value: {{ $root.Values.rateLimit.default | quote }} }
        {{- $tenants := list }}
        {{- range $name, $limit := $root.Values.rateLimit.tenants }}
        {{- $tenants = append $tenants (printf "%s=%s" $name $limit) }}
        {{- end }}
        - { name: RATE_LIMIT_TENANTS, value: {{ join "," $tenants | quote }} }
        - name: GOMEMLIMIT
~~~


<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway --set rateLimit.tenants.acme=50:100 | grep -q 'value: "acme=50:100"' -->

### kload, with a token

kload from the Python Bridge can't send a token, and its jobs all last the same time. Bring it into this phase's practice folder, so its changes live with the code they test:

~~~bash
cp -r ../../python-bridge/practice kload
rm -rf kload/.venv
~~~

<!-- continue: ../python-bridge/TEACHING.md into kload -->

Add `--header`, repeatable, read the way `curl -H` reads it, and `--job-ms` for how long each created job runs. Headers stay out of the settings file kload writes beside its results: one of them holds a token. In `kload/src/kload/cli.py`:

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python
    "create": lambda client: client.post("/jobs", json={"description": "load test"}),
}


~~~

to:

~~~python
    "create": lambda client: client.post("/jobs", json={"description": "load test"}),
}


def create_jobs_lasting(job_ms: int) -> RequestFn:
    """The create target, for jobs that take job_ms to run."""
    body = {"description": "load test", "duration_ms": job_ms}
    return lambda client: client.post("/jobs", json=body)


def parse_header(text: str) -> tuple[str, str]:
    """Read "Name: value", as curl's -H does."""
    name, sep, value = text.partition(":")
    if not sep or not name.strip():
        raise argparse.ArgumentTypeError(f"header {text!r}: want 'Name: value'")
    return name.strip(), value.strip()


~~~

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python
        async with httpx.AsyncClient(base_url=args.url, timeout=10, limits=limits) as client:
~~~

to:

~~~python
        request = TARGETS[args.target]
        if args.target == "create" and args.job_ms:
            request = create_jobs_lasting(args.job_ms)
        headers = dict(args.header)
        async with httpx.AsyncClient(
            base_url=args.url, timeout=10, limits=limits, headers=headers
        ) as client:
~~~

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python
                return await run_closed_loop(client, TARGETS[args.target], count)
~~~

to:

~~~python
                return await run_closed_loop(client, request, count)
~~~

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python
                TARGETS[args.target],
~~~

to:

~~~python
                request,
~~~

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python
    settings = {k: v for k, v in vars(args).items() if k != "handler"}
~~~

to:

~~~python
    # Headers stay out of the settings file: one may hold a token.
    settings = {k: v for k, v in vars(args).items() if k not in ("handler", "header")}
~~~

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python
    p.add_argument("--max-in-flight", type=int, default=200)
    p.add_argument("--out", default="results/run.csv")
~~~

to:

~~~python
    p.add_argument("--max-in-flight", type=int, default=200)
    p.add_argument(
        "--header",
        type=parse_header,
        action="append",
        default=[],
        help="'Name: value' sent with every request; repeat for more",
    )
    p.add_argument(
        "--job-ms", type=int, default=0, help="with --target create: how long each job runs"
    )
    p.add_argument("--out", default="results/run.csv")
~~~


In `kload/tests/test_cli.py`:

Change:

<!-- edit: kload/tests/test_cli.py -->
~~~python
    with pytest.raises(ValueError):
        main(["summarize", str(data)])
~~~

to:

~~~python
    with pytest.raises(ValueError):
        main(["summarize", str(data)])


def test_header_is_read_like_curls():
    from kload.cli import parse_header

    assert parse_header("Authorization: Bearer a:b") == ("Authorization", "Bearer a:b")


@pytest.mark.parametrize("bad", ["no colon", ": empty name"])
def test_bad_header_is_a_usage_error(bad, capsys):
    with pytest.raises(SystemExit) as exc:
        main(["load", "--rate", "1", "--duration", "1", "--header", bad])
    assert exc.value.code == 2
    assert "want 'Name: value'" in capsys.readouterr().err
~~~

<!-- run: cd kload && uv run pytest -q && uv run ruff check && uv run ruff format --check -->

The image shouldn't carry kload. In `.dockerignore`:

Change:

<!-- edit: .dockerignore -->
~~~text
audit
tla
~~~

to:

~~~text
audit
kload
tla
~~~


From now on, run kload as `uv run --project kload kload ...` from the practice folder.

### Run it: the noisy neighbour

First the problem, with limiting off. Acme sends 60 one-second jobs a second; globex sends 2. Both for a minute:

~~~bash
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --set rateLimit.default=off --wait
ACME=$(token acme-ci); GLOBEX=$(token globex-ci)
uv run --project kload kload load --url http://localhost:8080 --target create --job-ms 1000 --rate 60 --duration 60 --header "Authorization: Bearer $ACME" --out results/acme.csv &
uv run --project kload kload load --url http://localhost:8080 --target create --job-ms 1000 --rate 2 --duration 60 --header "Authorization: Bearer $GLOBEX" --out results/globex.csv
wait
~~~

When every job has finished, measure how long each tenant's jobs waited in the queue (finished, minus created, minus the second of work), for jobs created since the run started:

~~~bash
kubectl -n runway exec postgres-0 -- psql -U runway -c "
SELECT tenant, count(*) AS jobs,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY wait)::numeric, 1) AS p50_wait,
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY wait)::numeric, 1) AS p95_wait,
       round(max(wait)::numeric, 1) AS max_wait
FROM (SELECT tenant, extract(epoch FROM updated_at - created_at) - duration_ms / 1000.0 AS wait
      FROM jobs WHERE created_at >= now() - interval '10 minutes' AND state = 'completed') j
GROUP BY tenant ORDER BY tenant"
~~~

~~~text
 tenant | jobs | p50_wait | p95_wait | max_wait 
--------+------+----------+----------+----------
 acme   | 3600 |     42.8 |     72.3 |     75.4
 globex |  120 |     41.6 |     70.8 |     75.2
(2 rows)
~~~

Globex sent two jobs a second, nothing unusual, and its median job waited **41.6 seconds** behind acme's flood. The autoscaler went from 2 workers to its maximum of 8, and it wasn't enough: 60 one-second jobs a second needs 60 workers. More capacity can't fix an unfair share of it.

Now with a limit of 5 jobs a second and 10 at once, the same load:

~~~bash
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --set rateLimit.default=5:10 --wait
# the same two kload runs, then the same query
~~~

~~~text
 tenant | jobs | p50_wait | p95_wait | max_wait 
--------+------+----------+----------+----------
 acme   |  309 |      0.1 |      0.8 |      1.2
 globex |  120 |      0.1 |      0.8 |      1.3
(2 rows)
~~~

Count kload's status codes (`tail -n +2 results/acme.csv | cut -d, -f3 | sort | uniq -c`): acme got 309 `201`s and 3,291 `429`s, and globex all 120 `201`s. Globex's median wait fell from 41.6 seconds to 0.1, and the workers stayed at 2. Acme is refused most of what it asks for, which is the point: its share is now its quota, and the rest of the system is everyone else's.

**But is the bucket shared?** 309 is close to the 310 that one shared bucket allows in 60 seconds (10 at once, then 5 a second). Then look at `rate_limited_total` on each API Pod:

~~~text
pod/api-8b46d64bd-5qcck: rate_limited_total{action="jobs.create",tenant="acme"} 3246
pod/api-8b46d64bd-9jbhj: rate_limited_total{action="jobs.create",tenant="acme"} 16
pod/api-8b46d64bd-hqpmv: rate_limited_total{action="jobs.create",tenant="acme"} 31
~~~

Almost every request went to one Pod. kload keeps its connections open and reuses them, so its traffic was pinned to whichever Pod each connection reached (the gRPC stickiness of Phase 5, step 4, in HTTP form). So 309 doesn't prove sharing: three *separate* buckets would have looked almost the same. Test it with a new connection per request, so they spread across Pods:

~~~bash
for i in $(seq 16); do curl -s -o /dev/null -w "%{http_code} %header{x-served-by}\n" -X POST localhost:8080/jobs -H "Authorization: Bearer $GLOBEX" -H 'Content-Type: application/json' -d '{"description":"x"}'; done | sort | uniq -c
kubectl -n runway exec redis-0 -- sh -c 'printf "HGETALL runway:ratelimit:jobs.create:globex\nPTTL runway:ratelimit:jobs.create:globex\n" | redis-cli'
~~~

~~~text
      4 201 api-8b46d64bd-5qcck
      6 201 api-8b46d64bd-9jbhj
      2 201 api-8b46d64bd-hqpmv
      3 429 api-8b46d64bd-5qcck
      1 429 api-8b46d64bd-9jbhj
tokens
0.5300649999999987
at
1791554092773499
2112
~~~

Twelve `201`s spread over all three Pods, then `429` from two of them. Three separate buckets would have allowed 10 each, so all 16 would have been created. One bucket allowed its 10, plus the two tokens that refilled during the loop. In Redis, the bucket holds half a token and expires in about two seconds: once it would be full again, it's gone. (The key lives on one of the three Redis servers, whichever the ring picks; try each. And read both values in one `redis-cli` call: a bucket that lasts three seconds can expire between two `kubectl exec`s.)

Set the default back (`--set rateLimit.default=20:40`) when you're done.

**Explain it:** why does a token bucket need no timer? Why does the Redis version take its time from Redis? Why is the limiter a wrapper around the authorizer rather than a separate middleware, and why does it charge only allowed requests? Why didn't more workers fix the noisy neighbour? Why didn't 309 successes prove the bucket was shared, and what did?

**Read.** The Stripe engineering blog, *Scaling your API with rate limiters* (2017): four kinds of limiter, and why they shed load in a particular order. Then the [IETF draft on RateLimit header fields](https://datatracker.ietf.org/doc/draft-ietf-httpapi-ratelimit-headers/): what would Runway send? Then Amazon's Builders' Library, *Fairness in multi-tenant systems*: what is a rate limit *not* enough for, and what does shuffle sharding add?

---
## Step 6: Signed webhooks

**The problem.** Tenants want to know when their jobs finish without polling. So Runway will call *them*: a **webhook**, an HTTP request to a URL the tenant registers. That turns T5, replay, around. Now Runway is the client, and the tenant's server has to decide whether a request claiming to be from Runway really is. Anyone who learns the URL can post to it. And the URL is the tenant's choice, which means Runway will make requests, from inside its cluster, to addresses someone outside chose.

This step started as "jti revocation" (refusing a stolen token before it expires), from step 1's plan. I left that as a trade-off to discuss rather than build: it puts a lookup on every request to save at most a few minutes of a five-minute token, and **sender-constrained tokens** (bound to the client's TLS certificate, step 7) solve it better. Webhooks needed the same ideas, replay windows and nonces, and were missing entirely.

**New ideas.**

- **HMAC** (a keyed hash) proves a message came from someone holding a shared secret, and wasn't changed. It's symmetric: the receiver can also make valid signatures, which is fine here, since only Runway and that one tenant hold the secret.
- **What to sign.** The body (integrity), a **message ID** that stays the same across retries (so the receiver can drop duplicates), and a **timestamp** (so an old request replayed later can be refused). Signing only the body would let a captured request be replayed forever.
- **The replay window.** The receiver refuses timestamps more than a few minutes from its own clock, and remembers the IDs it has handled for that long. Old enough requests are refused without remembering anything.
- **Secret rotation, without a gap.** For a while, every request carries two signatures, one per secret, and the receiver accepts either. The tenant switches its receiver to the new secret whenever it's ready.
- **Standard Webhooks** is a published format for all of this, used by several providers, so tenants can verify with an existing library rather than your documentation.
- **SSRF**, server-side request forgery. If a tenant registers `http://redis-0.redis:6379/` or `http://169.254.169.254/` (the cloud metadata service, which hands out credentials), Runway makes that request *for* them, from a place they can't reach. The defence has to be made on the address actually dialled, after DNS. A name that resolved to a public address at registration can resolve to a private one later: **DNS rebinding**.
- **Isolate what talks to the outside.** Sending webhooks is the only thing in Runway that connects to addresses tenants choose. Put it in its own process, the **notifier**, so step 12 can give that process a route to the internet and nothing else.

### Signing and verifying

Create `internal/webhook/sign.go`:

<!-- file: internal/webhook/sign.go -->
~~~go
// Package webhook sends and checks signed webhooks: HTTP requests Runway
// makes to a tenant's own server when one of its jobs finishes.
//
// The receiver can't tell who sent a request just by looking at it: anyone
// who learns the URL can post to it. So every webhook is signed with a
// secret that only Runway and the tenant know, and the signature covers
// three things:
//
//   - the body, so a changed body fails (integrity);
//   - an ID, which stays the same when a delivery is retried, so the
//     receiver can drop duplicates;
//   - the time it was sent, so the receiver can refuse an old request
//     replayed later, and needs to remember IDs only for a short window.
//
// The format is Standard Webhooks (https://www.standardwebhooks.com), used
// by several providers, so receivers can use an existing library.
package webhook

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Headers carrying the ID, the time and the signatures.
const (
	HeaderID        = "webhook-id"
	HeaderTimestamp = "webhook-timestamp"
	HeaderSignature = "webhook-signature"
)

// Tolerance is how far a webhook's timestamp may be from the receiver's
// clock. Older requests are refused, so a captured request can be replayed
// only within this window, where the receiver still remembers its ID.
const Tolerance = 5 * time.Minute

// Secret is a signing key shared with one tenant.
type Secret []byte

const secretPrefix = "whsec_"

// NewSecret returns a random 32-byte secret.
func NewSecret() Secret {
	s := make(Secret, 32)
	rand.Read(s)
	return s
}

// String is the form a tenant is given and configures: "whsec_" and the
// bytes in base64.
func (s Secret) String() string {
	return secretPrefix + base64.StdEncoding.EncodeToString(s)
}

// ParseSecret reads a secret in the form String writes.
func ParseSecret(text string) (Secret, error) {
	b, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(text, secretPrefix))
	if err != nil || len(b) < 24 {
		return nil, errors.New("webhook secret: want whsec_ and at least 24 bytes of base64")
	}
	return b, nil
}

// signature is base64(HMAC-SHA256(secret, id.timestamp.body)).
func signature(secret Secret, id string, ts int64, body []byte) string {
	mac := hmac.New(sha256.New, secret)
	fmt.Fprintf(mac, "%s.%d.", id, ts)
	mac.Write(body)
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

// Sign sets the webhook headers on h for body, with one signature for each
// secret. While a secret is being replaced there are two: the receiver
// accepts the request if either matches, so it can switch to the new
// secret whenever it is ready.
func Sign(h http.Header, id string, at time.Time, body []byte, secrets ...Secret) {
	ts := at.Unix()
	sigs := make([]string, len(secrets))
	for i, s := range secrets {
		sigs[i] = "v1," + signature(s, id, ts, body)
	}
	h.Set(HeaderID, id)
	h.Set(HeaderTimestamp, strconv.FormatInt(ts, 10))
	h.Set(HeaderSignature, strings.Join(sigs, " "))
}

// Why a webhook was refused.
var (
	ErrMissing   = errors.New("webhook headers missing")
	ErrTimestamp = errors.New("webhook timestamp outside the tolerance")
	ErrSignature = errors.New("no webhook signature matches")
)

// Verify checks the headers in h against body, at time now, with any of
// secrets. It checks the timestamp first, so an old request is refused
// without any cryptography.
func Verify(h http.Header, body []byte, now time.Time, secrets ...Secret) error {
	id, tsText, sigs := h.Get(HeaderID), h.Get(HeaderTimestamp), h.Get(HeaderSignature)
	if id == "" || tsText == "" || sigs == "" {
		return ErrMissing
	}
	ts, err := strconv.ParseInt(tsText, 10, 64)
	if err != nil {
		return ErrMissing
	}
	if d := now.Sub(time.Unix(ts, 0)); d > Tolerance || d < -Tolerance {
		return ErrTimestamp
	}
	for _, s := range secrets {
		want := []byte(signature(s, id, ts, body))
		for sig := range strings.FieldsSeq(sigs) {
			version, got, ok := strings.Cut(sig, ",")
			// hmac.Equal takes the same time however many bytes match, so
			// timing the answer reveals nothing about the right signature.
			if ok && version == "v1" && hmac.Equal([]byte(got), want) {
				return nil
			}
		}
	}
	return ErrSignature
}
~~~

The signed text is `id.timestamp.body`, as Standard Webhooks specifies. `Verify` checks the timestamp before any cryptography, and compares signatures with `hmac.Equal`, which takes the same time however many bytes match.

The receiver's side. Runway doesn't need it, but a tenant does, and so does the demo receiver below. Create `internal/webhook/receiver.go`:

<!-- file: internal/webhook/receiver.go -->
~~~go
package webhook

import (
	"bytes"
	"io"
	"net/http"
	"sync"
	"time"
)

// Receiver is the tenant's side, as an http.Handler: it checks each
// webhook, drops duplicates, and passes the rest to Next with the body
// still readable. Runway doesn't need it; it shows what a receiver must do,
// and the demo receiver (cmd/hookcatcher) uses it.
type Receiver struct {
	Secrets []Secret
	Next    http.Handler
	Now     func() time.Time

	mu   sync.Mutex
	seen map[string]time.Time // webhook ID → when it can be forgotten
}

// maxBody bounds what a receiver reads, before it knows who sent it.
const maxBody = 64 << 10

func (r *Receiver) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	now := time.Now()
	if r.Now != nil {
		now = r.Now()
	}
	body, err := io.ReadAll(io.LimitReader(req.Body, maxBody))
	if err != nil {
		http.Error(w, "unreadable body", http.StatusBadRequest)
		return
	}
	if err := Verify(req.Header, body, now, r.Secrets...); err != nil {
		http.Error(w, err.Error(), http.StatusUnauthorized)
		return
	}
	id := req.Header.Get(HeaderID)
	if r.handled(id, now) {
		// Already handled. Answer 200 all the same: the sender must stop
		// retrying, and a retry is exactly how a duplicate arrives.
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, "duplicate\n")
		return
	}
	req.Body = io.NopCloser(bytes.NewReader(body))
	sw := &statusWriter{ResponseWriter: w, code: http.StatusOK}
	r.Next.ServeHTTP(sw, req)
	// Remember the ID only once the work succeeded, or the sender's retry
	// of a failed one would be dropped as a duplicate. (Two copies arriving
	// at the same moment can both get through here; a real receiver records
	// the ID in the same database transaction as the work.)
	if sw.code < 300 {
		r.remember(id, now)
	}
}

// handled reports whether id was handled already. An ID need only be
// remembered for twice the tolerance: after that its timestamp is refused
// anyway, so the map can't grow without bound.
func (r *Receiver) handled(id string, now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for k, until := range r.seen {
		if now.After(until) {
			delete(r.seen, k)
		}
	}
	_, ok := r.seen[id]
	return ok
}

func (r *Receiver) remember(id string, now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.seen == nil {
		r.seen = map[string]time.Time{}
	}
	r.seen[id] = now.Add(2 * Tolerance)
}

type statusWriter struct {
	http.ResponseWriter
	code int
}

func (s *statusWriter) WriteHeader(code int) {
	s.code = code
	s.ResponseWriter.WriteHeader(code)
}
~~~

Two details took thought. A duplicate gets `200`, not an error: duplicates arrive because the sender retried, and the sender must stop. And an ID is remembered only once the work *succeeded*. Remember it on arrival, and the sender's retry of a request that failed would be dropped as a duplicate, losing the event.

### Where webhooks may go

Create `internal/webhook/guard.go`:

<!-- file: internal/webhook/guard.go -->
~~~go
package webhook

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"slices"
	"strings"
	"syscall"
	"time"
)

// A tenant chooses its webhook URL, and Runway then sends a request there
// from inside the cluster. Unchecked, that is server-side request forgery
// (SSRF): a tenant could point its webhook at http://redis-0.redis:6379,
// at metad, or at a cloud metadata service (169.254.169.254, which hands
// out credentials), and Runway would make the request for it, from a place
// the tenant can't reach.
//
// So webhooks may only go to public addresses. The check that matters is
// made when connecting, on the address actually dialled. Checking the name
// when the URL is registered is not enough: DNS can answer with a public
// address then and a private one later ("DNS rebinding").

// ErrBlocked means a webhook URL leads somewhere Runway won't send to.
var ErrBlocked = errors.New("webhook address not allowed")

// blocked are ranges that aren't the public internet.
var blocked = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),      // "this network"
	netip.MustParsePrefix("100.64.0.0/10"),  // carrier-grade NAT
	netip.MustParsePrefix("192.0.0.0/24"),   // IETF protocol assignments
	netip.MustParsePrefix("198.18.0.0/15"),  // benchmarking
	netip.MustParsePrefix("240.0.0.0/4"),    // reserved, and broadcast
	netip.MustParsePrefix("64:ff9b::/96"),   // NAT64: an IPv4 address in disguise
	netip.MustParsePrefix("64:ff9b:1::/48"), // local NAT64
	netip.MustParsePrefix("2001:db8::/32"),  // documentation
	netip.MustParsePrefix("fec0::/10"),      // old site-local
}

// Public reports whether addr is a public unicast address.
func Public(addr netip.Addr) bool {
	addr = addr.Unmap() // ::ffff:10.0.0.1 is 10.0.0.1
	if !addr.IsValid() || addr.IsLoopback() || addr.IsPrivate() || addr.IsLinkLocalUnicast() ||
		addr.IsLinkLocalMulticast() || addr.IsInterfaceLocalMulticast() || addr.IsMulticast() ||
		addr.IsUnspecified() {
		return false
	}
	return !slices.ContainsFunc(blocked, func(p netip.Prefix) bool { return p.Contains(addr) })
}

// Policy says where webhooks may go.
type Policy struct {
	// AllowHosts are host names exempt from the checks: a receiver inside
	// the cluster for the demo, or a test server. Leave it empty in
	// production.
	AllowHosts []string
}

func (p Policy) allowed(host string) bool {
	return slices.Contains(p.AllowHosts, strings.ToLower(host))
}

// CheckURL is the check at registration, to give a tenant a clear answer
// at once: HTTPS only, no credentials in the URL, and a host that resolves
// only to public addresses. It is a courtesy; Client's check is the guard.
func (p Policy) CheckURL(ctx context.Context, raw string, resolver *net.Resolver) error {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.Opaque != "" {
		return fmt.Errorf("webhook URL %q: not an absolute URL", raw)
	}
	if u.User != nil {
		return fmt.Errorf("webhook URL: no user names or passwords in it")
	}
	host := u.Hostname()
	if p.allowed(host) {
		if u.Scheme != "https" && u.Scheme != "http" {
			return fmt.Errorf("webhook URL: scheme must be https or http")
		}
		return nil
	}
	if u.Scheme != "https" {
		return fmt.Errorf("webhook URL: must use https")
	}
	addrs, err := resolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return fmt.Errorf("webhook URL: can't resolve %s: %w", host, err)
	}
	for _, a := range addrs {
		if !Public(a) {
			return fmt.Errorf("%w: %s resolves to %s", ErrBlocked, host, a.Unmap())
		}
	}
	return nil
}

// Client returns the HTTP client for sending webhooks. It refuses to
// connect to any address that isn't public (unless the host is allowed),
// doesn't follow redirects (a public server could redirect to a private
// one), and gives up after timeout.
func (p Policy) Client(timeout time.Duration) *http.Client {
	guarded := &net.Dialer{
		Timeout: timeout,
		// Control runs after DNS, on the very address about to be dialled.
		Control: func(network, address string, _ syscall.RawConn) error {
			ap, err := netip.ParseAddrPort(address)
			if err != nil || !Public(ap.Addr()) {
				return fmt.Errorf("%w: %s", ErrBlocked, address)
			}
			return nil
		},
	}
	plain := &net.Dialer{Timeout: timeout}
	transport := &http.Transport{
		Proxy: nil, // a proxy from the environment would dial for us, unchecked
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			host, _, _ := net.SplitHostPort(address)
			if p.allowed(host) {
				return plain.DialContext(ctx, network, address)
			}
			return guarded.DialContext(ctx, network, address)
		},
		TLSHandshakeTimeout:   timeout,
		ResponseHeaderTimeout: timeout,
		MaxIdleConnsPerHost:   2,
	}
	return &http.Client{
		Transport: transport,
		Timeout:   timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse // a 3xx is an answer, not an instruction
		},
	}
}
~~~

There are two checks, and only one of them is the guard. `CheckURL`, at registration, gives the tenant a clear answer at once. `Client` is what actually protects: its dialer's `Control` function runs *after* DNS, on the exact address about to be dialled, so a rebinding answer is caught too. It also ignores proxy settings from the environment, which would dial for it unchecked, and it doesn't follow redirects, since a public server could redirect to a private one. Look at `Public`: `Unmap` turns `::ffff:10.0.0.1`, an IPv4 address written as IPv6, back into `10.0.0.1` before checking it. Without that, the IPv6 spelling of a private address would pass.

### Sending, and the tenant's endpoint

Create `internal/webhook/sender.go`:

<!-- file: internal/webhook/sender.go -->
~~~go
package webhook

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Endpoint is where one tenant's webhooks go, and the secrets to sign them
// with: the current one, and while it is being replaced, the previous one.
type Endpoint struct {
	URL     string
	Secrets []Secret
}

// ErrNoEndpoint means the tenant has no webhook: nothing to send.
var ErrNoEndpoint = errors.New("no webhook endpoint")

// Event is a webhook's body.
type Event struct {
	Type      string    `json:"type"` // "job.completed" or "job.failed"
	Timestamp time.Time `json:"timestamp"`
	Data      any       `json:"data"`
}

// StatusError is a receiver's answer other than 2xx.
type StatusError struct{ Code int }

func (e *StatusError) Error() string { return fmt.Sprintf("webhook receiver answered %d", e.Code) }

// Sender delivers webhooks.
type Sender struct {
	Client *http.Client // from Policy.Client
	Now    func() time.Time
}

// Send posts event to ep, signed, with id. A retry of the same delivery
// must use the same id, so the receiver can tell it's a duplicate. The
// timestamp is new on every try: it says when this request was sent.
func (s Sender) Send(ctx context.Context, ep Endpoint, id string, event Event) error {
	body, err := json.Marshal(event)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ep.URL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "Runway-Webhooks/1")
	now := time.Now
	if s.Now != nil {
		now = s.Now
	}
	Sign(req.Header, id, now(), body, ep.Secrets...)
	resp, err := s.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	// Read a little of the answer, so the connection can be reused, and no
	// more: the receiver isn't trusted to send a sensible amount.
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4<<10))
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return &StatusError{Code: resp.StatusCode}
	}
	return nil
}
~~~

Create `internal/webhook/registry.go`:

<!-- file: internal/webhook/registry.go -->
~~~go
package webhook

import (
	"context"
	"errors"
	"net"
	"time"
)

// Store keeps each tenant's endpoint. Every method acts for the tenant in
// ctx, and only for it.
type Store interface {
	// Put sets the URL. The first time, it also stores secret and reports
	// created; after that, the secret stays as it is.
	Put(ctx context.Context, url string, secret Secret, now time.Time) (created bool, err error)
	// Rotate makes secret the current one, and keeps the old one signing
	// until previousUntil. ErrNoEndpoint if there is none.
	Rotate(ctx context.Context, secret Secret, now, previousUntil time.Time) error
	Delete(ctx context.Context) error
	// Endpoint returns the URL and the secrets that sign at now.
	Endpoint(ctx context.Context, now time.Time) (Endpoint, error)
}

// ErrInvalidURL wraps the reason a URL was refused.
var ErrInvalidURL = errors.New("invalid webhook URL")

// Registry is what tenants manage their webhook through.
type Registry struct {
	Store    Store
	Policy   Policy
	Resolver *net.Resolver    // nil: the system's
	Overlap  time.Duration    // how long a replaced secret keeps signing
	Now      func() time.Time // nil: time.Now
}

func (r Registry) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

// Set points the tenant's webhook at url. It returns the signing secret
// when it made one, the first time: this is the only time it is shown.
func (r Registry) Set(ctx context.Context, url string) (Secret, error) {
	resolver := r.Resolver
	if resolver == nil {
		resolver = net.DefaultResolver
	}
	if err := r.Policy.CheckURL(ctx, url, resolver); err != nil {
		return nil, errors.Join(ErrInvalidURL, err)
	}
	secret := NewSecret()
	created, err := r.Store.Put(ctx, url, secret, r.now())
	if err != nil || !created {
		return nil, err
	}
	return secret, nil
}

// Rotate replaces the secret, and returns the new one. The old one keeps
// signing for Overlap, so the tenant can update its receiver without
// missing a webhook.
func (r Registry) Rotate(ctx context.Context) (Secret, error) {
	secret := NewSecret()
	now := r.now()
	if err := r.Store.Rotate(ctx, secret, now, now.Add(r.Overlap)); err != nil {
		return nil, err
	}
	return secret, nil
}

func (r Registry) Delete(ctx context.Context) error { return r.Store.Delete(ctx) }
~~~

The secret is returned once, when it's made. After that, nobody can see it through the API, so it can't leak from there.

Test all of it. Create `internal/webhook/webhook_test.go`:

<!-- file: internal/webhook/webhook_test.go -->
~~~go
package webhook

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strings"
	"testing"
	"time"
)

var t0 = time.Unix(1_791_550_000, 0)

func signed(body string, at time.Time, secrets ...Secret) http.Header {
	h := http.Header{}
	Sign(h, "msg_1", at, []byte(body), secrets...)
	return h
}

func TestSecretRoundTrips(t *testing.T) {
	s := NewSecret()
	if !strings.HasPrefix(s.String(), "whsec_") {
		t.Fatalf("secret %q lacks whsec_", s)
	}
	back, err := ParseSecret(s.String())
	if err != nil || string(back) != string(s) {
		t.Fatalf("ParseSecret = %v, %v", back, err)
	}
	if _, err := ParseSecret("whsec_c2hvcnQ="); err == nil {
		t.Fatal("a 5-byte secret was accepted")
	}
}

// The signature is the Standard Webhooks one. This vector was computed with
// Python's hmac module, so a receiver using any library agrees with us.
func TestSignatureMatchesTheStandard(t *testing.T) {
	secret, _ := ParseSecret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
	h := http.Header{}
	Sign(h, "msg_p5jXN8AQM9LWM0D4loKWxJek", time.Unix(1614265330, 0), []byte(`{"test": 2432232314}`), secret)
	if got, want := h.Get(HeaderSignature), "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="; got != want {
		t.Fatalf("signature %s, want %s", got, want)
	}
}

func TestVerify(t *testing.T) {
	secret, other := NewSecret(), NewSecret()
	body := `{"type":"job.completed"}`
	for _, tc := range []struct {
		name string
		h    http.Header
		body string
		want error
	}{
		{"good", signed(body, t0, secret), body, nil},
		{"a changed body", signed(body, t0, secret), `{"type":"job.failed"}`, ErrSignature},
		{"another secret", signed(body, t0, other), body, ErrSignature},
		{"too old: a replay", signed(body, t0.Add(-Tolerance-time.Second), secret), body, ErrTimestamp},
		{"from the future", signed(body, t0.Add(Tolerance+time.Second), secret), body, ErrTimestamp},
		{"no headers", http.Header{}, body, ErrMissing},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := Verify(tc.h, []byte(tc.body), t0, secret); !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
		})
	}
}

// A changed timestamp is a changed signature: an attacker can't make an old
// request look new.
func TestTheTimestampIsSigned(t *testing.T) {
	secret := NewSecret()
	h := signed("{}", t0.Add(-time.Hour), secret)
	h.Set(HeaderTimestamp, "1791550000") // t0: within the tolerance
	if err := Verify(h, []byte("{}"), t0, secret); !errors.Is(err, ErrSignature) {
		t.Fatalf("got %v, want ErrSignature", err)
	}
}

// During a rotation each request carries two signatures, so a receiver with
// either secret accepts it.
func TestRotationSignsWithBoth(t *testing.T) {
	old, current := NewSecret(), NewSecret()
	h := signed("{}", t0, current, old)
	if n := len(strings.Fields(h.Get(HeaderSignature))); n != 2 {
		t.Fatalf("%d signatures, want 2", n)
	}
	for name, s := range map[string]Secret{"old": old, "current": current} {
		if err := Verify(h, []byte("{}"), t0, s); err != nil {
			t.Errorf("receiver with the %s secret: %v", name, err)
		}
	}
}

func post(r http.Handler, h http.Header, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/hooks", strings.NewReader(body))
	for k, v := range h {
		req.Header[k] = v
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func TestReceiverDropsDuplicatesButNotRetriesOfFailures(t *testing.T) {
	secret := NewSecret()
	handled, fail := 0, true
	r := &Receiver{Secrets: []Secret{secret}, Now: func() time.Time { return t0 }, Next: http.HandlerFunc(
		func(w http.ResponseWriter, req *http.Request) {
			body, _ := io.ReadAll(req.Body)
			if string(body) != "{}" {
				t.Errorf("Next got body %q", body)
			}
			if fail {
				fail = false
				http.Error(w, "busy", http.StatusServiceUnavailable)
				return
			}
			handled++
		})}
	h := signed("{}", t0, secret)
	codes := []int{post(r, h, "{}").Code, post(r, h, "{}").Code, post(r, h, "{}").Code}
	if codes[0] != 503 || codes[1] != 200 || codes[2] != 200 || handled != 1 {
		t.Fatalf("codes %v, handled %d; want [503 200 200], once", codes, handled)
	}
	if got := post(r, h, "{}").Body.String(); got != "duplicate\n" {
		t.Fatalf("a duplicate got %q", got)
	}
	if got := post(r, signed("{}", t0, NewSecret()), "{}").Code; got != http.StatusUnauthorized {
		t.Fatalf("a forged webhook got %d, want 401", got)
	}
}

func TestPublic(t *testing.T) {
	for addr, want := range map[string]bool{
		"93.184.215.14":        true,
		"2606:4700::6810:84e5": true,
		"127.0.0.1":            false,
		"10.96.0.10":           false, // a Kubernetes Service
		"10.244.1.7":           false, // a Pod
		"172.18.0.2":           false, // a kind node
		"192.168.1.1":          false,
		"169.254.169.254":      false, // cloud metadata
		"100.100.100.200":      false, // carrier-grade NAT (and Alibaba's metadata)
		"0.0.0.0":              false,
		"::1":                  false,
		"::ffff:127.0.0.1":     false, // IPv4 in IPv6 clothing
		"fd00:ec2::254":        false, // AWS metadata over IPv6
		"64:ff9b::a00:1":       false, // NAT64 for 10.0.0.1
		"fe80::1":              false,
		"224.0.0.1":            false,
	} {
		if got := Public(netip.MustParseAddr(addr)); got != want {
			t.Errorf("Public(%s) = %v, want %v", addr, got, want)
		}
	}
}

func TestCheckURL(t *testing.T) {
	p := Policy{AllowHosts: []string{"hookcatcher.partner"}}
	ctx := context.Background()
	for raw, ok := range map[string]bool{
		"http://hookcatcher.partner:8080/hooks":    true, // allowed host: http is fine
		"https://127.0.0.1/hooks":                  false,
		"https://169.254.169.254/latest/meta-data": false,
		"https://[::1]/hooks":                      false,
		"http://93.184.215.14/hooks":               false, // http
		"https://user:pw@93.184.215.14/hooks":      false,
		"ftp://hookcatcher.partner/":               false,
		"/hooks":                                   false,
		"https://93.184.215.14/hooks":              true,
	} {
		err := p.CheckURL(ctx, raw, net.DefaultResolver)
		if (err == nil) != ok {
			t.Errorf("CheckURL(%s) = %v, want ok=%v", raw, err, ok)
		}
	}
}

// The guard that matters: at connect time, on the address dialled. A name
// that resolves to a private address is refused, whatever it resolved to
// when the URL was registered.
func TestClientRefusesPrivateAddresses(t *testing.T) {
	hits := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits++ }))
	defer server.Close()
	u, _ := url.Parse(server.URL)
	_, port, _ := net.SplitHostPort(u.Host)

	for _, target := range []string{server.URL, "http://localhost:" + port} {
		_, err := Policy{}.Client(time.Second).Post(target, "application/json", nil)
		if !errors.Is(err, ErrBlocked) {
			t.Errorf("POST %s: %v, want ErrBlocked", target, err)
		}
	}
	if hits != 0 {
		t.Fatalf("the server was reached %d times", hits)
	}
	// An allowed host is let through.
	resp, err := Policy{AllowHosts: []string{"127.0.0.1"}}.Client(time.Second).Post(server.URL, "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
}

// A redirect is not followed: a public server could send us anywhere.
func TestClientDoesNotFollowRedirects(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://169.254.169.254/latest/meta-data/", http.StatusTemporaryRedirect)
	}))
	defer server.Close()
	resp, err := Policy{AllowHosts: []string{"127.0.0.1"}}.Client(time.Second).Post(server.URL, "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusTemporaryRedirect {
		t.Fatalf("status %d, want the 307 itself", resp.StatusCode)
	}
}

func TestSenderSignsWithTheMessageID(t *testing.T) {
	secret := NewSecret()
	var got error
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		got = Verify(r.Header, body, time.Now(), secret)
		if r.Header.Get(HeaderID) != "msg_42" {
			got = errors.New("wrong id " + r.Header.Get(HeaderID))
		}
	}))
	defer server.Close()
	s := Sender{Client: Policy{AllowHosts: []string{"127.0.0.1"}}.Client(time.Second)}
	ep := Endpoint{URL: server.URL, Secrets: []Secret{secret}}
	if err := s.Send(context.Background(), ep, "msg_42", Event{Type: "job.completed", Timestamp: t0}); err != nil || got != nil {
		t.Fatalf("send: %v; receiver: %v", err, got)
	}
}

func TestSenderReportsNon2xx(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()
	s := Sender{Client: Policy{AllowHosts: []string{"127.0.0.1"}}.Client(time.Second)}
	err := s.Send(context.Background(), Endpoint{URL: server.URL, Secrets: []Secret{NewSecret()}}, "m", Event{})
	if e, ok := errors.AsType[*StatusError](err); !ok || e.Code != 500 {
		t.Fatalf("got %v, want StatusError 500", err)
	}
}
~~~

`TestSignatureMatchesTheStandard` checks one signature against a value worked out independently (I computed it with Python's `hmac` module), so a mistake in the signed text can't hide behind a test that uses the same code to sign and verify. `TestClientRefusesPrivateAddresses` points the client at a real server on `127.0.0.1` and checks the dialler refuses it.

<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/webhook/ && go test -race -count=1 ./internal/webhook/ -->

**Break it.** In `signature`, leave the timestamp out of the signed text (change the format to `"%s.", id`):

~~~text
--- FAIL: TestSignatureMatchesTheStandard (0.00s)
    webhook_test.go:46: signature v1,KhBcAeOVVEEQGArWJukdc6o7/kiWajoqZ/6+e/MYDV8=, want v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=
--- FAIL: TestTheTimestampIsSigned (0.00s)
    webhook_test.go:81: got <nil>, want ErrSignature
~~~

Now anyone can put a fresh timestamp on a captured request, and the replay window means nothing. Put it back.

### Storing endpoints

Create `internal/pgstore/migrations/0008_webhooks.sql`:

<!-- file: internal/pgstore/migrations/0008_webhooks.sql -->
~~~sql
-- Phase 6, step 6: where each tenant's webhooks go, and the secret that
-- signs them. One webhook per tenant.

-- +goose Up
CREATE TABLE webhooks (
    tenant          TEXT        PRIMARY KEY,
    url             TEXT        NOT NULL,
    -- The secret signs, so it must be readable, not hashed like a password.
    -- Step 9 encrypts it with a key kept outside the database.
    secret          TEXT        NOT NULL,
    -- After a rotation the old secret signs too, until previous_until, so
    -- the tenant has time to switch its receiver to the new one.
    previous_secret TEXT,
    previous_until  TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL
);
GRANT SELECT, INSERT, UPDATE, DELETE ON webhooks TO runway_tenant;
ALTER TABLE webhooks ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON webhooks
    USING (tenant = current_tenant())
    WITH CHECK (tenant = current_tenant());

-- +goose Down
DROP TABLE webhooks;
~~~

The secret is stored readable, not hashed like a password, because Runway must sign with it. That makes this column a target. Step 9 encrypts it with a key the database never sees.

Create `internal/pgstore/webhooks.go`:

<!-- file: internal/pgstore/webhooks.go -->
~~~go
package pgstore

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"runway/internal/tenant"
	"runway/internal/webhook"
)

// Webhooks keeps each tenant's webhook endpoint (Phase 6), under the same
// row-level security as its jobs.
type Webhooks struct{ s *Store }

// Webhooks returns the webhook store that shares s's pool.
func (s *Store) Webhooks() Webhooks { return Webhooks{s} }

var _ webhook.Store = Webhooks{}

func (w Webhooks) Put(ctx context.Context, url string, secret webhook.Secret, now time.Time) (bool, error) {
	var created bool
	err := w.s.inTenant(ctx, func(owner tenant.ID, tx pgx.Tx) error {
		// xmax is 0 on a row this statement inserted, and not on one it
		// updated: PostgreSQL's way of saying which one happened.
		return tx.QueryRow(ctx, `
			INSERT INTO webhooks (tenant, url, secret, updated_at) VALUES ($1, $2, $3, $4)
			ON CONFLICT (tenant) DO UPDATE SET url = EXCLUDED.url, updated_at = EXCLUDED.updated_at
			RETURNING xmax = 0`,
			owner, url, secret.String(), now).Scan(&created)
	})
	return created, err
}

func (w Webhooks) Rotate(ctx context.Context, secret webhook.Secret, now, previousUntil time.Time) error {
	return w.s.inTenant(ctx, func(_ tenant.ID, tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE webhooks SET previous_secret = secret, previous_until = $2, secret = $1, updated_at = $3`,
			secret.String(), previousUntil, now)
		if err == nil && tag.RowsAffected() == 0 {
			err = webhook.ErrNoEndpoint
		}
		return err
	})
}

func (w Webhooks) Delete(ctx context.Context) error {
	return w.s.inTenant(ctx, func(_ tenant.ID, tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM webhooks`) // row-level security: only ours
		if err == nil && tag.RowsAffected() == 0 {
			err = webhook.ErrNoEndpoint
		}
		return err
	})
}

func (w Webhooks) Endpoint(ctx context.Context, now time.Time) (webhook.Endpoint, error) {
	var ep webhook.Endpoint
	err := w.s.inTenant(ctx, func(_ tenant.ID, tx pgx.Tx) error {
		var current string
		var previous *string
		var until *time.Time
		err := tx.QueryRow(ctx, `SELECT url, secret, previous_secret, previous_until FROM webhooks`).
			Scan(&ep.URL, &current, &previous, &until)
		if errors.Is(err, pgx.ErrNoRows) {
			return webhook.ErrNoEndpoint
		}
		if err != nil {
			return err
		}
		texts := []string{current}
		if previous != nil && until != nil && now.Before(*until) {
			texts = append(texts, *previous)
		}
		for _, t := range texts {
			s, err := webhook.ParseSecret(t)
			if err != nil {
				return err
			}
			ep.Secrets = append(ep.Secrets, s)
		}
		return nil
	})
	return ep, err
}
~~~

Create `internal/pgstore/webhooks_test.go`:

<!-- file: internal/pgstore/webhooks_test.go -->
~~~go
package pgstore

import (
	"context"
	"errors"
	"testing"
	"time"

	"runway/internal/pgstore/pgtest"
	"runway/internal/tenant"
	"runway/internal/webhook"
)

func TestWebhooks(t *testing.T) {
	hooks := New(pgtest.Pool(t, Migrate)).Webhooks()
	globex := tenant.With(context.Background(), "globex")
	first, second := webhook.NewSecret(), webhook.NewSecret()

	if _, err := hooks.Endpoint(acme, t0); !errors.Is(err, webhook.ErrNoEndpoint) {
		t.Fatalf("before Put: %v, want ErrNoEndpoint", err)
	}
	created, err := hooks.Put(acme, "https://acme.example/hooks", first, t0)
	if err != nil || !created {
		t.Fatalf("first Put: created %v, %v", created, err)
	}
	// A second Put changes the URL and keeps the secret.
	created, err = hooks.Put(acme, "https://acme.example/v2/hooks", second, t0)
	if err != nil || created {
		t.Fatalf("second Put: created %v, %v; want an update", created, err)
	}
	ep, err := hooks.Endpoint(acme, t0)
	if err != nil || ep.URL != "https://acme.example/v2/hooks" || len(ep.Secrets) != 1 || string(ep.Secrets[0]) != string(first) {
		t.Fatalf("endpoint %+v, %v", ep, err)
	}

	// Row-level security: globex sees no webhook, and can't rotate acme's.
	if _, err := hooks.Endpoint(globex, t0); !errors.Is(err, webhook.ErrNoEndpoint) {
		t.Fatalf("globex reads acme's webhook: %v", err)
	}
	if err := hooks.Rotate(globex, second, t0, t0.Add(time.Hour)); !errors.Is(err, webhook.ErrNoEndpoint) {
		t.Fatalf("globex rotates: %v, want ErrNoEndpoint", err)
	}

	// After a rotation both secrets sign, until the old one's time is up.
	if err := hooks.Rotate(acme, second, t0, t0.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	ep, _ = hooks.Endpoint(acme, t0.Add(time.Minute))
	if len(ep.Secrets) != 2 || string(ep.Secrets[0]) != string(second) || string(ep.Secrets[1]) != string(first) {
		t.Fatalf("during the overlap: %d secrets, want the new one then the old", len(ep.Secrets))
	}
	ep, _ = hooks.Endpoint(acme, t0.Add(2*time.Hour))
	if len(ep.Secrets) != 1 || string(ep.Secrets[0]) != string(second) {
		t.Fatalf("after the overlap: %d secrets, want only the new one", len(ep.Secrets))
	}

	if err := hooks.Delete(globex); !errors.Is(err, webhook.ErrNoEndpoint) {
		t.Fatalf("globex deletes acme's webhook: %v", err)
	}
	if err := hooks.Delete(acme); err != nil {
		t.Fatal(err)
	}
	if _, err := hooks.Endpoint(acme, t0); !errors.Is(err, webhook.ErrNoEndpoint) {
		t.Fatalf("after Delete: %v", err)
	}
}
~~~

### The routes

Managing a webhook is an admin's job. In `internal/authz/authz.go`:

Change:

<!-- edit: internal/authz/authz.go -->
~~~go
	CreateJob Action = "jobs.create"
	ReadJob   Action = "jobs.read"
~~~

to:

~~~go
	CreateJob      Action = "jobs.create"
	ReadJob        Action = "jobs.read"
	ManageWebhooks Action = "webhooks.manage" // step 6
~~~

Change:

<!-- edit: internal/authz/authz.go -->
~~~go
	"admin":     {CreateJob, ReadJob},
~~~

to:

~~~go
	"admin":     {CreateJob, ReadJob, ManageWebhooks},
~~~


In `internal/authz/authz_test.go`:

Change:

<!-- edit: internal/authz/authz_test.go -->
~~~go
		{"an admin does both", as("admin"), CreateJob, true},
		{"no roles: nothing", as(), ReadJob, false},
~~~

to:

~~~go
		{"an admin does both", as("admin"), CreateJob, true},
		{"an admin manages webhooks", as("admin"), ManageWebhooks, true},
		{"a submitter can't", as("submitter", "reader"), ManageWebhooks, false},
		{"no roles: nothing", as(), ReadJob, false},
~~~


Create `internal/httpapi/webhooks.go`:

<!-- file: internal/httpapi/webhooks.go -->
~~~go
package httpapi

import (
	"context"
	"errors"
	"net/http"

	"runway/internal/tenant"
	"runway/internal/webhook"
)

// Webhooks is what the webhook routes need: webhook.Registry.
type Webhooks interface {
	Set(ctx context.Context, url string) (webhook.Secret, error)
	Rotate(ctx context.Context) (webhook.Secret, error)
	Delete(ctx context.Context) error
}

// WithWebhooks adds the routes a tenant manages its webhook with
// (Phase 6, step 6):
//
//	PUT    /webhook         {"url": ...}: set it; the first time, get its secret
//	POST   /webhook/secret  replace the secret; the old one signs for a while yet
//	DELETE /webhook         stop sending
func WithWebhooks(w Webhooks) Option {
	return func(c *config) { c.webhooks = w }
}

type webhookRequest struct {
	URL string `json:"url"`
}

type webhookResponse struct {
	URL string `json:"url,omitempty"`
	// Secret is shown once, when it is made, and never again: Runway can't
	// show it later without keeping it somewhere a person could read it.
	Secret string `json:"secret,omitempty"`
}

func (h *handlers) putWebhook(hooks Webhooks) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req webhookRequest
		if err := decodeJSON(w, r, &req); err != nil {
			h.writeRequestError(w, err)
			return
		}
		secret, err := hooks.Set(r.Context(), req.URL)
		switch {
		case errors.Is(err, webhook.ErrInvalidURL):
			writeError(w, http.StatusBadRequest, err.Error())
		case err != nil:
			h.writeWebhookError(w, r, err)
		case secret != nil:
			writeJSON(w, http.StatusCreated, webhookResponse{URL: req.URL, Secret: secret.String()})
		default:
			writeJSON(w, http.StatusOK, webhookResponse{URL: req.URL})
		}
	}
}

func (h *handlers) rotateWebhookSecret(hooks Webhooks) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		secret, err := hooks.Rotate(r.Context())
		if err != nil {
			h.writeWebhookError(w, r, err)
			return
		}
		writeJSON(w, http.StatusOK, webhookResponse{Secret: secret.String()})
	}
}

func (h *handlers) deleteWebhook(hooks Webhooks) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := hooks.Delete(r.Context()); err != nil {
			h.writeWebhookError(w, r, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

func (h *handlers) writeWebhookError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, webhook.ErrNoEndpoint):
		writeError(w, http.StatusNotFound, "no webhook")
	case errors.Is(err, tenant.ErrMissing):
		writeError(w, http.StatusForbidden, "no tenant")
	default:
		h.logger.Error("webhook", "error", err, "path", r.URL.Path)
		writeError(w, http.StatusInternalServerError, "internal error")
	}
}
~~~

In `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	authorize      authz.Authorizer
}
~~~

to:

~~~go
	authorize      authz.Authorizer
	webhooks       Webhooks
}
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	mux.Handle("GET /jobs/{id}", protect(allow(authz.ReadJob, http.HandlerFunc(h.getJob))))
	if cfg.metrics != nil {
~~~

to:

~~~go
	mux.Handle("GET /jobs/{id}", protect(allow(authz.ReadJob, http.HandlerFunc(h.getJob))))
	if hooks := cfg.webhooks; hooks != nil {
		mux.Handle("PUT /webhook", protect(allow(authz.ManageWebhooks, h.putWebhook(hooks))))
		mux.Handle("POST /webhook/secret", protect(allow(authz.ManageWebhooks, h.rotateWebhookSecret(hooks))))
		mux.Handle("DELETE /webhook", protect(allow(authz.ManageWebhooks, h.deleteWebhook(hooks))))
	}
	if cfg.metrics != nil {
~~~


Create `internal/httpapi/webhooks_test.go`:

<!-- file: internal/httpapi/webhooks_test.go -->
~~~go
package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"runway/internal/authz"
	"runway/internal/webhook"
)

// memoryHooks is a webhook.Store for one tenant, in memory.
type memoryHooks struct{ url string }

func (m *memoryHooks) Put(_ context.Context, url string, _ webhook.Secret, _ time.Time) (bool, error) {
	created := m.url == ""
	m.url = url
	return created, nil
}

func (m *memoryHooks) Rotate(context.Context, webhook.Secret, time.Time, time.Time) error {
	if m.url == "" {
		return webhook.ErrNoEndpoint
	}
	return nil
}

func (m *memoryHooks) Delete(context.Context) error {
	if m.url == "" {
		return webhook.ErrNoEndpoint
	}
	m.url = ""
	return nil
}

func (m *memoryHooks) Endpoint(context.Context, time.Time) (webhook.Endpoint, error) {
	return webhook.Endpoint{}, webhook.ErrNoEndpoint
}

func registry() webhook.Registry { return webhook.Registry{Store: &memoryHooks{}} }

func TestWebhookRoutes(t *testing.T) {
	h := newTestHandler(WithWebhooks(registry()))
	secretOf := func(body []byte) string {
		var resp webhookResponse
		_ = json.Unmarshal(body, &resp)
		return resp.Secret
	}
	got := do(t, h, http.MethodPut, "/webhook", `{"url":"https://93.184.215.14/hooks"}`)
	if got.Code != http.StatusCreated || secretOf(got.Body.Bytes()) == "" {
		t.Fatalf("first PUT: %d %s; want 201 with the secret", got.Code, got.Body)
	}
	got = do(t, h, http.MethodPut, "/webhook", `{"url":"https://93.184.215.14/v2"}`)
	if got.Code != http.StatusOK || secretOf(got.Body.Bytes()) != "" {
		t.Fatalf("second PUT: %d %s; want 200 and no secret: it is shown once", got.Code, got.Body)
	}
	got = do(t, h, http.MethodPost, "/webhook/secret", "")
	if got.Code != http.StatusOK || secretOf(got.Body.Bytes()) == "" {
		t.Fatalf("rotate: %d %s", got.Code, got.Body)
	}
	if got := do(t, h, http.MethodDelete, "/webhook", ""); got.Code != http.StatusNoContent {
		t.Fatalf("delete: %d", got.Code)
	}
	if got := do(t, h, http.MethodDelete, "/webhook", ""); got.Code != http.StatusNotFound {
		t.Fatalf("delete again: %d, want 404", got.Code)
	}
}

func TestAPrivateWebhookURLIsRefused(t *testing.T) {
	h := newTestHandler(WithWebhooks(registry()))
	got := do(t, h, http.MethodPut, "/webhook", `{"url":"https://169.254.169.254/latest/meta-data/"}`)
	if got.Code != http.StatusBadRequest {
		t.Fatalf("got %d %s, want 400", got.Code, got.Body)
	}
}

func TestWebhookRoutesAreAuthorized(t *testing.T) {
	asked := map[authz.Action]int{}
	deny := func(_ context.Context, a authz.Action) error {
		asked[a]++
		return authz.ErrDenied
	}
	h := newTestHandler(WithWebhooks(registry()), WithAuthorizer(deny))
	for _, r := range [][3]string{{"PUT", "/webhook", `{"url":"https://93.184.215.14/"}`}, {"POST", "/webhook/secret", ""}, {"DELETE", "/webhook", ""}} {
		if got := do(t, h, r[0], r[1], r[2]); got.Code != http.StatusForbidden {
			t.Errorf("%s %s = %d, want 403", r[0], r[1], got.Code)
		}
	}
	if asked[authz.ManageWebhooks] != 3 {
		t.Fatalf("asked %v", asked)
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/authz/ ./internal/httpapi/ ./internal/pgstore/... && go test -race -count=1 ./internal/authz/ ./internal/httpapi/ ./internal/pgstore/... -->

### From a finished job to a webhook

A finished job sends one more message, to a new queue. In `internal/messages/messages.go`:

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
// Queue names. Commands go to workers; events come back to the API.
const (
~~~

to:

~~~go
// Queue names. Commands go to workers; events come back to the API.
// Finished jobs go to the notifier, which sends webhooks (Phase 6).
const (
~~~

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
	EventsQueue   = "jobs.events"
)
~~~

to:

~~~go
	EventsQueue   = "jobs.events"
	WebhooksQueue = "webhooks.deliveries"
)
~~~


In `internal/eventing/eventing.go`, the outbox writes it in the same transaction as the job's last change, so a finished job's webhook can't be lost, and has its own envelope ID, which becomes the webhook's ID:

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go

// OutboxMessages returns what a change to a job must send, for
~~~

to:

~~~go

// Outbox says which messages, beyond RunJob commands, changes to jobs send.
type Outbox struct {
	StreamEvents bool // every change, to the Kafka job-events topic
	Webhooks     bool // finished jobs, to the notifier (Phase 6)
}

// OutboxMessages returns what a change to a job must send, for
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
// streamEvents, every change is also streamed as a JobChanged event, keyed
// by job ID so that one job's events stay in order.
func OutboxMessages(streamEvents bool) func(jobs.Job) ([]outbox.Message, error) {
~~~

to:

~~~go
// StreamEvents, every change is also streamed as a JobChanged event, keyed
// by job ID so that one job's events stay in order. With Webhooks, a job
// that finished is sent to the notifier, which tells the tenant if it has
// asked to be told.
func OutboxMessages(o Outbox) func(jobs.Job) ([]outbox.Message, error) {
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
		if streamEvents {
			event := jobs.EventFor(job)
			env, err := messages.New(messages.TypeJobChanged, messages.JobChanged{
				JobID:  int64(event.JobID),
				State:  string(event.State),
				Reason: event.Reason,
			}, event.At)
~~~

to:

~~~go
		finished := job.State == jobs.StateCompleted || job.State == jobs.StateFailed
		if !o.StreamEvents && !(o.Webhooks && finished) {
			return msgs, nil
		}
		event := jobs.EventFor(job)
		changed := messages.JobChanged{JobID: int64(event.JobID), State: string(event.State), Reason: event.Reason}
		if o.StreamEvents {
			env, err := messages.New(messages.TypeJobChanged, changed, event.At)
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
			})
		}
~~~

to:

~~~go
			})
		}
		if o.Webhooks && finished {
			// Its own envelope, with its own ID: the webhook's ID, which
			// stays the same however many times delivery is retried.
			env, err := messages.New(messages.TypeJobChanged, changed, event.At)
			if err != nil {
				return nil, err
			}
			env.Tenant = string(job.Tenant)
			msgs = append(msgs, outbox.Message{Destination: messages.WebhooksQueue, Envelope: env})
		}
~~~


In `internal/eventing/eventing_test.go`:

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	msgs, err := OutboxMessages(false)(job)
~~~

to:

~~~go
	msgs, err := OutboxMessages(Outbox{})(job)
~~~

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	if msgs, _ := OutboxMessages(false)(job); len(msgs) != 0 {
~~~

to:

~~~go
	if msgs, _ := OutboxMessages(Outbox{})(job); len(msgs) != 0 {
~~~

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	msgs, err := OutboxMessages(true)(job)
~~~

to:

~~~go
	msgs, err := OutboxMessages(Outbox{StreamEvents: true})(job)
~~~

Add this at the end of the file:

<!-- append: internal/eventing/eventing_test.go -->
~~~go
// Only finished jobs are sent to the notifier, each with its tenant.
func TestOutboxMessagesNotifyFinishedJobs(t *testing.T) {
	t0 := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	job, _ := jobs.New("resize", time.Second, t0)
	job.ID, job.Tenant = 7, "acme"
	webhooks := OutboxMessages(Outbox{Webhooks: true})
	_ = job.Start(t0)
	if msgs, _ := webhooks(job); len(msgs) != 0 {
		t.Fatalf("a started job sent %d messages, want none", len(msgs))
	}
	_ = job.Complete(t0.Add(time.Second))
	msgs, err := webhooks(job)
	if err != nil || len(msgs) != 1 || msgs[0].Destination != messages.WebhooksQueue || msgs[0].Envelope.Tenant != "acme" {
		t.Fatalf("got %+v, %v; want one message to %s for acme", msgs, err, messages.WebhooksQueue)
	}
}
~~~


The notifier itself. Create `internal/notifier/notifier.go`:

<!-- file: internal/notifier/notifier.go -->
~~~go
// Package notifier turns finished jobs into webhooks (Phase 6, step 6). It
// runs in its own process, cmd/notifier, because it is the one part of
// Runway that sends requests to addresses tenants choose: kept apart, it
// can be given network access to the internet and none to the rest of
// Runway (step 12), and nothing else needs either.
package notifier

import (
	"context"
	"errors"
	"time"

	"runway/internal/bus"
	"runway/internal/messages"
	"runway/internal/retry"
	"runway/internal/tenant"
	"runway/internal/webhook"
)

// Endpoints finds the webhook of the tenant in ctx: webhook.Store does.
type Endpoints interface {
	Endpoint(ctx context.Context, now time.Time) (webhook.Endpoint, error)
}

// Results of handling one message, for metrics.
const (
	Delivered  = "delivered"
	NoEndpoint = "no_endpoint"
	Blocked    = "blocked"
	Failed     = "failed"
)

// Notifier sends one webhook for each message on messages.WebhooksQueue.
type Notifier struct {
	Endpoints Endpoints
	Sender    webhook.Sender
	// Retry is for brief failures, a few seconds' worth. After it gives
	// up, the bus retries the message, and in the end dead-letters it.
	Retry  retry.Policy
	Now    func() time.Time
	Result func(result string, msg messages.Envelope, err error) // nil: ignored
}

// JobData is the "data" of a job webhook. It leaves out the description:
// the tenant has it already, and it may hold personal data (step 11).
type JobData struct {
	ID            int64  `json:"id"`
	State         string `json:"state"`
	FailureReason string `json:"failure_reason,omitempty"`
}

func (n *Notifier) Handle(ctx context.Context, msg messages.Envelope) error {
	result, err := n.handle(ctx, msg)
	if n.Result != nil {
		n.Result(result, msg, err)
	}
	return err
}

func (n *Notifier) handle(ctx context.Context, msg messages.Envelope) (string, error) {
	if msg.Tenant == "" {
		return Failed, bus.Permanent(tenant.ErrMissing)
	}
	var changed messages.JobChanged
	if err := messages.Decode(msg, messages.TypeJobChanged, &changed); err != nil {
		return Failed, bus.Permanent(err)
	}
	ctx = tenant.With(ctx, tenant.ID(msg.Tenant))
	ep, err := n.Endpoints.Endpoint(ctx, n.Now())
	if errors.Is(err, webhook.ErrNoEndpoint) {
		return NoEndpoint, nil // this tenant hasn't asked for webhooks
	}
	if err != nil {
		return Failed, err
	}
	event := webhook.Event{
		Type:      "job." + changed.State,
		Timestamp: msg.OccurredAt,
		Data:      JobData{ID: changed.JobID, State: changed.State, FailureReason: changed.Reason},
	}
	err = n.Retry.Do(ctx, func(ctx context.Context) error {
		// The message's ID is the webhook's: the same on every retry.
		err := n.Sender.Send(ctx, ep, msg.ID, event)
		if errors.Is(err, webhook.ErrBlocked) {
			return retry.Stop(err)
		}
		return err
	})
	switch {
	case err == nil:
		return Delivered, nil
	case errors.Is(err, webhook.ErrBlocked):
		// Trying again will be refused again: dead-letter it, where an
		// operator will see it.
		return Blocked, bus.Permanent(err)
	default:
		return Failed, err
	}
}
~~~

The webhook's body leaves out the job's description. The tenant has it already, and it may hold personal data (step 11). A blocked address is `Permanent`: trying again will be refused again, so it goes to the dead-letter queue, where an operator sees it.

Create `internal/notifier/notifier_test.go`:

<!-- file: internal/notifier/notifier_test.go -->
~~~go
package notifier

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"runway/internal/bus"
	"runway/internal/messages"
	"runway/internal/retry"
	"runway/internal/tenant"
	"runway/internal/webhook"
)

// endpoints is a webhook store with one tenant's endpoint.
type endpoints struct {
	tenant tenant.ID
	ep     webhook.Endpoint
}

func (e endpoints) Endpoint(ctx context.Context, _ time.Time) (webhook.Endpoint, error) {
	if owner, _ := tenant.From(ctx); owner != e.tenant {
		return webhook.Endpoint{}, webhook.ErrNoEndpoint
	}
	return e.ep, nil
}

func finished(t *testing.T, owner string) messages.Envelope {
	t.Helper()
	env, err := messages.New(messages.TypeJobChanged, messages.JobChanged{JobID: 7, State: "completed"}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	env.Tenant = owner
	return env
}

func newNotifier(e Endpoints, results *[]string) *Notifier {
	return &Notifier{
		Endpoints: e,
		Sender:    webhook.Sender{Client: webhook.Policy{AllowHosts: []string{"127.0.0.1"}}.Client(time.Second)},
		Retry:     retry.Policy{Attempts: 3, Sleep: func(context.Context, time.Duration) error { return nil }},
		Now:       time.Now,
		Result:    func(r string, _ messages.Envelope, _ error) { *results = append(*results, r) },
	}
}

func TestAFinishedJobIsDeliveredSigned(t *testing.T) {
	secret := webhook.NewSecret()
	var got webhook.Event
	var id string
	receiver := httptest.NewServer(&webhook.Receiver{Secrets: []webhook.Secret{secret}, Next: http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			id = r.Header.Get(webhook.HeaderID)
			body, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(body, &got)
		})})
	defer receiver.Close()
	var results []string
	n := newNotifier(endpoints{"acme", webhook.Endpoint{URL: receiver.URL, Secrets: []webhook.Secret{secret}}}, &results)
	msg := finished(t, "acme")
	if err := n.Handle(context.Background(), msg); err != nil {
		t.Fatal(err)
	}
	if id != msg.ID || got.Type != "job.completed" {
		t.Fatalf("received id %q type %q; want %q, job.completed", id, got.Type, msg.ID)
	}
	// Another tenant's finished job goes nowhere: it has no endpoint.
	if err := n.Handle(context.Background(), finished(t, "globex")); err != nil {
		t.Fatal(err)
	}
	if len(results) != 2 || results[0] != Delivered || results[1] != NoEndpoint {
		t.Fatalf("results %v", results)
	}
}

func TestAFailingReceiverIsRetriedThenLeftToTheBus(t *testing.T) {
	var calls atomic.Int32
	ids := map[string]bool{}
	receiver := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		ids[r.Header.Get(webhook.HeaderID)] = true
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer receiver.Close()
	var results []string
	n := newNotifier(endpoints{"acme", webhook.Endpoint{URL: receiver.URL, Secrets: []webhook.Secret{webhook.NewSecret()}}}, &results)
	err := n.Handle(context.Background(), finished(t, "acme"))
	if err == nil || bus.IsPermanent(err) {
		t.Fatalf("got %v, want an error the bus retries", err)
	}
	if calls.Load() != 3 || len(ids) != 1 {
		t.Fatalf("%d calls with %d IDs; want 3 tries of one webhook", calls.Load(), len(ids))
	}
}

func TestABlockedAddressIsNotRetried(t *testing.T) {
	var results []string
	n := newNotifier(endpoints{"acme", webhook.Endpoint{URL: "http://10.96.0.1:6379/", Secrets: []webhook.Secret{webhook.NewSecret()}}}, &results)
	n.Sender.Client = webhook.Policy{}.Client(time.Second)
	err := n.Handle(context.Background(), finished(t, "acme"))
	if !bus.IsPermanent(err) || !errors.Is(err, webhook.ErrBlocked) {
		t.Fatalf("got %v, want a permanent ErrBlocked", err)
	}
	if results[0] != Blocked {
		t.Fatalf("result %v", results)
	}
}

func TestAMessageWithoutATenantIsRefused(t *testing.T) {
	var results []string
	n := newNotifier(endpoints{}, &results)
	if err := n.Handle(context.Background(), finished(t, "")); !errors.Is(err, tenant.ErrMissing) || !bus.IsPermanent(err) {
		t.Fatalf("got %v", err)
	}
}
~~~

Create `cmd/notifier/main.go`:

<!-- file: cmd/notifier/main.go -->
~~~go
// Command notifier sends webhooks (Phase 6, step 6). It takes finished jobs
// from RabbitMQ, looks up each tenant's webhook in PostgreSQL, and posts a
// signed request to it.
//
// It is the only part of Runway that connects to addresses tenants choose,
// so it is the only part that is given a way out to the internet, and the
// one most carefully kept away from everything else (see internal/webhook).
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"runway/internal/envconfig"
	"runway/internal/messages"
	"runway/internal/notifier"
	"runway/internal/pgstore"
	"runway/internal/rabbit"
	"runway/internal/retry"
	"runway/internal/webhook"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Getenv, os.Stdout, nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type config struct {
	AMQPURL       string
	DatabaseURL   string
	AllowHosts    []string
	Timeout       time.Duration
	Consumers     int
	QueueCapacity int
	MaxDeliveries int
	ShutdownGrace time.Duration
	ListenAddr    string // /health and /metrics
}

func loadConfig(getenv envconfig.Getenv) (config, error) {
	cfg := config{AMQPURL: getenv("AMQP_URL"), DatabaseURL: getenv("DATABASE_URL")}
	if cfg.AMQPURL == "" || cfg.DatabaseURL == "" {
		return config{}, errors.New("AMQP_URL and DATABASE_URL are required")
	}
	if hosts := getenv("WEBHOOK_ALLOW_HOSTS"); hosts != "" {
		cfg.AllowHosts = strings.Split(hosts, ",")
	}
	var err error
	if cfg.Timeout, err = envconfig.Duration(getenv, "WEBHOOK_TIMEOUT", 5*time.Second); err != nil {
		return config{}, err
	}
	if cfg.Consumers, err = envconfig.PositiveInt(getenv, "CONSUMERS", 4); err != nil {
		return config{}, err
	}
	if cfg.QueueCapacity, err = envconfig.PositiveInt(getenv, "QUEUE_CAPACITY", 100); err != nil {
		return config{}, err
	}
	if cfg.MaxDeliveries, err = envconfig.PositiveInt(getenv, "MAX_DELIVERIES", 5); err != nil {
		return config{}, err
	}
	if cfg.ShutdownGrace, err = envconfig.Duration(getenv, "SHUTDOWN_GRACE", 10*time.Second); err != nil {
		return config{}, err
	}
	if cfg.ListenAddr, err = envconfig.HostPort(getenv, "LISTEN_ADDR", "127.0.0.1:8082"); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer, ready func(addr string)) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	// The API migrates the schema; the notifier only reads webhooks.
	pool, err := pgstore.Open(ctx, cfg.DatabaseURL, pgstore.PoolOptions{MaxConns: int32(cfg.Consumers)})
	if err != nil {
		return err
	}
	defer pool.Close()
	// The queue's settings must match the API's, which declares it too.
	client, err := rabbit.Dial(cfg.AMQPURL, rabbit.Options{
		MaxLength:     cfg.QueueCapacity,
		MaxDeliveries: cfg.MaxDeliveries,
		Prefetch:      1,
	}, messages.WebhooksQueue)
	if err != nil {
		return err
	}
	defer client.Close()

	registry := prometheus.NewRegistry()
	results := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "webhook_deliveries_total",
		Help: "Webhook messages handled, by result: delivered, no_endpoint, blocked or failed.",
	}, []string{"result"})
	registry.MustRegister(results)
	policy := webhook.Policy{AllowHosts: cfg.AllowHosts}
	n := &notifier.Notifier{
		Endpoints: pgstore.New(pool).Webhooks(),
		Sender:    webhook.Sender{Client: policy.Client(cfg.Timeout)},
		Retry:     retry.Policy{Attempts: 3, Base: 500 * time.Millisecond, Max: 5 * time.Second},
		Now:       time.Now,
		Result: func(result string, msg messages.Envelope, err error) {
			results.WithLabelValues(result).Inc()
			if result == notifier.NoEndpoint {
				return // most tenants: not worth a line each
			}
			attrs := []any{"result", result, "tenant", msg.Tenant, "webhook_id", msg.ID}
			if err != nil {
				logger.Warn("webhook", append(attrs, "error", err)...)
				return
			}
			logger.Info("webhook", attrs...)
		},
	}

	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok\n") })
	mux.Handle("GET /metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	if ready != nil {
		ready(listener.Addr().String())
	}

	stopConsuming, cancelConsuming := context.WithCancel(context.Background())
	defer cancelConsuming()
	consumerErr := make(chan error, cfg.Consumers)
	var consumers sync.WaitGroup
	for range cfg.Consumers {
		consumers.Go(func() {
			if err := client.Subscribe(stopConsuming, messages.WebhooksQueue, n.Handle); err != nil {
				consumerErr <- err
			}
		})
	}
	logger.Info("notifier ready", "consumers", cfg.Consumers, "allow_hosts", strings.Join(cfg.AllowHosts, ","))

	var runErr error
	select {
	case <-ctx.Done():
	case runErr = <-consumerErr:
		logger.Error("lost the broker; shutting down", "error", runErr)
	}
	cancelConsuming()
	done := make(chan struct{})
	go func() {
		consumers.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(cfg.ShutdownGrace):
		logger.Warn("grace period over; unfinished deliveries will be retried")
	}
	logger.Info("stopped")
	return runErr
}
~~~

Create `cmd/notifier/main_test.go`:

<!-- file: cmd/notifier/main_test.go -->
~~~go
package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"runway/internal/messages"
	"runway/internal/pgstore"
	"runway/internal/pgstore/pgtest"
	"runway/internal/rabbit"
	"runway/internal/tenant"
	"runway/internal/webhook"
)

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestLoadConfig(t *testing.T) {
	if _, err := loadConfig(env(nil)); err == nil || !strings.Contains(err.Error(), "AMQP_URL and DATABASE_URL") {
		t.Fatalf("no settings: %v", err)
	}
	cfg, err := loadConfig(env(map[string]string{"AMQP_URL": "amqp://x", "DATABASE_URL": "postgres://x", "WEBHOOK_ALLOW_HOSTS": "a,b"}))
	if err != nil || cfg.Timeout != 5*time.Second || cfg.Consumers != 4 || len(cfg.AllowHosts) != 2 {
		t.Fatalf("defaults: %+v, %v", cfg, err)
	}
}

// The whole path: a finished job on the queue becomes a signed webhook at
// the tenant's receiver.
func TestAFinishedJobBecomesAWebhook(t *testing.T) {
	amqpURL := os.Getenv("RUNWAY_AMQP_URL")
	if amqpURL == "" {
		t.Skip("set RUNWAY_AMQP_URL to run this test")
	}
	dbURL := pgtest.URL(t)
	pool, err := pgxpool.New(context.Background(), dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := pgstore.Migrate(context.Background(), pool); err != nil {
		t.Fatal(err)
	}

	secret := webhook.NewSecret()
	got := make(chan string, 1)
	receiver := httptest.NewServer(&webhook.Receiver{Secrets: []webhook.Secret{secret}, Next: http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			body, _ := io.ReadAll(r.Body)
			got <- string(body)
		})})
	defer receiver.Close()
	// A tenant name of its own, so messages left on the shared queue by
	// other runs find no webhook and are dropped.
	owner := tenant.ID("t" + strings.ToLower(time.Now().Format("150405.000000")))
	ctx := tenant.With(context.Background(), owner)
	if _, err := pgstore.New(pool).Webhooks().Put(ctx, receiver.URL+"/hooks", secret, time.Now()); err != nil {
		t.Fatal(err)
	}

	runCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	u, _ := url.Parse(receiver.URL)
	ready := make(chan string, 1)
	done := make(chan error, 1)
	go func() {
		done <- run(runCtx, env(map[string]string{
			"AMQP_URL": amqpURL, "DATABASE_URL": dbURL, "LISTEN_ADDR": "127.0.0.1:0",
			"WEBHOOK_ALLOW_HOSTS": u.Hostname(),
		}), io.Discard, func(addr string) { ready <- addr })
	}()
	select {
	case <-ready:
	case err := <-done:
		t.Fatal(err)
	}

	client, err := rabbit.Dial(amqpURL, rabbit.Options{MaxLength: 100, MaxDeliveries: 5, Prefetch: 1}, messages.WebhooksQueue)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	env, _ := messages.New(messages.TypeJobChanged, messages.JobChanged{JobID: 42, State: "completed"}, time.Now())
	env.Tenant = string(owner)
	if err := client.Publish(context.Background(), messages.WebhooksQueue, env); err != nil {
		t.Fatal(err)
	}
	select {
	case body := <-got:
		if !strings.Contains(body, `"type":"job.completed"`) || !strings.Contains(body, `"id":42`) {
			t.Fatalf("webhook body %s", body)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no webhook within 10s")
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
~~~

And a receiver to try it on, the kind a tenant would run. It logs whole requests, so you can replay one. Create `cmd/hookcatcher/main.go`:

<!-- file: cmd/hookcatcher/main.go -->
~~~go
// Command hookcatcher is a webhook receiver, the kind a tenant runs, for
// trying webhooks out (Phase 6, step 6). It checks each request with
// webhook.Receiver and logs what it accepted and what it refused.
//
//	HOOK_SECRETS=whsec_...[,whsec_...] hookcatcher
//
// It logs whole requests, headers and body, so you can see what a webhook
// looks like, and replay one. A real receiver wouldn't.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"runway/internal/webhook"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, getenv func(string) string, stdout io.Writer) error {
	var secrets []webhook.Secret
	for text := range strings.SplitSeq(getenv("HOOK_SECRETS"), ",") {
		s, err := webhook.ParseSecret(strings.TrimSpace(text))
		if err != nil {
			return fmt.Errorf("HOOK_SECRETS: %w", err)
		}
		secrets = append(secrets, s)
	}
	addr := getenv("LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8090"
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
	// A real receiver would act on the webhook here.
	accepted := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "ok\n")
	})
	receiver := &webhook.Receiver{Secrets: secrets, Next: accepted}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok\n") })
	mux.Handle("POST /hooks", logRequests(logger, receiver))
	server := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		_ = server.Close()
	}()
	logger.Info("listening", "addr", addr, "secrets", len(secrets))
	if err := server.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// logRequests logs each request as it came, and the answer it got.
func logRequests(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(io.LimitReader(r.Body, 64<<10))
		r.Body = io.NopCloser(strings.NewReader(string(body)))
		rec := &recorder{ResponseWriter: w, code: http.StatusOK}
		next.ServeHTTP(rec, r)
		logger.Info("request",
			"status", rec.code,
			"answer", strings.TrimSpace(rec.body.String()),
			webhook.HeaderID, r.Header.Get(webhook.HeaderID),
			webhook.HeaderTimestamp, r.Header.Get(webhook.HeaderTimestamp),
			webhook.HeaderSignature, r.Header.Get(webhook.HeaderSignature),
			"body", string(body))
	})
}

type recorder struct {
	http.ResponseWriter
	code int
	body strings.Builder
}

func (r *recorder) WriteHeader(code int) {
	r.code = code
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(b []byte) (int, error) {
	r.body.Write(b)
	return r.ResponseWriter.Write(b)
}
~~~

### A finding: one stalled destination stopped every job

My first version stopped here, and the cluster test below found a real outage. With the notifier stopped, its queue filled up (RabbitMQ refuses messages to a full queue, Phase 5), and *jobs stopped running*. The outbox relay sends messages oldest first and stops at the first failure. So the oldest pending message, a webhook for a full queue, failed every time, and every `RunJob` command written after it waited behind it. That's **head-of-line blocking**: a problem in an optional feature stopped the core one.

The fix is a relay per destination, so each stall holds back only itself. Order still holds where it matters, within one destination. In `internal/outbox/outbox.go`:

Change:

<!-- edit: internal/outbox/outbox.go -->
~~~go
	pool      *pgxpool.Pool
	publisher Publisher
	batchSize int
	interval  time.Duration
	logger    *slog.Logger
~~~

to:

~~~go
	pool        *pgxpool.Pool
	publisher   Publisher
	batchSize   int
	interval    time.Duration
	logger      *slog.Logger
	destination string // "" for all
~~~

Change:

<!-- edit: internal/outbox/outbox.go -->
~~~go
	return &Relay{pool: pool, publisher: publisher, batchSize: batchSize, interval: interval, logger: logger}
}
~~~

to:

~~~go
	return &Relay{pool: pool, publisher: publisher, batchSize: batchSize, interval: interval, logger: logger}
}

// For returns a relay that sends only the messages for destination.
//
// One relay for every destination has a weakness: it sends oldest first and
// stops at the first failure, so when one destination can't take messages
// (a full queue, a consumer that's down), messages for every other
// destination wait behind it. A relay per destination keeps each stall to
// its own destination, and messages to one destination still go in order
// (Phase 6: a stopped notifier stopped every job from running).
func (r *Relay) For(destination string) *Relay {
	c := *r
	c.destination = destination
	return &c
}
~~~

Change:

<!-- edit: internal/outbox/outbox.go -->
~~~go
		WHERE published_at IS NULL
~~~

to:

~~~go
		WHERE published_at IS NULL AND ($2 = '' OR destination = $2)
~~~

Change:

<!-- edit: internal/outbox/outbox.go -->
~~~go
		FOR UPDATE SKIP LOCKED`, r.batchSize)
~~~

to:

~~~go
		FOR UPDATE SKIP LOCKED`, r.batchSize, r.destination)
~~~

Change:

<!-- edit: internal/outbox/outbox.go -->
~~~go
			r.logger.Warn("outbox relay failed; will retry", "error", err)
~~~

to:

~~~go
			r.logger.Warn("outbox relay failed; will retry", "destination", r.destination, "error", err)
~~~


Create `internal/pgstore/migrations/0009_outbox_by_destination.sql`, the index each relay's query needs:

<!-- file: internal/pgstore/migrations/0009_outbox_by_destination.sql -->
~~~sql
-- Phase 6, step 6: the outbox is relayed one destination at a time, so a
-- stalled destination can't hold back the others. Each relay looks for the
-- oldest unsent messages for its destination; this index finds them.

-- +goose Up
CREATE INDEX outbox_pending_by_destination ON outbox (destination, id) WHERE published_at IS NULL;
DROP INDEX outbox_pending;

-- +goose Down
CREATE INDEX outbox_pending ON outbox (id) WHERE published_at IS NULL;
DROP INDEX outbox_pending_by_destination;
~~~

And the test that would have caught it. In `internal/outbox/outbox_test.go`:

Add this at the end of the file:

<!-- append: internal/outbox/outbox_test.go -->
~~~go
// fullQueue refuses every message for one destination, as a full queue
// does, and records the rest.
type fullQueue struct {
	mu   sync.Mutex
	full string
	sent []string
}

func (f *fullQueue) Publish(_ context.Context, m outbox.Message) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if m.Destination == f.full {
		return errors.New("queue full")
	}
	f.sent = append(f.sent, m.Envelope.ID)
	return nil
}

// A destination that can't take messages must not hold back the others.
// With one relay for all of them it did: the oldest message failed, and
// everything behind it waited.
func TestAStalledDestinationHoldsBackOnlyItself(t *testing.T) {
	pool := pgtest.Pool(t, pgstore.Migrate)
	ctx := context.Background()
	err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		for i, dest := range []string{"webhooks", "commands", "commands"} {
			env := messages.Envelope{ID: fmt.Sprint(i), Type: "test", Version: 1, Payload: []byte(`{}`)}
			if err := outbox.Write(ctx, tx, outbox.Message{Destination: dest, Envelope: env}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	p := &fullQueue{full: "webhooks"}
	all := newRelay(pool, p, 10)
	if _, err := all.For("webhooks").RelayOnce(ctx); err == nil {
		t.Fatal("the full destination reported no error")
	}
	if n, err := all.For("commands").RelayOnce(ctx); err != nil || n != 2 {
		t.Fatalf("commands: sent %d, %v; want both", n, err)
	}
	if n, _ := outbox.Pending(ctx, pool); n != 1 {
		t.Fatalf("%d pending, want the webhook's 1", n)
	}
}
~~~


Break it: make `For` ignore its destination (delete `c.destination = destination`):

~~~text
    outbox_test.go:188: commands: sent 0, publish outbox message: queue full; want both
~~~

### The API

In `cmd/api/main.go`: webhooks are on with `WEBHOOKS_ENABLED`, they need RabbitMQ and PostgreSQL, and there's one relay per destination:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/tenant"
	"runway/internal/worker"
~~~

to:

~~~go
	"runway/internal/tenant"
	"runway/internal/webhook"
	"runway/internal/worker"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	RateLimit *ratelimit.Quotas
}
~~~

to:

~~~go
	RateLimit *ratelimit.Quotas
	// Step 6: send finished jobs to the notifier, and let tenants register
	// webhooks, which may go only to public addresses or WebhookAllowHosts.
	Webhooks          bool
	WebhookAllowHosts []string
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	var err error
	if cfg.ListenAddr, err = envconfig.HostPort(getenv, "LISTEN_ADDR", "127.0.0.1:8080"); err != nil {
~~~

to:

~~~go
	var err error
	if cfg.Webhooks, err = envconfig.Bool(getenv, "WEBHOOKS_ENABLED", false); err != nil {
		return config{}, err
	}
	if cfg.Webhooks && (cfg.AMQPURL == "" || cfg.DatabaseURL == "") {
		return config{}, errors.New("WEBHOOKS_ENABLED needs AMQP_URL and DATABASE_URL: webhooks are stored in PostgreSQL and sent by the notifier, through RabbitMQ")
	}
	if hosts := getenv("WEBHOOK_ALLOW_HOSTS"); hosts != "" {
		cfg.WebhookAllowHosts = strings.Split(hosts, ",")
	}
	if cfg.ListenAddr, err = envconfig.HostPort(getenv, "LISTEN_ADDR", "127.0.0.1:8080"); err != nil {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	}, messages.CommandsQueue, messages.EventsQueue)
~~~

to:

~~~go
	}, queues(cfg)...)
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	return client, client, client.Close, nil
}
~~~

to:

~~~go
	return client, client, client.Close, nil
}

// queues are the queues the API declares: the notifier's too, when there
// are webhooks, since the API sends to it.
func queues(cfg config) []string {
	q := []string{messages.CommandsQueue, messages.EventsQueue}
	if cfg.Webhooks {
		q = append(q, messages.WebhooksQueue)
	}
	return q
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		store = pgstore.New(pool, pgstore.WithOutbox(eventing.OutboxMessages(producer != nil)))
~~~

to:

~~~go
		store = pgstore.New(pool, pgstore.WithOutbox(eventing.OutboxMessages(eventing.Outbox{StreamEvents: producer != nil, Webhooks: cfg.Webhooks})))
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	options = append(options, httpapi.WithAuthorizer(authorize))
	if cfg.ServedBy != "" {
~~~

to:

~~~go
	options = append(options, httpapi.WithAuthorizer(authorize))
	if cfg.Webhooks {
		options = append(options, httpapi.WithWebhooks(webhook.Registry{
			Store:   store.Webhooks(),
			Policy:  webhook.Policy{AllowHosts: cfg.WebhookAllowHosts},
			Overlap: 24 * time.Hour, // a day to move the receiver to a new secret
		}))
	}
	if cfg.ServedBy != "" {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		consumers.Add(1)
		go func() {
			defer consumers.Done()
			relay.Run(stopConsuming)
		}()
~~~

to:

~~~go
		// One relay per destination, so one that stalls holds back only
		// itself: a full webhooks queue must not stop jobs from running.
		destinations := []string{messages.CommandsQueue}
		if producer != nil {
			destinations = append(destinations, messages.JobEventsTopic)
		}
		if cfg.Webhooks {
			destinations = append(destinations, messages.WebhooksQueue)
		}
		for _, d := range destinations {
			consumers.Go(func() { relay.For(d).Run(stopConsuming) })
		}
~~~


In `cmd/api/main_test.go`:

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go

// With authentication off, everything is tenant "dev", which has a budget
~~~

to:

~~~go

func TestWebhooksConfig(t *testing.T) {
	if _, err := loadConfig(env(map[string]string{"WEBHOOKS_ENABLED": "true"})); err == nil || !strings.Contains(err.Error(), "WEBHOOKS_ENABLED needs") {
		t.Fatalf("webhooks without a database and broker: %v", err)
	}
	cfg, err := loadConfig(env(map[string]string{
		"WEBHOOKS_ENABLED": "true", "AMQP_URL": "amqp://x", "DATABASE_URL": "postgres://x",
		"WEBHOOK_ALLOW_HOSTS": "hookcatcher.partner",
	}))
	if err != nil || !cfg.Webhooks || !slices.Equal(queues(cfg), []string{"jobs.commands", "jobs.events", "webhooks.deliveries"}) {
		t.Fatalf("got %+v, %v", cfg, err)
	}
}

// With authentication off, everything is tenant "dev", which has a budget
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/webhook/... ./internal/notifier/... ./internal/outbox/... ./internal/eventing/... ./cmd/notifier/... ./cmd/hookcatcher/... ./cmd/api/... -->

### The chart

In `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
  tenants: {} # a different limit for some tenants, such as { acme: "50:100" }

~~~

to:

~~~yaml
  tenants: {} # a different limit for some tenants, such as { acme: "50:100" }

# Webhooks (Phase 6, step 6): tenants register a URL, and the notifier
# posts a signed request to it when one of their jobs finishes.
webhooks:
  enabled: true
  replicas: 1
  # Host names exempt from the rule that webhooks go only to public
  # addresses. Empty in production; the demo receiver needs one.
  allowHosts: []

~~~


In `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        - { name: RATE_LIMIT_TENANTS, value: {{ join "," $tenants | quote }} }
        - name: GOMEMLIMIT
~~~

to:

~~~yaml
        - { name: RATE_LIMIT_TENANTS, value: {{ join "," $tenants | quote }} }
        - { name: WEBHOOKS_ENABLED, value: {{ $root.Values.webhooks.enabled | quote }} }
        - { name: WEBHOOK_ALLOW_HOSTS, value: {{ join "," $root.Values.webhooks.allowHosts | quote }} }
        - name: GOMEMLIMIT
~~~


Create `deploy/helm/runway/templates/notifier.yaml`:

<!-- file: deploy/helm/runway/templates/notifier.yaml -->
~~~yaml
{{- if .Values.webhooks.enabled }}
# The notifier sends webhooks (Phase 6, step 6). It is the only part of
# Runway that connects to addresses tenants choose, so it runs on its own,
# where step 12's network policies can let it out to the internet and
# nowhere else.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notifier
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.webhooks.replicas }}
  selector:
    matchLabels: { app: notifier }
  template:
    metadata:
      labels: { app: notifier }
      annotations:
        {{- include "runway.configChecksum" . | nindent 8 }}
        prometheus.io/scrape: "true"
        prometheus.io/port: "8082"
    spec:
      securityContext:
        runAsNonRoot: true
      automountServiceAccountToken: false # it never calls the Kubernetes API
      containers:
        - name: notifier
          image: {{ include "runway.image" (list $ .Values.image.tag) }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: ["/usr/local/bin/notifier"]
          {{- include "runway.envFrom" . | nindent 10 }}
          env:
            - { name: LISTEN_ADDR, value: "0.0.0.0:8082" }
            - { name: WEBHOOK_ALLOW_HOSTS, value: {{ join "," .Values.webhooks.allowHosts | quote }} }
          ports:
            - { name: http, containerPort: 8082 }
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { cpu: 200m, memory: 64Mi }
          {{- include "runway.containerSecurity" . | nindent 10 }}
{{- end }}
~~~

And the receiver, in a namespace of its own, `partner`, standing in for a customer's server outside Runway. Create `deploy/k8s/hookcatcher.yaml`:

<!-- file: deploy/k8s/hookcatcher.yaml -->
~~~yaml
# A tenant's webhook receiver, for trying webhooks out (Phase 6, step 6).
# It lives in its own namespace, "partner", standing in for a customer's
# server outside Runway. Its secret comes from the Secret "hookcatcher",
# which you create with the secret PUT /webhook returned.
apiVersion: v1
kind: Namespace
metadata:
  name: partner
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hookcatcher
  namespace: partner
spec:
  replicas: 1
  selector:
    matchLabels: { app: hookcatcher }
  template:
    metadata:
      labels: { app: hookcatcher }
    spec:
      securityContext:
        runAsNonRoot: true
      automountServiceAccountToken: false
      containers:
        - name: hookcatcher
          image: runway:dev
          imagePullPolicy: IfNotPresent
          command: ["/usr/local/bin/hookcatcher"]
          env:
            - { name: LISTEN_ADDR, value: "0.0.0.0:8080" }
            - name: HOOK_SECRETS
              valueFrom:
                secretKeyRef: { name: hookcatcher, key: HOOK_SECRETS }
          ports:
            - { name: http, containerPort: 8080 }
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { cpu: 100m, memory: 32Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
---
apiVersion: v1
kind: Service
metadata:
  name: hookcatcher
  namespace: partner
spec:
  selector: { app: hookcatcher }
  ports:
    - { name: http, port: 8080, targetPort: http }
~~~

<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway | grep -q 'name: notifier' -->

### Run it

Add an admin client for each tenant, then roll out with the receiver allowed (it's in the cluster, so the public-address rule would refuse it):

~~~bash
clients="$(cat ~/.runway/idp-clients.txt),acme-admin:$(openssl rand -hex 32):acme:admin,globex-admin:$(openssl rand -hex 32):globex:admin"
(umask 077; echo "$clients" > ~/.runway/idp-clients.txt)
kubectl -n runway create secret generic idp-clients --from-literal=IDP_CLIENTS="$clients" --dry-run=client -o yaml | kubectl apply -f -
# rebuild and roll out, with: --set 'webhooks.allowHosts={hookcatcher.partner}'
ACME_ADMIN=$(token acme-admin); GLOBEX_ADMIN=$(token globex-admin); ACME=$(token acme-ci); GLOBEX=$(token globex-ci)
~~~

**Register, and receive.** Acme registers a webhook. Keep the secret it gets back, and give it to the receiver:

~~~bash
curl -s -w "  (%{http_code})\n" -X PUT localhost:8080/webhook -H "Authorization: Bearer $ACME_ADMIN" -H "Content-Type: application/json" -d '{"url":"http://hookcatcher.partner:8080/hooks"}'
~~~

~~~text
{"url":"http://hookcatcher.partner:8080/hooks","secret":"whsec_SImYwb…"}
  (201)
~~~

(I've shortened the secret; yours is 44 characters after `whsec_`.) The same request again gets `200` and no secret, and from `acme-ci`, a submitter, it gets `403`. Then:

~~~bash
kubectl create namespace partner
kubectl -n partner create secret generic hookcatcher --from-literal=HOOK_SECRETS="whsec_..."   # the secret you got
kubectl apply -f deploy/k8s/hookcatcher.yaml
curl -s -X POST localhost:8080/jobs -H "Authorization: Bearer $ACME" -H "Content-Type: application/json" -d '{"description":"nightly report","duration_ms":10}'
kubectl -n partner logs -l app=hookcatcher --tail=-1 | grep '"msg":"request"' | tail -1
kubectl -n runway logs -l app=notifier --tail=-1 | grep '"msg":"webhook"' | tail -1
~~~

~~~text
{"time":"2026-10-09T14:37:07.415687234Z","level":"INFO","msg":"request","status":200,"answer":"ok","webhook-id":"FHRX4YEFJ4Z3GLZENWO2NINFKF","webhook-timestamp":"1791556627","webhook-signature":"v1,fps7+U6xM9Wl/BnH4f5Ffrx0fUTNvbnqiGqdZ/3cwUs=","body":"{\"type\":\"job.completed\",\"timestamp\":\"2026-10-09T14:37:07.323279479Z\",\"data\":{\"id\":18685,\"state\":\"completed\"}}"}
{"time":"2026-10-09T14:37:07.416115744Z","level":"INFO","msg":"webhook","result":"delivered","tenant":"acme","webhook_id":"FHRX4YEFJ4Z3GLZENWO2NINFKF"}
~~~

(`kubectl logs deploy/X` reads only one Pod's logs; `-l app=X --tail=-1` reads all of them.) The job completed about 90 ms before the webhook arrived.

**Break it: replay what you captured.** Take the ID, timestamp, signature and body from that log line, port-forward to the receiver (`kubectl -n partner port-forward svc/hookcatcher 18090:8080 &`), and send them again, unchanged and then altered:

~~~bash
replay() { curl -s -w "  (%{http_code})\n" -X POST localhost:18090/hooks -H "webhook-id: $1" -H "webhook-timestamp: $2" -H "webhook-signature: $SIG" -H "Content-Type: application/json" -d "$3"; }
replay "$ID" "$TS" "$BODY"                       # exactly as captured
replay "$ID" "$TS" "${BODY//completed/failed}"   # the body changed
replay "${ID}x" "$TS" "$BODY"                    # a new ID, to get past the duplicate check
replay "$ID" "$(date +%s)" "$BODY"               # a fresh timestamp on the old signature
~~~

~~~text
duplicate
  (200)
no webhook signature matches
  (401)
no webhook signature matches
  (401)
no webhook signature matches
  (401)
~~~

Every way of reusing the request failed except the exact copy, which the receiver recognised and ignored. Wait five minutes and send the exact copy once more:

~~~text
webhook timestamp outside the tolerance
  (401)
~~~

Now the receiver doesn't even need to remember the ID.

**Rotate the secret** while the receiver still has only the old one:

~~~bash
curl -s -w "  (%{http_code})\n" -X POST localhost:8080/webhook/secret -H "Authorization: Bearer $ACME_ADMIN"
# create a job, and look at the next request the receiver logs
~~~

~~~text
{"secret":"whsec_ZCxahS…"}
  (200)
status 200 | signatures: 2 | v1,P8DpJDyVkhKiMoWuS… v1,1dGkL6dvE…
~~~

Two signatures, and the receiver with only the old secret still accepted it. Update its Secret to `new,old` (it accepts a comma-separated list), then to `new` alone, any time in the next 24 hours.

**Break it: SSRF.** Globex tries to aim its webhook inside the cluster:

~~~bash
for url in http://redis-0.redis.runway:6379/ https://169.254.169.254/latest/meta-data/ https://metad-0.metad.runway:7001/kv/leader 'https://[::ffff:10.96.0.1]/'; do
  curl -s -w "  (%{http_code})\n" -X PUT localhost:8080/webhook -H "Authorization: Bearer $GLOBEX_ADMIN" -H "Content-Type: application/json" -d "{\"url\":\"$url\"}"
done
~~~

~~~text
{"error":"invalid webhook URL\nwebhook URL: must use https"}
  (400)
{"error":"invalid webhook URL\nwebhook address not allowed: 169.254.169.254 resolves to 169.254.169.254"}
  (400)
{"error":"invalid webhook URL\nwebhook address not allowed: metad-0.metad.runway resolves to 10.244.2.5"}
  (400)
{"error":"invalid webhook URL\nwebhook address not allowed: ::ffff:10.96.0.1 resolves to 10.96.0.1"}
  (400)
~~~

Now suppose one got past registration, as a rebinding DNS name would. Put it straight into the database, and give globex a job:

~~~bash
kubectl -n runway exec postgres-0 -- psql -U runway -c "INSERT INTO webhooks VALUES ('globex', 'https://redis-0.redis.runway:6379/', 'whsec_c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0', NULL, NULL, now())"
curl -s -o /dev/null -X POST localhost:8080/jobs -H "Authorization: Bearer $GLOBEX" -H "Content-Type: application/json" -d '{"description":"x","duration_ms":10}'
kubectl -n runway logs -l app=notifier --tail=-1 | grep globex | tail -1
kubectl -n runway exec rabbitmq-0 -- rabbitmqctl list_queues name messages | grep webhooks
~~~

~~~text
{"time":"2026-10-09T14:37:11.942342492Z","level":"WARN","msg":"webhook","result":"blocked","tenant":"globex","webhook_id":"4QWYB5TTWJDET534T7MYQPJAUA","error":"permanent: Post \"https://redis-0.redis.runway:6379/\": dial tcp 10.244.2.2:6379: webhook address not allowed: 10.244.2.2:6379"}
webhooks.deliveries.dead	1
webhooks.deliveries	0
~~~

The dialler refused `10.244.2.2:6379`, the address DNS gave it, at the moment of connecting. Not retried: dead-lettered at once. Delete globex's row afterwards.

**Break it: stop the notifier.** This is the experiment that found the head-of-line blocking. Scale the notifier to zero and send 150 jobs:

~~~bash
kubectl -n runway scale deploy/notifier --replicas 0
for i in $(seq 150); do curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8080/jobs -H "Authorization: Bearer $ACME" -H "Content-Type: application/json" -d '{"description":"nightly report","duration_ms":10}'; sleep 0.07; done | sort | uniq -c
# then: jobs by state; the outbox's pending messages by destination; the queues; the relay's log
~~~

~~~text
    150 201
   state   | count 
-----------+-------
 completed |   150
(1 row)

     destination     | count 
---------------------+-------
 webhooks.deliveries |    49
(1 row)

webhooks.deliveries.dead	1
webhooks.deliveries	101
{"time":"2026-10-09T14:37:54.559392161Z","level":"WARN","msg":"outbox relay failed; will retry","destination":"webhooks.deliveries","error":"publish outbox message: broker rejected the message: webhooks.deliveries: queue is full"}
~~~

All 150 jobs completed. The webhooks queue is at its limit (each queue holds about 100, Phase 5), 49 more webhooks wait in the outbox, and only that destination's relay is failing. Scale the notifier back to 1: the outbox empties, and the receiver gets every webhook.

**Explain it:** what does each of the three signed parts (ID, timestamp, body) protect against? Why does a duplicate get `200`, and why is an ID remembered only after success? Why is the registration check a courtesy and the dial-time check the guard? What is DNS rebinding? Why did a stopped notifier stop jobs, and what did the fix keep that a relay without order would lose?

**Read.** The [Standard Webhooks specification](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md). Then OWASP's *Server-Side Request Forgery Prevention Cheat Sheet*, and the 2019 Capital One breach write-ups: an SSRF that reached the metadata service. Then RFC 8705 §3 (certificate-bound access tokens): how would it make step 2's stolen tokens useless?

---
## Step 7: TLS and your own certificate authority

**The problem.** Tokens say which *tenant* a request is for. Nothing yet says which *service* is calling. Inside the cluster everything is plain HTTP (T7), so any Pod that can reach a port can speak for anyone. Look at `metad`, the Raft cluster from Phase 4. From a Pod with nothing but `curl`:

~~~bash
kubectl -n runway run intruder --image=curlimages/curl:8.18.0 --restart=Never --command -- sleep 3600
kubectl -n runway exec intruder -- curl -s http://metad-2.metad:7001/status     # find the leader: try each member
kubectl -n runway exec intruder -- curl -s -X PUT http://metad-2.metad:7001/kv/owner -d intruder -w ' (%{http_code})'
kubectl -n runway exec intruder -- curl -s -X POST http://metad-2.metad:7001/raft/message -d '{"Type":1,"From":1,"To":3,"Term":124}' -w '(%{http_code})'
kubectl -n runway exec intruder -- curl -s http://metad-2.metad:7001/status
~~~

~~~text
{"id":3,"role":"leader","term":24,"leader":3,"commit":26}
{"value":"","found":false,"ok":true}
 (200)
(204)
{"id":3,"role":"follower","term":124,"leader":0,"commit":27}
~~~

The intruder wrote a key, with no credentials of any kind. Then it sent one forged Raft message: a vote request "from member 1" in term 124, a hundred terms ahead. Raft's rules say a member that sees a higher term must step down, so the leader did. A second later the members held a new election (term 125) and recovered. Send that message in a loop and `metad` never has a leader. The Raft protocol assumes its messages come from members (Phase 4 called that out of scope). Here's how to make it true.

**New ideas.**

- **TLS** gives a connection confidentiality (nobody on the path can read it), integrity (nobody can change it), and *server* authentication: the server proves it holds the private key of a certificate the client trusts.
- **Mutual TLS (mTLS):** the client presents a certificate too, so *both* ends know who the other is. It's the foundation of **zero trust** networking: being inside the network proves nothing, and every connection proves its identity.
- **A certificate authority (CA)** signs certificates. Trusting a CA means trusting everything it signs, so the CA's private key is the most valuable secret in the system. Public CAs vouch for domain names; a private CA, yours, vouches for your services.
- **Identity, not address.** A Pod's address changes every time it's replaced, so certificates name the *service*. **SPIFFE** is a standard for this: an identity is a URI such as `spiffe://runway/api`, written into the certificate's subject alternative name. Each end checks the other's identity against a list it accepts.
- **Short-lived certificates.** A day, here. A stolen key is useful only until its certificate expires, which matters more than revocation, since revocation in practice is often unchecked.
- **Rotation without restarts.** New certificates are files that appear in a mounted Secret; services notice and use them for new connections. Replacing the *CA* needs a period when both CAs are trusted.

### The CA

Create `internal/pki/pki.go`:

<!-- file: internal/pki/pki.go -->
~~~go
// Package pki is Runway's own certificate authority, and the TLS settings
// its services use to prove who they are to each other (Phase 6, step 7).
//
// Every service gets a certificate naming it with a URI, in the style of
// SPIFFE: spiffe://runway/api, spiffe://runway/gateway. Both ends of every
// connection present one (mutual TLS), and each checks the other's name
// against the ones it accepts. The name says which service is calling, not
// which machine or address: Pods come and go, and their addresses with them.
//
// Certificates are short-lived (a day), and services re-read them from disk
// as they change, so they can be replaced without a restart. A stolen key is
// worth something only until its certificate expires.
package pki

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// TrustDomain is the authority part of every Runway identity.
const TrustDomain = "runway"

// ID returns the identity of service: spiffe://runway/service.
func ID(service string) string { return "spiffe://" + TrustDomain + "/" + service }

// CA is a certificate authority: a certificate that signs others, and its
// private key. Whoever has the key can make any service's certificate, so
// it belongs somewhere far safer than the cluster it vouches for.
type CA struct {
	Cert *x509.Certificate
	Key  crypto.Signer
}

func newKey() (*ecdsa.PrivateKey, error) {
	return ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
}

func serial() (*big.Int, error) {
	return rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
}

// NewCA makes a self-signed CA, valid from now for validity.
func NewCA(name string, now time.Time, validity time.Duration) (*CA, error) {
	key, err := newKey()
	if err != nil {
		return nil, err
	}
	sn, err := serial()
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          sn,
		Subject:               pkix.Name{CommonName: name, Organization: []string{"Runway"}},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(validity),
		IsCA:                  true,
		BasicConstraintsValid: true,
		MaxPathLenZero:        true, // it signs services' certificates, not other CAs
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		// It may vouch only for names in Runway's trust domain.
		PermittedURIDomains: []string{TrustDomain},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, key.Public(), key)
	if err != nil {
		return nil, err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	return &CA{Cert: cert, Key: key}, nil
}

// Leaf is an issued certificate and its key.
type Leaf struct {
	Cert *x509.Certificate
	Key  *ecdsa.PrivateKey
}

// Issue makes a certificate for service, valid from now for validity, that
// can serve (for dnsNames, if any) and be a client. The key is made here;
// in a larger system the service makes its own and sends only a request,
// so the key never leaves it.
func (ca *CA) Issue(service string, dnsNames []string, now time.Time, validity time.Duration) (*Leaf, error) {
	id, err := url.Parse(ID(service))
	if err != nil {
		return nil, err
	}
	key, err := newKey()
	if err != nil {
		return nil, err
	}
	sn, err := serial()
	if err != nil {
		return nil, err
	}
	notAfter := now.Add(validity)
	if notAfter.After(ca.Cert.NotAfter) {
		notAfter = ca.Cert.NotAfter // nothing outlives the CA that signed it
	}
	tmpl := &x509.Certificate{
		SerialNumber: sn,
		Subject:      pkix.Name{CommonName: service, Organization: []string{"Runway"}},
		URIs:         []*url.URL{id},
		DNSNames:     dnsNames,
		NotBefore:    now.Add(-time.Minute), // a little slack for clocks that differ
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.Cert, key.Public(), ca.Key)
	if err != nil {
		return nil, err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	return &Leaf{Cert: cert, Key: key}, nil
}

// Files a CA or an issued certificate is kept in, in one directory. The
// names are the ones a Kubernetes TLS Secret uses, plus ca.crt.
const (
	CertFile = "tls.crt"
	KeyFile  = "tls.key"
	CAFile   = "ca.crt"
)

func certPEM(c *x509.Certificate) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: c.Raw})
}

func keyPEM(k crypto.Signer) ([]byte, error) {
	der, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), nil
}

// Save writes the CA's certificate and key to dir. The key file can be read
// only by its owner.
func (ca *CA) Save(dir string) error {
	key, err := keyPEM(ca.Key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, KeyFile), key, 0o600); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, CertFile), certPEM(ca.Cert), 0o644)
}

// LoadCA reads a CA that Save wrote.
func LoadCA(dir string) (*CA, error) {
	certs, err := readCerts(filepath.Join(dir, CertFile))
	if err != nil {
		return nil, err
	}
	keyBytes, err := os.ReadFile(filepath.Join(dir, KeyFile))
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(keyBytes)
	if block == nil {
		return nil, errors.New("CA key: no PEM data")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	signer, ok := key.(crypto.Signer)
	if !ok {
		return nil, errors.New("CA key can't sign")
	}
	return &CA{Cert: certs[0], Key: signer}, nil
}

// Save writes the certificate, its key, and the trust bundle (the CA
// certificates to trust, one or more) to dir.
func (l *Leaf) Save(dir string, bundle []*x509.Certificate) error {
	key, err := keyPEM(l.Key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	var b strings.Builder
	for _, c := range bundle {
		b.Write(certPEM(c))
	}
	if err := os.WriteFile(filepath.Join(dir, CAFile), []byte(b.String()), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, KeyFile), key, 0o600); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, CertFile), certPEM(l.Cert), 0o644)
}

// readCerts reads every certificate in a PEM file.
func readCerts(path string) ([]*x509.Certificate, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var certs []*x509.Certificate
	for {
		var block *pem.Block
		block, data = pem.Decode(data)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		c, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		certs = append(certs, c)
	}
	if len(certs) == 0 {
		return nil, fmt.Errorf("%s: no certificates", path)
	}
	return certs, nil
}

// IDOf returns the Runway identity in cert, or "" if it has none.
func IDOf(cert *x509.Certificate) string {
	for _, u := range cert.URIs {
		if u.Scheme == "spiffe" && u.Host == TrustDomain {
			return u.String()
		}
	}
	return ""
}
~~~

A few choices in `NewCA`. `MaxPathLenZero` means the CA signs services' certificates, never other CAs. `PermittedURIDomains` is a **name constraint**: this CA can vouch only for `spiffe://runway/...` names, so even its own key can't make a certificate that a strict verifier would accept for anything else. Keys are ECDSA P-256 (small, fast, universally supported). And every certificate's validity starts a minute in the past, for clocks that differ a little.

### TLS settings

Create `internal/pki/tls.go`:

<!-- file: internal/pki/tls.go -->
~~~go
package pki

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

// Source holds a service's certificate and trust bundle, read from the
// files Leaf.Save writes, and reads them again when they change: when a new
// certificate is issued, or the CA itself is being replaced. On Kubernetes
// the directory is a mounted Secret, which the kubelet updates in place.
type Source struct {
	dir    string
	logger *slog.Logger

	mu      sync.Mutex
	cert    *tls.Certificate
	roots   *x509.CertPool
	modTime time.Time
	checked time.Time
	failed  time.Time // the modification time of files that failed to load
}

// recheck is how often Source looks at the files: often enough that a new
// certificate is used within seconds, rarely enough to cost nothing.
const recheck = time.Second

// NewSource reads the files in dir, and fails if it can't. It logs every
// reload to logger (if not nil), and every one that fails: a certificate
// that can't be replaced is an outage on the day it expires.
func NewSource(dir string, logger *slog.Logger) (*Source, error) {
	if logger == nil {
		logger = slog.New(slog.DiscardHandler)
	}
	s := &Source{dir: dir, logger: logger}
	if err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Source) load() error {
	info, err := os.Stat(filepath.Join(s.dir, CertFile))
	if err != nil {
		return err
	}
	cert, err := tls.LoadX509KeyPair(filepath.Join(s.dir, CertFile), filepath.Join(s.dir, KeyFile))
	if err != nil {
		return err
	}
	bundle, err := readCerts(filepath.Join(s.dir, CAFile))
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	for _, c := range bundle {
		roots.AddCert(c)
	}
	s.cert, s.roots, s.modTime = &cert, roots, info.ModTime()
	return nil
}

// current returns the certificate and roots, reloading them if the files
// changed. A reload that fails keeps the old ones: a half-written update
// must not take the service down. The next check tries again.
func (s *Source) current() (*tls.Certificate, *x509.CertPool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Since(s.checked) >= recheck {
		s.checked = time.Now()
		if info, err := os.Stat(filepath.Join(s.dir, CertFile)); err == nil && !info.ModTime().Equal(s.modTime) {
			if err := s.load(); err != nil {
				if !info.ModTime().Equal(s.failed) { // once per bad version, not every second
					s.failed = info.ModTime()
					s.logger.Warn("reloading the certificate failed; keeping the old one", "dir", s.dir, "error", err)
				}
			} else {
				leaf := s.cert.Leaf
				s.logger.Info("certificate reloaded", "id", IDOf(leaf), "serial", fmt.Sprintf("%x", leaf.SerialNumber),
					"not_after", leaf.NotAfter.UTC().Format(time.RFC3339))
			}
		}
	}
	return s.cert, s.roots
}

// Certificate returns the certificate in use now.
func (s *Source) Certificate() *x509.Certificate {
	cert, _ := s.current()
	return cert.Leaf
}

// ErrNotAllowed means the peer proved an identity, but not one this end
// accepts.
var ErrNotAllowed = errors.New("peer identity not allowed")

func checkID(cert *x509.Certificate, allowed []string) error {
	id := IDOf(cert)
	if !slices.Contains(allowed, id) {
		return fmt.Errorf("%w: %q (allowed: %v)", ErrNotAllowed, id, allowed)
	}
	return nil
}

// ServerConfig is TLS for a server whose clients must be one of allowed.
// With requireClient false, a client may also come without a certificate,
// and the handlers decide (see RequireClient): health checks and metrics
// scrapers don't have one. A client that does present one must pass every
// check either way.
func ServerConfig(src *Source, requireClient bool, allowed ...string) *tls.Config {
	auth := tls.VerifyClientCertIfGiven
	if requireClient {
		auth = tls.RequireAndVerifyClientCert
	}
	return &tls.Config{
		MinVersion: tls.VersionTLS13,
		// A fresh config for each connection, with the certificate and
		// roots as they are now.
		GetConfigForClient: func(*tls.ClientHelloInfo) (*tls.Config, error) {
			cert, roots := src.current()
			return &tls.Config{
				MinVersion:   tls.VersionTLS13,
				Certificates: []tls.Certificate{*cert},
				// This config replaces the outer one, so it must offer the
				// protocols itself: h2 for gRPC (which insists) and HTTP/2.
				NextProtos: []string{"h2", "http/1.1"},
				ClientAuth: auth,
				ClientCAs:  roots,
				// Go has checked the chain to our CA by now; this checks
				// the name in it.
				VerifyPeerCertificate: func(_ [][]byte, chains [][]*x509.Certificate) error {
					if len(chains) == 0 {
						return nil // no certificate, and none required
					}
					return checkID(chains[0][0], allowed)
				},
			}, nil
		},
	}
}

// ClientConfig is TLS for a client of a server that must be server (an
// identity, such as ID("api")).
//
// It checks the server's identity, not its host name. Go's own check is
// by host name, so it is switched off (InsecureSkipVerify) and done here
// instead, in full: the chain to our CA, the dates, the key usage, then
// the name. Switching it off without doing that would accept anyone.
func ClientConfig(src *Source, server string) *tls.Config {
	return &tls.Config{
		MinVersion: tls.VersionTLS13,
		GetClientCertificate: func(*tls.CertificateRequestInfo) (*tls.Certificate, error) {
			cert, _ := src.current()
			return cert, nil
		},
		InsecureSkipVerify: true,
		VerifyConnection: func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 {
				return errors.New("server sent no certificate")
			}
			_, roots := src.current()
			intermediates := x509.NewCertPool()
			for _, c := range cs.PeerCertificates[1:] {
				intermediates.AddCert(c)
			}
			_, err := cs.PeerCertificates[0].Verify(x509.VerifyOptions{
				Roots:         roots,
				Intermediates: intermediates,
				KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
			})
			if err != nil {
				return err
			}
			return checkID(cs.PeerCertificates[0], []string{server})
		},
	}
}

// PeerID returns the verified identity of the other end of a connection, or
// "" if it proved none.
func PeerID(cs *tls.ConnectionState) string {
	if cs == nil || len(cs.VerifiedChains) == 0 {
		return ""
	}
	return IDOf(cs.VerifiedChains[0][0])
}

// RequireClient wraps an HTTP handler so it answers only clients that
// proved an identity, for servers that let others in (ServerConfig with
// requireClient false) for their health checks.
func RequireClient(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if PeerID(r.TLS) == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":"client certificate required"}` + "\n"))
			return
		}
		next.ServeHTTP(w, r)
	})
}

type connStartKey struct{}

// ConnStart records when each connection was made, for LimitConnectionAge.
// Set it as the http.Server's ConnContext.
func ConnStart(ctx context.Context, _ net.Conn) context.Context {
	return context.WithValue(ctx, connStartKey{}, time.Now())
}

// LimitConnectionAge asks a client to reconnect once its connection is
// older than age, by answering with "Connection: close" (which HTTP/2
// turns into a GOAWAY, letting requests in flight finish). Certificates
// are checked only in the handshake, and a busy client never needs a new
// one: without this, a connection made with a certificate since replaced,
// or expired, would carry on for as long as the traffic did. gRPC has the
// same setting built in (MaxConnectionAge).
func LimitConnectionAge(next http.Handler, age time.Duration) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if start, ok := r.Context().Value(connStartKey{}).(time.Time); ok && time.Since(start) > age {
			w.Header().Set("Connection", "close")
		}
		next.ServeHTTP(w, r)
	})
}
~~~

This file is the heart of the step. Read it in four parts.
- **`Source`** holds the certificate and the CAs to trust, and re-reads them when the files change, checking at most once a second. A reload that fails keeps the old ones (a half-written Secret must not take the service down) and logs the failure once.
- **`ServerConfig`** builds a fresh TLS config for every connection with `GetConfigForClient`, so each handshake uses the files as they are now. Go checks the client's chain to our CA; `VerifyPeerCertificate` then checks the identity in it. With `requireClient` false, a client *may* come without a certificate (the kubelet's probes, Prometheus) and `RequireClient` lets each handler decide; a client that does present one must pass every check.
- **`ClientConfig`** is the subtle one. Go's client checks the server's *host name* against the certificate. We want to check its *identity* instead. So it turns Go's check off with `InsecureSkipVerify`, and then does the whole job itself in `VerifyConnection`: the chain to our CA, the dates, the key usage, then the identity. `InsecureSkipVerify` on its own is the most common TLS bug there is, because it accepts anyone. With the check written out in full, it's correct.
- **`LimitConnectionAge`**, and why it exists, comes from the cluster test below.

Test it. Create `internal/pki/pki_test.go`:

<!-- file: internal/pki/pki_test.go -->
~~~go
package pki

import (
	"bytes"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"log"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// issue writes a certificate for service, from ca, to a new directory, with
// bundle as the CAs it trusts.
func issue(t *testing.T, ca *CA, service string, validity time.Duration, bundle ...*x509.Certificate) string {
	t.Helper()
	leaf, err := ca.Issue(service, []string{"localhost"}, time.Now(), validity)
	if err != nil {
		t.Fatal(err)
	}
	if len(bundle) == 0 {
		bundle = []*x509.Certificate{ca.Cert}
	}
	dir := t.TempDir()
	if err := leaf.Save(dir, bundle); err != nil {
		t.Fatal(err)
	}
	return dir
}

func source(t *testing.T, dir string) *Source {
	t.Helper()
	s, err := NewSource(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func newCA(t *testing.T) *CA {
	t.Helper()
	ca, err := NewCA("Runway test CA", time.Now(), 24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	return ca
}

// server starts an HTTPS server that answers with the caller's identity.
func server(t *testing.T, src *Source, requireClient bool, allowed ...string) *httptest.Server {
	t.Helper()
	s := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, PeerID(r.TLS))
	}))
	s.TLS = ServerConfig(src, requireClient, allowed...)
	s.Config.ErrorLog = log.New(io.Discard, "", 0) // refused handshakes are expected
	s.StartTLS()
	t.Cleanup(s.Close)
	return s
}

func get(src *Source, serverID, url string) (string, error) {
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: ClientConfig(src, serverID)}}
	resp, err := client.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	return string(body), err
}

func TestMutualTLSNamesBothEnds(t *testing.T) {
	ca := newCA(t)
	api := source(t, issue(t, ca, "api", time.Hour))
	gateway := source(t, issue(t, ca, "gateway", time.Hour))
	s := server(t, api, true, ID("gateway"))
	got, err := get(gateway, ID("api"), s.URL)
	if err != nil || got != "spiffe://runway/gateway" {
		t.Fatalf("got %q, %v; the server should see the gateway", got, err)
	}
}

func TestTheWrongPeerIsRefused(t *testing.T) {
	ca := newCA(t)
	api := source(t, issue(t, ca, "api", time.Hour))
	worker := source(t, issue(t, ca, "worker", time.Hour))
	s := server(t, api, true, ID("gateway"))

	// A real certificate from our CA, but for a service the API doesn't
	// accept: refused by the server.
	if _, err := get(worker, ID("api"), s.URL); err == nil {
		t.Fatal("the worker was let in")
	}
	// The client refuses a server that isn't the one it wanted, even with
	// a good certificate: talking to the wrong service is as bad as
	// talking to an impostor.
	gateway := source(t, issue(t, ca, "gateway", time.Hour))
	if _, err := get(gateway, ID("metad"), s.URL); !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("got %v, want ErrNotAllowed", err)
	}
}

func TestAnotherCAIsNotTrusted(t *testing.T) {
	ours, theirs := newCA(t), newCA(t)
	api := source(t, issue(t, ours, "api", time.Hour))
	impostor := source(t, issue(t, theirs, "gateway", time.Hour, ours.Cert)) // trusts ours, signed by theirs
	s := server(t, api, true, ID("gateway"))
	if _, err := get(impostor, ID("api"), s.URL); err == nil {
		t.Fatal("a certificate from another CA was accepted")
	}
	// And the other way round: the client won't trust a server from
	// another CA, though it names the right service.
	fake := source(t, issue(t, theirs, "api", time.Hour, ours.Cert)) // and it lets our clients in
	gateway := source(t, issue(t, ours, "gateway", time.Hour))
	s2 := server(t, fake, true, ID("gateway"))
	_, err := get(gateway, ID("api"), s2.URL)
	if err == nil || !strings.Contains(err.Error(), "unknown authority") {
		t.Fatalf("got %v, want an unknown authority", err)
	}
}

func TestAnExpiredCertificateIsRefused(t *testing.T) {
	ca := newCA(t)
	api := source(t, issue(t, ca, "api", time.Hour))
	old := source(t, issue(t, ca, "gateway", -30*time.Second)) // expired half a minute ago
	s := server(t, api, true, ID("gateway"))
	if _, err := get(old, ID("api"), s.URL); err == nil {
		t.Fatal("an expired certificate was accepted")
	}
}

func TestOptionalClientCertificates(t *testing.T) {
	ca := newCA(t)
	api := source(t, issue(t, ca, "api", time.Hour))
	s := httptest.NewUnstartedServer(nil)
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") })
	mux.Handle("/jobs", RequireClient(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {})))
	s.Config.Handler = mux
	s.TLS = ServerConfig(api, false, ID("gateway"))
	s.StartTLS()
	defer s.Close()

	// A client with no certificate (a health check) that trusts our CA.
	roots := x509.NewCertPool()
	roots.AddCert(ca.Cert)
	anon := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, ServerName: "localhost"}}}
	for path, want := range map[string]int{"/health": 200, "/jobs": 403} {
		resp, err := anon.Get(s.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != want {
			t.Errorf("%s without a certificate: %d, want %d", path, resp.StatusCode, want)
		}
	}
}

// A new certificate is used without a restart: write it over the old one,
// and within a second or so the server presents it.
func TestCertificatesAreReloaded(t *testing.T) {
	ca := newCA(t)
	dir := issue(t, ca, "api", time.Hour)
	api := source(t, dir)
	first := api.Certificate().SerialNumber
	s := server(t, api, true, ID("gateway"))
	gateway := source(t, issue(t, ca, "gateway", time.Hour))

	leaf, _ := ca.Issue("api", []string{"localhost"}, time.Now(), time.Hour)
	time.Sleep(10 * time.Millisecond) // a later modification time
	if err := leaf.Save(dir, []*x509.Certificate{ca.Cert}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * recheck)
	for api.Certificate().SerialNumber.Cmp(first) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the new certificate was not picked up")
		}
		time.Sleep(100 * time.Millisecond)
	}
	if _, err := get(gateway, ID("api"), s.URL); err != nil {
		t.Fatalf("after the reload: %v", err)
	}
}

// lockedBuffer is a log destination tests can read while servers write.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// A broken update (here, a certificate file that isn't one) is reported,
// once, and the old certificate stays in use: the service keeps working
// while someone fixes it.
func TestABadUpdateKeepsTheOldCertificate(t *testing.T) {
	ca := newCA(t)
	dir := issue(t, ca, "api", time.Hour)
	var logs lockedBuffer
	api, err := NewSource(dir, slog.New(slog.NewTextHandler(&logs, nil)))
	if err != nil {
		t.Fatal(err)
	}
	s := server(t, api, true, ID("gateway"))
	gateway := source(t, issue(t, ca, "gateway", time.Hour))

	time.Sleep(10 * time.Millisecond) // a later modification time
	if err := os.WriteFile(filepath.Join(dir, CertFile), []byte("half a certificate"), 0o644); err != nil {
		t.Fatal(err)
	}
	for range 3 { // three checks, a recheck apart
		time.Sleep(recheck + 100*time.Millisecond)
		if _, err := get(gateway, ID("api"), s.URL); err != nil {
			t.Fatalf("after a bad update: %v", err)
		}
	}
	if n := strings.Count(logs.String(), "reloading the certificate failed"); n != 1 {
		t.Fatalf("%d warnings, want 1:\n%s", n, logs.String())
	}
}

// Replacing the CA: for a while, everyone trusts both, so certificates from
// either work, whichever end has been updated.
func TestCARotationWithABundle(t *testing.T) {
	old, next := newCA(t), newCA(t)
	both := []*x509.Certificate{old.Cert, next.Cert}
	api := source(t, issue(t, old, "api", time.Hour, both...))          // not yet reissued
	gateway := source(t, issue(t, next, "gateway", time.Hour, both...)) // already on the new CA
	s := server(t, api, true, ID("gateway"))
	if _, err := get(gateway, ID("api"), s.URL); err != nil {
		t.Fatalf("old and new CA, both trusted: %v", err)
	}
}

// The CA may only vouch for Runway names: a certificate it signed for
// another trust domain fails verification, even made with its own key.
func TestTheCAIsLimitedToRunwayNames(t *testing.T) {
	ca := newCA(t)
	key, _ := newKey()
	other, _ := url.Parse("spiffe://evil/api")
	sn, _ := serial()
	tmpl := &x509.Certificate{
		SerialNumber: sn, URIs: []*url.URL{other},
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour),
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.Cert, key.Public(), ca.Key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	roots := x509.NewCertPool()
	roots.AddCert(ca.Cert)
	_, err = cert.Verify(x509.VerifyOptions{Roots: roots, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}})
	if err == nil || !strings.Contains(err.Error(), "not permitted") {
		t.Fatalf("got %v, want a name constraint violation", err)
	}
}

func TestCAFilesRoundTrip(t *testing.T) {
	ca := newCA(t)
	dir := t.TempDir()
	if err := ca.Save(dir); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(filepath.Join(dir, KeyFile))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("key file mode %v, want 0600", info.Mode().Perm())
	}
	back, err := LoadCA(dir)
	if err != nil || !back.Cert.Equal(ca.Cert) {
		t.Fatalf("LoadCA: %v", err)
	}
	if _, err := back.Issue("api", nil, time.Now(), time.Hour); err != nil {
		t.Fatalf("issue with the loaded CA: %v", err)
	}
}

// A busy client keeps its connection, and with it the certificates checked
// when it was made. LimitConnectionAge makes it reconnect, over HTTP/2 as
// the gateway speaks it, so a new handshake checks the certificates in use
// now.
func TestOldConnectionsAreClosed(t *testing.T) {
	ca := newCA(t)
	api := source(t, issue(t, ca, "api", time.Hour))
	gateway := source(t, issue(t, ca, "gateway", time.Hour))
	var conns atomic.Int32
	s := httptest.NewUnstartedServer(LimitConnectionAge(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, r.Proto)
	}), 100*time.Millisecond))
	s.TLS = ServerConfig(api, true, ID("gateway"))
	s.EnableHTTP2 = true
	s.Config.ConnContext = ConnStart
	s.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			conns.Add(1)
		}
	}
	s.StartTLS()
	defer s.Close()
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: ClientConfig(gateway, ID("api")), ForceAttemptHTTP2: true}}
	get := func() string {
		t.Helper()
		resp, err := client.Get(s.URL)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return string(body)
	}

	if proto := get(); proto != "HTTP/2.0" {
		t.Fatalf("spoke %s, want HTTP/2.0", proto)
	}
	get()
	if n := conns.Load(); n != 1 {
		t.Fatalf("%d connections for two quick requests, want 1", n)
	}
	time.Sleep(150 * time.Millisecond)
	get() // answered, with a GOAWAY
	get() // so this one needs a new connection
	// (At least 2: on a slow machine the new one can grow old too.)
	if n := conns.Load(); n < 2 {
		t.Fatalf("%d connection(s) after the first grew old, want a new one", n)
	}
}
~~~

The tests make real TLS connections over loopback: the right peer, the wrong peer, another CA, an expired certificate, a missing one, a reload, a bad update, a CA rotation with both CAs in the bundle, and a CA trying to sign outside its name constraint.

<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/pki/ && go test -race -count=1 ./internal/pki/ -->

**Break it.** In `ClientConfig`, replace the last line of `VerifyConnection` (`return checkID(...)`) with `return nil`, so the chain is checked but not the identity:

~~~text
    pki_test.go:112: got <nil>, want ErrNotAllowed
~~~

A client now accepts *any* service with a certificate from our CA as the API. Remember this one: it comes back below, in a test where it lets a compromised worker hand out signing keys.

### A tool to run the CA

Create `cmd/ca/main.go`:

<!-- file: cmd/ca/main.go -->
~~~go
// Command ca is Runway's certificate authority (Phase 6, step 7).
//
//	ca init DIR                       make a new CA in DIR (valid a year)
//	ca issue [flags] CADIR SERVICE OUT  issue SERVICE a certificate, into OUT
//
// issue writes tls.crt, tls.key and ca.crt to OUT, ready for
//
//	kubectl create secret generic tls-SERVICE --from-file=OUT
//
// Flags for issue:
//
//	-dns NAMES    host names it serves, comma-separated (for clients that
//	              check names; Runway's own clients check the identity)
//	-ttl 24h      how long it is valid
//	-trust FILE   another CA certificate to trust as well, while replacing
//	              the CA (repeatable)
package main

import (
	"crypto/x509"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"runway/internal/pki"
)

func main() {
	if err := run(os.Args[1:], os.Stdout, time.Now()); err != nil {
		fmt.Fprintln(os.Stderr, "ca:", err)
		os.Exit(1)
	}
}

type files []string

func (f *files) String() string     { return strings.Join(*f, ",") }
func (f *files) Set(v string) error { *f = append(*f, v); return nil }

func run(args []string, stdout io.Writer, now time.Time) error {
	if len(args) == 0 {
		return errors.New("usage: ca init DIR | ca issue [-dns NAMES] [-ttl D] [-trust FILE] CADIR SERVICE OUT")
	}
	switch args[0] {
	case "init":
		if len(args) != 2 {
			return errors.New("usage: ca init DIR")
		}
		if _, err := os.Stat(args[1] + "/" + pki.KeyFile); err == nil {
			return fmt.Errorf("%s already holds a CA; replacing it is a rotation, not an init", args[1])
		}
		ca, err := pki.NewCA("Runway CA "+now.UTC().Format("2006-01-02"), now, 365*24*time.Hour)
		if err != nil {
			return err
		}
		if err := ca.Save(args[1]); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "CA %q in %s, valid until %s\n", ca.Cert.Subject.CommonName, args[1], ca.Cert.NotAfter.UTC().Format(time.DateOnly))
		return nil
	case "issue":
		fs := flag.NewFlagSet("issue", flag.ContinueOnError)
		dns := fs.String("dns", "", "host names, comma-separated")
		ttl := fs.Duration("ttl", 24*time.Hour, "validity")
		var trust files
		fs.Var(&trust, "trust", "another CA certificate to trust (repeatable)")
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		if fs.NArg() != 3 {
			return errors.New("usage: ca issue [flags] CADIR SERVICE OUT")
		}
		ca, err := pki.LoadCA(fs.Arg(0))
		if err != nil {
			return err
		}
		var names []string
		if *dns != "" {
			names = strings.Split(*dns, ",")
		}
		leaf, err := ca.Issue(fs.Arg(1), names, now, *ttl)
		if err != nil {
			return err
		}
		bundle := []*x509.Certificate{ca.Cert}
		for _, path := range trust {
			certs, err := readPEM(path)
			if err != nil {
				return err
			}
			bundle = append(bundle, certs...)
		}
		if err := leaf.Save(fs.Arg(2), bundle); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "%s: serial %x, valid until %s, trusting %d CA(s)\n",
			pki.IDOf(leaf.Cert), leaf.Cert.SerialNumber, leaf.Cert.NotAfter.UTC().Format(time.RFC3339), len(bundle))
		return nil
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func readPEM(path string) ([]*x509.Certificate, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var certs []*x509.Certificate
	for block, rest := pem.Decode(data); block != nil; block, rest = pem.Decode(rest) {
		c, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		certs = append(certs, c)
	}
	if len(certs) == 0 {
		return nil, fmt.Errorf("%s: no certificates", path)
	}
	return certs, nil
}
~~~

Create `cmd/ca/main_test.go`:

<!-- file: cmd/ca/main_test.go -->
~~~go
package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"runway/internal/pki"
)

func TestInitThenIssue(t *testing.T) {
	dir := t.TempDir()
	caDir, out := filepath.Join(dir, "ca"), filepath.Join(dir, "api")
	now := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	var stdout bytes.Buffer
	if err := run([]string{"init", caDir}, &stdout, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"init", caDir}, &stdout, now); err == nil {
		t.Fatal("init over an existing CA succeeded")
	}
	if err := run([]string{"issue", "-dns", "api,api.runway", "-ttl", "1h", caDir, "api", out}, &stdout, now); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stdout.String(), "spiffe://runway/api: serial") || !strings.Contains(stdout.String(), "2026-10-09T13:00:00Z") {
		t.Fatalf("output %q", stdout.String())
	}
	src, err := pki.NewSource(out, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := src.Certificate().DNSNames; len(got) != 2 {
		t.Fatalf("DNS names %v", got)
	}
}

// While replacing the CA, a certificate is issued trusting both.
func TestIssueTrustingAnotherCA(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for _, d := range []string{"old", "new"} {
		if err := run([]string{"init", filepath.Join(dir, d)}, &bytes.Buffer{}, now); err != nil {
			t.Fatal(err)
		}
	}
	var stdout bytes.Buffer
	err := run([]string{"issue", "-trust", filepath.Join(dir, "old", pki.CertFile), filepath.Join(dir, "new"), "api", filepath.Join(dir, "api")}, &stdout, now)
	if err != nil || !strings.Contains(stdout.String(), "trusting 2 CA(s)") {
		t.Fatalf("%q, %v", stdout.String(), err)
	}
}
~~~

And a script that issues every service a certificate and stores each one in the cluster as `tls-SERVICE`. Create `deploy/certs.sh`:

<!-- file: deploy/certs.sh -->
~~~bash
#!/usr/bin/env bash
# Issue every Runway service a certificate from the CA in CADIR (made with
# "go run ./cmd/ca init CADIR"), and store each in the cluster as the
# Secret tls-SERVICE, which the service's Pods mount (Phase 6, step 7).
# The operator's certificate, for curl and jobsctl, goes to CADIR/operator.
#
#   deploy/certs.sh CADIR [TTL]
#
# Run it again before the certificates expire (TTL, a day by default): the
# kubelet updates the mounted Secrets, and the services pick up the new
# files without restarting. While replacing the CA, set TRUST to the other
# CA's certificate, so both are trusted (see the guide).
set -euo pipefail
ca=${1:?usage: deploy/certs.sh CADIR [TTL]}
ttl=${2:-24h}
trust=()
if [[ -n ${TRUST:-} ]]; then trust=(-trust "$TRUST"); fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
go build -o "$work/ca" ./cmd/ca

# The DNS names are for clients that check names, such as curl. Runway's own
# clients check the spiffe://runway/... identity instead.
declare -A dns=(
  [api]=api,api.runway,api.runway.svc,api-pods.runway
  [gateway]=""
  [idp]=idp,idp.runway,idp.runway.svc
  [metad]="metad.runway,*.metad.runway,*.metad.runway.svc"
)
for service in api gateway idp metad; do
  "$work/ca" issue -dns "${dns[$service]}" -ttl "$ttl" "${trust[@]}" "$ca" "$service" "$work/$service"
  # Server-side apply: a client-side "kubectl apply" would also copy the
  # private key into an annotation on the Secret.
  kubectl -n runway create secret generic "tls-$service" --from-file="$work/$service" \
    --dry-run=client -o yaml | kubectl apply --server-side --field-manager=certs -f - >/dev/null
done
"$work/ca" issue -ttl "$ttl" "${trust[@]}" "$ca" operator "$ca/operator"
~~~

It uses server-side apply because client-side `kubectl apply` would also copy the whole object, private key included, into an annotation on the Secret.

### The API

In `cmd/api/main.go`: TLS on both listeners, mutual TLS required for job routes and every RPC, and the issuer's keys fetched only from a server that proves it's `spiffe://runway/idp`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
~~~

to:

~~~go
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/reflection"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/pgstore"
	"runway/internal/rabbit"
~~~

to:

~~~go
	"runway/internal/pgstore"
	"runway/internal/pki"
	"runway/internal/rabbit"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	WebhookAllowHosts []string
}
~~~

to:

~~~go
	WebhookAllowHosts []string
	// Step 7: with TLSDir, both listeners use TLS with the certificate in
	// it, and only TLSClients (identities) may call the job routes and RPCs.
	TLSDir     string
	TLSClients []string
	// TLSMaxConnAge: how long a client may keep one connection before it
	// must reconnect, and so present its certificate again.
	TLSMaxConnAge time.Duration
	// AuthIssuerID is the identity the issuer must prove when the API
	// fetches its keys, if it is one of ours (spiffe://runway/idp).
	AuthIssuerID string
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		cfg.RateLimit = &quotas
	}
~~~

to:

~~~go
		cfg.RateLimit = &quotas
	}
	cfg.TLSDir, cfg.AuthIssuerID = getenv("TLS_DIR"), getenv("AUTH_ISSUER_ID")
	cfg.TLSClients = []string{pki.ID("gateway"), pki.ID("operator")}
	if clients := getenv("TLS_CLIENTS"); clients != "" {
		cfg.TLSClients = strings.Split(clients, ",")
	}
	if cfg.AuthIssuerID != "" && cfg.TLSDir == "" {
		return config{}, errors.New("AUTH_ISSUER_ID needs TLS_DIR: the API's certificate and the CAs it trusts")
	}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		cfg.WebhookAllowHosts = strings.Split(hosts, ",")
	}
~~~

to:

~~~go
		cfg.WebhookAllowHosts = strings.Split(hosts, ",")
	}
	if cfg.TLSMaxConnAge, err = envconfig.Duration(getenv, "TLS_MAX_CONNECTION_AGE", 10*time.Minute); err != nil {
		return config{}, err
	}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	// the circuit breaker answers 503 at once, which tells clients more.
	var unary []grpc.UnaryServerInterceptor
	var stream []grpc.StreamServerInterceptor
	// Authorization (step 3): the policy decides, every handler enforces.
~~~

to:

~~~go
	// the circuit breaker answers 503 at once, which tells clients more.
	var tlsSource *pki.Source
	if cfg.TLSDir != "" {
		if tlsSource, err = pki.NewSource(cfg.TLSDir, logger); err != nil {
			return fmt.Errorf("TLS_DIR: %w", err)
		}
	}
	var unary []grpc.UnaryServerInterceptor
	var stream []grpc.StreamServerInterceptor
	var authenticate func(http.Handler) http.Handler
	// Authorization (step 3): the policy decides, every handler enforces.
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		logger.Warn("authentication is off (AUTH_MODE=off): anyone can call this API, as tenant dev")
		options = append(options, httpapi.WithAuthentication(func(next http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
~~~

to:

~~~go
		logger.Warn("authentication is off (AUTH_MODE=off): anyone can call this API, as tenant dev")
		authenticate = func(next http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
			})
		}))
		unary = append(unary, func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
~~~

to:

~~~go
			})
		}
		unary = append(unary, func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		})
		verifier := auth.Verifier{
~~~

to:

~~~go
		})
		keys := &auth.RemoteJWKS{URL: cfg.AuthJWKSURL, MinRefresh: 30 * time.Second}
		// Whoever can answer for the issuer can sign any tenant's tokens, so
		// the keys must come from the real one (step 7). With AuthIssuerID,
		// it must prove it is that service, with a certificate from our CA.
		// Without it, an https issuer is checked against the public CAs,
		// like any website: that is how Dex, Cognito or Auth0 would be.
		if cfg.AuthIssuerID != "" {
			keys.Client = &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
				TLSClientConfig: pki.ClientConfig(tlsSource, cfg.AuthIssuerID),
			}}
		} else if !strings.HasPrefix(cfg.AuthJWKSURL, "https://") {
			logger.Warn("the issuer's keys are fetched over plain HTTP: anyone on the path could replace them", "url", cfg.AuthJWKSURL)
		}
		verifier := auth.Verifier{
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
			Keys:     &auth.RemoteJWKS{URL: cfg.AuthJWKSURL, MinRefresh: 30 * time.Second},
~~~

to:

~~~go
			Keys:     keys,
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		}
		options = append(options, httpapi.WithAuthentication(func(next http.Handler) http.Handler {
			return auth.Require(verifier, logger, next)
		}))
		unary = append(unary, auth.UnaryInterceptor(verifier, logger))
~~~

to:

~~~go
		}
		authenticate = func(next http.Handler) http.Handler {
			return auth.Require(verifier, logger, next)
		}
		unary = append(unary, auth.UnaryInterceptor(verifier, logger))
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	}
	if cfg.RateLimit != nil {
~~~

to:

~~~go
	}
	if tlsSource != nil {
		// Two layers (step 7): the certificate says which service is
		// calling, the token which tenant it calls for. The job routes need
		// both; health checks and metrics need neither.
		user := authenticate
		authenticate = func(next http.Handler) http.Handler { return pki.RequireClient(user(next)) }
		logger.Info("mutual TLS", "id", pki.IDOf(tlsSource.Certificate()), "clients", strings.Join(cfg.TLSClients, ","))
	}
	options = append(options, httpapi.WithAuthentication(authenticate))
	if cfg.RateLimit != nil {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	grpcOptions := []grpc.ServerOption{grpc.ChainUnaryInterceptor(unary...), grpc.ChainStreamInterceptor(stream...)}
	handler := httpapi.NewHandler(service, options...)
~~~

to:

~~~go
	grpcOptions := []grpc.ServerOption{grpc.ChainUnaryInterceptor(unary...), grpc.ChainStreamInterceptor(stream...)}
	if tlsSource != nil {
		// gRPC has no health checks to let in: every caller needs a
		// certificate.
		grpcOptions = append(grpcOptions, grpc.Creds(credentials.NewTLS(pki.ServerConfig(tlsSource, true, cfg.TLSClients...))),
			// A certificate is checked once, in the handshake. A connection
			// made with one carries on after it is replaced, or even
			// expires, so close each after a while: the client reconnects,
			// and the new handshake checks the certificates in use now.
			grpc.KeepaliveParams(keepalive.ServerParameters{MaxConnectionAge: cfg.TLSMaxConnAge, MaxConnectionAgeGrace: 30 * time.Second}))
	}
	handler := httpapi.NewHandler(service, options...)
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		IdleTimeout:       60 * time.Second,
	}
~~~

to:

~~~go
		IdleTimeout:       60 * time.Second,
	}
	if tlsSource != nil {
		server.TLSConfig = pki.ServerConfig(tlsSource, false, cfg.TLSClients...)
		// The same for HTTP: the gateway, always busy, would otherwise keep
		// its first connections, and their certificates, for good.
		server.ConnContext = pki.ConnStart
		server.Handler = pki.LimitConnectionAge(server.Handler, cfg.TLSMaxConnAge)
		// Refused handshakes are logged by the server itself; into the
		// JSON log with everything else, not plain text on stderr.
		server.ErrorLog = slog.NewLogLogger(logger.Handler(), slog.LevelWarn)
	}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	go func() { serveErr <- server.Serve(listener) }()
~~~

to:

~~~go
	go func() {
		if server.TLSConfig != nil {
			serveErr <- server.ServeTLS(listener, "", "")
			return
		}
		serveErr <- server.Serve(listener)
	}()
~~~


Two layers now guard a job route, and they answer different questions: the certificate says *which service* is calling (the gateway, or an operator), the token says *which tenant* it's calling for. Health checks and metrics need neither.

And look at `AuthIssuerID`. Whoever can answer at the issuer's URL can serve any keys they like, and so sign tokens for any tenant. With plain HTTP, any Pod that could get between the API and the issuer, or answer for `idp.runway`, would own every tenant. Create `cmd/api/tls_test.go`:

<!-- file: cmd/api/tls_test.go -->
~~~go
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"

	"runway/internal/auth"
	"runway/internal/grpcapi/jobsv1"
	"runway/internal/pki"
)

// certs makes a CA and a certificate for each service, in dir/SERVICE.
func certs(t *testing.T, dir string, services ...string) *pki.CA {
	t.Helper()
	ca, err := pki.NewCA("test", time.Now(), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range services {
		leaf, err := ca.Issue(s, []string{"localhost"}, time.Now(), time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		if err := leaf.Save(filepath.Join(dir, s), []*x509.Certificate{ca.Cert}); err != nil {
			t.Fatal(err)
		}
	}
	return ca
}

func freePort(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().String()
}

func TestMutualTLS(t *testing.T) {
	dir := t.TempDir()
	ca := certs(t, dir, "api", "gateway", "operator", "worker")
	grpcAddr := freePort(t)
	base, _, _, _ := startServer(t, map[string]string{"TLS_DIR": filepath.Join(dir, "api"), "GRPC_ADDR": grpcAddr})
	base = strings.Replace(base, "http://", "https://", 1)

	client := func(service string) *http.Client {
		if service == "" { // trusts the CA, but has no certificate: a health check
			roots := x509.NewCertPool()
			roots.AddCert(ca.Cert)
			return &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, ServerName: "localhost"}}}
		}
		src, err := pki.NewSource(filepath.Join(dir, service), nil)
		if err != nil {
			t.Fatal(err)
		}
		return &http.Client{Transport: &http.Transport{TLSClientConfig: pki.ClientConfig(src, pki.ID("api"))}}
	}
	post := func(c *http.Client) (int, error) {
		resp, err := c.Post(base+"/jobs", "application/json", strings.NewReader(`{"description":"x"}`))
		if err != nil {
			return 0, err
		}
		resp.Body.Close()
		return resp.StatusCode, nil
	}

	if resp, err := client("").Get(base + "/health"); err != nil || resp.StatusCode != 200 {
		t.Fatalf("/health without a certificate: %v %v", resp, err)
	}
	if code, err := post(client("")); err != nil || code != http.StatusForbidden {
		t.Fatalf("POST /jobs without a certificate: %d %v, want 403", code, err)
	}
	if code, err := post(client("gateway")); err != nil || code != http.StatusCreated {
		t.Fatalf("POST /jobs as the gateway: %d %v, want 201", code, err)
	}
	if _, err := post(client("worker")); err == nil {
		t.Fatal("the worker, not an allowed client, got through")
	}
	if resp, err := http.Get(strings.Replace(base, "https://", "http://", 1) + "/health"); err == nil {
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("plain HTTP: %d, want 400", resp.StatusCode)
		}
	}

	// gRPC: the operator gets in; a caller without a certificate doesn't.
	src, _ := pki.NewSource(filepath.Join(dir, "operator"), nil)
	conn, err := grpc.NewClient(grpcAddr, grpc.WithTransportCredentials(credentials.NewTLS(pki.ClientConfig(src, pki.ID("api")))))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := jobsv1.NewJobsClient(conn).CreateJob(ctx, &jobsv1.CreateJobRequest{Description: "x"}); err != nil {
		t.Fatalf("gRPC as the operator: %v", err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca.Cert)
	anon, _ := grpc.NewClient(grpcAddr, grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{RootCAs: roots, ServerName: "localhost"})))
	defer anon.Close()
	if _, err := jobsv1.NewJobsClient(anon).CreateJob(ctx, &jobsv1.CreateJobRequest{Description: "x"}); status.Code(err) != codes.Unavailable {
		t.Fatalf("gRPC without a certificate: %v, want the handshake refused", err)
	}
}

// Whoever answers for the issuer decides which tokens are good. A Pod with
// a certificate from our CA, but not the issuer's, that gets the API to
// fetch keys from it (a poisoned DNS answer, say) can't: the API checks it
// reached spiffe://runway/idp before believing the keys.
func TestKeysComeOnlyFromTheIssuer(t *testing.T) {
	dir := t.TempDir()
	certs(t, dir, "api", "gateway", "idp", "worker")
	// Each publishes its own key and signs a token with it.
	issuer := func(service string) (url, token string) {
		key, err := auth.NewSigningKey(time.Now())
		if err != nil {
			t.Fatal(err)
		}
		src, err := pki.NewSource(filepath.Join(dir, service), nil)
		if err != nil {
			t.Fatal(err)
		}
		s := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_ = json.NewEncoder(w).Encode(auth.Publish([]auth.SigningKey{key}))
		}))
		s.TLS = pki.ServerConfig(src, false, pki.ID("api"))
		s.Config.ErrorLog = log.New(io.Discard, "", 0)
		s.StartTLS()
		t.Cleanup(s.Close)
		now := time.Now()
		token, err = auth.Sign(auth.Claims{
			Issuer: "https://idp.test", Subject: "acme-ci", Audience: auth.Audience{"runway"},
			IssuedAt: now.Unix(), Expiry: now.Add(time.Minute).Unix(), Tenant: "acme", Roles: []string{"submitter"},
		}, key)
		if err != nil {
			t.Fatal(err)
		}
		return s.URL + "/.well-known/jwks.json", token
	}
	gwSrc, err := pki.NewSource(filepath.Join(dir, "gateway"), nil)
	if err != nil {
		t.Fatal(err)
	}
	gateway := &http.Client{Transport: &http.Transport{TLSClientConfig: pki.ClientConfig(gwSrc, pki.ID("api"))}}

	for _, tc := range []struct {
		service string
		want    int
	}{{"idp", http.StatusCreated}, {"worker", http.StatusUnauthorized}} {
		jwks, token := issuer(tc.service)
		base, logs, _, _ := startServer(t, map[string]string{
			"TLS_DIR": filepath.Join(dir, "api"), "AUTH_MODE": "required", "AUTH_ISSUER": "https://idp.test",
			"AUTH_JWKS_URL": jwks, "AUTH_ISSUER_ID": pki.ID("idp"),
		})
		req, _ := http.NewRequest(http.MethodPost, strings.Replace(base, "http://", "https://", 1)+"/jobs", strings.NewReader(`{"description":"x"}`))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		resp, err := gateway.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != tc.want {
			t.Errorf("keys served by %s: %d, want %d", tc.service, resp.StatusCode, tc.want)
		}
		if tc.service == "worker" && !strings.Contains(logs.String(), "peer identity not allowed") {
			t.Errorf("the refusal should say why:\n%s", logs.String())
		}
	}
}
~~~

`TestKeysComeOnlyFromTheIssuer` stands up a fake issuer with a perfectly valid certificate from our CA, for the *worker*, as a compromised worker would have, and checks that the API won't take keys from it. Make the identity break from above again (`return nil` in `ClientConfig`), and:

~~~text
--- FAIL: TestKeysComeOnlyFromTheIssuer (0.05s)
    tls_test.go:183: keys served by worker: 201, want 401
~~~

A worker forged a token and created a job. Put the check back.

<!-- run: test -z "$(gofmt -l .)" && go vet ./cmd/api/ && go test -race -count=1 ./cmd/api/ -->

### The gateway

The gateway proves it's the gateway to the API, and checks it reached the API. In `internal/lb/proxy.go`:

Change:

<!-- edit: internal/lb/proxy.go -->
~~~go
	"context"
	"log/slog"
~~~

to:

~~~go
	"context"
	"crypto/tls"
	"log/slog"
~~~

Change:

<!-- edit: internal/lb/proxy.go -->
~~~go
	"strconv"

~~~

to:

~~~go
	"strconv"
	"time"

~~~

Change:

<!-- edit: internal/lb/proxy.go -->
~~~go
	requests *prometheus.CounterVec
}
~~~

to:

~~~go
	requests *prometheus.CounterVec
	scheme   string
}
~~~

Change:

<!-- edit: internal/lb/proxy.go -->
~~~go
		balancer: balancer,
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
~~~

to:

~~~go
		balancer: balancer,
		scheme:   "http",
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
~~~

Change:

<!-- edit: internal/lb/proxy.go -->
~~~go
			r.SetURL(&url.URL{Scheme: "http", Host: addr})
~~~

to:

~~~go
			r.SetURL(&url.URL{Scheme: p.scheme, Host: addr})
~~~

Change:

<!-- edit: internal/lb/proxy.go -->
~~~go
	return p
}
~~~

to:

~~~go
	return p
}

// UseTLS makes the proxy call backends over TLS, with config (Phase 6:
// pki.ClientConfig, so the gateway proves who it is, and checks it reached
// the API).
func (p *Proxy) UseTLS(config *tls.Config) {
	p.scheme = "https"
	p.proxy.Transport = &http.Transport{
		TLSClientConfig:     config,
		ForceAttemptHTTP2:   true,
		MaxIdleConnsPerHost: 32,
		IdleConnTimeout:     90 * time.Second,
	}
}
~~~


In `internal/lb/lb_test.go`:

Change:

<!-- edit: internal/lb/lb_test.go -->
~~~go
	"context"
	"io"
~~~

to:

~~~go
	"context"
	"crypto/x509"
	"io"
~~~

Change:

<!-- edit: internal/lb/lb_test.go -->
~~~go
	"net/http/httptest"
	"strings"
~~~

to:

~~~go
	"net/http/httptest"
	"path/filepath"
	"strings"
~~~

Change:

<!-- edit: internal/lb/lb_test.go -->
~~~go
	"time"
)
~~~

to:

~~~go
	"time"

	"runway/internal/pki"
)
~~~

Add this at the end of the file:

<!-- append: internal/lb/lb_test.go -->
~~~go
// With UseTLS, the proxy proves it is the gateway and checks it reached
// the API (Phase 6).
func TestProxyOverMutualTLS(t *testing.T) {
	dir := t.TempDir()
	ca, err := pki.NewCA("test", time.Now(), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{"api", "gateway"} {
		leaf, _ := ca.Issue(s, nil, time.Now(), time.Hour)
		if err := leaf.Save(filepath.Join(dir, s), []*x509.Certificate{ca.Cert}); err != nil {
			t.Fatal(err)
		}
	}
	apiSrc, _ := pki.NewSource(filepath.Join(dir, "api"), nil)
	backend := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, pki.PeerID(r.TLS))
	}))
	backend.TLS = pki.ServerConfig(apiSrc, true, pki.ID("gateway"))
	backend.StartTLS()
	defer backend.Close()

	b := New(Options{Policy: Random})
	b.SetBackends([]string{strings.TrimPrefix(backend.URL, "https://")})
	proxy := NewProxy(b, slog.New(slog.DiscardHandler))
	gwSrc, _ := pki.NewSource(filepath.Join(dir, "gateway"), nil)
	proxy.UseTLS(pki.ClientConfig(gwSrc, pki.ID("api")))
	front := httptest.NewServer(proxy)
	defer front.Close()
	resp, err := http.Get(front.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || string(body) != "spiffe://runway/gateway" {
		t.Fatalf("%d %q: the API should see the gateway", resp.StatusCode, body)
	}
}
~~~


In `cmd/gateway/main.go`:

Change:

<!-- edit: cmd/gateway/main.go -->
~~~go
//	ADMIN_ADDR        /health and /metrics (default 127.0.0.1:8001)
package main
~~~

to:

~~~go
//	ADMIN_ADDR        /health and /metrics (default 127.0.0.1:8001)
//	UPSTREAM_TLS_DIR  the gateway's certificate, for mutual TLS to the API
//	UPSTREAM_ID       the identity the API must prove (default spiffe://runway/api)
package main
~~~

Change:

<!-- edit: cmd/gateway/main.go -->
~~~go
	"runway/internal/lb"
)
~~~

to:

~~~go
	"runway/internal/lb"
	"runway/internal/pki"
)
~~~

Change:

<!-- edit: cmd/gateway/main.go -->
~~~go
	proxy := lb.NewProxy(balancer, logger)

~~~

to:

~~~go
	proxy := lb.NewProxy(balancer, logger)
	// With UPSTREAM_TLS_DIR, the gateway calls the API over mutual TLS
	// (Phase 6): it proves it is the gateway, and checks that the other end
	// is UPSTREAM_ID.
	if dir := getenv("UPSTREAM_TLS_DIR"); dir != "" {
		src, err := pki.NewSource(dir, logger)
		if err != nil {
			return fmt.Errorf("UPSTREAM_TLS_DIR: %w", err)
		}
		upstreamID := getenv("UPSTREAM_ID")
		if upstreamID == "" {
			upstreamID = pki.ID("api")
		}
		proxy.UseTLS(pki.ClientConfig(src, upstreamID))
		logger.Info("mutual TLS to upstream", "id", pki.IDOf(src.Certificate()), "upstream_id", upstreamID)
	}

~~~


### metad

Members prove they're members, to each other and to clients. The Raft route takes only other members, the store and locks only the identities in `METAD_TLS_CLIENTS`. `/ready` and `/status` stay open for the kubelet's probes: they reveal who leads, but change nothing. In `internal/metad/metad.go`:

Change:

<!-- edit: internal/metad/metad.go -->
~~~go
import (
	"context"
~~~

to:

~~~go
import (
	"cmp"
	"context"
~~~

Change:

<!-- edit: internal/metad/metad.go -->
~~~go
	"net/http"
	"strconv"
~~~

to:

~~~go
	"net/http"
	"slices"
	"strconv"
~~~

Change:

<!-- edit: internal/metad/metad.go -->
~~~go
	"runway/internal/metastore"
	"runway/internal/raft"
~~~

to:

~~~go
	"runway/internal/metastore"
	"runway/internal/pki"
	"runway/internal/raft"
~~~

Change:

<!-- edit: internal/metad/metad.go -->
~~~go
	return mux
}
~~~

to:

~~~go
	return mux
}

// RequirePeers wraps a member's handler for mutual TLS (Phase 6): the Raft
// route takes only other members, and the store and locks only callers in
// clients. /ready and /status stay open, for the kubelet's probes, which
// have no certificate; they say who leads, but change nothing.
func RequirePeers(next http.Handler, clients ...string) http.Handler {
	member := pki.ID("metad")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := pki.PeerID(r.TLS)
		switch {
		case r.URL.Path == "/ready", r.URL.Path == "/status":
		case r.URL.Path == "/raft/message" && id != member,
			r.URL.Path != "/raft/message" && !slices.Contains(clients, id):
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "not allowed: " + cmp.Or(id, "no certificate")})
			return
		}
		next.ServeHTTP(w, r)
	})
}
~~~


The Raft transport takes a client, so it can be one that speaks mutual TLS. In `internal/raft/raftnode/transport.go`:

Change:

<!-- edit: internal/raft/raftnode/transport.go -->
~~~go
// NewHTTPTransport starts a sender for every peer in urls (by ID).
func NewHTTPTransport(urls map[raft.ID]string, logger *slog.Logger) *HTTPTransport {
~~~

to:

~~~go
// NewHTTPTransport starts a sender for every peer in urls (by ID), using
// client, or a plain one if it is nil. (Phase 6 passes one that speaks
// mutual TLS, so only members can talk to members.)
func NewHTTPTransport(urls map[raft.ID]string, client *http.Client, logger *slog.Logger) *HTTPTransport {
~~~

Change:

<!-- edit: internal/raft/raftnode/transport.go -->
~~~go
	client := &http.Client{Timeout: time.Second}
~~~

to:

~~~go
	if client == nil {
		client = &http.Client{Timeout: time.Second}
	}
~~~


In `cmd/metad/main.go`:

Change:

<!-- edit: cmd/metad/main.go -->
~~~go
//	               own METAD_PEERS entry
package main
~~~

to:

~~~go
//	               own METAD_PEERS entry
//	METAD_TLS_DIR  this member's certificate, for mutual TLS with the other
//	               members (whose METAD_PEERS URLs are then https) and its
//	               clients (Phase 6)
//	METAD_TLS_CLIENTS  the identities that may use the store and locks
//	               (default spiffe://runway/operator)
package main
~~~

Change:

<!-- edit: cmd/metad/main.go -->
~~~go
	"context"
	"errors"
~~~

to:

~~~go
	"context"
	"crypto/tls"
	"errors"
~~~

Change:

<!-- edit: cmd/metad/main.go -->
~~~go
	"runway/internal/metastore"
	"runway/internal/raft"
~~~

to:

~~~go
	"runway/internal/metastore"
	"runway/internal/pki"
	"runway/internal/raft"
~~~

Change:

<!-- edit: cmd/metad/main.go -->
~~~go
	slices.Sort(ids)
	node, err := raftnode.Start(raftnode.Config{
~~~

to:

~~~go
	slices.Sort(ids)

	// With METAD_TLS_DIR, every member proves it is a member, to the others
	// and to its clients. Without it, anyone who can reach the port can
	// send Raft messages: vote, or append entries as a leader.
	handler := func(h http.Handler) http.Handler { return h }
	var peerClient *http.Client
	var tlsConfig *tls.Config
	if tlsDir := getenv("METAD_TLS_DIR"); tlsDir != "" {
		src, err := pki.NewSource(tlsDir, logger)
		if err != nil {
			return fmt.Errorf("METAD_TLS_DIR: %w", err)
		}
		clients := []string{pki.ID("operator")}
		if v := getenv("METAD_TLS_CLIENTS"); v != "" {
			clients = strings.Split(v, ",")
		}
		peerClient = &http.Client{Timeout: time.Second, Transport: &http.Transport{
			TLSClientConfig: pki.ClientConfig(src, pki.ID("metad")),
		}}
		tlsConfig = pki.ServerConfig(src, false, append(clients, pki.ID("metad"))...)
		// Members talk all the time, so their connections would never end:
		// make them reconnect now and then, presenting their certificates
		// as they are now (see pki.LimitConnectionAge).
		handler = func(h http.Handler) http.Handler {
			return pki.LimitConnectionAge(metad.RequirePeers(h, clients...), 10*time.Minute)
		}
		logger.Info("mutual TLS", "id", pki.IDOf(src.Certificate()), "clients", strings.Join(clients, ","))
	}

	node, err := raftnode.Start(raftnode.Config{
~~~

Change:

<!-- edit: cmd/metad/main.go -->
~~~go
		Transport:     raftnode.NewHTTPTransport(others, logger),
~~~

to:

~~~go
		Transport:     raftnode.NewHTTPTransport(others, peerClient, logger),
~~~

Change:

<!-- edit: cmd/metad/main.go -->
~~~go
	server := &http.Server{Handler: metad.New(node, peers, 3*time.Second).Handler(), ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = server.Serve(listener) }()
~~~

to:

~~~go
	server := &http.Server{
		Handler:           handler(metad.New(node, peers, 3*time.Second).Handler()),
		ReadHeaderTimeout: 5 * time.Second,
		TLSConfig:         tlsConfig,
	}
	if tlsConfig != nil {
		server.ConnContext = pki.ConnStart
		// Refused handshakes go into the JSON log, as in the API.
		server.ErrorLog = slog.NewLogLogger(logger.Handler(), slog.LevelWarn)
	}
	go func() {
		if tlsConfig != nil {
			_ = server.ServeTLS(listener, "", "")
			return
		}
		_ = server.Serve(listener)
	}()
~~~


The test is the intruder's attack, made by every identity. In `internal/metad/metad_test.go`:

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go
import (
	"encoding/json"
~~~

to:

~~~go
import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
~~~

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go
	"io"
	"log/slog"
~~~

to:

~~~go
	"io"
	"log"
	"log/slog"
~~~

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go
	"net/http"
	"strings"
~~~

to:

~~~go
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
~~~

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go
	"runway/internal/metastore"
	"runway/internal/raft"
~~~

to:

~~~go
	"runway/internal/metastore"
	"runway/internal/pki"
	"runway/internal/raft"
~~~

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go
	t       *testing.T
	urls    map[raft.ID]string
~~~

to:

~~~go
	t       *testing.T
	certs   string // with mutual TLS: a directory of certificates, by service
	urls    map[raft.ID]string
~~~

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go
func newCluster(t *testing.T, size int) *cluster {
	c := &cluster{t: t, urls: map[raft.ID]string{}, dirs: map[raft.ID]string{}, members: map[raft.ID]*member{}}
~~~

to:

~~~go
func newCluster(t *testing.T, size int) *cluster { return newClusterIn(t, size, "") }

// newClusterIn starts a cluster whose members speak mutual TLS with the
// certificates in certs/metad, if certs isn't "".
func newClusterIn(t *testing.T, size int, certs string) *cluster {
	c := &cluster{t: t, certs: certs, urls: map[raft.ID]string{}, dirs: map[raft.ID]string{}, members: map[raft.ID]*member{}}
	scheme := "http://"
	if certs != "" {
		scheme = "https://"
	}
~~~

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go
		c.urls[id] = "http://" + l.Addr().String()
~~~

to:

~~~go
		c.urls[id] = scheme + l.Addr().String()
~~~

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	node, err := raftnode.Start(raftnode.Config{
~~~

to:

~~~go
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	var client *http.Client
	var src *pki.Source
	if c.certs != "" {
		var err error
		if src, err = pki.NewSource(filepath.Join(c.certs, "metad"), nil); err != nil {
			c.t.Fatal(err)
		}
		client = &http.Client{Timeout: time.Second, Transport: &http.Transport{TLSClientConfig: pki.ClientConfig(src, pki.ID("metad"))}}
	}
	node, err := raftnode.Start(raftnode.Config{
~~~

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go
		Machine: metastore.NewMachine(), Transport: raftnode.NewHTTPTransport(others, logger), Logger: logger,
~~~

to:

~~~go
		Machine: metastore.NewMachine(), Transport: raftnode.NewHTTPTransport(others, client, logger), Logger: logger,
~~~

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go
	go func() { _ = server.Serve(l) }()
~~~

to:

~~~go
	if src != nil {
		operator := pki.ID("operator")
		server.Handler = RequirePeers(server.Handler, operator)
		server.TLSConfig = pki.ServerConfig(src, false, operator, pki.ID("metad"))
		server.ErrorLog = log.New(io.Discard, "", 0)
		go func() { _ = server.ServeTLS(l, "", "") }()
	} else {
		go func() { _ = server.Serve(l) }()
	}
~~~

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go
	l, err := net.Listen("tcp", strings.TrimPrefix(c.urls[id], "http://"))
~~~

to:

~~~go
	u, _ := url.Parse(c.urls[id])
	l, err := net.Listen("tcp", u.Host)
~~~

Add this at the end of the file:

<!-- append: internal/metad/metad_test.go -->
~~~go
// With mutual TLS, only the operator may use the store, and only members
// may send Raft messages: a client with a good certificate still can't
// vote, or append entries as if it led (Phase 6).
func TestOnlyMembersSpeakRaft(t *testing.T) {
	dir := t.TempDir()
	ca, err := pki.NewCA("test", time.Now(), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{"metad", "operator", "worker"} {
		leaf, err := ca.Issue(s, nil, time.Now(), time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		if err := leaf.Save(filepath.Join(dir, s), []*x509.Certificate{ca.Cert}); err != nil {
			t.Fatal(err)
		}
	}
	c := newClusterIn(t, 3, dir)
	leader := c.leader() // the members elected one, so they reach each other

	client := func(service string) *http.Client {
		if service == "" { // trusts the CA, has no certificate: the kubelet
			roots := x509.NewCertPool()
			roots.AddCert(ca.Cert)
			return &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, InsecureSkipVerify: true}}}
		}
		src, err := pki.NewSource(filepath.Join(dir, service), nil)
		if err != nil {
			t.Fatal(err)
		}
		return &http.Client{Transport: &http.Transport{TLSClientConfig: pki.ClientConfig(src, pki.ID("metad"))}}
	}
	call := func(c *http.Client, method, url, body string) int {
		t.Helper()
		req, _ := http.NewRequest(method, url, strings.NewReader(body))
		resp, err := c.Do(req)
		if err != nil {
			return 0 // refused in the handshake
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	base := c.urls[leader]
	// A vote request in a later term: a leader that took it would step down.
	vote := fmt.Sprintf(`{"Type":%d,"From":%d,"To":%d,"Term":99}`, raft.MsgVote, leader%3+1, leader)
	for _, tc := range []struct {
		who, method, path, body string
		want                    int
	}{
		{"operator", http.MethodPut, "/kv/k", "v", http.StatusOK},
		{"operator", http.MethodPost, "/raft/message", vote, http.StatusForbidden},
		{"metad", http.MethodPost, "/raft/message", "not json", http.StatusBadRequest}, // let in, then refused as a bad message
		{"worker", http.MethodGet, "/kv/k", "", 0},                                     // not an identity metad accepts
		{"", http.MethodGet, "/kv/k", "", http.StatusForbidden},
		{"", http.MethodGet, "/ready", "", http.StatusOK},
		{"", http.MethodGet, "/status", "", http.StatusOK},
	} {
		if got := call(client(tc.who), tc.method, base+tc.path, tc.body); got != tc.want {
			t.Errorf("%q %s %s = %d, want %d", tc.who, tc.method, tc.path, got, tc.want)
		}
	}
	if st := c.members[leader].node.Status(); st.Role != raft.Leader {
		t.Fatalf("member %d is %s after the refused vote", leader, st.Role)
	}
}
~~~


<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/metad/... ./internal/raft/... ./internal/lb/... ./cmd/metad/ ./cmd/gateway/ && go test -race -count=1 ./internal/metad/ ./internal/lb/ ./cmd/metad/ ./cmd/gateway/ -->

**Break it.** In `RequirePeers`, let any certificate of ours speak Raft: change `id != member` to `id == "" && member != ""`. Run `go test -count=1 -run TestOnlyMembersSpeakRaft ./internal/metad/`:

~~~text
    metad_test.go:344: "operator" POST /raft/message = 204, want 403
    metad_test.go:344: "" GET /ready = 503, want 200
    metad_test.go:348: member 3 is follower after the refused vote
~~~

The operator's forged vote went through, and the leader stepped down. `/ready` then said 503, because for that moment there was no leader. Mutual TLS alone isn't authorization: it tells you *who* is calling, and you still have to decide what they may do.

### The issuer and jobsctl

The issuer serves HTTPS, and accepts a client certificate only from the API. Other clients prove who they are with their secrets. In `cmd/idp/main.go`:

Change:

<!-- edit: cmd/idp/main.go -->
~~~go
//	IDP_CREATE_KEY      true: make a key if IDP_KEYS has none (for Compose)
//	LISTEN_ADDR         where to listen (127.0.0.1:8081)
~~~

to:

~~~go
//	IDP_CREATE_KEY      true: make a key if IDP_KEYS has none (for Compose)
//	IDP_TLS_DIR         its certificate (Phase 6, step 7): serve HTTPS, so
//	                    the API can check it has the real issuer's keys
//	LISTEN_ADDR         where to listen (127.0.0.1:8081)
~~~

Change:

<!-- edit: cmd/idp/main.go -->
~~~go
	"runway/internal/envconfig"
)
~~~

to:

~~~go
	"runway/internal/envconfig"
	"runway/internal/pki"
)
~~~

Change:

<!-- edit: cmd/idp/main.go -->
~~~go
	go func() { _ = server.Serve(listener) }()
~~~

to:

~~~go
	if dir := getenv("IDP_TLS_DIR"); dir != "" {
		src, err := pki.NewSource(dir, logger)
		if err != nil {
			return fmt.Errorf("IDP_TLS_DIR: %w", err)
		}
		// Clients prove who they are with their secrets, not certificates,
		// so none is required. The API presents its own when it fetches
		// the keys; one that isn't the API's is refused.
		server.TLSConfig = pki.ServerConfig(src, false, pki.ID("api"))
		server.ErrorLog = slog.NewLogLogger(logger.Handler(), slog.LevelWarn)
	}
	go func() {
		if server.TLSConfig != nil {
			_ = server.ServeTLS(listener, "", "")
			return
		}
		_ = server.Serve(listener)
	}()
~~~


`jobsctl` speaks mutual TLS with an operator's certificate. In `cmd/jobsctl/main.go`:

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
// RUNWAY_TOKEN, if set, is sent with every call as a bearer token.
package main
~~~

to:

~~~go
// RUNWAY_TOKEN, if set, is sent with every call as a bearer token.
// RUNWAY_TLS_DIR, if set, holds a certificate (an operator's, from
// cmd/ca) to call the API with over mutual TLS (Phase 6, step 7).
package main
~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
~~~

to:

~~~go
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
	"runway/internal/grpcapi/jobsv1"
)
~~~

to:

~~~go
	"runway/internal/grpcapi/jobsv1"
	"runway/internal/pki"
)
~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
	opts := []grpc.DialOption{grpc.WithTransportCredentials(insecure.NewCredentials())}
	if token := os.Getenv("RUNWAY_TOKEN"); token != "" {
~~~

to:

~~~go
	opts := []grpc.DialOption{grpc.WithTransportCredentials(insecure.NewCredentials())}
	if dir := os.Getenv("RUNWAY_TLS_DIR"); dir != "" {
		src, err := pki.NewSource(dir, nil)
		if err != nil {
			return fmt.Errorf("RUNWAY_TLS_DIR: %w", err)
		}
		opts = []grpc.DialOption{grpc.WithTransportCredentials(credentials.NewTLS(pki.ClientConfig(src, pki.ID("api"))))}
	}
	if token := os.Getenv("RUNWAY_TOKEN"); token != "" {
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/pki/... ./cmd/... -->

### The chart

Each service mounts its Secret at `/etc/runway/tls`. Not with `subPath`: the kubelet can't update a `subPath` mount, and updating in place is how certificates are renewed. Probes switch to HTTPS. In `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
  issuer: http://idp.runway:8081 # the "iss" in its tokens, and where its keys are
~~~

to:

~~~yaml
  issuer: https://idp.runway:8081 # the "iss" in its tokens, and where its keys are (http without tls)
~~~

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
  allowHosts: []

~~~

to:

~~~yaml
  allowHosts: []

# Mutual TLS between services (Phase 6, step 7). Each service's
# certificate, key and trusted CAs are the Secret tls-SERVICE, made from
# your CA by deploy/certs.sh. Pods re-read them as they change, so renewing
# them needs no restart. The API, metad and the issuer serve HTTPS; the
# gateway and the API prove to each other who they are, as metad's
# members do.
tls:
  enabled: true
  # A certificate is checked only when a connection is made, so the API
  # makes its clients reconnect after this long, and show theirs again.
  maxConnectionAge: 10m

~~~


In `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
{{/*
An API Pod template. The stable Deployment and the canary differ only in
~~~

to:

~~~yaml
{{/*
Mutual TLS (step 7): the Secret tls-SERVICE as a volume, mounted at
/etc/runway/tls. Not with subPath: the kubelet can't update a subPath
mount, and updating it in place is how certificates are renewed.
runway.tlsVolume "api"
*/}}
{{- define "runway.tlsVolume" -}}
- name: tls
  secret:
    secretName: tls-{{ . }}
    defaultMode: 0440 # root and the image's group (fsGroup 65532); nobody else
{{- end }}

{{- define "runway.tlsMount" -}}
- { name: tls, mountPath: /etc/runway/tls, readOnly: true }
{{- end }}

{{/*
An API Pod template. The stable Deployment and the canary differ only in
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
    prometheus.io/path: /metrics
spec:
~~~

to:

~~~yaml
    prometheus.io/path: /metrics
    {{- if $root.Values.tls.enabled }}
    prometheus.io/scheme: https
    {{- end }}
spec:
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
    runAsNonRoot: true
  terminationGracePeriodSeconds: {{ $api.terminationGracePeriodSeconds }}
~~~

to:

~~~yaml
    runAsNonRoot: true
    fsGroup: 65532 # so the image's user can read the mounted certificate
  terminationGracePeriodSeconds: {{ $api.terminationGracePeriodSeconds }}
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        - { name: WEBHOOK_ALLOW_HOSTS, value: {{ join "," $root.Values.webhooks.allowHosts | quote }} }
        - name: GOMEMLIMIT
~~~

to:

~~~yaml
        - { name: WEBHOOK_ALLOW_HOSTS, value: {{ join "," $root.Values.webhooks.allowHosts | quote }} }
        {{- if $root.Values.tls.enabled }}
        - { name: TLS_DIR, value: /etc/runway/tls }
        - { name: TLS_MAX_CONNECTION_AGE, value: {{ $root.Values.tls.maxConnectionAge | quote }} }
        {{- if $root.Values.auth.idp.enabled }}
        - { name: AUTH_ISSUER_ID, value: "spiffe://runway/idp" } # take keys only from the real issuer
        {{- end }}
        {{- end }}
        - name: GOMEMLIMIT
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        {{- toYaml $api.resources | nindent 8 }}
      livenessProbe:
        httpGet: { path: /health, port: http }
~~~

to:

~~~yaml
        {{- toYaml $api.resources | nindent 8 }}
      # With TLS, the kubelet probes over HTTPS. It sends no certificate and
      # checks none, so these routes are open to callers without one.
      {{- $scheme := ternary "HTTPS" "HTTP" $root.Values.tls.enabled }}
      livenessProbe:
        httpGet: { path: /health, port: http, scheme: {{ $scheme }} }
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        httpGet: { path: /ready, port: http }
~~~

to:

~~~yaml
        httpGet: { path: /ready, port: http, scheme: {{ $scheme }} }
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
      {{- include "runway.containerSecurity" $root | nindent 6 }}
{{- end }}
~~~

to:

~~~yaml
      {{- include "runway.containerSecurity" $root | nindent 6 }}
      {{- if $root.Values.tls.enabled }}
      volumeMounts:
        {{- include "runway.tlsMount" . | nindent 8 }}
  volumes:
    {{- include "runway.tlsVolume" "api" | nindent 4 }}
  {{- end }}
{{- end }}
~~~


In `deploy/helm/runway/templates/api.yaml`, refuse an issuer URL that doesn't match the TLS setting:

Change:

<!-- edit: deploy/helm/runway/templates/api.yaml -->
~~~yaml
{{- fail "auth.issuer is required unless auth.mode is off: an API without an issuer would refuse every request, or with mode off accept every one" }}
{{- end }}
~~~

to:

~~~yaml
{{- fail "auth.issuer is required unless auth.mode is off: an API without an issuer would refuse every request, or with mode off accept every one" }}
{{- end }}
{{- if and .Values.auth.idp.enabled (ne (hasPrefix "https://" .Values.auth.issuer) .Values.tls.enabled) }}
{{- fail "auth.issuer must start https:// with tls.enabled, and http:// without: the chart's issuer serves one or the other" }}
{{- end }}
~~~


In `deploy/helm/runway/templates/gateway.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/gateway.yaml -->
~~~yaml
        runAsNonRoot: true
      containers:
~~~

to:

~~~yaml
        runAsNonRoot: true
        fsGroup: 65532
      containers:
~~~

Change:

<!-- edit: deploy/helm/runway/templates/gateway.yaml -->
~~~yaml
            - { name: ADMIN_ADDR, value: "0.0.0.0:8001" }
          ports:
~~~

to:

~~~yaml
            - { name: ADMIN_ADDR, value: "0.0.0.0:8001" }
            {{- if .Values.tls.enabled }}
            - { name: UPSTREAM_TLS_DIR, value: /etc/runway/tls } # call the API over mutual TLS
            {{- end }}
          ports:
~~~

Change:

<!-- edit: deploy/helm/runway/templates/gateway.yaml -->
~~~yaml
          {{- include "runway.containerSecurity" . | nindent 10 }}
---
~~~

to:

~~~yaml
          {{- include "runway.containerSecurity" . | nindent 10 }}
          {{- if .Values.tls.enabled }}
          volumeMounts:
            {{- include "runway.tlsMount" . | nindent 12 }}
      volumes:
        {{- include "runway.tlsVolume" "gateway" | nindent 8 }}
          {{- end }}
---
~~~


In `deploy/helm/runway/templates/idp.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/idp.yaml -->
~~~yaml
            - { name: LISTEN_ADDR, value: "0.0.0.0:8081" }
            - name: IDP_CLIENTS
~~~

to:

~~~yaml
            - { name: LISTEN_ADDR, value: "0.0.0.0:8081" }
            {{- if .Values.tls.enabled }}
            - { name: IDP_TLS_DIR, value: /etc/runway/tls }
            {{- end }}
            - name: IDP_CLIENTS
~~~

Change:

<!-- edit: deploy/helm/runway/templates/idp.yaml -->
~~~yaml
            httpGet: { path: /health, port: http }
~~~

to:

~~~yaml
            httpGet: { path: /health, port: http, scheme: {{ ternary "HTTPS" "HTTP" .Values.tls.enabled }} }
~~~

Change:

<!-- edit: deploy/helm/runway/templates/idp.yaml -->
~~~yaml
            - { name: keys, mountPath: /keys, readOnly: true }
          {{- include "runway.containerSecurity" . | nindent 10 }}
~~~

to:

~~~yaml
            - { name: keys, mountPath: /keys, readOnly: true }
            {{- if .Values.tls.enabled }}
            {{- include "runway.tlsMount" . | nindent 12 }}
            {{- end }}
          {{- include "runway.containerSecurity" . | nindent 10 }}
~~~

Change:

<!-- edit: deploy/helm/runway/templates/idp.yaml -->
~~~yaml
            defaultMode: 0440 # readable by root and the issuer's group; nobody else
---
~~~

to:

~~~yaml
            defaultMode: 0440 # readable by root and the issuer's group; nobody else
        {{- if .Values.tls.enabled }}
        {{- include "runway.tlsVolume" "idp" | nindent 8 }}
        {{- end }}
---
~~~


In `deploy/helm/runway/templates/metad.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/metad.yaml -->
~~~yaml
{{- $peers := list }}
{{- range $i := until $n }}
{{- $peers = append $peers (printf "%d=http://metad-%d.metad:7001" (add1 $i) $i) }}
~~~

to:

~~~yaml
{{- $peers := list }}
{{- $scheme := ternary "https" "http" .Values.tls.enabled }}
{{- range $i := until $n }}
{{- $peers = append $peers (printf "%d=%s://metad-%d.metad:7001" (add1 $i) $scheme $i) }}
~~~

Change:

<!-- edit: deploy/helm/runway/templates/metad.yaml -->
~~~yaml
            - { name: METAD_DATA, value: /data }
          ports:
~~~

to:

~~~yaml
            - { name: METAD_DATA, value: /data }
            {{- if .Values.tls.enabled }}
            # Members prove to each other that they are members; only the
            # operator may use the store and locks (step 7).
            - { name: METAD_TLS_DIR, value: /etc/runway/tls }
            {{- end }}
          ports:
~~~

Change:

<!-- edit: deploy/helm/runway/templates/metad.yaml -->
~~~yaml
            httpGet: { path: /ready, port: http }
~~~

to:

~~~yaml
            httpGet: { path: /ready, port: http, scheme: {{ upper $scheme }} }
~~~

Change:

<!-- edit: deploy/helm/runway/templates/metad.yaml -->
~~~yaml
            httpGet: { path: /status, port: http }
~~~

to:

~~~yaml
            httpGet: { path: /status, port: http, scheme: {{ upper $scheme }} }
~~~

Change:

<!-- edit: deploy/helm/runway/templates/metad.yaml -->
~~~yaml
            - { name: data, mountPath: /data }
  volumeClaimTemplates:
~~~

to:

~~~yaml
            - { name: data, mountPath: /data }
            {{- if .Values.tls.enabled }}
            {{- include "runway.tlsMount" . | nindent 12 }}
            {{- end }}
      {{- if .Values.tls.enabled }}
      volumes:
        {{- include "runway.tlsVolume" "metad" | nindent 8 }}
      {{- end }}
  volumeClaimTemplates:
~~~


In `deploy/helm/runway/templates/NOTES.txt`:

Change:

<!-- edit: deploy/helm/runway/templates/NOTES.txt -->
~~~text

  API:      curl localhost:8080/health
  Gateway:  curl localhost:8000/health
~~~

to:

~~~text

{{- if .Values.tls.enabled }}
  API:      curl --cacert CA/tls.crt --resolve api.runway:8080:127.0.0.1 https://api.runway:8080/health
            (jobs also need --cert and --key: the operator's, from deploy/certs.sh)
{{- else }}
  API:      curl localhost:8080/health
{{- end }}
  Gateway:  curl localhost:8000/health
~~~


Prometheus scrapes Pods by address, which no certificate names, and has no certificate of its own yet, so it encrypts but checks nothing. In `deploy/prometheus/prometheus.yml`:

Change:

<!-- edit: deploy/prometheus/prometheus.yml -->
~~~yaml
        namespaces: { names: [runway] }
    relabel_configs:
~~~

to:

~~~yaml
        namespaces: { names: [runway] }
    # Phase 6, step 7: Pods that serve TLS say so (prometheus.io/scheme:
    # https). Prometheus scrapes by Pod IP, which no certificate names,
    # and has no certificate of its own yet, so it checks nothing: the
    # metrics are encrypted on the way, but whoever answers is believed.
    # Exercise: give it a certificate, and check spiffe://runway/... instead.
    tls_config:
      insecure_skip_verify: true
    relabel_configs:
~~~

Change:

<!-- edit: deploy/prometheus/prometheus.yml -->
~~~yaml
        target_label: __metrics_path__
      # job="api", "worker", ... from the Pod's app label, so queries read
~~~

to:

~~~yaml
        target_label: __metrics_path__
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scheme]
        regex: (https?)
        target_label: __scheme__
      # job="api", "worker", ... from the Pod's app label, so queries read
~~~


The smoke test makes a CA for a new cluster, and talks to the gateway, since the API itself now wants a client certificate. In `deploy/smoke.sh`:

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash
url=${RUNWAY_URL:-http://localhost:8080}
~~~

to:

~~~bash
url=${RUNWAY_URL:-http://localhost:8000} # the gateway: the API itself wants a client certificate
~~~

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash

# install the first time, upgrade after that
~~~

to:

~~~bash

# Certificates for mutual TLS (step 7), from a CA made for this cluster, the
# first time. Keep the CA's directory if you want to renew them later.
if ! kubectl -n runway get secret tls-api >/dev/null 2>&1; then
  ca=$(mktemp -d)
  go run ./cmd/ca init "$ca/ca"
  deploy/certs.sh "$ca/ca"
  echo "the CA is in $ca/ca"
fi

# install the first time, upgrade after that
~~~

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash
# the issuer. (Whoever runs this can read Secrets anyway.)
client=$(kubectl -n runway get secret idp-clients -o jsonpath='{.data.IDP_CLIENTS}' | base64 -d | cut -d, -f1)
kubectl -n runway port-forward svc/idp 18081:8081 >/dev/null 2>&1 &
~~~

to:

~~~bash
# the issuer. (Whoever runs this can read Secrets anyway.) Over HTTPS, the
# issuer proves it is idp.runway with a certificate from the cluster's CA.
client=$(kubectl -n runway get secret idp-clients -o jsonpath='{.data.IDP_CLIENTS}' | base64 -d | cut -d, -f1)
cacert=$(mktemp)
kubectl -n runway get secret tls-idp -o jsonpath='{.data.ca\.crt}' | base64 -d >"$cacert"
kubectl -n runway port-forward svc/idp 18081:8081 >/dev/null 2>&1 &
~~~

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash
trap 'kill $forward 2>/dev/null' EXIT
~~~

to:

~~~bash
trap 'kill $forward 2>/dev/null; rm -f "$cacert"' EXIT
~~~

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash
token=$(curl -sf -u "$(echo "$client" | cut -d: -f1):$(echo "$client" | cut -d: -f2)" \
  -d grant_type=client_credentials localhost:18081/token | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
~~~

to:

~~~bash
token=$(curl -sf --cacert "$cacert" --resolve idp.runway:18081:127.0.0.1 \
  -u "$(echo "$client" | cut -d: -f1):$(echo "$client" | cut -d: -f2)" \
  -d grant_type=client_credentials https://idp.runway:18081/token | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
~~~


<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway | grep -q 'secretName: tls-api' && ! helm template runway deploy/helm/runway --set auth.issuer=http://idp.runway:8081 2>/dev/null -->

### Run it

Make a CA, keep it outside the cluster, and issue the certificates:

~~~bash
go run ./cmd/ca init ~/.runway/ca
ls -l ~/.runway/ca
deploy/certs.sh ~/.runway/ca
kubectl -n runway get secret tls-api -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName,extendedKeyUsage
openssl x509 -in ~/.runway/ca/tls.crt -noout -subject -dates -ext basicConstraints,keyUsage,nameConstraints
~~~

~~~text
CA "Runway CA 2026-10-09" in /home/techieemma/blueprint-scratch/p6ca, valid until 2027-10-09
-rw-r--r-- tls.crt
-rw------- tls.key
spiffe://runway/api: serial 16a8bfc615602cf45f7001a9634793d7, valid until 2026-10-10T20:04:00Z, trusting 1 CA(s)
spiffe://runway/gateway: serial 12c115478132d166a50e6201152086f6, valid until 2026-10-10T20:04:00Z, trusting 1 CA(s)
spiffe://runway/idp: serial 26cb04acaacd7dd7ec785405bb1ef9ba, valid until 2026-10-10T20:04:01Z, trusting 1 CA(s)
spiffe://runway/metad: serial 5aba7d795da268d1edbaad1aab6265cb, valid until 2026-10-10T20:04:01Z, trusting 1 CA(s)
spiffe://runway/operator: serial 229367e3294f7628f89d59deaa2b810a, valid until 2026-10-10T20:04:02Z, trusting 1 CA(s)
subject=O = Runway, CN = api
issuer=O = Runway, CN = Runway CA 2026-10-09
notBefore=Oct  9 20:03:00 2026 GMT
notAfter=Oct 10 20:04:00 2026 GMT
X509v3 Extended Key Usage: 
    TLS Web Server Authentication, TLS Web Client Authentication
X509v3 Subject Alternative Name: 
    DNS:api, DNS:api.runway, DNS:api.runway.svc, DNS:api-pods.runway, URI:spiffe://runway/api
subject=O = Runway, CN = Runway CA 2026-10-09
notBefore=Oct  9 20:02:59 2026 GMT
notAfter=Oct  9 20:03:59 2027 GMT
X509v3 Key Usage: critical
    Certificate Sign, CRL Sign
X509v3 Basic Constraints: critical
    CA:TRUE, pathlen:0
X509v3 Name Constraints: 
    Permitted:
      URI:runway
~~~

(My CA was in a scratch directory; yours is `~/.runway/ca`. `ls -l` is trimmed to the modes and names.) The CA's key is readable by you alone. The API's certificate names it twice: by DNS names, for clients such as `curl` that check names, and by `URI:spiffe://runway/api`, for Runway's own clients.

Rebuild and roll out (the chart's `tls.enabled` is `true` by default, and the issuer's URL is now `https://`). Then update Prometheus's configuration and restart it:

~~~bash
kubectl -n observability create configmap prometheus --from-file=deploy/prometheus/ --dry-run=client -o yaml | kubectl apply -f -
kubectl -n observability rollout restart deployment/prometheus
~~~

Now each way in. The issuer is HTTPS, so `curl` needs the CA's certificate to trust it, and `--resolve` so the name it checks is `idp.runway`:

~~~bash
CA=~/.runway/ca; OP="--cert $CA/operator/tls.crt --key $CA/operator/tls.key"
token() { curl -s --cacert $CA/tls.crt --resolve idp.runway:8081:127.0.0.1 -u "$1:$(secret $1)" -d grant_type=client_credentials https://idp.runway:8081/token | jq -r .access_token; }
TOKEN=$(token acme-ci)
curl -s -o /dev/null -w '%{http_code}\n' --resolve idp.runway:8081:127.0.0.1 https://idp.runway:8081/token   # without --cacert
curl -s -X POST localhost:8000/jobs -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"description":"over mTLS","duration_ms":10}' -w ' (%{http_code})\n'
curl -s localhost:8080/health -w ' (%{http_code})\n'
curl -s --cacert $CA/tls.crt --resolve api.runway:8080:127.0.0.1 https://api.runway:8080/health -w ' (%{http_code})\n'
curl -s --cacert $CA/tls.crt --resolve api.runway:8080:127.0.0.1 -X POST https://api.runway:8080/jobs -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"description":"no cert"}' -w ' (%{http_code})\n'
curl -s --cacert $CA/tls.crt $OP --resolve api.runway:8080:127.0.0.1 -X POST https://api.runway:8080/jobs -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"description":"as the operator","duration_ms":10}' -w ' (%{http_code})\n'
curl -s --cacert $CA/tls.crt $OP --resolve api.runway:8080:127.0.0.1 -X POST https://api.runway:8080/jobs -H 'Content-Type: application/json' -d '{"description":"cert, no token"}' -w ' (%{http_code})\n'
~~~

~~~text
000
{"id":18838,"state":"queued","description":"over mTLS","duration_ms":10,"created_at":"2026-10-10T11:15:40.180044Z","updated_at":"2026-10-10T11:15:40.180044Z"}
 (201)
Client sent an HTTP request to an HTTPS server.
 (400)
{"status":"ok"}
 (200)
{"error":"client certificate required"}
 (403)
{"id":18839,"state":"queued","description":"as the operator","duration_ms":10,"created_at":"2026-10-10T11:15:40.411525Z","updated_at":"2026-10-10T11:15:40.411525Z"}
 (201)
{"error":"authentication required"}
 (401)
~~~

Read it as a table of who gets in. Without the CA's certificate, `curl` refuses the issuer (`000`: no connection), which is TLS protecting the *client*. Through the gateway: `201`, the gateway proving itself to the API on your behalf. Plain HTTP to the API: refused. HTTPS with no certificate: health yes, jobs no. The operator's certificate *and* a token: in. The certificate alone: `401`, because a service identity isn't a tenant.

gRPC, through a port-forward to the API's gRPC port:

~~~bash
RUNWAY_TOKEN=$TOKEN jobsctl create 'plain gRPC'
RUNWAY_TOKEN=$TOKEN RUNWAY_TLS_DIR=$CA/operator jobsctl create 'gRPC over mTLS' 10
~~~

~~~text
jobsctl: Unavailable: connection error: desc = "error reading server preface: EOF"
job 18840: STATE_QUEUED "gRPC over mTLS" (10 ms)
~~~

**Break it: the intruder again.** Run the attack from the start of this step, and then the same thing from a Pod that has *stolen the gateway's certificate*, by mounting its Secret (create it with `--overrides`, a volume from `tls-gateway` mounted at `/stolen`, and `fsGroup: 65532` so it can read the files):

~~~bash
kubectl -n runway exec intruder -- curl -s http://metad-1.metad:7001/status -w ' (%{http_code})\n'
kubectl -n runway exec intruder -- curl -sk -X PUT https://metad-1.metad:7001/kv/owner -d intruder -w ' (%{http_code})\n'
kubectl -n runway exec intruder -- curl -sk -X POST https://metad-1.metad:7001/raft/message -d '{"Type":1,"From":3,"To":2,"Term":227}' -w ' (%{http_code})\n'
kubectl -n runway exec intruder -- curl -sk https://metad-1.metad:7001/status
C="--cacert /stolen/ca.crt --cert /stolen/tls.crt --key /stolen/tls.key"
kubectl -n runway exec thief -- sh -c "curl -s $C https://api.runway:8080/jobs/1 -w ' (%{http_code})\n'"
kubectl -n runway exec thief -- sh -c "curl -s $C -X PUT https://metad-1.metad.runway:7001/kv/owner -d thief -w ' (%{http_code})'; echo \" exit \$?\""
kubectl -n runway logs metad-1 --since=1m | grep 'TLS handshake error'
~~~

~~~text
Client sent an HTTP request to an HTTPS server.
 (400)
{"error":"not allowed: no certificate"}
 (403)
{"error":"not allowed: no certificate"}
 (403)
{"id":2,"role":"leader","term":127,"leader":2,"commit":30}
{"error":"authentication required"}
 (401)
 (000) exit 56
{"time":"2026-10-10T11:16:51.718031488Z","level":"WARN","msg":"http: TLS handshake error from 10.244.2.21:39514: client sent an HTTP request to an HTTPS server"}
{"time":"2026-10-10T11:16:53.507469905Z","level":"WARN","msg":"http: TLS handshake error from 10.244.2.22:46088: peer identity not allowed: \"spiffe://runway/gateway\" (allowed: [spiffe://runway/operator spiffe://runway/metad])"}
~~~

(The leader is `metad-1` now; use whichever is.) The forged vote was refused, and the term is unchanged. The thief, holding the gateway's real certificate, still can't create jobs without a token, and `metad` refuses its handshake outright, because the gateway has no business there. A stolen certificate gives exactly the access of the service it belonged to, and for a day.

**Break it: renew the certificates under load.** Run `certs.sh` again while sending jobs through the gateway, five a second, and watch each Pod's log for `certificate reloaded`. For this run I set `tls.maxConnectionAge` to `1m`, to see the effect within minutes:

~~~text
$ deploy/certs.sh ...    # at 2026-10-10T11:41:13Z
# all 9 Pods reloaded within 59 s:
11:41:23 metad-2 spiffe://runway/metad 7d749b4461c4e361227ac626a2d918c
11:41:25 metad-0 spiffe://runway/metad 7d749b4461c4e361227ac626a2d918c
11:41:27 api-58f54b85c-wf9rv spiffe://runway/api 67f9c3b935b8cb3f86b5c3456147ef98
11:41:30 metad-1 spiffe://runway/metad 7d749b4461c4e361227ac626a2d918c
11:41:33 api-58f54b85c-9l8gg spiffe://runway/api 67f9c3b935b8cb3f86b5c3456147ef98
11:41:41 api-58f54b85c-cf45k spiffe://runway/api 67f9c3b935b8cb3f86b5c3456147ef98
11:41:42 idp-75699f54b5-wrvdr spiffe://runway/idp 65a55b8b8e844a1085bbffa90d91c3fe
11:42:09 gateway-54855dcfc4-r5rqw spiffe://runway/gateway 2230424277756c0d9b1c2bf5b46fae1c
11:42:10 idp-75699f54b5-4rcs4 spiffe://runway/idp 65a55b8b8e844a1085bbffa90d91c3fe
# restarts after: 0 for every Pod
# answers during the 150 s of load:
    637 201
~~~

Every Pod picked up its new certificate within a minute, with no restarts and no failed requests. **My first version didn't get there.** Without `LimitConnectionAge`, eight of the nine Pods reloaded, and the gateway never did. `Source` re-reads the files only when it's asked for a certificate, which happens in a handshake. The gateway, always busy, kept its first HTTP/2 connections to the API open forever, so it never made another handshake, and would have gone on using the old certificate until it expired, and then failed all at once. Now the API answers a request on a connection older than `maxConnectionAge` with `Connection: close`. In HTTP/2 that becomes a `GOAWAY`: requests in flight finish, and the client reconnects with a new handshake. gRPC's `MaxConnectionAge` does the same, and `metad` sets ten minutes for its members' own connections, which Raft heartbeats would otherwise keep open forever.

**Break it: the wrong certificate.** Give the gateway a valid certificate from our CA, for the wrong service, as a mistake in a deploy script would:

~~~bash
go run ./cmd/ca issue ~/.runway/ca worker /tmp/worker
kubectl -n runway create secret generic tls-gateway --from-file=/tmp/worker --dry-run=client -o yaml | kubectl apply --server-side --field-manager=certs -f -
# 140 s later, put it right: deploy/certs.sh ~/.runway/ca
~~~

~~~text
t=  0- 15  201×62
t= 15- 30  201×65
t= 30- 45  201×66
t= 45- 60  201×64
t= 60- 75  201×11  502×55
t= 75- 90  502×67
...
t=150-165  502×69
t=165-180  201×24  502×44
t=180-195  201×68
{"time":"2026-10-10T11:56:02.463539087Z","level":"WARN","msg":"upstream failed","upstream":"10.244.1.19:8080","error":"remote error: tls: bad certificate"}
{"time":"2026-10-10T11:56:05.782866555Z","level":"WARN","msg":"http: TLS handshake error from 10.244.2.31:45942: peer identity not allowed: \"spiffe://runway/worker\" (allowed: [spiffe://runway/gateway spiffe://runway/operator])"}
~~~

Requests through the gateway, by 15-second window from the change. Nothing happened for about a minute, the time the kubelet takes to update a mounted Secret. Then failures as the gateway's connections aged out and reconnected as "worker", which the API refused. Then recovery within 15 to 45 seconds of the fix. (The timings vary from run to run; the shape doesn't.) Both ends logged exactly what was wrong.

**Break it: replace the CA.** A CA's certificate expires too, and a CA key may have to be replaced in a hurry. Every service must trust the new CA *before* any service presents a certificate from it. Three phases, each waiting until all nine Pods have reloaded:

~~~bash
go run ./cmd/ca init ~/.runway/ca-2
TRUST=~/.runway/ca-2/tls.crt deploy/certs.sh ~/.runway/ca     # 1: old certificates, trusting both CAs
TRUST=~/.runway/ca/tls.crt deploy/certs.sh ~/.runway/ca-2     # 2: new certificates, still trusting both
deploy/certs.sh ~/.runway/ca-2                                # 3: trust only the new CA
~~~

~~~text
# t=10 s: 1: trust both; certificates still from the old CA
spiffe://runway/api: serial 3388d2a8818f97485900f91e2b59f399, trusting 2 CA(s)
...
# all 9 Pods reloaded after 88 s
# t=98 s: 2: certificates from the new CA; still trust both
spiffe://runway/api: serial 16672b385b758729d2572a24e88db073, trusting 2 CA(s)
...
# all 9 Pods reloaded after 64 s
# t=162 s: 3: trust only the new CA
spiffe://runway/api: serial 1e9e62dc27d3a2d57b9231228417702c, trusting 1 CA(s)
...
# all 9 Pods reloaded after 123 s

# answers through the gateway, by 15-second window: 201 in every window, 0 errors in 315 s
# metad: changes of role during the run: (0 changes)
~~~

(I've trimmed the dates and the other services' lines.) No errors, and no `metad` elections. Now skip the overlap, and go straight from one CA to a third:

~~~text
# t=10 s: straight to the new CA
$ deploy/certs.sh ~/.runway/ca-3
# all 9 Pods reloaded after 79 s

t= 45- 60  201×63
t= 60- 75  201×54  502×12
t= 75- 90  201×58  502×8
t= 90-105  201×66
# metad: changes of role during the run: (0 changes)
~~~

Twenty failures in a window of about 30 seconds: Pods reload at different moments, and for a while some present certificates that others don't yet trust. `metad` had no elections, because its members' existing connections survived; only new handshakes failed. On a slower cluster, or with more Pods, the window grows. Keep the CA you end with, and its `operator` directory, since everything later uses them.

**Explain it:** what does mutual TLS prove that a token doesn't, and the other way round? Why do certificates name a service rather than an address? Why is `InsecureSkipVerify` safe in `ClientConfig` and dangerous almost everywhere else? Why did the gateway never reload its certificate in the first version? Why does replacing a CA take three phases, and what goes wrong with one?

**Read.** Bulletproof TLS and PKI (Ivan Ristić), the chapters on PKI and on validation. Then the [SPIFFE concepts](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/) page. Then Google's *BeyondCorp: A New Approach to Enterprise Security* (2014), the paper that named zero trust. Then RFC 5280 §4.2.1.10 (name constraints): which clients enforce them, and what would `PermittedURIDomains` stop?

---
## Step 8: A sidecar proxy

**The problem.** Step 7 gave mutual TLS to the services you wrote. Redis isn't one of them. It has no idea about SPIFFE identities, and any Pod can talk to it (T10). Watch what that means, from a Pod with `redis-cli`:

~~~bash
kubectl -n runway run intruder --image=redis:8 --restart=Never --command -- sleep 3600
kubectl -n runway exec intruder -- redis-cli -h redis-1.redis --scan --pattern 'runway:job:*' | head -3
kubectl -n runway exec intruder -- redis-cli -h redis-1.redis GET runway:job:v2:acme:25455
kubectl -n runway exec intruder -- redis-cli -h redis-1.redis SET runway:job:v2:acme:25455 '{"ID":25455,"Tenant":"acme","Description":"quarterly payroll export","Duration":10000000,"State":"failed","FailureReason":"cancelled by the intruder","CreatedAt":"2026-10-10T12:48:31.46622Z","UpdatedAt":"2026-10-10T12:48:31.529534Z"}' KEEPTTL
curl -s localhost:8000/jobs/25455 -H "Authorization: Bearer $READ"     # as acme
~~~

~~~text
runway:job:v2:acme:25455
runway:job:v2:acme:24425
{"ID":25455,"Tenant":"acme","Description":"quarterly payroll export","Duration":10000000,"State":"completed","FailureReason":"","CreatedAt":"2026-10-10T12:48:31.46622Z","UpdatedAt":"2026-10-10T12:48:31.529534Z"}
OK
{"id":25455,"state":"failed","description":"quarterly payroll export","duration_ms":10,"failure_reason":"cancelled by the intruder","created_at":"2026-10-10T12:48:31.46622Z","updated_at":"2026-10-10T12:48:31.529534Z"}
~~~

(Use one of your own cached job keys.) The intruder read acme's payroll job, then rewrote it, and acme's own API now tells acme the job failed. Every safeguard from steps 2 to 7 was bypassed, because the cache sits underneath them. Redis 6 and later can do TLS and passwords, but not SPIFFE identities, and the same problem comes up with every program you can't change. The general answer is to put something beside it that can.

**New ideas.**

- **A sidecar** is a second container in the same Pod. Containers in a Pod share a network namespace, so they reach each other on `127.0.0.1`, and nothing outside the Pod can reach the loopback.
- **A TLS proxy as a sidecar**, in two directions. *Inbound*, in Redis's Pod: it takes mutual TLS from callers it accepts, and passes the bytes to Redis, which now listens only on the loopback. *Outbound*, in the API's Pod: the API connects in plain text to `127.0.0.1`, and the sidecar carries the connection to Redis's sidecar over mutual TLS. Neither Redis nor the API's code changes.
- **A service mesh** (Istio, Linkerd) is exactly this for every Pod, with a proxy such as Envoy injected automatically and configured by a control plane. Building the small version shows what the big one costs and what it can't see.
- **Layer 4.** A proxy that only moves bytes can't see requests: it doesn't know where one Redis command ends and the next begins. That matters for closing old connections (step 7's lesson) and for every feature that needs the protocol (retries, per-request metrics).
- **Native sidecars** (Kubernetes 1.29 and later): an init container with `restartPolicy: Always`. Kubernetes starts it before the main containers, waits for its startup probe, and stops it only after they've stopped. An ordinary second container has no order at all.
- **Measure the cost.** Two extra hops per request, and TLS. How much is each?

### The proxy

Create `internal/tlsproxy/tlsproxy.go`:

<!-- file: internal/tlsproxy/tlsproxy.go -->
~~~go
// Package tlsproxy gives mutual TLS to programs that don't speak it
// (Phase 6, step 8). It runs beside the program, in the same Pod: a
// sidecar. It knows nothing of the protocol inside; it moves bytes.
//
// Inbound, it stands in front of a server: it takes TLS connections from
// callers whose identity it accepts, and passes the bytes to the server on
// the Pod's loopback, where nothing else can reach it.
//
// Outbound, it stands in front of a client: the client connects to it on
// the loopback, in plain text, and it carries the connection to the
// server's sidecar over TLS, checking the server is who it should be.
//
//	client ─plain─▶ outbound ═══mutual TLS═══▶ inbound ─plain─▶ server
//	└─────── one Pod ───────┘                  └─────── one Pod ──────┘
//
// This is what a service mesh (Istio, Linkerd) does, with a proxy such as
// Envoy, for every Pod, configured by a control plane.
package tlsproxy

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"runway/internal/pki"
)

// Inbound accepts TLS on Listen from the identities in Allowed, and passes
// each connection to Target.
type Inbound struct {
	Listen, Target string
	Allowed        []string
}

// Outbound accepts plain connections on Listen, and carries each to Target
// over TLS, which must prove it is Server.
type Outbound struct {
	Listen, Target, Server string
}

// ParseInbound reads LISTEN,TARGET,ID[,ID...].
func ParseInbound(s string) (Inbound, error) {
	parts := strings.Split(s, ",")
	if len(parts) < 3 {
		return Inbound{}, fmt.Errorf("inbound %q: want LISTEN,TARGET,ID[,ID...]", s)
	}
	return Inbound{Listen: parts[0], Target: parts[1], Allowed: parts[2:]}, nil
}

// ParseOutbound reads LISTEN,TARGET,ID.
func ParseOutbound(s string) (Outbound, error) {
	parts := strings.Split(s, ",")
	if len(parts) != 3 {
		return Outbound{}, fmt.Errorf("outbound %q: want LISTEN,TARGET,ID", s)
	}
	return Outbound{Listen: parts[0], Target: parts[1], Server: parts[2]}, nil
}

// Proxy carries connections, with its certificate from Source.
type Proxy struct {
	Source *pki.Source
	Logger *slog.Logger
	// A certificate is checked only in the handshake (step 7), so a
	// connection older than MaxAge is closed: as soon as it has been Quiet
	// that long, or after Grace more if it never is. The proxy can't see
	// where one request ends and the next begins, so a quiet moment is the
	// best it can do; closing a busy connection may cut a request off,
	// which the client must retry. Zero MaxAge keeps connections for good.
	MaxAge, Quiet, Grace time.Duration

	connections *prometheus.CounterVec
	open        *prometheus.GaugeVec
	recycled    *prometheus.CounterVec
	wg          sync.WaitGroup
}

// New returns a proxy with the defaults: connections recycled after ten
// minutes, once quiet for a second, or a minute later regardless.
func New(src *pki.Source, logger *slog.Logger) *Proxy {
	return &Proxy{
		Source: src, Logger: logger,
		MaxAge: 10 * time.Minute, Quiet: time.Second, Grace: time.Minute,
		connections: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "tlsproxy_connections_total",
			Help: "Connections handled, by listener and result: ok, refused (TLS or identity), or unreachable (the target).",
		}, []string{"listener", "result"}),
		open: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "tlsproxy_open_connections",
			Help: "Connections open now, by listener.",
		}, []string{"listener"}),
		recycled: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "tlsproxy_recycled_total",
			Help: "Connections closed for being older than the maximum age: when quiet, or forced after the grace period.",
		}, []string{"listener", "how"}),
	}
}

// Collectors returns the proxy's metrics, to register.
func (p *Proxy) Collectors() []prometheus.Collector {
	return []prometheus.Collector{p.connections, p.open, p.recycled}
}

// Wait waits for every connection to finish.
func (p *Proxy) Wait() { p.wg.Wait() }

const handshakeTimeout = 5 * time.Second

// ServeInbound serves in on l until l is closed.
func (p *Proxy) ServeInbound(l net.Listener, in Inbound) error {
	config := pki.ServerConfig(p.Source, true, in.Allowed...)
	return p.serve(l, in.Listen, func(c net.Conn) (net.Conn, net.Conn, error) {
		callers := tls.Server(c, config)
		if err := handshake(callers); err != nil {
			return nil, nil, errRefused{err}
		}
		target, err := net.DialTimeout("tcp", in.Target, handshakeTimeout)
		if err != nil {
			callers.Close()
			return nil, nil, err
		}
		return callers, target, nil
	})
}

// ServeOutbound serves out on l until l is closed.
func (p *Proxy) ServeOutbound(l net.Listener, out Outbound) error {
	config := pki.ClientConfig(p.Source, out.Server)
	return p.serve(l, out.Listen, func(c net.Conn) (net.Conn, net.Conn, error) {
		raw, err := net.DialTimeout("tcp", out.Target, handshakeTimeout)
		if err != nil {
			return nil, nil, err
		}
		server := tls.Client(raw, config)
		if err := handshake(server); err != nil {
			return nil, nil, errRefused{err}
		}
		return c, server, nil
	})
}

func handshake(c *tls.Conn) error {
	ctx, cancel := context.WithTimeout(context.Background(), handshakeTimeout)
	defer cancel()
	err := c.HandshakeContext(ctx)
	if err != nil {
		c.Close()
	}
	return err
}

// errRefused marks a failed handshake: the other end's fault, or ours.
type errRefused struct{ error }

func (p *Proxy) serve(l net.Listener, name string, connect func(net.Conn) (a, b net.Conn, err error)) error {
	for {
		c, err := l.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		p.wg.Add(1)
		go func() {
			defer p.wg.Done()
			a, b, err := connect(c)
			if err != nil {
				result := "unreachable"
				if errors.As(err, new(errRefused)) {
					result = "refused"
				}
				// Counted before the caller sees the connection close.
				p.connections.WithLabelValues(name, result).Inc()
				p.Logger.Warn("connection "+result, "listener", name, "from", c.RemoteAddr().String(), "error", err)
				c.Close()
				return
			}
			p.connections.WithLabelValues(name, "ok").Inc()
			p.open.WithLabelValues(name).Inc()
			defer p.open.WithLabelValues(name).Dec()
			p.pipe(name, a, b)
		}()
	}
}

// pipe copies bytes both ways until both are done, or the connection is
// recycled.
func (p *Proxy) pipe(name string, a, b net.Conn) {
	start := time.Now()
	var last atomic.Int64 // when bytes last moved, in Unix nanoseconds
	last.Store(start.UnixNano())
	done := make(chan struct{})
	var once sync.Once
	closeBoth := func() { once.Do(func() { a.Close(); b.Close() }) }

	var copies sync.WaitGroup
	copies.Add(2)
	go p.copy(&copies, b, a, &last)
	go p.copy(&copies, a, b, &last)
	go func() { copies.Wait(); close(done) }()

	if p.MaxAge > 0 {
		tick := time.NewTicker(min(p.Quiet, p.Grace) / 4)
		defer tick.Stop()
		for {
			select {
			case <-done:
				closeBoth()
				return
			case now := <-tick.C:
				age := now.Sub(start)
				if age < p.MaxAge {
					continue
				}
				how := ""
				if now.Sub(time.Unix(0, last.Load())) >= p.Quiet {
					how = "quiet"
				} else if age >= p.MaxAge+p.Grace {
					how = "forced"
				}
				if how != "" {
					p.recycled.WithLabelValues(name, how).Inc()
					closeBoth()
					<-done
					return
				}
			}
		}
	}
	<-done
	closeBoth()
}

// copy copies from src to dst, recording each time bytes move. When src
// ends, it tells dst it will get no more (a half-close), as TCP allows:
// the other direction may still have something to say.
func (p *Proxy) copy(wg *sync.WaitGroup, dst, src net.Conn, last *atomic.Int64) {
	defer wg.Done()
	buf := make([]byte, 32*1024)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			last.Store(time.Now().UnixNano())
			if _, werr := dst.Write(buf[:n]); werr != nil {
				src.Close() // the other end is gone; stop the other copy too
				return
			}
		}
		if err != nil {
			if cw, ok := dst.(interface{ CloseWrite() error }); ok && err == io.EOF {
				_ = cw.CloseWrite()
			} else {
				dst.Close()
			}
			return
		}
	}
}
~~~

It reuses step 7's `ServerConfig` and `ClientConfig`, so identities are checked the same way as everywhere else. Three things a byte pipe has to get right:
- **Half-close.** When one side finishes sending, `copy` tells the other side with `CloseWrite`, rather than closing the whole connection. The other direction may still have something to say: a client that sends a command and then closes its sending side still needs the answer.
- **Old connections.** A certificate is checked only in the handshake (step 7). An HTTP server can ask a client to reconnect between requests; a byte pipe can't, because it can't see requests. So it waits for a quiet moment, a second with no bytes, after the connection is older than `MaxAge`, and if one never comes, it closes the connection anyway after `Grace`. That may cut off a command in flight, which the client must retry. The API's cache and rate limiter already treat a failed Redis call as a miss.
- **What it counts:** connections that worked, that were refused (a TLS or identity failure, the other end's fault or ours), and that couldn't reach the target.

Create `internal/tlsproxy/tlsproxy_test.go`:

<!-- file: internal/tlsproxy/tlsproxy_test.go -->
~~~go
package tlsproxy

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"io"
	"log/slog"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"

	"runway/internal/pki"
)

// certs makes a CA, and a certificate for each service in dir/SERVICE.
func certs(t testing.TB, services ...string) (string, *pki.CA) {
	t.Helper()
	dir := t.TempDir()
	ca, err := pki.NewCA("test", time.Now(), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range services {
		leaf, err := ca.Issue(s, nil, time.Now(), time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		if err := leaf.Save(filepath.Join(dir, s), []*x509.Certificate{ca.Cert}); err != nil {
			t.Fatal(err)
		}
	}
	return dir, ca
}

func listen(t *testing.T) net.Listener {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	return l
}

func proxy(t testing.TB, dir, service string) *Proxy {
	t.Helper()
	src, err := pki.NewSource(filepath.Join(dir, service), nil)
	if err != nil {
		t.Fatal(err)
	}
	return New(src, slog.New(slog.DiscardHandler))
}

// shout is a plain-text server that knows nothing of TLS: it answers each
// line in capitals, and when the client has finished sending, says "bye".
func shout(t *testing.T) string {
	l := listen(t)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				r := bufio.NewScanner(c)
				for r.Scan() {
					io.WriteString(c, strings.ToUpper(r.Text())+"\n")
				}
				io.WriteString(c, "bye\n")
			}()
		}
	}()
	return l.Addr().String()
}

// chain starts server ← inbound (as inService, accepting allowed) ←
// outbound (as outService, expecting server) and returns where a plain
// client connects, and both proxies. setup, if not nil, can change the
// outbound proxy's settings before it starts.
func chain(t *testing.T, dir, inService, outService, server string, setup func(*Proxy), allowed ...string) (string, *Proxy, *Proxy) {
	t.Helper()
	target := shout(t)
	inL, outL := listen(t), listen(t)
	in, out := proxy(t, dir, inService), proxy(t, dir, outService)
	if setup != nil {
		setup(out)
	}
	go in.ServeInbound(inL, Inbound{Listen: "in", Target: target, Allowed: allowed})
	go out.ServeOutbound(outL, Outbound{Listen: "out", Target: inL.Addr().String(), Server: server})
	return outL.Addr().String(), in, out
}

func TestBytesCrossBothProxies(t *testing.T) {
	dir, _ := certs(t, "api", "redis")
	addr, in, out := chain(t, dir, "redis", "api", pki.ID("redis"), nil, pki.ID("api"))
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	io.WriteString(c, "hello\nworld\n")
	c.(*net.TCPConn).CloseWrite() // done sending; the answer must still arrive
	got, err := io.ReadAll(c)
	if err != nil || string(got) != "HELLO\nWORLD\nbye\n" {
		t.Fatalf("got %q, %v", got, err)
	}
	if n := testutil.ToFloat64(in.connections.WithLabelValues("in", "ok")); n != 1 {
		t.Errorf("inbound ok = %v", n)
	}
	if n := testutil.ToFloat64(out.connections.WithLabelValues("out", "ok")); n != 1 {
		t.Errorf("outbound ok = %v", n)
	}
}

// failed returns an error if a plain client through addr gets no answer.
func failed(addr string) error {
	c, err := net.Dial("tcp", addr)
	if err != nil {
		return err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	io.WriteString(c, "hello\n")
	line, err := bufio.NewReader(c).ReadString('\n')
	if err == nil && line == "HELLO\n" {
		return nil
	}
	if err == nil {
		err = io.ErrUnexpectedEOF
	}
	return err
}

// The inbound side takes only the callers it is told to.
func TestAnotherCallerIsRefused(t *testing.T) {
	dir, _ := certs(t, "worker", "redis")
	addr, in, _ := chain(t, dir, "redis", "worker", pki.ID("redis"), nil, pki.ID("api"))
	if failed(addr) == nil {
		t.Fatal("the worker got through")
	}
	deadline := time.Now().Add(2 * time.Second)
	for testutil.ToFloat64(in.connections.WithLabelValues("in", "refused")) != 1 {
		if time.Now().After(deadline) {
			t.Fatal("the inbound side didn't count the refusal")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The outbound side checks it reached the right server: here, something
// with a good certificate, but not Redis's.
func TestTheWrongServerIsRefused(t *testing.T) {
	dir, _ := certs(t, "api", "worker")
	addr, _, out := chain(t, dir, "worker", "api", pki.ID("redis"), nil, pki.ID("api"))
	if failed(addr) == nil {
		t.Fatal("the API's sidecar talked to the worker as if it were Redis")
	}
	if n := testutil.ToFloat64(out.connections.WithLabelValues("out", "refused")); n != 1 {
		t.Errorf("outbound refused = %v", n)
	}
}

// A caller with no certificate never gets past the handshake.
func TestNoCertificateNoEntry(t *testing.T) {
	dir, ca := certs(t, "redis")
	inL := listen(t)
	go proxy(t, dir, "redis").ServeInbound(inL, Inbound{Listen: "in", Target: shout(t), Allowed: []string{pki.ID("api")}})
	roots := x509.NewCertPool()
	roots.AddCert(ca.Cert)
	c, err := tls.Dial("tcp", inL.Addr().String(), &tls.Config{RootCAs: roots, InsecureSkipVerify: true})
	if err == nil {
		defer c.Close()
		// In TLS 1.3 the client may finish first; the refusal comes next.
		io.WriteString(c, "hello\n")
		if _, err = bufio.NewReader(c).ReadString('\n'); err == nil {
			t.Fatal("a caller without a certificate got an answer")
		}
	}
}

// An old connection is closed once it falls quiet, so the next one makes a
// new handshake with the certificates in use then.
func TestOldConnectionsCloseWhenQuiet(t *testing.T) {
	dir, _ := certs(t, "api", "redis")
	addr, _, out := chain(t, dir, "redis", "api", pki.ID("redis"), func(p *Proxy) {
		p.MaxAge, p.Quiet, p.Grace = 100*time.Millisecond, 200*time.Millisecond, time.Hour
	}, pki.ID("api"))
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	r := bufio.NewReader(c)
	io.WriteString(c, "one\n")
	if line, _ := r.ReadString('\n'); line != "ONE\n" {
		t.Fatalf("got %q", line)
	}
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := r.ReadString('\n'); err != io.EOF {
		t.Fatalf("read %v, want EOF: the proxy should have closed it", err)
	}
	if n := testutil.ToFloat64(out.recycled.WithLabelValues("out", "quiet")); n != 1 {
		t.Errorf("recycled when quiet = %v", n)
	}
}

// A connection that is never quiet is closed anyway, after the grace period.
func TestBusyConnectionsAreClosedAfterGrace(t *testing.T) {
	dir, _ := certs(t, "api", "redis")
	addr, _, out := chain(t, dir, "redis", "api", pki.ID("redis"), func(p *Proxy) {
		p.MaxAge, p.Quiet, p.Grace = 100*time.Millisecond, time.Hour, 300*time.Millisecond
	}, pki.ID("api"))
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	r := bufio.NewReader(c)
	start := time.Now()
	for time.Since(start) < 3*time.Second {
		if _, err := io.WriteString(c, "ping\n"); err != nil {
			break
		}
		if _, err := r.ReadString('\n'); err != nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if took := time.Since(start); took < 400*time.Millisecond || took > 2*time.Second {
		t.Fatalf("closed after %v, want soon after 400ms", took)
	}
	if n := testutil.ToFloat64(out.recycled.WithLabelValues("out", "forced")); n != 1 {
		t.Errorf("recycled by force = %v", n)
	}
}

func TestParse(t *testing.T) {
	in, err := ParseInbound("0.0.0.0:6380,127.0.0.1:6379,spiffe://runway/api,spiffe://runway/operator")
	if err != nil || in.Target != "127.0.0.1:6379" || len(in.Allowed) != 2 {
		t.Fatalf("%+v %v", in, err)
	}
	out, err := ParseOutbound("127.0.0.1:16379,redis-0.redis:6380,spiffe://runway/redis")
	if err != nil || out.Server != "spiffe://runway/redis" {
		t.Fatalf("%+v %v", out, err)
	}
	for _, bad := range []string{"", "a,b", "a,b,c,d"} {
		if _, err := ParseOutbound(bad); err == nil {
			t.Errorf("ParseOutbound(%q) should fail", bad)
		}
	}
	if _, err := ParseInbound("a,b"); err == nil {
		t.Error("an inbound with no allowed callers should fail")
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/tlsproxy/ && go test -race -count=1 ./internal/tlsproxy/ -->

**Break it.** In `copy`, replace the whole `CloseWrite` branch with a plain `dst.Close()`, and run the tests:

~~~text
--- FAIL: TestBytesCrossBothProxies (0.03s)
    tlsproxy_test.go:111: got "", <nil>
~~~

The test's client sends its request, closes its sending side, and reads the answer. With a full close, the answer had nowhere to go: it got nothing back. Put it back.

### The command

Create `cmd/tlsproxy/main.go`:

<!-- file: cmd/tlsproxy/main.go -->
~~~go
// Command tlsproxy is a sidecar that gives mutual TLS to a program that
// doesn't speak it, without changing the program (Phase 6, step 8). See
// internal/tlsproxy.
//
//	tlsproxy -tls DIR [-in LISTEN,TARGET,ID[,ID...]]... [-out LISTEN,TARGET,ID]...
//
//	-tls DIR       its certificate, from cmd/ca (the Secret tls-SERVICE)
//	-in            take TLS on LISTEN from the identities ID..., pass to TARGET
//	-out           take plain connections on LISTEN, carry them to TARGET over
//	               TLS; TARGET must prove it is ID
//	-admin ADDR    /ready and /metrics (default 0.0.0.0:9901)
//	-max-age D     recycle connections older than this (default 10m; 0: never)
//
// For example, beside Redis, which then listens only on 127.0.0.1:
//
//	tlsproxy -tls /etc/runway/tls -in 0.0.0.0:6380,127.0.0.1:6379,spiffe://runway/api
//
// and beside the API, which then connects to Redis at 127.0.0.1:16379:
//
//	tlsproxy -tls /etc/runway/tls -out 127.0.0.1:16379,redis-0.redis:6380,spiffe://runway/redis
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"runway/internal/pki"
	"runway/internal/tlsproxy"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "tlsproxy:", err)
		os.Exit(1)
	}
}

type list []string

func (l *list) String() string     { return strings.Join(*l, " ") }
func (l *list) Set(v string) error { *l = append(*l, v); return nil }

// procs is how many threads run Go code at once, unless GOMAXPROCS says
// otherwise. Go's default is one per CPU the container may use, which with
// no CPU limit is every CPU on the node: 16 here. The proxy wakes for every
// small message, and with 16 the scheduler spent its time starting and
// parking threads. Measured through a pair of these proxies, 20 Redis
// clients: 16 gave 7,900 requests a second for 2.7 CPUs each; 2 gave
// 17,000 for 1.8. A CPU limit of 1 instead gave 8,500, with p99 at 40 ms:
// the kernel stops a container that spends its quota, until the next
// 100 ms period.
const procs = 2

func run(ctx context.Context, args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("tlsproxy", flag.ContinueOnError)
	tlsDir := fs.String("tls", "", "certificate directory")
	admin := fs.String("admin", "0.0.0.0:9901", "address for /ready and /metrics")
	maxAge := fs.Duration("max-age", 10*time.Minute, "recycle connections older than this")
	var ins, outs list
	fs.Var(&ins, "in", "LISTEN,TARGET,ID[,ID...] (repeatable)")
	fs.Var(&outs, "out", "LISTEN,TARGET,ID (repeatable)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *tlsDir == "" || len(ins)+len(outs) == 0 {
		return errors.New("usage: tlsproxy -tls DIR [-in LISTEN,TARGET,ID...]... [-out LISTEN,TARGET,ID]...")
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
	if os.Getenv("GOMAXPROCS") == "" {
		runtime.GOMAXPROCS(min(procs, runtime.GOMAXPROCS(0)))
	}
	src, err := pki.NewSource(*tlsDir, logger)
	if err != nil {
		return fmt.Errorf("-tls: %w", err)
	}
	proxy := tlsproxy.New(src, logger)
	proxy.MaxAge = *maxAge

	// Bind every listener before saying it is ready: the program beside it
	// starts only then (a native sidecar), and must find them open.
	var listeners []net.Listener
	defer func() {
		for _, l := range listeners {
			l.Close()
		}
	}()
	errs := make(chan error, len(ins)+len(outs))
	for _, spec := range ins {
		in, err := tlsproxy.ParseInbound(spec)
		if err != nil {
			return err
		}
		l, err := net.Listen("tcp", in.Listen)
		if err != nil {
			return err
		}
		listeners = append(listeners, l)
		go func() { errs <- proxy.ServeInbound(l, in) }()
		logger.Info("inbound", "listen", in.Listen, "target", in.Target, "allowed", strings.Join(in.Allowed, ","))
	}
	for _, spec := range outs {
		out, err := tlsproxy.ParseOutbound(spec)
		if err != nil {
			return err
		}
		l, err := net.Listen("tcp", out.Listen)
		if err != nil {
			return err
		}
		listeners = append(listeners, l)
		go func() { errs <- proxy.ServeOutbound(l, out) }()
		logger.Info("outbound", "listen", out.Listen, "target", out.Target, "server", out.Server)
	}

	registry := prometheus.NewRegistry()
	registry.MustRegister(proxy.Collectors()...)
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))
	mux.HandleFunc("GET /ready", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok\n") })
	adminServer := &http.Server{Addr: *admin, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = adminServer.ListenAndServe() }()
	logger.Info("tlsproxy started", "id", pki.IDOf(src.Certificate()), "admin", *admin, "max_age", maxAge.String(), "procs", runtime.GOMAXPROCS(0))

	select {
	case <-ctx.Done():
	case err := <-errs:
		return err
	}
	// As a native sidecar, it is stopped after the program beside it has
	// exited, so whatever is still open has no one left to serve; give it a
	// moment, then go.
	for _, l := range listeners {
		l.Close()
	}
	finished := make(chan struct{})
	go func() { proxy.Wait(); close(finished) }()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
	}
	shutdown, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	return adminServer.Shutdown(shutdown)
}
~~~

Look at `procs`. Go runs as many threads as the container may use CPUs, and with no CPU limit that's every CPU on the node: 16 on mine. A proxy wakes for every small message, and with 16 threads the scheduler spent its time starting and parking them. The comment has the numbers, from the measurements below.

Create `cmd/tlsproxy/main_test.go`:

<!-- file: cmd/tlsproxy/main_test.go -->
~~~go
package main

import (
	"context"
	"crypto/x509"
	"io"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"runway/internal/pki"
)

func TestUsage(t *testing.T) {
	dir := t.TempDir()
	ca, _ := pki.NewCA("test", time.Now(), time.Hour)
	leaf, _ := ca.Issue("redis", nil, time.Now(), time.Hour)
	if err := leaf.Save(dir, []*x509.Certificate{ca.Cert}); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		args []string
		want string
	}{
		{nil, "usage"},
		{[]string{"-tls", dir}, "usage"}, // nothing to proxy
		{[]string{"-in", "a,b,c"}, "usage"},
		{[]string{"-tls", filepath.Join(dir, "missing"), "-in", "127.0.0.1:0,b,c"}, "-tls"},
		{[]string{"-tls", dir, "-out", "127.0.0.1:0,b"}, "want LISTEN,TARGET,ID"},
	} {
		err := run(context.Background(), tc.args, io.Discard)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%v: %v, want an error about %q", tc.args, err, tc.want)
		}
	}
}
~~~

### What a hop costs

Before deploying it, measure it on your machine. Create `internal/tlsproxy/bench_test.go`:

<!-- file: internal/tlsproxy/bench_test.go -->
~~~go
package tlsproxy

import (
	"bufio"
	"io"
	"net"
	"sync"
	"testing"

	"runway/internal/pki"
)

// relay forwards every connection on l to target, in plain text: a hop
// without TLS, to tell the cost of the hops from the cost of the crypto.
func relay(l net.Listener, target string) {
	for {
		c, err := l.Accept()
		if err != nil {
			return
		}
		go func() {
			t, err := net.Dial("tcp", target)
			if err != nil {
				c.Close()
				return
			}
			go func() { io.Copy(t, c); t.Close() }()
			io.Copy(c, t)
			c.Close()
		}()
	}
}

// BenchmarkRoundTrip sends small requests as Redis commands go: one out,
// one back, on 20 kept connections. "direct" is straight to the server;
// "relays" through two plain hops; "tlsproxy" through both proxies.
func BenchmarkRoundTrip(b *testing.B) {
	for _, mode := range []string{"direct", "relays", "tlsproxy"} {
		b.Run(mode, func(b *testing.B) { roundTrips(b, mode) })
	}
}

func roundTrips(b *testing.B, mode string) {
	dir, _ := certs(b, "api", "redis")
	echo, _ := net.Listen("tcp", "127.0.0.1:0")
	defer echo.Close()
	go func() {
		for {
			c, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	inL, _ := net.Listen("tcp", "127.0.0.1:0")
	outL, _ := net.Listen("tcp", "127.0.0.1:0")
	defer inL.Close()
	defer outL.Close()
	addr := outL.Addr().String()
	switch mode {
	case "direct":
		addr = echo.Addr().String()
	case "relays":
		go relay(inL, echo.Addr().String())
		go relay(outL, inL.Addr().String())
	default:
		go proxy(b, dir, "redis").ServeInbound(inL, Inbound{Listen: "in", Target: echo.Addr().String(), Allowed: []string{pki.ID("api")}})
		go proxy(b, dir, "api").ServeOutbound(outL, Outbound{Listen: "out", Target: inL.Addr().String(), Server: pki.ID("redis")})
	}

	const clients = 20
	conns := make([]net.Conn, clients)
	for i := range conns {
		c, err := net.Dial("tcp", addr)
		if err != nil {
			b.Fatal(err)
		}
		defer c.Close()
		conns[i] = c
	}
	msg := []byte("*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n")
	b.ResetTimer()
	var wg sync.WaitGroup
	per := b.N/clients + 1
	for _, c := range conns {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := bufio.NewReader(c)
			buf := make([]byte, len(msg))
			for range per {
				c.Write(msg)
				if _, err := io.ReadFull(r, buf); err != nil {
					return
				}
			}
		}()
	}
	wg.Wait()
}
~~~

It sends small request-and-answer pairs, the shape of Redis commands, over 20 connections, three ways: straight to an echo server; through two *plain* relays; and through the two proxies. The middle one separates the cost of the hops from the cost of the cryptography.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/tlsproxy/... ./cmd/tlsproxy/... -->

~~~bash
go test -run '^$' -bench RoundTrip -benchtime 3s -count 3 ./internal/tlsproxy/
~~~

~~~text
BenchmarkRoundTrip/direct-16         	  412927	      8865 ns/op
BenchmarkRoundTrip/direct-16         	  429931	      9137 ns/op
BenchmarkRoundTrip/direct-16         	  407336	      7795 ns/op
BenchmarkRoundTrip/relays-16         	  141225	     25758 ns/op
BenchmarkRoundTrip/relays-16         	  132321	     29884 ns/op
BenchmarkRoundTrip/relays-16         	  126228	     28945 ns/op
BenchmarkRoundTrip/tlsproxy-16       	  127466	     27010 ns/op
BenchmarkRoundTrip/tlsproxy-16       	  111888	     28042 ns/op
BenchmarkRoundTrip/tlsproxy-16       	  112216	     29298 ns/op
~~~

Two hops roughly tripled the round trip. TLS added almost nothing on top: the two plain relays cost about the same as the two proxies. So the price of a sidecar is the hops themselves (more system calls, more wake-ups, more copies), not the cryptography. AES on a modern CPU is cheap; going through the kernel twice more isn't.

### Deploying it

Redis listens on its loopback, and its sidecar takes mutual TLS from the API alone. In `deploy/k8s/redis.yaml`:

Change:

<!-- edit: deploy/k8s/redis.yaml -->
~~~yaml
# needs: it must reach a particular server, not any of them.
apiVersion: apps/v1
~~~

to:

~~~yaml
# needs: it must reach a particular server, not any of them.
#
# Phase 6, step 8: Redis can't check who is calling, and any Pod could read
# or rewrite the cache. Now it listens only on its Pod's loopback, and a
# sidecar (tlsproxy) beside it takes mutual TLS on 6380 from the API alone.
apiVersion: apps/v1
~~~

Change:

<!-- edit: deploy/k8s/redis.yaml -->
~~~yaml
      labels: { app: redis }
    spec:
      containers:
~~~

to:

~~~yaml
      labels: { app: redis }
      annotations:
        # The sidecar's metrics: connections taken, refused, recycled.
        prometheus.io/scrape: "true"
        prometheus.io/port: "9901"
    spec:
      securityContext:
        fsGroup: 65532 # the sidecar's group, so it can read its certificate
      automountServiceAccountToken: false
      # A native sidecar: an init container that keeps running. Kubernetes
      # starts it, and waits for its startup probe, before Redis; and stops
      # it only after Redis has stopped.
      initContainers:
        - name: tlsproxy
          image: runway:dev
          restartPolicy: Always
          command: ["/usr/local/bin/tlsproxy", "-tls", "/etc/runway/tls",
                    "-in", "0.0.0.0:6380,127.0.0.1:6379,spiffe://runway/api"]
          ports:
            - { name: tls, containerPort: 6380 }
            - { name: proxy-admin, containerPort: 9901 }
          startupProbe:
            httpGet: { path: /ready, port: proxy-admin }
            periodSeconds: 1
            failureThreshold: 30
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { memory: 64Mi }
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: tls, mountPath: /etc/runway/tls, readOnly: true }
      containers:
~~~

Change:

<!-- edit: deploy/k8s/redis.yaml -->
~~~yaml
          ports:
            - { name: redis, containerPort: 6379 }
~~~

to:

~~~yaml
          # The loopback only: from outside the Pod, the sidecar is the way in.
          args: ["--bind", "127.0.0.1"]
~~~

Change:

<!-- edit: deploy/k8s/redis.yaml -->
~~~yaml
            limits: { memory: 128Mi }
---
~~~

to:

~~~yaml
            limits: { memory: 128Mi }
      volumes:
        - name: tls
          secret:
            secretName: tls-redis
            defaultMode: 0440
---
~~~

Change:

<!-- edit: deploy/k8s/redis.yaml -->
~~~yaml
    - { name: redis, port: 6379, targetPort: redis }
~~~

to:

~~~yaml
    - { name: tls, port: 6380, targetPort: tls }
~~~


The API gets an outbound sidecar with one local port per Redis server, and `REDIS_URL` pointing at them. In `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
  maxConnectionAge: 10m

~~~

to:

~~~yaml
  maxConnectionAge: 10m

# Redis through sidecars (Phase 6, step 8). Redis can't check who calls it,
# so a tlsproxy beside each server (deploy/k8s/redis.yaml) takes mutual TLS
# from the API alone, and one beside each API Pod carries the API's
# connections there. The API connects to 127.0.0.1:firstPort for the first
# server, the next port for the next, and so on; its own code is unchanged.
# Needs tls.enabled. Off: the API uses REDIS_URL from config as it is,
# which reaches Redis only if Redis listens beyond its own Pod; the one in
# deploy/k8s/redis.yaml doesn't, so the API would run without its cache.
redisProxy:
  enabled: true
  servers: [redis-0.redis:6380, redis-1.redis:6380, redis-2.redis:6380]
  firstPort: 16379

~~~


In `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
  terminationGracePeriodSeconds: {{ $api.terminationGracePeriodSeconds }}
  containers:
~~~

to:

~~~yaml
  terminationGracePeriodSeconds: {{ $api.terminationGracePeriodSeconds }}
  {{- with $root.Values.redisProxy }}
  {{- if .enabled }}
  # Step 8: a native sidecar (an init container that keeps running), up
  # before the API starts and down only after it stops. It speaks for the
  # Pod with the API's certificate.
  initContainers:
    - name: tlsproxy
      image: {{ include "runway.image" (list $root $.tag) }}
      imagePullPolicy: {{ $root.Values.image.pullPolicy }}
      restartPolicy: Always
      command:
        - /usr/local/bin/tlsproxy
        - -tls
        - /etc/runway/tls
        {{- range $i, $server := .servers }}
        - -out
        - {{ printf "127.0.0.1:%d,%s,spiffe://runway/redis" (add $.root.Values.redisProxy.firstPort $i) $server }}
        {{- end }}
      ports:
        - { name: proxy-admin, containerPort: 9901 }
      startupProbe:
        httpGet: { path: /ready, port: proxy-admin }
        periodSeconds: 1
        failureThreshold: 30
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
      {{- include "runway.containerSecurity" $root | nindent 6 }}
      volumeMounts:
        {{- include "runway.tlsMount" . | nindent 8 }}
  {{- end }}
  {{- end }}
  containers:
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        {{- end }}
        {{- end }}
~~~

to:

~~~yaml
        {{- end }}
        {{- end }}
        {{- if $root.Values.redisProxy.enabled }}
        {{- $urls := list }}
        {{- range $i, $_ := $root.Values.redisProxy.servers }}
        {{- $urls = append $urls (printf "redis://127.0.0.1:%d/0" (add $root.Values.redisProxy.firstPort $i)) }}
        {{- end }}
        # Overrides the one in config: through the sidecar (step 8).
        - { name: REDIS_URL, value: {{ join "," $urls | quote }} }
        {{- end }}
~~~


In `deploy/helm/runway/templates/api.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/api.yaml -->
~~~yaml
{{- fail "auth.issuer must start https:// with tls.enabled, and http:// without: the chart's issuer serves one or the other" }}
{{- end }}
~~~

to:

~~~yaml
{{- fail "auth.issuer must start https:// with tls.enabled, and http:// without: the chart's issuer serves one or the other" }}
{{- end }}
{{- if and .Values.redisProxy.enabled (not .Values.tls.enabled) }}
{{- fail "redisProxy.enabled needs tls.enabled: the sidecar proves who the API is with the API's certificate" }}
{{- end }}
~~~


Redis's sidecar needs a certificate. In `deploy/certs.sh`:

Change:

<!-- edit: deploy/certs.sh -->
~~~bash
  [metad]="metad.runway,*.metad.runway,*.metad.runway.svc"
)
for service in api gateway idp metad; do
~~~

to:

~~~bash
  [metad]="metad.runway,*.metad.runway,*.metad.runway.svc"
  [redis]="*.redis.runway,*.redis.runway.svc" # its sidecar's (step 8)
)
for service in api gateway idp metad redis; do
~~~


The smoke test needs certificates *before* Redis now, since Redis's sidecar won't start without one, and it applies Redis with the image under test. The certificate block moves up, so here is the whole of `deploy/smoke.sh`:

<!-- file: deploy/smoke.sh -->
~~~bash
#!/usr/bin/env bash
# Deploy Runway to the current kubectl cluster and check that one job runs
# from start to finish. CI runs this on a throwaway kind cluster against the
# image it just built; you can run it against yours.
#   deploy/smoke.sh [IMAGE_TAG]
set -euo pipefail
tag=${1:-dev}
url=${RUNWAY_URL:-http://localhost:8000} # the gateway: the API itself wants a client certificate

kubectl apply -f deploy/k8s/config.yaml # the namespace, first

# Certificates for mutual TLS (step 7), from a CA made for this cluster, the
# first time. Keep the CA's directory if you want to renew them later.
# Redis's sidecar needs its own before Redis can start (step 8).
if ! kubectl -n runway get secret tls-api >/dev/null 2>&1; then
  ca=$(mktemp -d)
  go run ./cmd/ca init "$ca/ca"
  deploy/certs.sh "$ca/ca"
  echo "the CA is in $ca/ca"
elif ! kubectl -n runway get secret tls-redis >/dev/null 2>&1; then
  echo "no tls-redis Secret: run deploy/certs.sh with your CA's directory first" >&2
  exit 1
fi

# Redis's sidecar is Runway's own tlsproxy, from the image being tested.
kubectl apply -f deploy/k8s/postgres.yaml -f deploy/k8s/rabbitmq.yaml
sed "s|image: runway:dev|image: runway:$tag|" deploy/k8s/redis.yaml | kubectl apply -f -
# "rollout status", not "wait": wait fails at once if the Pods don't exist yet.
for store in postgres rabbitmq redis; do
  kubectl -n runway rollout status "statefulset/$store" --timeout=300s
done

# The token issuer's key and a client, made once per cluster (Phase 6).
if ! kubectl -n runway get secret idp-keys >/dev/null 2>&1; then
  keys=$(mktemp -d)
  go run ./cmd/idp rotate "$keys"
  kubectl -n runway create secret generic idp-keys --from-file="$keys"
  rm -rf "$keys"
fi
if ! kubectl -n runway get secret idp-clients >/dev/null 2>&1; then
  kubectl -n runway create secret generic idp-clients \
    --from-literal=IDP_CLIENTS="smoke:$(openssl rand -hex 32):smoke:submitter+reader"
fi

# install the first time, upgrade after that
helm upgrade --install runway deploy/helm/runway -n runway \
  --set image.tag="$tag" --wait --timeout 5m

# A token for the first client in the Secret, through a port-forward to
# the issuer. (Whoever runs this can read Secrets anyway.) Over HTTPS, the
# issuer proves it is idp.runway with a certificate from the cluster's CA.
client=$(kubectl -n runway get secret idp-clients -o jsonpath='{.data.IDP_CLIENTS}' | base64 -d | cut -d, -f1)
cacert=$(mktemp)
kubectl -n runway get secret tls-idp -o jsonpath='{.data.ca\.crt}' | base64 -d >"$cacert"
kubectl -n runway port-forward svc/idp 18081:8081 >/dev/null 2>&1 &
forward=$!
trap 'kill $forward 2>/dev/null; rm -f "$cacert"' EXIT
sleep 2
token=$(curl -sf --cacert "$cacert" --resolve idp.runway:18081:127.0.0.1 \
  -u "$(echo "$client" | cut -d: -f1):$(echo "$client" | cut -d: -f2)" \
  -d grant_type=client_credentials https://idp.runway:18081/token | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
auth="Authorization: Bearer $token"

created=$(curl -sf -X POST "$url/jobs" -H "$auth" -H 'Content-Type: application/json' \
  -d '{"description":"smoke test","duration_ms":50}')
id=$(echo "$created" | sed 's/{"id":\([0-9]*\).*/\1/')
for _ in $(seq 30); do
  job=$(curl -sf -H "$auth" "$url/jobs/$id")
  case "$job" in
    *'"state":"completed"'*) echo "smoke test passed: job $id completed"; exit 0 ;;
    *'"state":"failed"'*) break ;;
  esac
  sleep 1
done
echo "smoke test failed: $job" >&2
kubectl -n runway get pods >&2
exit 1
~~~

And one change found while measuring. RabbitMQ's readiness probe ran `rabbitmq-diagnostics`, which starts a whole Erlang virtual machine every five seconds. During the benchmarks it was using 1.6 to 2 CPUs, all day, on an idle broker. A TCP probe asks nearly the same question for almost nothing (9 millicores, measured afterwards). In `deploy/k8s/rabbitmq.yaml`:

Change:

<!-- edit: deploy/k8s/rabbitmq.yaml -->
~~~yaml
            - { name: prometheus, containerPort: 15692 } # step 10
          readinessProbe:
            exec: { command: ["rabbitmq-diagnostics", "-q", "check_port_connectivity"] }
            periodSeconds: 5
            timeoutSeconds: 10
~~~

to:

~~~yaml
            - { name: prometheus, containerPort: 15692 } # step 10
          # Is the AMQP port taking connections? A TCP probe asks the same
          # question rabbitmq-diagnostics check_port_connectivity did, but
          # that started a whole Erlang VM every 5 seconds: measured in
          # Phase 6, step 8, it cost 1.6 to 2 CPUs, all day.
          readinessProbe:
            tcpSocket: { port: amqp }
            periodSeconds: 5
~~~

<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway | grep -q 'redis://127.0.0.1:16379/0' && ! helm template runway deploy/helm/runway --set tls.enabled=false --set auth.issuer=http://idp.runway:8081 2>/dev/null -->

### Run it

Issue Redis its certificate, build, apply Redis, then the chart:

~~~bash
deploy/certs.sh ~/.runway/ca
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
kubectl apply -f deploy/k8s/redis.yaml -f deploy/k8s/rabbitmq.yaml
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait
kubectl -n runway get pods -l "app in (api,redis)"
~~~

~~~text
NAME                   READY   STATUS    RESTARTS   AGE
api-7bdfb44f8d-254tl   2/2     Running   0          44s
api-7bdfb44f8d-sm9fz   2/2     Running   0          49s
api-7bdfb44f8d-wf4hg   2/2     Running   0          56s
redis-0                2/2     Running   0          3m16s
redis-1                2/2     Running   0          3m20s
redis-2                2/2     Running   0          3m26s
~~~

Two containers in each Pod. I did this under load, five jobs a second through the gateway, and got no errors at all. That's partly luck of design: for the minutes between Redis moving behind its sidecar and the API getting its own, the old API Pods couldn't reach Redis ("connection refused"), and the cache and rate limiter fell back, as they were built to in Phases 3 and 6. A service that *needed* Redis would have failed for those minutes. Order your rollouts so that both sides overlap, or accept the gap knowingly.

**A Helm gotcha, again.** My first upgrade used `--reuse-values`:

~~~text
Error: UPGRADE FAILED: runway/templates/api.yaml:8:18
  executing "runway/templates/api.yaml" at <.Values.redisProxy.enabled>:
    nil pointer evaluating interface {}.enabled
~~~

`--reuse-values` reuses the *old release's* values and ignores the chart's new defaults, so `redisProxy` didn't exist. That's why this guide always says `--reset-then-reuse-values`.

**Break it: the intruder, and two thieves.** The intruder from the start, then a Pod holding the gateway's certificate, then one holding the API's:

~~~bash
kubectl -n runway exec intruder -- redis-cli -h redis-0.redis -p 6379 GET runway:job:v2:acme:26282
kubectl -n runway exec intruder -- redis-cli -h redis-0.redis -p 6380 GET runway:job:v2:acme:26282
kubectl -n runway exec thief -- redis-cli -h redis-0.redis -p 6380 --tls --cacert /stolen/gateway/ca.crt --cert /stolen/gateway/tls.crt --key /stolen/gateway/tls.key --sni redis-0.redis.runway GET runway:job:v2:acme:26282
kubectl -n runway exec thief -- redis-cli -h redis-0.redis -p 6380 --tls --cacert /stolen/api/ca.crt --cert /stolen/api/tls.crt --key /stolen/api/tls.key --sni redis-0.redis.runway GET runway:job:v2:acme:26282
kubectl get --raw /api/v1/namespaces/runway/pods/redis-0:9901/proxy/metrics | grep ^tlsproxy_connections_total
kubectl -n runway logs redis-0 -c tlsproxy | grep 'connection refused'
~~~

~~~text
Could not connect to Redis at redis-0.redis:6379: Connection refused
Error: Server closed the connection
Error: Server closed the connection
{"ID":26282,"Tenant":"acme","Description":"quarterly payroll export","Duration":10000000,"State":"completed","FailureReason":"","CreatedAt":"2026-10-10T13:00:15.09731Z","UpdatedAt":"2026-10-10T13:00:15.192453Z"}
tlsproxy_connections_total{listener="0.0.0.0:6380",result="ok"} 6
tlsproxy_connections_total{listener="0.0.0.0:6380",result="refused"} 4
{"time":"2026-10-10T13:00:20.550461406Z","level":"WARN","msg":"connection refused","listener":"0.0.0.0:6380","from":"10.244.2.51:55914","error":"tls: first record does not look like a TLS handshake"}
{"time":"2026-10-10T13:00:20.970045472Z","level":"WARN","msg":"connection refused","listener":"0.0.0.0:6380","from":"10.244.1.30:44032","error":"peer identity not allowed: \"spiffe://runway/gateway\" (allowed: [spiffe://runway/api])"}
~~~

(The thief mounts both Secrets, `tls-gateway` at `/stolen/gateway` and `tls-api` at `/stolen/api`.) Port 6379 is closed from outside the Pod. Port 6380 refuses plain text and the gateway's certificate. And the API's stolen certificate works: to Redis's sidecar, whoever holds it *is* the API. Mutual TLS moves the question from "can you reach it?" to "do you hold the key?". The key is a file in a Secret, which is why step 9 is about secrets.

**Break it: forget the bind.** Keep the sidecar, but let Redis listen on every interface again, as a hasty edit of the manifest would:

~~~bash
sed /--bind/d deploy/k8s/redis.yaml | kubectl apply -f -
kubectl -n runway exec intruder -- redis-cli -h redis-0.redis -p 6379 GET runway:job:v2:acme:37183
kubectl get --raw /api/v1/namespaces/runway/pods/redis-0:9901/proxy/metrics | grep ^tlsproxy_connections_total
kubectl apply -f deploy/k8s/redis.yaml     # put the bind back
~~~

~~~text
{"ID":37183,"Tenant":"acme","Description":"quarterly payroll export","Duration":10000000,"State":"completed","FailureReason":"","CreatedAt":"2026-10-10T14:06:10.197485Z","UpdatedAt":"2026-10-10T14:06:10.329405Z"}
tlsproxy_connections_total{listener="0.0.0.0:6380",result="ok"} 3
~~~

The intruder reads the cache again, and the sidecar's metrics look perfectly healthy: the API still goes through it. A sidecar protects only the paths that go through it. Nothing about the sidecar can tell you there's another way in. Step 12's network policies close that door from the outside, so it's no longer one line of one manifest.

**Measure it on the cluster.** A `redis-benchmark` Pod on the other node from `redis-0` (so every request crosses the network, as the API's do), first straight to Redis, then through a sidecar of its own with the API's certificate. Plain, sidecar, plain, sidecar, so a busy moment can't masquerade as a difference. GETs per second with 20 kept connections, latency, new connections per second, a job's end-to-end latency through the gateway, and each container's CPU:

~~~text
round          GET/s  p50 ms  p99 ms  new conn/s  new p50   e2e p50/p95/p99 ms   CPU (millicores)
r1-plain       26055    0.40    1.21        8999      4.7    13.0 /  19.4 /  23.8   bench/bench 953, redis-0/redis 548
r2-sidecar     16781    0.97    3.66         800     23.6    17.2 /  28.2 /  44.4   bench/bench 489, bench/tlsproxy 1804, redis-0/redis 508, redis-0/tlsproxy 1839
r3-plain       24988    0.41    1.25        9027      4.2    12.9 /  19.0 /  24.8   bench/bench 868, redis-0/redis 426
r4-sidecar     17298    0.95    3.43         787     23.5    15.4 /  24.0 /  30.1   bench/bench 435, bench/tlsproxy 1782, redis-0/redis 471, redis-0/tlsproxy 1736
~~~

Read it carefully, because each column says something different.
- **Throughput fell by a third**, and the median GET went from 0.4 to about 1 ms: the extra hops.
- **New connections fell by an order of magnitude**, from 9,000 a second to 800. Each one is now a TLS handshake, with two ECDSA signatures to check. A client that opens a connection per request pays heavily; one that keeps a pool barely notices. That's another reason for connection pools.
- **A job's end-to-end latency rose by 2 to 4 ms at the median.** A job makes one Redis round trip (the rate limiter), plus the cache.
- **The sidecars used more CPU than Redis itself**: about 1.8 CPUs each, against half a CPU for Redis. This was the benchmark flat out. At Runway's real load it's a few millicores, but the ratio is the true cost of a mesh, paid on every Pod.

Two more rounds, one setting each, explain the `procs` line in `cmd/tlsproxy`. With Go's default of 16 threads, the same benchmark managed **7,900** GETs a second for 2.7 CPUs per sidecar; with 2, about 17,000 for 1.8. And a CPU *limit* of 1 instead gave 8,500 a second with p99 at **40 ms**: the kernel's CFS quota stops a container that has spent its share until the next 100 ms period begins, so a busy proxy stalls in tenth-of-a-second steps. CPU limits on latency-sensitive proxies are a classic way to make p99 terrible.

**Old connections are recycled.** Twelve minutes of a job every five seconds, past the ten-minute maximum age:

~~~text
# 12 minutes of a job every 5 s:     143 201
== api-75d484c849-gnch7
tlsproxy_recycled_total{how="forced",listener="127.0.0.1:16379"} 1
tlsproxy_recycled_total{how="forced",listener="127.0.0.1:16381"} 1
tlsproxy_recycled_total{how="quiet",listener="127.0.0.1:16380"} 1
== redis-1
tlsproxy_recycled_total{how="forced",listener="0.0.0.0:6380"} 1
tlsproxy_recycled_total{how="quiet",listener="0.0.0.0:6380"} 3
# rate limiter errors on the API (each instance):
rate_limiter_errors_total 0
rate_limiter_errors_total 0
rate_limiter_errors_total 0
~~~

(Trimmed to one API Pod and one Redis.) Every connection was replaced, some in a quiet moment, some forced after the grace period, and nothing failed.

**Break it: the order of containers.** Why a *native* sidecar? I ran a copy of the API Deployment with `tlsproxy` as an ordinary second container instead, five times. On *start*, it never failed, because the API happens to connect to PostgreSQL and RabbitMQ before Redis, and by then the proxy is up. That's luck, not design. On *stop*, both containers get `SIGTERM` at the same moment. With the API's five-second `preStop` sleep (Phase 5), the proxy waited for its open connections and nothing user-visible failed, though in one of three runs the API logged four `connection refused` lines to Redis while stopping. With a ten-second `preStop`, the proxy was gone five seconds before the API, and the API logged 18 and 19 refused dials in two runs, counted two cache errors, and its circuit breaker opened. The native sidecar, with the same ten seconds: zero. Users saw no errors in any run, because the cache is optional. A sidecar in front of the database would have failed requests.

**Explain it:** what can't a layer-4 proxy see, and what does that cost when recycling connections? Why did the cost of the sidecar come from the hops, not TLS, and how did the plain relays show it? Why did a stolen API certificate get into Redis? Why did removing `--bind` go unnoticed? Why does a native sidecar matter at shutdown more than at startup?

**Read.** The Istio documentation's [architecture](https://istio.io/latest/docs/ops/deployment/architecture/) page, and Linkerd's *Why Linkerd doesn't use Envoy* (2020): what does each mesh's proxy cost? Then the Kubernetes blog post introducing native sidecar containers (2023). Then Dan Luu, or any write-up, on CFS quota throttling: why do latency-sensitive services often run without CPU limits?

---
## Step 9: Secrets

**The problem.** Step 8 ended with a stolen certificate, and every credential Runway has is the same kind of thing: a file or an environment variable that works for anyone who copies it, for as long as it exists. Look at where they live now:

~~~bash
etcdctl() { kubectl -n kube-system exec etcd-runway-control-plane -- etcdctl --endpoints https://127.0.0.1:2379 \
  --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key "$@"; }
etcdctl get /registry/secrets/runway/runway | strings | grep -i -e pass -e url | head -1
kubectl -n runway get deploy api -o jsonpath='{..containers[?(@.name=="api")].envFrom}'; echo
kubectl -n runway get secret runway -o json | jq -r ".data | keys[]"
~~~

~~~text
{"apiVersion":"v1","kind":"Secret","metadata":{"annotations":{},"name":"runway","namespace":"runway"},"stringData":{"AMQP_URL":"amqp://runway:runway@rabbitmq:5672/","DATABASE_URL":"postgres://runway:runway@postgres:5432/runway","POSTGRES_PASSWORD":"runway","RABBITMQ_DEFAULT_PASS":"runway","RABBITMQ_DEFAULT_USER":"runway"}}
[{"configMapRef":{"name":"runway-config"}},{"secretRef":{"name":"runway"}}]
AMQP_URL
DATABASE_URL
POSTGRES_PASSWORD
RABBITMQ_DEFAULT_PASS
RABBITMQ_DEFAULT_USER
~~~

(That first line is the `last-applied-configuration` annotation, which client-side `kubectl apply` stores on every object it writes.) The Secret is stored in etcd as plain text: anyone with the etcd data, or a backup of it, has every password. Every key reaches every API Pod through `envFrom`, including the database superuser's password, which the API doesn't need. And what can that `DATABASE_URL` do? From the intruder Pod (an image with `psql`, such as `postgres:17`):

~~~bash
kubectl -n runway exec intruder -- psql "$DATABASE_URL" -c "SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
kubectl -n runway exec intruder -- psql "$DATABASE_URL" -c "CREATE TEMP TABLE out (line text); COPY out FROM PROGRAM 'id; hostname'; SELECT * FROM out"
kubectl -n runway exec intruder -- psql "$DATABASE_URL" -c "BEGIN; ALTER TABLE jobs DISABLE ROW LEVEL SECURITY; ROLLBACK"
~~~

~~~text
 rolname | rolsuper | rolbypassrls 
---------+----------+--------------
 runway  | t        | t
(1 row)

CREATE TABLE
COPY 2
                                  line                                  
------------------------------------------------------------------------
 uid=999(postgres) gid=999(postgres) groups=999(postgres),101(ssl-cert)
 postgres-0
(2 rows)

BEGIN
ALTER TABLE
ROLLBACK
~~~

A superuser can run programs on the database server (`COPY FROM PROGRAM`), and switch off step 4's row-level security. One leaked environment variable from one Pod is the whole database, and the shell under it, for as long as nobody changes the password. In practice, that means forever (T11, T12).

**New ideas.**

- **A secrets manager** (OpenBao here, an open-source fork of HashiCorp Vault with the same API; AWS Secrets Manager; Google Secret Manager) keeps secrets encrypted, hands them only to callers that prove who they are, and logs every access.
- **Workload identity.** How does a Pod prove who it is to the secrets manager, without a secret to start with? Kubernetes signs a short-lived token for each Pod's **service account**, with an audience naming who it's for. OpenBao asks Kubernetes whether the token is genuine (a **TokenReview**) and, if the account matches a role, issues an OpenBao token with that role's policies. No password is ever configured.
- **Dynamic secrets.** Instead of storing a database password, OpenBao *creates* a PostgreSQL login for each Pod that asks, valid for an hour, and drops it when the lease ends. A leaked login works for at most an hour, and belongs to one Pod, so the database's own logs say which one.
- **Least privilege, in the database.** No service needs to own the tables, and no service needs to be a superuser. Each gets a role with exactly the grants its code uses, and tests run as that role, so a missing grant fails a test, not a deployment.
- **Encryption as a service.** Webhook secrets (step 6) must be readable, since they're used to sign. OpenBao's **transit** engine encrypts them with a key that never leaves OpenBao, so the database holds ciphertext, and a copy of the database is useless. A **derived** key adds a context (the tenant), so a ciphertext copied into another tenant's row won't decrypt.
- **Sealing.** OpenBao's own storage is encrypted with a key that is itself encrypted, and it starts **sealed**: unreadable, until enough **unseal keys** are given (three of five, here, by Shamir's secret sharing). A stolen disk is useless; the price is that every restart needs someone to unseal it, or a cloud KMS to do it automatically.
- **Encryption at rest for Kubernetes Secrets**: the API server encrypts them before writing to etcd.

### A client for OpenBao

OpenBao's API is plain HTTP and JSON, and Runway makes four kinds of call: log in, read a dynamic secret, revoke a lease, and encrypt or decrypt. That's a small client. Create `internal/secrets/bao.go`:

<!-- file: internal/secrets/bao.go -->
~~~go
// Package secrets gets Runway's secrets from OpenBao (Phase 6, step 9), an
// open-source fork of HashiCorp Vault with the same HTTP API. It is a small
// client for the few calls Runway makes: log in with the Pod's Kubernetes
// identity, fetch a database login made for this Pod alone, revoke it, and
// encrypt or decrypt with a key that never leaves OpenBao.
package secrets

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Client calls one OpenBao server. Every call carries a token, which login
// provides and the client renews by logging in again.
type Client struct {
	addr  string
	http  *http.Client
	login func(ctx context.Context, c *Client) (token string, ttl time.Duration, err error)
	now   func() time.Time

	mu      sync.Mutex
	token   string
	renewAt time.Time // zero: the token never expires
}

// WithToken returns a client that uses token as it is: a root token in
// development, or one an operator made. It is never renewed.
func WithToken(addr string, hc *http.Client, token string) *Client {
	return &Client{addr: strings.TrimSuffix(addr, "/"), http: hc, now: time.Now,
		login: func(context.Context, *Client) (string, time.Duration, error) { return token, 0, nil }}
}

// WithKubernetes returns a client that logs in as the Pod's service
// account. jwtFile holds a token Kubernetes signed for this Pod, audience
// "bao"; OpenBao asks Kubernetes whether it is genuine (a TokenReview) and,
// if the account is one role allows, issues an OpenBao token with that
// role's policies. The file is read at every login: the kubelet replaces
// it before it expires.
func WithKubernetes(addr string, hc *http.Client, role, jwtFile string) *Client {
	return &Client{addr: strings.TrimSuffix(addr, "/"), http: hc, now: time.Now,
		login: func(ctx context.Context, c *Client) (string, time.Duration, error) {
			jwt, err := os.ReadFile(jwtFile)
			if err != nil {
				return "", 0, err
			}
			var out response
			body := map[string]string{"role": role, "jwt": strings.TrimSpace(string(jwt))}
			if err := c.do(ctx, http.MethodPost, "auth/kubernetes/login", "", body, &out); err != nil {
				return "", 0, fmt.Errorf("log in as role %q: %w", role, err)
			}
			if out.Auth == nil || out.Auth.ClientToken == "" {
				return "", 0, errors.New("log in: no token in the reply")
			}
			return out.Auth.ClientToken, time.Duration(out.Auth.LeaseDuration) * time.Second, nil
		}}
}

// Secret is what a read returns: data, and for a dynamic secret, the lease
// that ends it.
type Secret struct {
	LeaseID string
	TTL     time.Duration
	Data    map[string]any
}

type response struct {
	LeaseID       string         `json:"lease_id"`
	LeaseDuration int            `json:"lease_duration"`
	Data          map[string]any `json:"data"`
	Auth          *struct {
		ClientToken   string `json:"client_token"`
		LeaseDuration int    `json:"lease_duration"`
	} `json:"auth"`
	Errors []string `json:"errors"`
}

// Error is a reply OpenBao refused, with its status and reasons.
type Error struct {
	Status  int
	Reasons []string
}

func (e *Error) Error() string {
	return fmt.Sprintf("openbao: %d %s", e.Status, strings.Join(e.Reasons, "; "))
}

// Read gets the secret at path, such as "database/creds/api".
func (c *Client) Read(ctx context.Context, path string) (Secret, error) {
	return c.call(ctx, http.MethodGet, path, nil)
}

// ReadWithNewToken logs in again, then reads path with the new token.
//
// A dynamic secret is revoked when the token that asked for it expires,
// whatever its own lease says (measured: a 60 s database login was gone
// when its 20 s token expired). With a token of its own, made for it, the
// secret lives as long as the role's token TTL allows, and no less.
func (c *Client) ReadWithNewToken(ctx context.Context, path string) (Secret, error) {
	c.mu.Lock()
	c.token = ""
	c.mu.Unlock()
	return c.Read(ctx, path)
}

// Write sends body to path, such as "transit/encrypt/webhooks".
func (c *Client) Write(ctx context.Context, path string, body any) (Secret, error) {
	return c.call(ctx, http.MethodPost, path, body)
}

// Revoke ends a lease now, rather than when it expires. For a database
// login, OpenBao runs the role's revocation statements: the login is gone.
// The lease is named in the path, not the body, so a policy can allow a
// service to revoke its own kind of lease and no other.
func (c *Client) Revoke(ctx context.Context, leaseID string) error {
	_, err := c.call(ctx, http.MethodPut, "sys/leases/revoke/"+leaseID, nil)
	return err
}

func (c *Client) call(ctx context.Context, method, path string, body any) (Secret, error) {
	token, err := c.currentToken(ctx)
	if err != nil {
		return Secret{}, err
	}
	var out response
	if err := c.do(ctx, method, path, token, body, &out); err != nil {
		return Secret{}, err
	}
	return Secret{LeaseID: out.LeaseID, TTL: time.Duration(out.LeaseDuration) * time.Second, Data: out.Data}, nil
}

// currentToken logs in when there is no token yet, or when two thirds of
// the last one's life has passed.
func (c *Client) currentToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.token != "" && (c.renewAt.IsZero() || now.Before(c.renewAt)) {
		return c.token, nil
	}
	token, ttl, err := c.login(ctx, c)
	if err != nil {
		return "", err
	}
	c.token, c.renewAt = token, time.Time{}
	if ttl > 0 {
		c.renewAt = now.Add(ttl * 2 / 3)
	}
	return token, nil
}

func (c *Client) do(ctx context.Context, method, path, token string, body any, out *response) error {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.addr+"/v1/"+path, reader)
	if err != nil {
		return err
	}
	if token != "" {
		req.Header.Set("X-Vault-Token", token) // OpenBao kept Vault's header name
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode == http.StatusNoContent {
		return nil
	}
	var r response
	if len(data) > 0 {
		if err := json.Unmarshal(data, &r); err != nil {
			return fmt.Errorf("openbao: %d, unreadable reply: %w", resp.StatusCode, err)
		}
	}
	if resp.StatusCode >= 300 {
		return &Error{Status: resp.StatusCode, Reasons: r.Errors}
	}
	if out != nil {
		*out = r
	}
	return nil
}
~~~

Read `ReadWithNewToken`'s comment: it records a measurement that surprised me. A dynamic secret is revoked when *the token that asked for it* expires, whatever the secret's own lease says. My first version reused one token for everything, and a 60-second database login vanished when its 20-second token expired. So each fetch logs in afresh, and the role's token TTL must be at least the login's (`setup.sh` makes them equal). `Revoke` puts the lease ID in the path, not the body, so a policy can say "this service may revoke its own leases and no others".

Create `internal/secrets/config.go`:

<!-- file: internal/secrets/config.go -->
~~~go
package secrets

import (
	"errors"
	"net/http"
	"strings"

	"runway/internal/envconfig"
	"runway/internal/pki"
)

// Config says how a service reaches OpenBao:
//
//	BAO_ADDR      its address; unset: no OpenBao, and DATABASE_URL is used as it is
//	BAO_ROLE      the role to log in as, and the database role to get logins for
//	BAO_JWT_FILE  the Pod's token for OpenBao (default /var/run/secrets/bao/token)
//	BAO_TOKEN     a fixed token instead of logging in: development only
type Config struct {
	Addr, Role, JWTFile, Token string
}

// LoadConfig reads Config from the environment.
func LoadConfig(getenv envconfig.Getenv) (Config, error) {
	c := Config{Addr: getenv("BAO_ADDR"), Role: getenv("BAO_ROLE"), JWTFile: getenv("BAO_JWT_FILE"), Token: getenv("BAO_TOKEN")}
	if c.JWTFile == "" {
		c.JWTFile = "/var/run/secrets/bao/token"
	}
	if c.Addr != "" && c.Role == "" {
		return Config{}, errors.New("BAO_ADDR needs BAO_ROLE")
	}
	return c, nil
}

// Enabled says whether BAO_ADDR is set.
func (c Config) Enabled() bool { return c.Addr != "" }

// NewClient connects to OpenBao. Over https it uses tls, which must prove
// the server is spiffe://runway/bao (step 7); over http, nothing: compose's
// development server.
func (c Config) NewClient(tls *pki.Source) (*Client, error) {
	hc := &http.Client{}
	if strings.HasPrefix(c.Addr, "https://") {
		if tls == nil {
			return nil, errors.New("BAO_ADDR is https: set TLS_DIR to a certificate from our CA")
		}
		hc.Transport = &http.Transport{TLSClientConfig: pki.ClientConfig(tls, pki.ID("bao"))}
	}
	if c.Token != "" {
		return WithToken(c.Addr, hc, c.Token), nil
	}
	return WithKubernetes(c.Addr, hc, c.Role, c.JWTFile), nil
}
~~~

### Database logins that rotate

Create `internal/secrets/dblogin.go`:

<!-- file: internal/secrets/dblogin.go -->
~~~go
package secrets

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// Login is a database user and password that OpenBao made for this process
// alone, and the lease that will end it.
type Login struct {
	User, Password string
	LeaseID        string
	Fetched        time.Time
	Expires        time.Time
}

// DBLogins keeps a current login from OpenBao's database secrets engine.
// OpenBao creates a PostgreSQL role for each request, and drops it when the
// lease ends, so no password lives long, and each one belongs to one Pod.
//
// Two thirds of the way through a login's life, DBLogins fetches the next
// one and calls OnRotate, so the pool can open new connections with it.
// After Grace it revokes the old one: connections still using it then are
// cut off, which is the point, since a leaked login stops working too.
type DBLogins struct {
	client *Client
	path   string // such as "database/creds/api"
	logger *slog.Logger
	now    func() time.Time

	// Grace is how long the previous login lives on after a new one
	// arrives, for connections that are in the middle of something.
	Grace time.Duration
	// OnRotate is called after a new login replaces the old one.
	OnRotate func()

	mu       sync.Mutex
	current  Login
	retiring []Login // replaced, waiting out Grace before they are revoked

	rotations *prometheus.CounterVec
	expires   prometheus.GaugeFunc
	renew     prometheus.GaugeFunc
}

// NewDBLogins fetches logins from database/creds/role.
func NewDBLogins(client *Client, role string, logger *slog.Logger) *DBLogins {
	d := &DBLogins{
		client: client,
		path:   "database/creds/" + role,
		logger: logger,
		now:    time.Now,
		Grace:  time.Minute,
		rotations: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "db_login_fetches_total",
			Help: "Database logins requested from OpenBao, by result.",
		}, []string{"result"}),
	}
	d.expires = prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "db_login_expiry_timestamp_seconds",
		Help: "When the current database login expires, as a Unix time.",
	}, func() float64 { return float64(d.Current().Expires.Unix()) })
	// Past this time and not yet renewed, OpenBao is failing us: the
	// alert DatabaseLoginNotRenewed watches it.
	d.renew = prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "db_login_renew_timestamp_seconds",
		Help: "When the current database login is due to be replaced, as a Unix time.",
	}, func() float64 { return float64(renewAt(d.Current()).Unix()) })
	return d
}

// Collectors returns the metrics, for registration.
func (d *DBLogins) Collectors() []prometheus.Collector {
	return []prometheus.Collector{d.rotations, d.expires, d.renew}
}

// Current returns the login to open new connections with.
func (d *DBLogins) Current() Login {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.current
}

// Credentials returns the current user and password: what
// pgstore.PoolOptions.Login wants.
func (d *DBLogins) Credentials() (user, password string) {
	l := d.Current()
	return l.User, l.Password
}

// Fetch gets a new login and makes it current. Call it once before opening
// the pool; Run calls it from then on.
func (d *DBLogins) Fetch(ctx context.Context) error {
	s, err := d.client.ReadWithNewToken(ctx, d.path)
	if err != nil {
		d.rotations.WithLabelValues("error").Inc()
		return fmt.Errorf("database login from %s: %w", d.path, err)
	}
	user, _ := s.Data["username"].(string)
	password, _ := s.Data["password"].(string)
	if user == "" || password == "" || s.LeaseID == "" || s.TTL <= 0 {
		d.rotations.WithLabelValues("error").Inc()
		return fmt.Errorf("database login from %s: incomplete reply", d.path)
	}
	now := d.now()
	login := Login{User: user, Password: password, LeaseID: s.LeaseID, Fetched: now, Expires: now.Add(s.TTL)}
	d.mu.Lock()
	old := d.current
	d.current = login
	if old.LeaseID != "" {
		d.retiring = append(d.retiring, old)
	}
	d.mu.Unlock()
	d.rotations.WithLabelValues("ok").Inc()
	d.logger.Info("database login", "user", user, "expires", login.Expires.Format(time.RFC3339))
	return nil
}

// Run renews the login until ctx ends. When OpenBao can't be reached, it
// tries again, more slowly each time, while the current login still works.
func (d *DBLogins) Run(ctx context.Context) {
	backoff := time.Second
	for {
		cur := d.Current()
		wait := max(renewAt(cur).Sub(d.now()), 0)
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		if err := d.Fetch(ctx); err != nil {
			if ctx.Err() != nil {
				return
			}
			d.logger.Error("renew database login", "error", err, "current_expires", cur.Expires.Format(time.RFC3339))
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			backoff = min(backoff*2, 30*time.Second)
			continue
		}
		backoff = time.Second
		if d.OnRotate != nil {
			d.OnRotate()
		}
		go d.retireAfter(ctx, d.Grace)
	}
}

// renewAt is two thirds of the way through l's life.
func renewAt(l Login) time.Time {
	return l.Fetched.Add(l.Expires.Sub(l.Fetched) * 2 / 3)
}

// retireAfter revokes the logins that were replaced, once grace has passed.
func (d *DBLogins) retireAfter(ctx context.Context, grace time.Duration) {
	select {
	case <-ctx.Done():
		return // Close revokes them
	case <-time.After(grace):
	}
	d.mu.Lock()
	old := d.retiring
	d.retiring = nil
	d.mu.Unlock()
	for _, l := range old {
		d.revoke(context.WithoutCancel(ctx), l)
	}
}

// Close revokes every login this process still holds. Call it after the
// pool has closed: the Pod is going, and nothing else may use them.
func (d *DBLogins) Close(ctx context.Context) error {
	d.mu.Lock()
	all := append(d.retiring, d.current)
	d.retiring, d.current = nil, Login{}
	d.mu.Unlock()
	var errs []error
	for _, l := range all {
		if l.LeaseID != "" {
			errs = append(errs, d.revoke(ctx, l))
		}
	}
	return errors.Join(errs...)
}

func (d *DBLogins) revoke(ctx context.Context, l Login) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := d.client.Revoke(ctx, l.LeaseID); err != nil {
		d.logger.Warn("revoke database login", "user", l.User, "error", err)
		return err
	}
	d.logger.Info("database login revoked", "user", l.User)
	return nil
}
~~~

Two thirds of the way through a login's life, `Run` fetches the next one and calls `OnRotate`, which resets the pool so new connections use it. A minute later it revokes the old one, and connections still on it are cut off. That's deliberate: if revocation waited for connections to finish, a leaked login held open by an attacker would never end. If OpenBao can't be reached, it keeps trying, more slowly each time, while the current login still works.

The pool asks for the current login whenever it opens a connection. In `internal/pgstore/pool.go`:

Change:

<!-- edit: internal/pgstore/pool.go -->
~~~go
	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5/pgxpool"
~~~

to:

~~~go
	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
~~~

Change:

<!-- edit: internal/pgstore/pool.go -->
~~~go
	MaxConnIdleTime time.Duration // close connections idle longer than this
}
~~~

to:

~~~go
	MaxConnIdleTime time.Duration // close connections idle longer than this

	// Login, when set, gives the user and password for each new
	// connection, in place of those in the URL (Phase 6): OpenBao's
	// current login for this Pod, which changes while the pool is open.
	Login func() (user, password string)
}
~~~

Change:

<!-- edit: internal/pgstore/pool.go -->
~~~go
		config.MaxConnIdleTime = opts.MaxConnIdleTime
	}
~~~

to:

~~~go
		config.MaxConnIdleTime = opts.MaxConnIdleTime
	}
	if opts.Login != nil {
		config.BeforeConnect = func(_ context.Context, c *pgx.ConnConfig) error {
			c.User, c.Password = opts.Login()
			return nil
		}
	}
~~~


### Sealing webhook secrets

Create `internal/secrets/transit.go`:

<!-- file: internal/secrets/transit.go -->
~~~go
package secrets

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
)

// Transit encrypts and decrypts with a key kept inside OpenBao's transit
// engine: encryption as a service. The database holds only ciphertext,
// and the key never reaches it, or the program: someone who copies the
// database, or a backup of it, has nothing they can read.
//
// The key is "derived": each tenant's data is encrypted under a key made
// from the named key and the tenant, so a ciphertext copied into another
// tenant's row can't be decrypted there.
type Transit struct {
	client *Client
	key    string
}

// NewTransit uses the transit key called key.
func NewTransit(client *Client, key string) *Transit {
	return &Transit{client: client, key: key}
}

// WebhookKey is the transit key that seals webhook secrets; the API seals
// with it, the notifier opens with it. deploy/bao/setup.sh creates it.
const WebhookKey = "webhooks"

// Prefix starts every transit ciphertext, followed by the key version:
// "vault:v1:...". OpenBao kept Vault's prefix.
const Prefix = "vault:v"

// Seal encrypts plaintext for tenant.
func (t *Transit) Seal(ctx context.Context, tenant string, plaintext []byte) (string, error) {
	s, err := t.client.Write(ctx, "transit/encrypt/"+t.key, map[string]string{
		"plaintext": base64.StdEncoding.EncodeToString(plaintext),
		"context":   base64.StdEncoding.EncodeToString([]byte(tenant)),
	})
	if err != nil {
		return "", fmt.Errorf("seal: %w", err)
	}
	ciphertext, _ := s.Data["ciphertext"].(string)
	if !strings.HasPrefix(ciphertext, Prefix) {
		return "", errors.New("seal: no ciphertext in the reply")
	}
	return ciphertext, nil
}

// Open decrypts what Seal returned for the same tenant.
func (t *Transit) Open(ctx context.Context, tenant, sealed string) ([]byte, error) {
	if !strings.HasPrefix(sealed, Prefix) {
		return nil, errors.New("open: not sealed by transit")
	}
	s, err := t.client.Write(ctx, "transit/decrypt/"+t.key, map[string]string{
		"ciphertext": sealed,
		"context":    base64.StdEncoding.EncodeToString([]byte(tenant)),
	})
	if err != nil {
		return nil, fmt.Errorf("open: %w", err)
	}
	b64, _ := s.Data["plaintext"].(string)
	return base64.StdEncoding.DecodeString(b64)
}
~~~

The store seals before its transaction and opens after it, so it never holds a database connection while waiting for OpenBao. In `internal/pgstore/pgstore.go`:

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	messages func(jobs.Job) ([]outbox.Message, error)
}
~~~

to:

~~~go
	messages func(jobs.Job) ([]outbox.Message, error)
	sealer   Sealer
}
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	return func(s *Store) { s.messages = messagesFor }
}
~~~

to:

~~~go
	return func(s *Store) { s.messages = messagesFor }
}

// Sealer encrypts a tenant's secret before it is stored and decrypts it
// after it is read (Phase 6, step 9). secrets.Transit is one.
type Sealer interface {
	Seal(ctx context.Context, tenant string, plaintext []byte) (string, error)
	Open(ctx context.Context, tenant, sealed string) ([]byte, error)
}

// WithSealer stores webhook secrets sealed by s. Without it they are
// stored as they are.
func WithSealer(s Sealer) Option {
	return func(st *Store) { st.sealer = s }
}
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
// as the connection's own role, which owns the table and so isn't subject
// to row-level security. The partial index jobs_running_updated_at answers
// this without reading the finished jobs.
~~~

to:

~~~go
// as the connection's own role, not as a tenant: the policy
// sweep_abandoned (migration 0010) lets that role see running jobs, and
// no others. The partial index jobs_running_updated_at answers this
// without reading the finished jobs.
~~~


In `internal/pgstore/webhooks.go`:

Change:

<!-- edit: internal/pgstore/webhooks.go -->
~~~go
	"errors"
	"time"
~~~

to:

~~~go
	"errors"
	"fmt"
	"time"
~~~

Change:

<!-- edit: internal/pgstore/webhooks.go -->
~~~go

func (w Webhooks) Put(ctx context.Context, url string, secret webhook.Secret, now time.Time) (bool, error) {
	var created bool
	err := w.s.inTenant(ctx, func(owner tenant.ID, tx pgx.Tx) error {
~~~

to:

~~~go

// seal returns secret as it is to be stored. It is sealed before the
// transaction begins: no call to OpenBao while holding a connection.
func (w Webhooks) seal(ctx context.Context, secret webhook.Secret) (string, error) {
	if w.s.sealer == nil {
		return secret.String(), nil
	}
	owner, err := tenant.Require(ctx)
	if err != nil {
		return "", err
	}
	return w.s.sealer.Seal(ctx, string(owner), []byte(secret.String()))
}

// open reverses seal.
func (w Webhooks) open(ctx context.Context, owner tenant.ID, stored string) (webhook.Secret, error) {
	if w.s.sealer != nil {
		plain, err := w.s.sealer.Open(ctx, string(owner), stored)
		if err != nil {
			// Secrets stored before they were sealed (before step 9)
			// end up here: rotating the secret replaces them.
			return nil, fmt.Errorf("webhook secret: %w", err)
		}
		stored = string(plain)
	}
	return webhook.ParseSecret(stored)
}

func (w Webhooks) Put(ctx context.Context, url string, secret webhook.Secret, now time.Time) (bool, error) {
	stored, err := w.seal(ctx, secret)
	if err != nil {
		return false, err
	}
	var created bool
	err = w.s.inTenant(ctx, func(owner tenant.ID, tx pgx.Tx) error {
~~~

Change:

<!-- edit: internal/pgstore/webhooks.go -->
~~~go
			owner, url, secret.String(), now).Scan(&created)
~~~

to:

~~~go
			owner, url, stored, now).Scan(&created)
~~~

Change:

<!-- edit: internal/pgstore/webhooks.go -->
~~~go
func (w Webhooks) Rotate(ctx context.Context, secret webhook.Secret, now, previousUntil time.Time) error {
	return w.s.inTenant(ctx, func(_ tenant.ID, tx pgx.Tx) error {
~~~

to:

~~~go
func (w Webhooks) Rotate(ctx context.Context, secret webhook.Secret, now, previousUntil time.Time) error {
	stored, err := w.seal(ctx, secret)
	if err != nil {
		return err
	}
	return w.s.inTenant(ctx, func(_ tenant.ID, tx pgx.Tx) error {
~~~

Change:

<!-- edit: internal/pgstore/webhooks.go -->
~~~go
			secret.String(), previousUntil, now)
~~~

to:

~~~go
			stored, previousUntil, now)
~~~

Change:

<!-- edit: internal/pgstore/webhooks.go -->
~~~go
	err := w.s.inTenant(ctx, func(_ tenant.ID, tx pgx.Tx) error {
~~~

to:

~~~go
	var owner tenant.ID
	var stored []string
	err := w.s.inTenant(ctx, func(o tenant.ID, tx pgx.Tx) error {
		owner = o
~~~

Change:

<!-- edit: internal/pgstore/webhooks.go -->
~~~go
		texts := []string{current}
~~~

to:

~~~go
		stored = []string{current}
~~~

Change:

<!-- edit: internal/pgstore/webhooks.go -->
~~~go
			texts = append(texts, *previous)
		}
		for _, t := range texts {
			s, err := webhook.ParseSecret(t)
			if err != nil {
				return err
			}
			ep.Secrets = append(ep.Secrets, s)
~~~

to:

~~~go
			stored = append(stored, *previous)
~~~

Change:

<!-- edit: internal/pgstore/webhooks.go -->
~~~go
	return ep, err
~~~

to:

~~~go
	if err != nil {
		return webhook.Endpoint{}, err
	}
	for _, text := range stored { // opened after the transaction, like seal
		s, err := w.open(ctx, owner, text)
		if err != nil {
			return webhook.Endpoint{}, err
		}
		ep.Secrets = append(ep.Secrets, s)
	}
	return ep, nil
~~~


Secrets stored before this step aren't sealed, and `open` refuses them. Rotating the secret replaces them; the guide's run below shows it.

### Least privilege

Create `internal/pgstore/migrations/0010_least_privilege.sql`:

<!-- file: internal/pgstore/migrations/0010_least_privilege.sql -->
~~~sql
-- Phase 6, step 9: each service logs in with only the rights its code uses.
-- Until now every service used the superuser that created the database, so
-- a leaked DATABASE_URL could switch off row-level security, read files and
-- run programs on the database server.
--
--   runway_owner      owns the tables; only migrations act as it
--   runway_api        what the API does outside a tenant: the outbox relay,
--                     idempotency keys, the sweep for abandoned jobs
--   runway_notifier   nothing outside a tenant
--   runway_projector  its inbox and read model
--   runway_tenant     (step 4) what a request does inside its tenant
--
-- None of them can log in. Logins are made by OpenBao, one per Pod, each
-- a member of one of these, and dropped when its lease ends.

-- +goose Up
-- +goose StatementBegin
DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['runway_owner', 'runway_api', 'runway_notifier', 'runway_projector'] LOOP
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOBYPASSRLS', r);
        END IF;
    END LOOP;
    EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO runway_owner', current_schema());
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO runway_api, runway_notifier, runway_projector', current_schema());
END
$$;
-- +goose StatementEnd

-- The owner of a table may change it, drop it, and switch off its
-- row-level security. Hand that to a role no service logs in as.
ALTER TABLE jobs OWNER TO runway_owner;
ALTER TABLE job_events OWNER TO runway_owner;
ALTER TABLE outbox OWNER TO runway_owner;
ALTER TABLE idempotency_keys OWNER TO runway_owner;
ALTER TABLE inbox OWNER TO runway_owner;
ALTER TABLE job_state_counts OWNER TO runway_owner;
ALTER TABLE webhooks OWNER TO runway_owner;
ALTER TABLE goose_db_version OWNER TO runway_owner;
ALTER FUNCTION current_tenant() OWNER TO runway_owner;

-- Requests switch to runway_tenant (SET LOCAL ROLE), so the services that
-- serve tenants must be members of it. INHERIT FALSE: a member may become
-- runway_tenant, but doesn't hold its rights, or fall under its policies,
-- while acting as itself (PostgreSQL 16 and later).
GRANT runway_tenant TO runway_api, runway_notifier WITH INHERIT FALSE;

GRANT SELECT, UPDATE, DELETE ON outbox TO runway_api; -- the relay; rows are inserted as the tenant
GRANT SELECT, INSERT, UPDATE, DELETE ON idempotency_keys TO runway_api;
GRANT SELECT ON jobs TO runway_api; -- the sweep, limited by sweep_abandoned below

GRANT SELECT, INSERT ON inbox TO runway_projector;
GRANT SELECT, INSERT, UPDATE ON job_state_counts TO runway_projector;

-- The tenant policies applied to every role (none was named). That didn't
-- matter while the services were owners, whom policies skip. Now the API
-- reads jobs as itself for the sweep, and the policy's current_tenant()
-- would raise for want of a tenant. Name the role each policy is for; it
-- then applies to that role and to members that inherit from it, which
-- is why the grant above says INHERIT FALSE.
ALTER POLICY tenant_isolation ON jobs TO runway_tenant;
ALTER POLICY tenant_isolation ON job_events TO runway_tenant;
ALTER POLICY tenant_isolation ON webhooks TO runway_tenant;

-- The sweep sees running jobs in every tenant, and nothing else: no
-- finished jobs, no descriptions it has any reason to read in bulk.
CREATE POLICY sweep_abandoned ON jobs FOR SELECT TO runway_api
    USING (state = 'running');

-- +goose Down
DROP POLICY sweep_abandoned ON jobs;
ALTER POLICY tenant_isolation ON webhooks TO PUBLIC;
ALTER POLICY tenant_isolation ON job_events TO PUBLIC;
ALTER POLICY tenant_isolation ON jobs TO PUBLIC;
REVOKE ALL ON inbox, job_state_counts FROM runway_projector;
REVOKE ALL ON outbox, idempotency_keys, jobs FROM runway_api;
REVOKE runway_tenant FROM runway_api, runway_notifier;
ALTER FUNCTION current_tenant() OWNER TO CURRENT_USER;
ALTER TABLE goose_db_version OWNER TO CURRENT_USER;
ALTER TABLE webhooks OWNER TO CURRENT_USER;
ALTER TABLE job_state_counts OWNER TO CURRENT_USER;
ALTER TABLE inbox OWNER TO CURRENT_USER;
ALTER TABLE idempotency_keys OWNER TO CURRENT_USER;
ALTER TABLE outbox OWNER TO CURRENT_USER;
ALTER TABLE job_events OWNER TO CURRENT_USER;
ALTER TABLE jobs OWNER TO CURRENT_USER;
~~~

The design, in the file's own words: `runway_owner` owns everything and only migrations act as it; each service has a group role with the grants its code uses; nobody can log in as any of them; OpenBao makes logins that are *members* of one. Two details were found the hard way:
- **`INHERIT FALSE`.** The API must be able to `SET ROLE runway_tenant` for requests (step 4), so it's a member. But a member that *inherits* from `runway_tenant` falls under its policies while acting as itself, and the sweep for abandoned jobs, which runs outside any tenant, then hit `current_tenant()`'s error. `INHERIT FALSE` (PostgreSQL 16 and later) lets a member become the role without being it the rest of the time.
- **Policies name their role.** Step 4's policies applied to everyone, which didn't matter while the services were owners, whom policies skip. Now they apply to `runway_tenant` alone, and a separate policy, `sweep_abandoned`, lets the API see running jobs in every tenant, and nothing else.

Roles belong to the whole server, and creating them is a right no service should have. So an operator creates them once, before any migration runs as `runway_owner`. Create `deploy/postgres/roles.sql`:

<!-- file: deploy/postgres/roles.sql -->
~~~sql
-- Runway's PostgreSQL roles (Phase 6, step 9). Run once, as the superuser,
-- before migrations run as runway_owner:
--
--   kubectl -n runway exec -i postgres-0 -- psql -U runway -d runway -v ON_ERROR_STOP=1 < deploy/postgres/roles.sql
--
-- Roles belong to the whole server, not to one database, and making them
-- needs a right no service should have. So the operator makes them here,
-- and the migrations, which create the tables, only grant on them. Running
-- it again changes nothing.
DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['runway_owner', 'runway_tenant', 'runway_api', 'runway_notifier', 'runway_projector'] LOOP
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOBYPASSRLS', r);
        END IF;
    END LOOP;
    -- The migrations create their tables here, and grant on the schema.
    EXECUTE format('ALTER SCHEMA %I OWNER TO runway_owner', current_schema());
END
$$;

-- Migration 0010 makes the API and the notifier members of runway_tenant;
-- to grant a role, you need ADMIN on it. INHERIT FALSE, SET FALSE: being
-- able to hand it out doesn't make runway_owner a tenant.
GRANT runway_tenant TO runway_owner WITH ADMIN TRUE, INHERIT FALSE, SET FALSE;
~~~

Tests should run as the roles the services use, or a missing grant shows up only in production. In `internal/pgstore/pgtest/pgtest.go`:

Change:

<!-- edit: internal/pgstore/pgtest/pgtest.go -->
~~~go
	"crypto/rand"
	"net/url"
~~~

to:

~~~go
	"crypto/rand"
	"fmt"
	"net/url"
~~~

Add this at the end of the file:

<!-- append: internal/pgstore/pgtest/pgtest.go -->
~~~go
// As returns a pool on admin's schema that logs in as a new role, a
// member of group and nothing else (Phase 6): the way each service's login
// from OpenBao is. A grant the code needs but the migrations forgot then
// fails a test instead of a deployment.
func As(t *testing.T, admin *pgxpool.Pool, group string) *pgxpool.Pool {
	t.Helper()
	ctx := context.Background()
	user, password := "test_"+strings.ToLower(rand.Text()), rand.Text()
	_, err := admin.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s LOGIN PASSWORD '%s' IN ROLE %s`,
		user, password, pgx.Identifier{group}.Sanitize()))
	if err != nil {
		t.Fatal(err)
	}
	config := admin.Config().Copy()
	config.ConnConfig.User, config.ConnConfig.Password = user, password
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	// Cleanups run last-registered first: this pool closes, then the role
	// is dropped while admin is still open.
	t.Cleanup(func() { _, _ = admin.Exec(context.Background(), "DROP ROLE "+user) })
	t.Cleanup(pool.Close)
	return pool
}
~~~


In `internal/pgstore/pgstore_test.go`, the tests now act as `runway_api`, and one tries everything an attacker with the API's login would:

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	"context"
	"fmt"
~~~

to:

~~~go
	"context"
	"errors"
	"fmt"
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	"github.com/jackc/pgx/v5"

~~~

to:

~~~go
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
		return New(pgtest.Pool(t, Migrate))
	})
}
~~~

to:

~~~go
		return New(asAPI(t))
	})
}

// asAPI migrates a fresh schema and logs in to it the way the API does
// (step 9): as a member of runway_api, not as the owner.
func asAPI(t *testing.T) *pgxpool.Pool {
	return pgtest.As(t, pgtest.Pool(t, Migrate), "runway_api")
}
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	ctx := acme
	store := New(pgtest.Pool(t, Migrate))
	job, _ := jobs.New("resize", time.Second, t0)
~~~

to:

~~~go
	ctx := acme
	store := New(asAPI(t))
	job, _ := jobs.New("resize", time.Second, t0)
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	ctx := acme
	store := New(pgtest.Pool(t, Migrate))
	add := func(state jobs.State, at time.Time) jobs.ID {
~~~

to:

~~~go
	ctx := acme
	store := New(asAPI(t))
	add := func(state jobs.State, at time.Time) jobs.ID {
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
func TestRowLevelSecurityKeepsTenantsApart(t *testing.T) {
	store := New(pgtest.Pool(t, Migrate))
	for _, owner := range []tenant.ID{"acme", "acme", "globex"} {
~~~

to:

~~~go
func TestRowLevelSecurityKeepsTenantsApart(t *testing.T) {
	store := New(asAPI(t))
	for _, owner := range []tenant.ID{"acme", "acme", "globex"} {
~~~

Add this at the end of the file:

<!-- append: internal/pgstore/pgstore_test.go -->
~~~go
// What a leaked API login can do (step 9): the work the API does, and no
// more. Before this step it was the superuser's, which could do all of this.
func TestTheAPIRoleCannotChangeOrEscapeTheDatabase(t *testing.T) {
	ctx := context.Background()
	pool := asAPI(t)
	store := New(pool)
	job, _ := jobs.New("payroll for acme", time.Second, t0)
	job, err := store.Create(acme, job)
	if err != nil {
		t.Fatal(err)
	}
	_ = job.Start(t0)
	_ = job.Complete(t0)
	if err := store.Update(acme, job, jobs.StateQueued); err != nil {
		t.Fatal(err)
	}

	for _, sql := range []string{
		`ALTER TABLE jobs DISABLE ROW LEVEL SECURITY`,
		`DROP POLICY tenant_isolation ON jobs`,
		`CREATE TEMP TABLE out (line text); COPY out FROM PROGRAM 'id'`,
		`SELECT pg_read_file('/etc/passwd')`,
		`CREATE ROLE intruder LOGIN SUPERUSER`,
	} {
		_, err := pool.Exec(ctx, sql)
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "42501" { // insufficient_privilege
			t.Errorf("%s: %v, want permission denied (42501)", sql, err)
		}
	}
	// Outside a tenant, the API's own role sees running jobs only: the
	// sweep for abandoned jobs needs no more.
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM jobs`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("finished jobs visible outside a tenant: %d, %v; want 0", n, err)
	}
}
~~~


In `internal/pgstore/pool_test.go`:

Change:

<!-- edit: internal/pgstore/pool_test.go -->
~~~go
	"context"
	"errors"
	"os"
	"sync"
	"testing"
~~~

to:

~~~go
	"context"
	"crypto/rand"
	"errors"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
~~~

Add this at the end of the file:

<!-- append: internal/pgstore/pool_test.go -->
~~~go
// New connections log in as whatever Login returns at that moment, and
// Reset retires the old ones (Phase 6): how a pool follows a rotation.
func TestPoolFollowsTheCurrentLogin(t *testing.T) {
	url := os.Getenv("RUNWAY_DATABASE_URL")
	if url == "" {
		t.Skip("set RUNWAY_DATABASE_URL to run PostgreSQL tests")
	}
	ctx := context.Background()
	admin, err := Open(ctx, url, PoolOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	users := []string{"login_" + strings.ToLower(rand.Text()), "login_" + strings.ToLower(rand.Text())}
	for _, u := range users {
		if _, err := admin.Exec(ctx, "CREATE ROLE "+u+" LOGIN PASSWORD 'pw'"); err != nil {
			t.Fatal(err)
		}
		defer admin.Exec(ctx, "DROP ROLE "+u)
	}
	var current atomic.Int32
	pool, err := Open(ctx, url, PoolOptions{Login: func() (string, string) { return users[current.Load()], "pw" }})
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	whoami := func() (user string) {
		t.Helper()
		if err := pool.QueryRow(ctx, "SELECT current_user").Scan(&user); err != nil {
			t.Fatal(err)
		}
		return user
	}
	if got := whoami(); got != users[0] {
		t.Fatalf("logged in as %s, want %s", got, users[0])
	}
	current.Store(1)
	if got := whoami(); got != users[0] {
		t.Fatalf("before Reset: %s, want the open connection's %s", got, users[0])
	}
	pool.Reset()
	if got := whoami(); got != users[1] {
		t.Fatalf("after Reset: %s, want %s", got, users[1])
	}
	pool.Close() // now: its connections must end before the roles are dropped
}
~~~


In `internal/pgstore/webhooks_test.go`:

Change:

<!-- edit: internal/pgstore/webhooks_test.go -->
~~~go
	"context"
	"errors"
	"testing"
~~~

to:

~~~go
	"context"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
~~~

Change:

<!-- edit: internal/pgstore/webhooks_test.go -->
~~~go
	hooks := New(pgtest.Pool(t, Migrate)).Webhooks()
~~~

to:

~~~go
	hooks := New(pgtest.As(t, pgtest.Pool(t, Migrate), "runway_notifier")).Webhooks()
~~~

Add this at the end of the file:

<!-- append: internal/pgstore/webhooks_test.go -->
~~~go
// fakeSealer stands in for OpenBao's transit engine: reversible, and bound
// to the tenant it sealed for.
type fakeSealer struct{}

func (fakeSealer) Seal(_ context.Context, tenant string, plaintext []byte) (string, error) {
	return "sealed:" + tenant + ":" + base64.StdEncoding.EncodeToString(plaintext), nil
}

func (fakeSealer) Open(_ context.Context, tenant, sealed string) ([]byte, error) {
	rest, ok := strings.CutPrefix(sealed, "sealed:"+tenant+":")
	if !ok {
		return nil, errors.New("not sealed for this tenant")
	}
	return base64.StdEncoding.DecodeString(rest)
}

// With a sealer (step 9), the database holds no secret it could leak.
func TestWebhookSecretsAreStoredSealed(t *testing.T) {
	admin := pgtest.Pool(t, Migrate)
	hooks := New(pgtest.As(t, admin, "runway_notifier"), WithSealer(fakeSealer{})).Webhooks()
	first, second := webhook.NewSecret(), webhook.NewSecret()
	if _, err := hooks.Put(acme, "https://acme.example/hooks", first, t0); err != nil {
		t.Fatal(err)
	}
	if err := hooks.Rotate(acme, second, t0, t0.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}

	var current, previous string
	err := admin.QueryRow(context.Background(), `SELECT secret, previous_secret FROM webhooks`).Scan(&current, &previous)
	if err != nil {
		t.Fatal(err)
	}
	for _, stored := range []string{current, previous} {
		if !strings.HasPrefix(stored, "sealed:acme:") || strings.Contains(stored, "whsec_") {
			t.Fatalf("stored %q, want it sealed for acme", stored)
		}
	}
	ep, err := hooks.Endpoint(acme, t0)
	if err != nil {
		t.Fatal(err)
	}
	if len(ep.Secrets) != 2 || ep.Secrets[0].String() != second.String() || ep.Secrets[1].String() != first.String() {
		t.Fatalf("secrets = %v, want the new one, then the old", ep.Secrets)
	}

	// A sealed secret copied into another tenant's row doesn't open.
	_, err = admin.Exec(context.Background(), `
		INSERT INTO webhooks (tenant, url, secret, updated_at)
		SELECT 'globex', 'https://globex.example/hooks', secret, now() FROM webhooks WHERE tenant = 'acme'`)
	if err != nil {
		t.Fatal(err)
	}
	globex := tenant.With(context.Background(), "globex")
	if _, err := hooks.Endpoint(globex, t0); err == nil {
		t.Fatal("globex opened acme's secret")
	}
}
~~~


The other packages' tests make their pools the same way. In `internal/pgstore/keys_test.go`, `internal/outbox/outbox_test.go` and `internal/projection/projection_test.go`:

Change:

<!-- edit: internal/pgstore/keys_test.go -->
~~~go
		return NewKeys(pgtest.Pool(t, Migrate), keystest.TTL, clock.Now)
~~~

to:

~~~go
		return NewKeys(pgtest.As(t, pgtest.Pool(t, Migrate), "runway_api"), keystest.TTL, clock.Now)
~~~


Change:

<!-- edit: internal/outbox/outbox_test.go -->
~~~go
	relay := newRelay(pool, pub, 10)
~~~

to:

~~~go
	relay := newRelay(pgtest.As(t, pool, "runway_api"), pub, 10) // the API's own role (Phase 6)
~~~


Change:

<!-- edit: internal/projection/projection_test.go -->
~~~go
	p := New(pgtest.Pool(t, pgstore.Migrate), "test")
~~~

to:

~~~go
	p := New(pgtest.As(t, pgtest.Pool(t, pgstore.Migrate), "runway_projector"), "test")
~~~


<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/pgstore/... ./internal/outbox/ ./internal/projection/ && go test -race -count=1 ./internal/pgstore/... ./internal/outbox/ ./internal/projection/ -->

**Break it.** In `0010_least_privilege.sql`, drop `WITH INHERIT FALSE` from the `GRANT runway_tenant` line, and run the `pgstore` tests. On my test server, *nothing failed*. Roles belong to the server, the membership already existed from earlier runs with `INHERIT FALSE`, and a plain `GRANT` of an existing membership leaves its options alone. On a fresh server (`docker run --rm -e POSTGRES_USER=runway -e POSTGRES_PASSWORD=runway -e POSTGRES_DB=runway -p 15432:5432 postgres:17`, with `RUNWAY_DATABASE_URL` pointing at it):

~~~text
--- FAIL: TestAbandonedFindsOnlyOldRunningJobs (0.37s)
    pgstore_test.go:161: ERROR: app.tenant is not set: no tenant for this transaction (SQLSTATE P0001)
--- FAIL: TestTheAPIRoleCannotChangeOrEscapeTheDatabase (0.36s)
    pgstore_test.go:239: finished jobs visible outside a tenant: 0, ERROR: app.tenant is not set: no tenant for this transaction (SQLSTATE P0001); want 0
~~~

A test database that outlives its tests carries state from one run to the next. Anything server-wide (roles, settings, extensions) can hide a bug that a fresh server shows at once. CI starts from a fresh container, which is one reason to trust it over your laptop.

### Tests against a real OpenBao

Compose gets OpenBao in development mode: in memory, unsealed, with a fixed root token. Never like this anywhere else. In `compose.yaml`:

Change:

<!-- edit: compose.yaml -->
~~~yaml

  # The token issuer (Phase 6). Its keys are in memory (tmpfs): a restart
~~~

to:

~~~yaml

  # OpenBao in development mode (Phase 6, step 9): in memory, unsealed,
  # with a fixed root token. Never like this anywhere but a laptop or CI;
  # deploy/k8s/bao.yaml is the real thing. The tests reach PostgreSQL
  # through it at postgres:5432, the address this network gives it.
  openbao:
    image: openbao/openbao:2.7.1
    environment:
      BAO_DEV_ROOT_TOKEN_ID: runway-dev
    ports:
      - "8200:8200"
    healthcheck:
      test: ["CMD", "bao", "status", "-address=http://127.0.0.1:8200"]
      interval: 2s
      timeout: 5s
      retries: 20

  # The token issuer (Phase 6). Its keys are in memory (tmpfs): a restart
~~~


A helper sets up a test's own corner of it. Create `internal/secrets/baotest/baotest.go`:

<!-- file: internal/secrets/baotest/baotest.go -->
~~~go
// Package baotest sets up the development OpenBao in compose.yaml for tests.
package baotest

import (
	"context"
	"crypto/rand"
	"errors"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"

	"runway/internal/secrets"
)

// Client returns a client of the development OpenBao, with the database
// and transit engines on. The test is skipped unless RUNWAY_BAO_ADDR and
// RUNWAY_BAO_TOKEN are set.
func Client(t *testing.T) *secrets.Client {
	t.Helper()
	addr, token := os.Getenv("RUNWAY_BAO_ADDR"), os.Getenv("RUNWAY_BAO_TOKEN")
	if addr == "" || token == "" {
		t.Skip("set RUNWAY_BAO_ADDR and RUNWAY_BAO_TOKEN to run OpenBao tests")
	}
	c := secrets.WithToken(addr, http.DefaultClient, token)
	for _, engine := range []string{"database", "transit"} {
		_, err := c.Write(context.Background(), "sys/mounts/"+engine, map[string]string{"type": engine})
		var e *secrets.Error
		if err != nil && !(errors.As(err, &e) && strings.Contains(strings.Join(e.Reasons, " "), "already in use")) {
			t.Fatal(err)
		}
	}
	return c
}

// Name returns a new name for something a test makes: "test-" and ten
// random letters or digits.
func Name() string { return "test-" + strings.ToLower(rand.Text())[:10] }

// DatabaseRole makes an OpenBao database role whose logins are members of
// the PostgreSQL role group, the way deploy/bao/setup.sh makes "api" a
// member of runway_api, and returns its name. Logins last ttl. Each of
// extra runs after the login is created, as in setup.sh.
func DatabaseRole(t *testing.T, c *secrets.Client, group, ttl string, extra ...string) string {
	t.Helper()
	ctx := context.Background()
	// OpenBao reaches PostgreSQL from inside compose's network, so by a
	// different address than the tests do.
	u, _ := url.Parse(os.Getenv("RUNWAY_BAO_DATABASE_URL"))
	if u == nil || u.User == nil {
		t.Skip("set RUNWAY_BAO_DATABASE_URL: PostgreSQL as OpenBao reaches it")
	}
	password, _ := u.User.Password()
	role := Name()
	_, err := c.Write(ctx, "database/config/"+role, map[string]any{
		"plugin_name":    "postgresql-database-plugin",
		"connection_url": "postgresql://{{username}}:{{password}}@" + u.Host + u.Path + "?" + u.RawQuery,
		"username":       u.User.Username(),
		"password":       password,
		"allowed_roles":  []string{role},
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.Write(ctx, "database/roles/"+role, map[string]any{
		"db_name":     role,
		"default_ttl": ttl,
		"max_ttl":     "10m",
		"creation_statements": append([]string{
			`CREATE ROLE "{{name}}" LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE ` + group,
		}, extra...),
		"revocation_statements": []string{
			`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '{{name}}'`,
			`DROP ROLE IF EXISTS "{{name}}"`,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return role
}
~~~

Create `internal/secrets/secrets_test.go`, unit tests with a fake server:

<!-- file: internal/secrets/secrets_test.go -->
~~~go
package secrets

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"
)

// The client logs in again when two thirds of its token's life is gone.
func TestClientLogsInAgainBeforeTheTokenExpires(t *testing.T) {
	var logins atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/kubernetes/login":
			n := logins.Add(1)
			io.WriteString(w, `{"auth":{"client_token":"t`+string('0'+n)+`","lease_duration":60}}`)
		case "/v1/kv/x":
			if r.Header.Get("X-Vault-Token") != "t"+string('0'+logins.Load()) {
				w.WriteHeader(http.StatusForbidden)
				io.WriteString(w, `{"errors":["permission denied"]}`)
				return
			}
			io.WriteString(w, `{"data":{"v":"ok"}}`)
		}
	}))
	defer srv.Close()
	jwt := t.TempDir() + "/token"
	os.WriteFile(jwt, []byte("a-kubernetes-token\n"), 0o600)
	c := WithKubernetes(srv.URL, srv.Client(), "api", jwt)
	now := time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)
	c.now = func() time.Time { return now }

	read := func() {
		t.Helper()
		if s, err := c.Read(context.Background(), "kv/x"); err != nil || s.Data["v"] != "ok" {
			t.Fatalf("read: %v, %v", s.Data, err)
		}
	}
	read()
	now = now.Add(39 * time.Second)
	read()
	if logins.Load() != 1 {
		t.Fatalf("%d logins after 39 s of a 60 s token, want 1", logins.Load())
	}
	now = now.Add(2 * time.Second)
	read()
	if logins.Load() != 2 {
		t.Fatalf("%d logins after 41 s, want 2", logins.Load())
	}

	_, err := WithToken(srv.URL, srv.Client(), "wrong").Read(context.Background(), "kv/x")
	var e *Error
	if !errors.As(err, &e) || e.Status != http.StatusForbidden || e.Reasons[0] != "permission denied" {
		t.Fatalf("wrong token: %v", err)
	}
}

// Each database login is fetched with a token of its own: it dies with
// that token, so it must not share one about to expire.
func TestEachLoginGetsATokenOfItsOwn(t *testing.T) {
	var logins atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/kubernetes/login":
			logins.Add(1)
			io.WriteString(w, `{"auth":{"client_token":"t","lease_duration":3600}}`)
		case "/v1/database/creds/api":
			io.WriteString(w, `{"lease_id":"database/creds/api/x","lease_duration":3600,"data":{"username":"u","password":"p"}}`)
		}
	}))
	defer srv.Close()
	jwt := t.TempDir() + "/token"
	os.WriteFile(jwt, []byte("a-kubernetes-token"), 0o600)
	d := NewDBLogins(WithKubernetes(srv.URL, srv.Client(), "api", jwt), "api", slog.New(slog.NewTextHandler(io.Discard, nil)))
	for range 2 {
		if err := d.Fetch(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if logins.Load() != 2 {
		t.Fatalf("%d logins for 2 fetches, want 2", logins.Load())
	}
}
~~~

And `internal/secrets/integration_test.go`, against the real one: a login that works, then is revoked; one that rotates under a running pool; transit, including another tenant's context failing:

<!-- file: internal/secrets/integration_test.go -->
~~~go
package secrets_test

import (
	"context"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"runway/internal/secrets"
	"runway/internal/secrets/baotest"
)

var quiet = slog.New(slog.NewTextHandler(io.Discard, nil))

// newGroup makes an empty PostgreSQL role for test logins to join, and
// returns its name.
func newGroup(t *testing.T) string {
	t.Helper()
	group := strings.ReplaceAll(baotest.Name(), "-", "_")
	if _, err := adminConn(t).Exec(context.Background(), "CREATE ROLE "+group+" NOLOGIN"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = adminConn(t).Exec(context.Background(), "DROP ROLE "+group) })
	return group
}

func adminConn(t *testing.T) *pgx.Conn {
	t.Helper()
	base := os.Getenv("RUNWAY_DATABASE_URL")
	if base == "" {
		t.Skip("set RUNWAY_DATABASE_URL to run PostgreSQL tests")
	}
	conn, err := pgx.Connect(context.Background(), base)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close(context.Background()) })
	return conn
}

// connectAs opens a connection to the tests' database as login.
func connectAs(ctx context.Context, t *testing.T, l secrets.Login) (*pgx.Conn, error) {
	t.Helper()
	config, err := pgx.ParseConfig(os.Getenv("RUNWAY_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	config.User, config.Password = l.User, l.Password
	return pgx.ConnectConfig(ctx, config)
}

func TestEachLoginIsNewAndEndsWhenRevoked(t *testing.T) {
	ctx := context.Background()
	c := baotest.Client(t)
	group := newGroup(t)
	logins := secrets.NewDBLogins(c, baotest.DatabaseRole(t, c, group, "1m"), quiet)

	if err := logins.Fetch(ctx); err != nil {
		t.Fatal(err)
	}
	first := logins.Current()
	conn, err := connectAs(ctx, t, first)
	if err != nil {
		t.Fatalf("connect as %s: %v", first.User, err)
	}
	var member bool
	if err := conn.QueryRow(ctx, `SELECT pg_has_role(current_user, $1, 'MEMBER')`, group).Scan(&member); err != nil || !member {
		t.Fatalf("%s a member of %s: %v, %v", first.User, group, member, err)
	}
	if left := time.Until(first.Expires); left < 50*time.Second || left > time.Minute {
		t.Fatalf("expires in %v, want about a minute", left)
	}

	if err := logins.Fetch(ctx); err != nil {
		t.Fatal(err)
	}
	second := logins.Current()
	if second.User == first.User || second.Password == first.Password {
		t.Fatalf("second login %s is the first one again", second.User)
	}

	// Closing revokes both: the open connection is cut off, and neither
	// can log in again.
	if err := logins.Close(ctx); err != nil {
		t.Fatal(err)
	}
	if err := conn.Ping(ctx); err == nil {
		t.Fatalf("%s's connection still works after revocation", first.User)
	}
	for _, l := range []secrets.Login{first, second} {
		if c, err := connectAs(ctx, t, l); err == nil {
			c.Close(ctx)
			t.Fatalf("%s can still log in after revocation", l.User)
		}
	}
}

func TestRunRenewsBeforeExpiryAndRevokesTheOld(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c := baotest.Client(t)
	logins := secrets.NewDBLogins(c, baotest.DatabaseRole(t, c, newGroup(t), "3s"), quiet) // renewed at 2 s
	logins.Grace = 500 * time.Millisecond
	var rotations atomic.Int32
	logins.OnRotate = func() { rotations.Add(1) }
	if err := logins.Fetch(ctx); err != nil {
		t.Fatal(err)
	}
	first := logins.Current()
	go logins.Run(ctx)
	defer logins.Close(context.Background())

	deadline := time.Now().Add(10 * time.Second)
	for rotations.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if rotations.Load() == 0 {
		t.Fatal("no rotation within 10 s of a 3 s login")
	}
	if renewed := time.Since(first.Fetched); renewed > first.Expires.Sub(first.Fetched) {
		t.Fatalf("renewed %v after fetching, after the login had expired", renewed)
	}
	time.Sleep(logins.Grace + time.Second)
	if conn, err := connectAs(ctx, t, first); err == nil {
		conn.Close(ctx)
		t.Fatalf("the replaced login %s still works after the grace period", first.User)
	}
	if conn, err := connectAs(ctx, t, logins.Current()); err != nil {
		t.Fatalf("the current login: %v", err)
	} else {
		conn.Close(ctx)
	}
}

func TestTransitBindsCiphertextToItsTenant(t *testing.T) {
	ctx := context.Background()
	c := baotest.Client(t)
	key := baotest.Name()
	if _, err := c.Write(ctx, "transit/keys/"+key, map[string]any{"derived": true}); err != nil {
		t.Fatal(err)
	}
	transit := secrets.NewTransit(c, key)

	sealed, err := transit.Seal(ctx, "acme", []byte("whsec_c2VjcmV0"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(sealed, "vault:v1:") || strings.Contains(sealed, "whsec") {
		t.Fatalf("sealed = %q", sealed)
	}
	if plain, err := transit.Open(ctx, "acme", sealed); err != nil || string(plain) != "whsec_c2VjcmV0" {
		t.Fatalf("open as acme = %q, %v", plain, err)
	}
	// Moved to another tenant's row, it opens to nothing.
	if plain, err := transit.Open(ctx, "globex", sealed); err == nil {
		t.Fatalf("open as globex = %q, want an error", plain)
	}
	if _, err := transit.Open(ctx, "acme", "whsec_c2VjcmV0"); err == nil {
		t.Fatal("opened plain text, want an error")
	}
}
~~~

They need `RUNWAY_BAO_ADDR=http://localhost:8200` and `RUNWAY_BAO_TOKEN=runway-dev`, and skip without them. OpenBao's database engine connects to PostgreSQL from inside Compose's network, where the server is `postgres:5432`, not `localhost`. So the tests also need `RUNWAY_BAO_DATABASE_URL`, the same URL as `RUNWAY_DATABASE_URL` with `postgres:5432` as the host. CI sets all three. In `.github/workflows/ci.yml`:

Change:

<!-- edit: .github/workflows/ci.yml -->
~~~yaml
      RUNWAY_SQS_ENDPOINT: http://localhost:9324
    steps:
~~~

to:

~~~yaml
      RUNWAY_SQS_ENDPOINT: http://localhost:9324
      RUNWAY_BAO_ADDR: http://localhost:8200
      RUNWAY_BAO_TOKEN: runway-dev
      RUNWAY_BAO_DATABASE_URL: postgres://runway:runway@postgres:5432/runway?sslmode=disable
    steps:
~~~


<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/secrets/... && go test -race -count=1 ./internal/secrets/... -->

### The services

The API fetches a login before opening its pool, renews it, and seals webhook secrets. In `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/ratelimit"
	"runway/internal/sqsbus"
~~~

to:

~~~go
	"runway/internal/ratelimit"
	"runway/internal/secrets"
	"runway/internal/sqsbus"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	AuthIssuerID string
}
~~~

to:

~~~go
	AuthIssuerID string
	// Step 9: with Bao enabled, the database login comes from OpenBao,
	// made for this Pod, and webhook secrets are sealed by its transit key.
	Bao secrets.Config
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	}
	if cfg.AMQPURL != "" && cfg.SQSPrefix != "" {
~~~

to:

~~~go
	}
	var err error
	if cfg.Bao, err = secrets.LoadConfig(getenv); err != nil {
		return config{}, err
	}
	if cfg.Bao.Enabled() && cfg.DatabaseURL == "" {
		return config{}, errors.New("BAO_ADDR needs DATABASE_URL: OpenBao gives the login, DATABASE_URL says where")
	}
	if cfg.AMQPURL != "" && cfg.SQSPrefix != "" {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		cfg.KafkaBrokers = strings.Split(brokers, ",")
	}
	var err error
	if cfg.Webhooks, err = envconfig.Bool(getenv, "WEBHOOKS_ENABLED", false); err != nil {
~~~

to:

~~~go
		cfg.KafkaBrokers = strings.Split(brokers, ",")
	}
	if cfg.Webhooks, err = envconfig.Bool(getenv, "WEBHOOKS_ENABLED", false); err != nil {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
// DATABASE_URL is unset.
func connectDatabase(ctx context.Context, cfg config, metrics *httpapi.Metrics) (*pgxpool.Pool, error) {
~~~

to:

~~~go
// DATABASE_URL is unset. With logins (step 9), each new connection logs in
// with the current one, and a rotation retires the old connections.
func connectDatabase(ctx context.Context, cfg config, metrics *httpapi.Metrics, logins *secrets.DBLogins) (*pgxpool.Pool, error) {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	pool, err := pgstore.Open(ctx, cfg.DatabaseURL, pgstore.PoolOptions{MaxConns: int32(cfg.DBMaxConns)})
	if err != nil {
		return nil, err
	}
	if cfg.MigrateOnStart {
~~~

to:

~~~go
	opts := pgstore.PoolOptions{MaxConns: int32(cfg.DBMaxConns)}
	if logins != nil {
		opts.Login = logins.Credentials
	}
	pool, err := pgstore.Open(ctx, cfg.DatabaseURL, opts)
	if err != nil {
		return nil, err
	}
	if logins != nil {
		logins.OnRotate = pool.Reset
		metrics.MustRegister(logins.Collectors()...)
	}
	if cfg.MigrateOnStart {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	pool, err := connectDatabase(ctx, cfg, metrics)
	if err != nil {
		return err
	}
	producer, err := connectStream(ctx, cfg)
~~~

to:

~~~go
	var tlsSource *pki.Source
	if cfg.TLSDir != "" {
		if tlsSource, err = pki.NewSource(cfg.TLSDir, logger); err != nil {
			return fmt.Errorf("TLS_DIR: %w", err)
		}
	}
	// OpenBao (step 9): a database login for this Pod alone. It is fetched
	// before the pool opens, renewed while the API runs, and revoked when
	// it stops, after the pool has closed (defers run last-first).
	var logins *secrets.DBLogins
	var sealer pgstore.Sealer
	if cfg.Bao.Enabled() {
		bao, err := cfg.Bao.NewClient(tlsSource)
		if err != nil {
			return err
		}
		logins = secrets.NewDBLogins(bao, cfg.Bao.Role, logger)
		if err := logins.Fetch(ctx); err != nil {
			return err
		}
		defer logins.Close(context.WithoutCancel(ctx))
		sealer = secrets.NewTransit(bao, secrets.WebhookKey)
	}
	pool, err := connectDatabase(ctx, cfg, metrics, logins)
	if err != nil {
		return err
	}
	if logins != nil {
		go logins.Run(ctx)
	}
	producer, err := connectStream(ctx, cfg)
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		store = pgstore.New(pool, pgstore.WithOutbox(eventing.OutboxMessages(eventing.Outbox{StreamEvents: producer != nil, Webhooks: cfg.Webhooks})))
~~~

to:

~~~go
		storeOptions := []pgstore.Option{pgstore.WithOutbox(eventing.OutboxMessages(eventing.Outbox{StreamEvents: producer != nil, Webhooks: cfg.Webhooks}))}
		if sealer != nil {
			storeOptions = append(storeOptions, pgstore.WithSealer(sealer))
		}
		store = pgstore.New(pool, storeOptions...)
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	// the circuit breaker answers 503 at once, which tells clients more.
	var tlsSource *pki.Source
	if cfg.TLSDir != "" {
		if tlsSource, err = pki.NewSource(cfg.TLSDir, logger); err != nil {
			return fmt.Errorf("TLS_DIR: %w", err)
		}
	}
~~~

to:

~~~go
	// the circuit breaker answers 503 at once, which tells clients more.
~~~


In `cmd/api/main_test.go`:

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go
	"net/http/httptest"
	"slices"
~~~

to:

~~~go
	"net/http/httptest"
	"os"
	"slices"
~~~

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go

	"runway/internal/auth"
	"runway/internal/pgstore/pgtest"
	"runway/internal/ratelimit"
)
~~~

to:

~~~go

	"github.com/jackc/pgx/v5/pgxpool"

	"runway/internal/auth"
	"runway/internal/pgstore"
	"runway/internal/pgstore/pgtest"
	"runway/internal/ratelimit"
	"runway/internal/secrets/baotest"
)
~~~

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go

func TestAuthIsRequiredByDefault(t *testing.T) {
~~~

to:

~~~go

// With OpenBao (step 9), the API logs in to PostgreSQL as a role made for
// it, a member of runway_api, and revokes it when it stops.
func TestDatabaseLoginComesFromOpenBao(t *testing.T) {
	bao := baotest.Client(t)
	url := pgtest.URL(t)
	admin, err := pgxpool.New(context.Background(), url)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	if err := pgstore.Migrate(context.Background(), admin); err != nil { // as the owner, before the API starts
		t.Fatal(err)
	}
	base, logs, stop, done := startServer(t, map[string]string{
		"DATABASE_URL": url, "MIGRATE_ON_START": "false",
		"BAO_ADDR": os.Getenv("RUNWAY_BAO_ADDR"), "BAO_TOKEN": os.Getenv("RUNWAY_BAO_TOKEN"),
		"BAO_ROLE": baotest.DatabaseRole(t, bao, "runway_api", "1m"),
	})
	createJob(t, base, 50)
	waitForState(t, base, "completed")

	var login struct{ User string }
	for line := range strings.Lines(logs.String()) {
		if strings.Contains(line, `"msg":"database login"`) {
			_ = json.Unmarshal([]byte(line), &login)
		}
	}
	exists := func() (found bool) {
		err := admin.QueryRow(context.Background(), `SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)`, login.User).Scan(&found)
		if err != nil {
			t.Fatal(err)
		}
		return found
	}
	if login.User == "" || !exists() {
		t.Fatalf("no login from OpenBao in the logs, or it isn't a role: %q", login.User)
	}
	stop()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if exists() {
		t.Fatalf("%s still exists after the API stopped", login.User)
	}
}

func TestAuthIsRequiredByDefault(t *testing.T) {
~~~


The notifier gets a login of its own, and opens the sealed secrets. In `cmd/notifier/main.go`:

Change:

<!-- edit: cmd/notifier/main.go -->
~~~go
	"runway/internal/pgstore"
	"runway/internal/rabbit"
	"runway/internal/retry"
	"runway/internal/webhook"
~~~

to:

~~~go
	"runway/internal/pgstore"
	"runway/internal/pki"
	"runway/internal/rabbit"
	"runway/internal/retry"
	"runway/internal/secrets"
	"runway/internal/webhook"
~~~

Change:

<!-- edit: cmd/notifier/main.go -->
~~~go
	ListenAddr    string // /health and /metrics
}
~~~

to:

~~~go
	ListenAddr    string // /health and /metrics
	// Step 9: the database login from OpenBao, and webhook secrets opened
	// with its transit key. TLSDir proves to OpenBao's sidecar who calls.
	Bao    secrets.Config
	TLSDir string
}
~~~

Change:

<!-- edit: cmd/notifier/main.go -->
~~~go
	}
	return cfg, nil
~~~

to:

~~~go
	}
	if cfg.Bao, err = secrets.LoadConfig(getenv); err != nil {
		return config{}, err
	}
	cfg.TLSDir = getenv("TLS_DIR")
	return cfg, nil
~~~

Change:

<!-- edit: cmd/notifier/main.go -->
~~~go
	pool, err := pgstore.Open(ctx, cfg.DatabaseURL, pgstore.PoolOptions{MaxConns: int32(cfg.Consumers)})
~~~

to:

~~~go
	registry := prometheus.NewRegistry()
	opts := pgstore.PoolOptions{MaxConns: int32(cfg.Consumers)}
	var storeOptions []pgstore.Option
	var logins *secrets.DBLogins
	if cfg.Bao.Enabled() {
		var tls *pki.Source
		if cfg.TLSDir != "" {
			if tls, err = pki.NewSource(cfg.TLSDir, logger); err != nil {
				return fmt.Errorf("TLS_DIR: %w", err)
			}
		}
		bao, err := cfg.Bao.NewClient(tls)
		if err != nil {
			return err
		}
		logins = secrets.NewDBLogins(bao, cfg.Bao.Role, logger)
		if err := logins.Fetch(ctx); err != nil {
			return err
		}
		defer logins.Close(context.WithoutCancel(ctx)) // after the pool closes
		registry.MustRegister(logins.Collectors()...)
		opts.Login = logins.Credentials
		storeOptions = append(storeOptions, pgstore.WithSealer(secrets.NewTransit(bao, secrets.WebhookKey)))
	}
	pool, err := pgstore.Open(ctx, cfg.DatabaseURL, opts)
~~~

Change:

<!-- edit: cmd/notifier/main.go -->
~~~go
	defer pool.Close()
	// The queue's settings must match the API's, which declares it too.
~~~

to:

~~~go
	defer pool.Close()
	if logins != nil {
		logins.OnRotate = pool.Reset
		go logins.Run(ctx)
	}
	// The queue's settings must match the API's, which declares it too.
~~~

Change:

<!-- edit: cmd/notifier/main.go -->
~~~go
	defer client.Close()

	registry := prometheus.NewRegistry()
	results := prometheus.NewCounterVec(prometheus.CounterOpts{
~~~

to:

~~~go
	defer client.Close()

	results := prometheus.NewCounterVec(prometheus.CounterOpts{
~~~

Change:

<!-- edit: cmd/notifier/main.go -->
~~~go
		Endpoints: pgstore.New(pool).Webhooks(),
~~~

to:

~~~go
		Endpoints: pgstore.New(pool, storeOptions...).Webhooks(),
~~~


In `cmd/notifier/main_test.go`:

Change:

<!-- edit: cmd/notifier/main_test.go -->
~~~go
	"runway/internal/rabbit"
	"runway/internal/tenant"
~~~

to:

~~~go
	"runway/internal/rabbit"
	"runway/internal/secrets"
	"runway/internal/secrets/baotest"
	"runway/internal/tenant"
~~~

Change:

<!-- edit: cmd/notifier/main_test.go -->
~~~go
func TestAFinishedJobBecomesAWebhook(t *testing.T) {
	amqpURL := os.Getenv("RUNWAY_AMQP_URL")
~~~

to:

~~~go
func TestAFinishedJobBecomesAWebhook(t *testing.T) {
	deliverOne(t, nil, nil)
}

// With OpenBao (step 9): the secret is stored sealed, as the API stores it,
// and the notifier, logged in to PostgreSQL as a login of its own, opens it
// with the transit key to sign.
func TestSealedSecretsStillSign(t *testing.T) {
	bao := baotest.Client(t)
	_, err := bao.Write(context.Background(), "transit/keys/"+secrets.WebhookKey, map[string]any{"derived": true})
	if err != nil {
		t.Fatal(err)
	}
	deliverOne(t, secrets.NewTransit(bao, secrets.WebhookKey), map[string]string{
		"BAO_ADDR": os.Getenv("RUNWAY_BAO_ADDR"), "BAO_TOKEN": os.Getenv("RUNWAY_BAO_TOKEN"),
		"BAO_ROLE": baotest.DatabaseRole(t, bao, "runway_notifier", "1m"),
	})
}

// deliverOne registers a webhook, stored through sealer when it isn't nil,
// runs the notifier with extra settings, and checks one message arrives.
func deliverOne(t *testing.T, sealer pgstore.Sealer, extra map[string]string) {
	t.Helper()
	amqpURL := os.Getenv("RUNWAY_AMQP_URL")
~~~

Change:

<!-- edit: cmd/notifier/main_test.go -->
~~~go
	if _, err := pgstore.New(pool).Webhooks().Put(ctx, receiver.URL+"/hooks", secret, time.Now()); err != nil {
		t.Fatal(err)
	}

~~~

to:

~~~go
	var options []pgstore.Option
	if sealer != nil {
		options = append(options, pgstore.WithSealer(sealer))
	}
	if _, err := pgstore.New(pool, options...).Webhooks().Put(ctx, receiver.URL+"/hooks", secret, time.Now()); err != nil {
		t.Fatal(err)
	}
	var stored string
	if err := pool.QueryRow(context.Background(), `SELECT secret FROM webhooks WHERE tenant = $1`, owner).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if sealed := strings.HasPrefix(stored, secrets.Prefix); sealed != (sealer != nil) {
		t.Fatalf("stored %.20s..., sealed %v", stored, sealed)
	}

~~~

Change:

<!-- edit: cmd/notifier/main_test.go -->
~~~go
	go func() {
		done <- run(runCtx, env(map[string]string{
			"AMQP_URL": amqpURL, "DATABASE_URL": dbURL, "LISTEN_ADDR": "127.0.0.1:0",
			"WEBHOOK_ALLOW_HOSTS": u.Hostname(),
		}), io.Discard, func(addr string) { ready <- addr })
	}()
~~~

to:

~~~go
	vars := map[string]string{
		"AMQP_URL": amqpURL, "DATABASE_URL": dbURL, "LISTEN_ADDR": "127.0.0.1:0",
		"WEBHOOK_ALLOW_HOSTS": u.Hostname(),
	}
	for k, v := range extra {
		vars[k] = v
	}
	go func() { done <- run(runCtx, env(vars), io.Discard, func(addr string) { ready <- addr }) }()
~~~


The migration gets a login for one run, revoked as soon as it's done. Its session acts as `runway_owner`, so what it creates belongs to `runway_owner` and not to a login about to be dropped. In `cmd/migrate/main.go`:

Change:

<!-- edit: cmd/migrate/main.go -->
~~~go
	"io"
	"os"
~~~

to:

~~~go
	"io"
	"log/slog"
	"os"
~~~

Change:

<!-- edit: cmd/migrate/main.go -->
~~~go
	"runway/internal/pgstore"
)
~~~

to:

~~~go
	"runway/internal/pgstore"
	"runway/internal/pki"
	"runway/internal/secrets"
)
~~~

Change:

<!-- edit: cmd/migrate/main.go -->
~~~go
	pool, err := pgstore.Open(ctx, url, pgstore.PoolOptions{MaxConns: 2})
~~~

to:

~~~go
	opts := pgstore.PoolOptions{MaxConns: 2}
	// With OpenBao (Phase 6, step 9), the login is made for this run: a
	// member of runway_owner, whose session acts as runway_owner, so what it
	// creates belongs to runway_owner and not to a login that is about to
	// be dropped. It is revoked as soon as the migrations are done.
	bao, err := secrets.LoadConfig(getenv)
	if err != nil {
		return err
	}
	if bao.Enabled() {
		logger := slog.New(slog.NewJSONHandler(stdout, nil))
		var tls *pki.Source
		if dir := getenv("TLS_DIR"); dir != "" {
			if tls, err = pki.NewSource(dir, logger); err != nil {
				return fmt.Errorf("TLS_DIR: %w", err)
			}
		}
		client, err := bao.NewClient(tls)
		if err != nil {
			return err
		}
		logins := secrets.NewDBLogins(client, bao.Role, logger)
		if err := logins.Fetch(ctx); err != nil {
			return err
		}
		defer logins.Close(context.WithoutCancel(ctx)) // after the pool closes
		opts.Login = logins.Credentials
	}
	pool, err := pgstore.Open(ctx, url, opts)
~~~


In `cmd/migrate/main_test.go`:

Change:

<!-- edit: cmd/migrate/main_test.go -->
~~~go
	"io"
	"strings"
~~~

to:

~~~go
	"io"
	"os"
	"strings"
~~~

Change:

<!-- edit: cmd/migrate/main_test.go -->
~~~go

	"runway/internal/pgstore/pgtest"
)
~~~

to:

~~~go

	"github.com/jackc/pgx/v5"

	"runway/internal/pgstore/pgtest"
	"runway/internal/secrets/baotest"
)
~~~

Add this at the end of the file:

<!-- append: cmd/migrate/main_test.go -->
~~~go
// A fresh install with OpenBao (step 9): the operator has run
// deploy/postgres/roles.sql as the superuser, and every migration then runs
// as a login OpenBao made in runway_owner. Everything ends up owned by
// runway_owner, and the login is gone afterwards.
func TestMigrationsRunAsAnOpenBaoLogin(t *testing.T) {
	ctx := context.Background()
	bao := baotest.Client(t)
	url := pgtest.URL(t)
	admin, err := pgx.Connect(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close(ctx)
	roles, err := os.ReadFile("../../deploy/postgres/roles.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := admin.Exec(ctx, string(roles)); err != nil { // on this test's schema: its search path
		t.Fatal(err)
	}
	role := baotest.DatabaseRole(t, bao, "runway_owner", "1m", `ALTER ROLE "{{name}}" SET role = 'runway_owner'`)

	var out strings.Builder
	err = run(ctx, env(map[string]string{"DATABASE_URL": url,
		"BAO_ADDR": os.Getenv("RUNWAY_BAO_ADDR"), "BAO_TOKEN": os.Getenv("RUNWAY_BAO_TOKEN"), "BAO_ROLE": role}), &out)
	if err != nil {
		t.Fatal(err)
	}
	var schema string
	var others, logins int
	err = admin.QueryRow(ctx, `
		SELECT current_schema(),
		       (SELECT count(*) FROM pg_tables WHERE schemaname = current_schema() AND tableowner <> 'runway_owner'),
		       (SELECT count(*) FROM pg_roles WHERE rolname LIKE '%' || $1 || '%')`, role).Scan(&schema, &others, &logins)
	if err != nil {
		t.Fatal(err)
	}
	if others != 0 {
		t.Errorf("%d tables in %s not owned by runway_owner", others, schema)
	}
	if logins != 0 {
		t.Errorf("%d logins from %s left after the run", logins, role)
	}
	if !strings.Contains(out.String(), "schema up to date") || !strings.Contains(out.String(), "database login revoked") {
		t.Errorf("output:\n%s", out.String())
	}
}
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/secrets/... ./internal/pgstore/... ./cmd/api/... ./cmd/notifier/... ./cmd/migrate/... -->

### OpenBao on the cluster

One server, its data on a volume, listening on its loopback behind step 8's sidecar, which admits only the API, the notifier, the migration and the operator. Create `deploy/k8s/bao.yaml`:

<!-- file: deploy/k8s/bao.yaml -->
~~~yaml
# OpenBao (Phase 6, step 9): where Runway's secrets live, and the one place
# that makes database logins. One server, its data on a volume (integrated
# Raft storage, so a second and third server could join later).
#
# It starts sealed: its data is encrypted with a key that is itself
# encrypted, and nothing can be read until enough unseal keys are given
# (deploy/bao/init.sh). Every restart seals it again. That is the price of
# a server whose disk is useless to a thief; in AWS, a KMS key unseals it
# instead of people (see the guide).
#
# Like Redis in step 8, it listens only on its Pod's loopback, and a tlsproxy
# beside it takes mutual TLS from the services that need it and the
# operator. Anyone else's connection ends at the handshake.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bao
  namespace: runway
---
# A Pod logs in with a token Kubernetes signed for its service account.
# OpenBao asks Kubernetes whether such a token is genuine (a TokenReview);
# this lets it ask, and nothing more.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: bao-tokenreview
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - { kind: ServiceAccount, name: bao, namespace: runway }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: bao
  namespace: runway
data:
  config.hcl: |
    storage "raft" {
      path    = "/openbao/data"
      node_id = "bao-0"
    }
    # Plain HTTP, on the loopback only: the sidecar is the way in.
    listener "tcp" {
      address     = "127.0.0.1:8210"
      tls_disable = true
    }
    # Who asked for what: every request, with secrets replaced by HMACs,
    # to the container's output (kubectl logs bao-0 -c bao). OpenBao takes
    # audit devices only from here, not from its API, so a stolen root
    # token can't switch them off or point them elsewhere. Step 10 makes
    # such a log tamper-evident.
    audit "file" "stdout" {
      options {
        file_path = "stdout"
      }
    }
    api_addr      = "https://bao.runway:8200"
    cluster_addr  = "http://127.0.0.1:8201"
    disable_mlock = true # Raft storage advises it; memory isn't swapped in kind anyway
    ui            = false
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: bao
  namespace: runway
spec:
  serviceName: bao
  replicas: 1
  selector:
    matchLabels: { app: bao }
  template:
    metadata:
      labels: { app: bao }
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9901" # the sidecar's
    spec:
      serviceAccountName: bao # it calls the Kubernetes API: TokenReviews
      securityContext:
        runAsNonRoot: true
        runAsUser: 100 # the image's openbao user
        runAsGroup: 1000
        fsGroup: 1000 # its data volume; and every container's extra group, so the sidecar can read its certificate
      initContainers:
        - name: tlsproxy
          image: runway:dev
          restartPolicy: Always
          command: ["/usr/local/bin/tlsproxy", "-tls", "/etc/runway/tls",
                    "-in", "0.0.0.0:8200,127.0.0.1:8210,spiffe://runway/api,spiffe://runway/notifier,spiffe://runway/migrate,spiffe://runway/operator"]
          ports:
            - { name: https, containerPort: 8200 }
            - { name: proxy-admin, containerPort: 9901 }
          startupProbe:
            httpGet: { path: /ready, port: proxy-admin }
            periodSeconds: 1
            failureThreshold: 30
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { memory: 64Mi }
          securityContext:
            runAsUser: 65532 # tlsproxy's image user, not OpenBao's
            runAsGroup: 65532
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: tls, mountPath: /etc/runway/tls, readOnly: true }
      containers:
        - name: bao
          image: openbao/openbao:2.7.1
          args: ["server", "-config=/openbao/config/config.hcl"]
          env:
            # For "kubectl exec bao-0 -- bao ...": the CLI talks to the
            # server over the loopback, past the sidecar.
            - { name: BAO_ADDR, value: "http://127.0.0.1:8210" }
          # Ready only once unsealed: "bao status" exits 2 while sealed.
          readinessProbe:
            exec: { command: ["bao", "status"] }
            periodSeconds: 5
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: config, mountPath: /openbao/config, readOnly: true }
            - { name: data, mountPath: /openbao/data }
      volumes:
        - name: config
          configMap: { name: bao }
        - name: tls
          secret:
            secretName: tls-bao
            defaultMode: 0440
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests: { storage: 1Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: bao
  namespace: runway
spec:
  selector: { app: bao }
  # Sealed is not ready, but the operator must still reach it to unseal:
  # through kubectl exec, which needs no Service. Clients wait.
  ports:
    - { name: https, port: 8200, targetPort: https }
~~~

Initialise and unseal it. Create `deploy/bao/init.sh`:

<!-- file: deploy/bao/init.sh -->
~~~bash
#!/usr/bin/env bash
# Initialise OpenBao the first time, and unseal it: now, and after every
# restart, which seals it again.
#   deploy/bao/init.sh KEYDIR
# The first run writes KEYDIR/init.json: five unseal keys, any three of
# which unseal it, and the root token. Readable by you alone. In a real
# team, each key goes to a different person, the root token is used for
# setup and then revoked, and nobody keeps all of it in one file.
set -euo pipefail
dir=${1:?usage: deploy/bao/init.sh KEYDIR}
bao() { kubectl -n runway exec -i bao-0 -c bao -- bao "$@"; }

# Ready means unsealed, so wait only for the server to be running.
kubectl -n runway wait pod/bao-0 --timeout=300s \
  --for=jsonpath='{.status.containerStatuses[?(@.name=="bao")].started}'=true >/dev/null
until bao status -format=json >/dev/null 2>&1 || [[ $? == 2 ]]; do sleep 1; done # 2: sealed, which is fine

if [[ ! -f $dir/init.json ]]; then
  mkdir -p "$dir"
  (umask 077 && bao operator init -key-shares=5 -key-threshold=3 -format=json >"$dir/init.json")
  echo "initialised: keys and root token in $dir/init.json"
fi
# The keys go in on stdin (key=-), not on the command line, where any
# process on the node could read them. ("bao operator unseal" wants a
# terminal to prompt on; this is the same request.)
for i in 0 1 2; do
  jq -r ".unseal_keys_b64[$i]" "$dir/init.json" | bao write sys/unseal key=- >/dev/null
done
bao status | grep -E '^(Initialized|Sealed|Total Shares|Threshold)'
~~~

Every key and token goes in on standard input, never on a command line, where any process on the node could read it in `/proc`.

Each service's policy says exactly which paths it may use. The API may *seal* webhook secrets but not open them; only the notifier, which signs with them, can open them. A leaked API token gives away no tenant's secret. Create `deploy/bao/policies/api.hcl`, `deploy/bao/policies/notifier.hcl` and `deploy/bao/policies/migrate.hcl`:

<!-- file: deploy/bao/policies/api.hcl -->
~~~
# The API (step 9): a database login of its own, and sealing webhook
# secrets. It can seal but not open them: only the notifier, which signs
# with them, can. A leaked API token gives no tenant's secret away.
path "database/creds/api" {
  capabilities = ["read"]
}
# Its own logins only: the lease ID is in the path.
path "sys/leases/revoke/database/creds/api/*" {
  capabilities = ["update"]
}
path "transit/encrypt/webhooks" {
  capabilities = ["update"]
}
~~~

<!-- file: deploy/bao/policies/notifier.hcl -->
~~~
# The notifier (step 9): a database login of its own, and opening the
# webhook secrets it signs with. It can't seal new ones.
path "database/creds/notifier" {
  capabilities = ["read"]
}
path "sys/leases/revoke/database/creds/notifier/*" {
  capabilities = ["update"]
}
path "transit/decrypt/webhooks" {
  capabilities = ["update"]
}
~~~

<!-- file: deploy/bao/policies/migrate.hcl -->
~~~
# The migration (step 9): a login that acts as runway_owner, for one run.
path "database/creds/migrate" {
  capabilities = ["read"]
}
path "sys/leases/revoke/database/creds/migrate/*" {
  capabilities = ["update"]
}
~~~

And the setup: Kubernetes logins, the roles, the database engine with a login of its own that only OpenBao knows (`rotate-root` changes its password the moment it's configured), and the transit key. Create `deploy/bao/setup.sh`:

<!-- file: deploy/bao/setup.sh -->
~~~bash
#!/usr/bin/env bash
# Set OpenBao up for Runway (Phase 6, step 9), after deploy/bao/init.sh.
#   deploy/bao/setup.sh KEYDIR [LOGIN_TTL]
# KEYDIR holds init.json, for the root token. LOGIN_TTL is how long each
# service's database login lasts (default 1h); services fetch the next one
# two thirds of the way through. Running it again changes nothing that is
# already set up, except the roles' TTLs.
set -euo pipefail
cd "$(dirname "$0")/../.."
keys=${1:?usage: deploy/bao/setup.sh KEYDIR [LOGIN_TTL]}/init.json
ttl=${2:-1h}

# Run "bao ARGS" in the Pod as root. The token goes in on stdin, ahead of
# whatever else is piped in, never on a command line.
as_root() {
  { jq -r .root_token "$keys"; cat; } |
    kubectl -n runway exec -i bao-0 -c bao -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' sh "$@"
}
psql() {
  kubectl -n runway exec -i postgres-0 -- env PGOPTIONS='-c client_min_messages=warning' \
    psql -U runway -d runway -v ON_ERROR_STOP=1 -q "$@"
}
enabled() { as_root "$1" list -format=json </dev/null | jq -e --arg p "$2/" 'has($p)' >/dev/null; }

# Pods log in with their service account's token (audience "bao"), and
# get the policy of the role their account is bound to.
enabled auth kubernetes || as_root auth enable kubernetes </dev/null
as_root write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc </dev/null
for service in api notifier migrate; do
  as_root policy write "$service" - <"deploy/bao/policies/$service.hcl"
  # A login dies with the token that fetched it, so the token must last
  # as long as the login (each fetch logs in afresh).
  as_root write "auth/kubernetes/role/$service" \
    bound_service_account_names="$service" bound_service_account_namespaces=runway \
    audience=bao token_policies="$service" token_ttl="$ttl" token_max_ttl="$ttl" </dev/null
done

# PostgreSQL: the roles (deploy/postgres/roles.sql), and a login for
# OpenBao itself. It may create logins in the services' roles and drop
# them, and do nothing else: ADMIN on those roles without being one of
# them (INHERIT FALSE, SET FALSE), and the right to end sessions.
psql <deploy/postgres/roles.sql
enabled secrets database || as_root secrets enable database </dev/null
if ! as_root read database/config/runway </dev/null >/dev/null 2>&1; then
  password=$(openssl rand -hex 24)
  psql <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bao') THEN
    CREATE ROLE bao LOGIN CREATEROLE;
  END IF;
END \$\$;
ALTER ROLE bao PASSWORD '$password';
GRANT runway_api, runway_notifier, runway_owner TO bao WITH ADMIN TRUE, INHERIT FALSE, SET FALSE;
GRANT pg_signal_backend TO bao;
SQL
  # scram-sha-256: OpenBao hashes each new password before sending it, so
  # it never appears in PostgreSQL's logs. printf, not echo: "-" takes
  # stdin as it is, newline and all.
  printf %s "$password" | as_root write database/config/runway plugin_name=postgresql-database-plugin \
    connection_url='postgresql://{{username}}:{{password}}@postgres:5432/runway?sslmode=disable' \
    username=bao password=- password_authentication=scram-sha-256 \
    allowed_roles=api,notifier,migrate
  # Now change it to one only OpenBao knows.
  as_root write -f database/rotate-root/runway </dev/null
fi

# One login per Pod, ended when its lease ends or is revoked. Ending it
# means ending its sessions too: a dropped role's open session carries on,
# without its privileges but still connected.
revoke=(
  revocation_statements="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '{{name}}'"
  revocation_statements='DROP ROLE IF EXISTS "{{name}}"'
)
login() { echo "CREATE ROLE \"{{name}}\" LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE $1"; }
as_root write database/roles/api db_name=runway default_ttl="$ttl" max_ttl="$ttl" \
  creation_statements="$(login runway_api)" "${revoke[@]}" </dev/null
as_root write database/roles/notifier db_name=runway default_ttl="$ttl" max_ttl="$ttl" \
  creation_statements="$(login runway_notifier)" "${revoke[@]}" </dev/null
# The migration's session acts as runway_owner, so what it creates belongs
# to runway_owner, not to a login about to be dropped.
as_root write database/roles/migrate db_name=runway default_ttl=10m max_ttl=10m \
  creation_statements="$(login runway_owner)" \
  creation_statements="ALTER ROLE \"{{name}}\" SET role = 'runway_owner'" "${revoke[@]}" </dev/null

# Webhook secrets, sealed with a key that never leaves OpenBao. "derived":
# each tenant's are sealed under a key made for that tenant.
enabled secrets transit || as_root secrets enable transit </dev/null
as_root read transit/keys/webhooks </dev/null >/dev/null 2>&1 ||
  as_root write transit/keys/webhooks derived=true </dev/null >/dev/null

echo "OpenBao is set up: logins last $ttl"
~~~

Read `revocation_statements`. Dropping a role doesn't end its open sessions: they carry on, connected, without the role's privileges. I measured it. So revocation first terminates the role's sessions, then drops it. And OpenBao's own PostgreSQL login has `ADMIN` on the service roles, so it can make members of them, but `INHERIT FALSE, SET FALSE`, so it can't act as them.

### The chart

Each service gets its own service account, so OpenBao can tell them apart. Create `deploy/helm/runway/templates/serviceaccounts.yaml`:

<!-- file: deploy/helm/runway/templates/serviceaccounts.yaml -->
~~~yaml
# One identity per service (Phase 6, step 9). OpenBao lets each one log in
# as itself, to its own role, and no other. None of them calls the
# Kubernetes API, so none is given the token for it; each Pod asks for a
# token with OpenBao's audience instead (runway.baoVolume). The migration's
# is in migrate.yaml: it must exist before the hook runs.
{{- range $name := list "api" "notifier" }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $name }}
  labels:
    {{- include "runway.labels" $ | nindent 4 }}
automountServiceAccountToken: false
{{- end }}
~~~

In `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
# A Secret this chart doesn't create, holding DATABASE_URL and AMQP_URL
# (deploy/k8s/config.yaml). Keeping passwords out of values keeps them out
# of "helm get values" and out of version control.
~~~

to:

~~~yaml
# A Secret this chart doesn't create, holding AMQP_URL, and DATABASE_URL
# when bao.enabled is false (deploy/k8s/config.yaml). Keeping passwords out
# of values keeps them out of "helm get values" and out of version control.
# Each service gets only the keys it needs.
~~~

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
  maxConnectionAge: 10m

~~~

to:

~~~yaml
  maxConnectionAge: 10m

# Secrets from OpenBao (Phase 6, step 9): deploy/k8s/bao.yaml runs it, and
# deploy/bao/setup.sh sets it up. The API, the notifier and the migration
# each log in as their own service account and get a PostgreSQL login made
# for that Pod alone, which OpenBao drops when its lease ends; DATABASE_URL
# then names only the server. Webhook secrets are stored sealed by
# OpenBao's transit key. Needs tls.enabled: OpenBao's sidecar admits only
# services with a certificate from our CA. Off: DATABASE_URL, with its
# password, comes from existingSecret.
bao:
  enabled: true
  addr: https://bao.runway:8200
  databaseURL: postgres://postgres:5432/runway

~~~


In `deploy/helm/runway/templates/_helpers.tpl`. Each service gets only the Secret keys it needs, by name, instead of `envFrom` of the whole Secret, and a token for OpenBao alone (audience `bao`), which is no use against the Kubernetes API:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
  - secretRef: { name: {{ .Values.existingSecret }} }
~~~

to:

~~~yaml
{{- end }}

{{/*
The Secret's keys one service needs, and no others (Phase 6, step 9; until
then every service got the whole Secret, every password in it):
runway.secretEnv (dict "root" $ "keys" (list "AMQP_URL")).
*/}}
{{- define "runway.secretEnv" -}}
{{- range .keys }}
- name: {{ . }}
  valueFrom:
    secretKeyRef: { name: {{ $.root.Values.existingSecret }}, key: {{ . }} }
{{- end }}
{{- end }}

{{/*
How a service reaches PostgreSQL: runway.databaseEnv (dict "root" $ "role"
"api"). With OpenBao (step 9), DATABASE_URL names only the server, and the
login comes from OpenBao's role of the same name.
*/}}
{{- define "runway.databaseEnv" -}}
{{- if .root.Values.bao.enabled }}
- { name: DATABASE_URL, value: {{ .root.Values.bao.databaseURL | quote }} }
- { name: BAO_ADDR, value: {{ .root.Values.bao.addr | quote }} }
- { name: BAO_ROLE, value: {{ .role }} }
{{- else }}
{{- include "runway.secretEnv" (dict "root" .root "keys" (list "DATABASE_URL")) }}
{{- end }}
{{- end }}

{{/*
A token Kubernetes signs for the Pod's service account, for OpenBao alone
(audience "bao"), so it is no use against the Kubernetes API. The kubelet
replaces it well before it expires.
*/}}
{{- define "runway.baoVolume" -}}
- name: bao-token
  projected:
    sources:
      - serviceAccountToken: { audience: bao, expirationSeconds: 600, path: token }
{{- end }}

{{- define "runway.baoMount" -}}
- { name: bao-token, mountPath: /var/run/secrets/bao, readOnly: true }
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
    fsGroup: 65532 # so the image's user can read the mounted certificate
  terminationGracePeriodSeconds: {{ $api.terminationGracePeriodSeconds }}
~~~

to:

~~~yaml
    fsGroup: 65532 # so the image's user can read the mounted certificate
  # Its own identity (step 9), and no token for the Kubernetes API, which
  # it never calls; the only token it gets is OpenBao's.
  serviceAccountName: api
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: {{ $api.terminationGracePeriodSeconds }}
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
      env:
        - name: SERVED_BY
~~~

to:

~~~yaml
      env:
        {{- include "runway.secretEnv" (dict "root" $root "keys" (list "AMQP_URL")) | nindent 8 }}
        {{- include "runway.databaseEnv" (dict "root" $root "role" "api") | nindent 8 }}
        - name: SERVED_BY
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
      {{- include "runway.containerSecurity" $root | nindent 6 }}
      {{- if $root.Values.tls.enabled }}
      volumeMounts:
        {{- include "runway.tlsMount" . | nindent 8 }}
  volumes:
    {{- include "runway.tlsVolume" "api" | nindent 4 }}
  {{- end }}
~~~

to:

~~~yaml
      {{- include "runway.containerSecurity" $root | nindent 6 }}
      {{- if or $root.Values.tls.enabled $root.Values.bao.enabled }}
      volumeMounts:
        {{- if $root.Values.tls.enabled }}
        {{- include "runway.tlsMount" . | nindent 8 }}
        {{- end }}
        {{- if $root.Values.bao.enabled }}
        {{- include "runway.baoMount" . | nindent 8 }}
        {{- end }}
  volumes:
    {{- if $root.Values.tls.enabled }}
    {{- include "runway.tlsVolume" "api" | nindent 4 }}
    {{- end }}
    {{- if $root.Values.bao.enabled }}
    {{- include "runway.baoVolume" . | nindent 4 }}
    {{- end }}
  {{- end }}
~~~


In `deploy/helm/runway/templates/api.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/api.yaml -->
~~~yaml
{{- fail "auth.issuer must start https:// with tls.enabled, and http:// without: the chart's issuer serves one or the other" }}
{{- end }}
~~~

to:

~~~yaml
{{- fail "auth.issuer must start https:// with tls.enabled, and http:// without: the chart's issuer serves one or the other" }}
{{- end }}
{{- if and .Values.bao.enabled (not .Values.tls.enabled) }}
{{- fail "bao.enabled needs tls.enabled: OpenBao's sidecar admits only services that prove who they are with a certificate" }}
{{- end }}
~~~


In `deploy/helm/runway/templates/notifier.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/notifier.yaml -->
~~~yaml
        runAsNonRoot: true
      automountServiceAccountToken: false # it never calls the Kubernetes API
~~~

to:

~~~yaml
        runAsNonRoot: true
        fsGroup: 65532 # so the image's user can read the mounted certificate
      serviceAccountName: notifier # its identity for OpenBao (step 9)
      automountServiceAccountToken: false # it never calls the Kubernetes API
~~~

Change:

<!-- edit: deploy/helm/runway/templates/notifier.yaml -->
~~~yaml
          env:
            - { name: LISTEN_ADDR, value: "0.0.0.0:8082" }
~~~

to:

~~~yaml
          env:
            {{- include "runway.secretEnv" (dict "root" $ "keys" (list "AMQP_URL")) | nindent 12 }}
            {{- include "runway.databaseEnv" (dict "root" $ "role" "notifier") | nindent 12 }}
            {{- if .Values.bao.enabled }}
            - { name: TLS_DIR, value: /etc/runway/tls } # proves to OpenBao's sidecar who calls
            {{- end }}
            - { name: LISTEN_ADDR, value: "0.0.0.0:8082" }
~~~

Change:

<!-- edit: deploy/helm/runway/templates/notifier.yaml -->
~~~yaml
          {{- include "runway.containerSecurity" . | nindent 10 }}
{{- end }}
~~~

to:

~~~yaml
          {{- include "runway.containerSecurity" . | nindent 10 }}
          {{- if .Values.bao.enabled }}
          volumeMounts:
            {{- include "runway.tlsMount" . | nindent 12 }}
            {{- include "runway.baoMount" . | nindent 12 }}
      volumes:
        {{- include "runway.tlsVolume" "notifier" | nindent 8 }}
        {{- include "runway.baoVolume" . | nindent 8 }}
      {{- end }}
{{- end }}
~~~


In `deploy/helm/runway/templates/worker.yaml` (the worker needs only the broker):

Change:

<!-- edit: deploy/helm/runway/templates/worker.yaml -->
~~~yaml
          env:
            - { name: METRICS_ADDR, value: "0.0.0.0:9100" }
~~~

to:

~~~yaml
          env:
            {{- include "runway.secretEnv" (dict "root" $ "keys" (list "AMQP_URL")) | nindent 12 }}
            - { name: METRICS_ADDR, value: "0.0.0.0:9100" }
~~~


The migration hook gets its own service account, made as a hook too, so it exists before the hook runs, and its login from OpenBao. The changes touch most of the file, so here it is whole, `deploy/helm/runway/templates/migrate.yaml`:

<!-- file: deploy/helm/runway/templates/migrate.yaml -->
~~~yaml
{{- if .Values.bao.enabled }}
# The migration's identity for OpenBao (step 9). A hook too, and made first
# (a lower weight): the release's ordinary resources are made only after
# the hooks have run.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: migrate
  labels:
    {{- include "runway.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-1"
    "helm.sh/hook-delete-policy": before-hook-creation
automountServiceAccountToken: false
---
{{- end }}
# The migration, as a hook: Helm runs this Job before installing or
# upgrading anything else, waits for it to succeed, and stops the release
# if it fails. So new code never runs against an old schema.
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Release.Name }}-migrate
  labels:
    {{- include "runway.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    # Delete the last run's Job before making a new one (a Job's template
    # can't change), and delete this one once it succeeds. A failed one
    # stays, with its logs, until the next attempt.
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 300
  template:
    metadata:
      labels: { app: migrate }
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        fsGroup: 65532
      {{- if .Values.bao.enabled }}
      serviceAccountName: migrate
      {{- end }}
      automountServiceAccountToken: false
      containers:
        - name: migrate
          image: {{ include "runway.image" (list $ .Values.image.tag) }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: ["/usr/local/bin/migrate"]
          env:
            {{- include "runway.databaseEnv" (dict "root" $ "role" "migrate") | nindent 12 }}
            {{- if .Values.bao.enabled }}
            - { name: TLS_DIR, value: /etc/runway/tls }
            {{- end }}
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits: { cpu: 500m, memory: 64Mi }
          {{- include "runway.containerSecurity" . | nindent 10 }}
          {{- if .Values.bao.enabled }}
          volumeMounts:
            {{- include "runway.tlsMount" . | nindent 12 }}
            {{- include "runway.baoMount" . | nindent 12 }}
      volumes:
        {{- include "runway.tlsVolume" "migrate" | nindent 8 }}
        {{- include "runway.baoVolume" . | nindent 8 }}
      {{- end }}
~~~

The superuser's URL leaves the Secret. In `deploy/k8s/config.yaml`:

Change:

<!-- edit: deploy/k8s/config.yaml -->
~~~yaml
# A Secret's values are only base64-encoded, not encrypted: anyone who can
# read Secrets in this namespace can read these. Phase 6 does better.
~~~

to:

~~~yaml
# A Secret's values are only base64-encoded: anyone who may read Secrets in
# this namespace can read these. Phase 6, step 9 encrypts them in etcd
# (deploy/kind-encrypt-secrets.sh), gives each service only the keys it
# needs, and takes the database out of here: logins come from OpenBao.
# POSTGRES_PASSWORD only creates the superuser, the first time PostgreSQL
# starts; step 9 then removes its password, so it can't log in over the
# network at all (break-glass: kubectl exec into postgres-0).
~~~

And delete the `DATABASE_URL` line:

<!-- edit: deploy/k8s/config.yaml -->
~~~yaml
  POSTGRES_PASSWORD: runway
  DATABASE_URL: postgres://runway:runway@postgres:5432/runway
~~~

to:

~~~yaml
  POSTGRES_PASSWORD: runway
~~~

OpenBao, the notifier and the migration need certificates. In `deploy/certs.sh`:

Change:

<!-- edit: deploy/certs.sh -->
~~~bash
  [redis]="*.redis.runway,*.redis.runway.svc" # its sidecar's (step 8)
)
for service in api gateway idp metad redis; do
~~~

to:

~~~bash
  [redis]="*.redis.runway,*.redis.runway.svc" # its sidecar's (step 8)
  [bao]=bao,bao.runway,bao.runway.svc # OpenBao's sidecar's (step 9)
  [notifier]="" # clients of OpenBao only (step 9)
  [migrate]=""
)
for service in api gateway idp metad redis bao notifier migrate; do
~~~


The smoke test deploys OpenBao, unseals it and sets it up. In `deploy/smoke.sh`:

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash
elif ! kubectl -n runway get secret tls-redis >/dev/null 2>&1; then
  echo "no tls-redis Secret: run deploy/certs.sh with your CA's directory first" >&2
~~~

to:

~~~bash
elif ! kubectl -n runway get secret tls-bao >/dev/null 2>&1; then
  echo "no tls-bao Secret: run deploy/certs.sh with your CA's directory first" >&2
~~~

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash
# Redis's sidecar is Runway's own tlsproxy, from the image being tested.
~~~

to:

~~~bash
# Redis's and OpenBao's sidecars are Runway's own tlsproxy, from the image
# being tested.
~~~

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash
sed "s|image: runway:dev|image: runway:$tag|" deploy/k8s/redis.yaml | kubectl apply -f -
~~~

to:

~~~bash
for f in redis bao; do
  sed "s|image: runway:dev|image: runway:$tag|" "deploy/k8s/$f.yaml" | kubectl apply -f -
done
~~~

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash
  kubectl -n runway rollout status "statefulset/$store" --timeout=300s
done

# The token issuer's key and a client, made once per cluster (Phase 6).
~~~

to:

~~~bash
  kubectl -n runway rollout status "statefulset/$store" --timeout=300s
done

# OpenBao (step 9): unseal it, the first time initialising it, then set it
# up. It is ready only once unsealed, so it isn't waited for above. Its
# unseal keys and root token stay in BAO_KEYS: keep them.
keys=${BAO_KEYS:-$HOME/.runway/bao}
deploy/bao/init.sh "$keys"
deploy/bao/setup.sh "$keys"

# The token issuer's key and a client, made once per cluster (Phase 6).
~~~


If OpenBao is sealed or down, every service keeps its current login until it expires, and then can't open a connection. Alert well before that. In `deploy/prometheus/rules.yml`:

Add this at the end of the file:

<!-- append: deploy/prometheus/rules.yml -->
~~~yaml
  - name: secrets
    rules:
      # Each service replaces its database login two thirds of the way
      # through its life (Phase 6, step 9), so a healthy one is never past
      # that point for long. Overdue means OpenBao is failing it: sealed,
      # down, or refusing. The login still works until it expires; after
      # that, no new connection can be made.
      - alert: DatabaseLoginNotRenewed
        expr: time() - db_login_renew_timestamp_seconds > 60
        for: 1m
        labels:
          severity: page
        annotations:
          summary: A database login is overdue for renewal
          description: "{{ $labels.pod }} should have replaced its database login {{ $value | humanizeDuration }} ago. Is OpenBao sealed? (kubectl -n runway exec bao-0 -c bao -- bao status)"
~~~


In `deploy/prometheus/rules_test.yml`:

Add this at the end of the file:

<!-- append: deploy/prometheus/rules_test.yml -->
~~~yaml
  # A login due for renewal at 5 minutes that is never renewed: OpenBao
  # was sealed. Pending a minute after it is due, paging a minute later.
  - name: an overdue database login pages
    interval: 1m
    input_series:
      - series: 'db_login_renew_timestamp_seconds{pod="api-1"}'
        values: '300x10'
    alert_rule_test:
      - eval_time: 6m
        alertname: DatabaseLoginNotRenewed
        exp_alerts: []
      - eval_time: 8m
        alertname: DatabaseLoginNotRenewed
        exp_alerts:
          - exp_labels: { severity: page, pod: api-1 }
            exp_annotations:
              summary: A database login is overdue for renewal
              description: "api-1 should have replaced its database login 3m 0s ago. Is OpenBao sealed? (kubectl -n runway exec bao-0 -c bao -- bao status)"
~~~


And encryption at rest for Secrets. kind's API server is a static Pod on the control-plane node, so turning it on means editing its manifest there. Create `deploy/kind-encrypt-secrets.sh`:

<!-- file: deploy/kind-encrypt-secrets.sh -->
~~~bash
#!/usr/bin/env bash
# Encrypt Kubernetes Secrets at rest in etcd (Phase 6, step 9), on the kind
# cluster made from deploy/kind.yaml. Until now etcd held them as plain
# JSON: anyone with a copy of etcd's data, or of a backup of it, could read
# every one.
#   deploy/kind-encrypt-secrets.sh
#
# The API server encrypts each Secret as it writes it, with a key from an
# EncryptionConfiguration file, and decrypts it as it reads it. Programs
# that read Secrets through the API see no difference. Here the key sits
# on the control-plane node, beside etcd's data: that protects copies of
# the data, not the node itself. EKS's KMS provider keeps the key in KMS,
# and the API server asks KMS to unwrap a data key (envelope encryption).
set -euo pipefail
node=runway-control-plane

# The first provider encrypts; all of them are tried to decrypt. identity
# (no encryption) stays last, so Secrets written before can still be read.
if ! docker exec "$node" test -f /etc/kubernetes/enc/enc.yaml; then
  key=$(head -c 32 /dev/urandom | base64)
  docker exec -i "$node" sh -c 'mkdir -p /etc/kubernetes/enc && umask 077 && cat > /etc/kubernetes/enc/enc.yaml' <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: [secrets]
    providers:
      - secretbox:
          keys:
            - name: key1
              secret: $key
      - identity: {}
EOF
fi

# The API server is a static Pod: the kubelet runs whatever its manifest
# says, and restarts it when the file changes. Give it the file and the flag.
manifest=/etc/kubernetes/manifests/kube-apiserver.yaml
if ! docker exec "$node" grep -q encryption-provider-config "$manifest"; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  docker cp "$node:$manifest" "$work/apiserver.yaml"
  uv run -q --with pyyaml python3 - "$work/apiserver.yaml" <<'PY'
import sys, yaml
path = sys.argv[1]
pod = yaml.safe_load(open(path))
spec = pod["spec"]
c = spec["containers"][0]
c["command"].append("--encryption-provider-config=/etc/kubernetes/enc/enc.yaml")
c["volumeMounts"].append({"name": "enc", "mountPath": "/etc/kubernetes/enc", "readOnly": True})
spec["volumes"].append({"name": "enc", "hostPath": {"path": "/etc/kubernetes/enc", "type": "DirectoryOrCreate"}})
yaml.safe_dump(pod, open(path, "w"), sort_keys=False)
PY
  # Write it outside the manifests directory first: the kubelet would read
  # a half-copied file.
  docker cp "$work/apiserver.yaml" "$node:/etc/kubernetes/apiserver.yaml.new"
  docker exec "$node" mv /etc/kubernetes/apiserver.yaml.new "$manifest"
  echo "restarting the API server..."
  sleep 10
  until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
fi

# Secrets are encrypted when written, so write every one again.
kubectl get secrets -A -o json | kubectl replace -f - >/dev/null
echo "every Secret rewritten, encrypted"
~~~

<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway | grep -q 'audience: bao' && ! helm template runway deploy/helm/runway | grep -q 'secretRef:' && bash -n deploy/bao/setup.sh deploy/bao/init.sh deploy/kind-encrypt-secrets.sh -->

### Run it

On an existing cluster, the order matters, because migration 0010 changes the tables' owner, and only their current owner (the old superuser) may do that:

~~~bash
deploy/certs.sh ~/.runway/ca                                  # bao, notifier, migrate too now
kubectl apply -f deploy/k8s/bao.yaml
deploy/bao/init.sh ~/.runway/bao                              # keep ~/.runway/bao/init.json safe
# rebuild and load the image, then migrate as the superuser, one last time:
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --set bao.enabled=false --wait
deploy/bao/setup.sh ~/.runway/bao
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --set bao.enabled=true --wait
kubectl -n runway rollout restart deployment
~~~

A new cluster doesn't need the two-step: `deploy/smoke.sh` runs the roles first, so migrations run as the migrate login from the start. I checked that too, from an empty namespace: every migration ran as a login acting as `runway_owner`, which owned every table and the schema afterwards, and the login's lease was revoked a second after the migration finished.

Who is logged in now?

~~~bash
kubectl -n runway exec postgres-0 -- psql -U runway -d runway -c "SELECT usename, count(*) FROM pg_stat_activity WHERE datname = 'runway' GROUP BY 1"
~~~

~~~text
                       usename                       | count 
-----------------------------------------------------+-------
 bao                                                 |     1
 v-kubernet-api-Ohh7SVu0z4HwbtiWXriC-1791855062      |     3
 v-kubernet-api-P3HiInDFvgHnWnusvPBa-1791855075      |     3
 v-kubernet-api-dyyWBlxHIxuAg2WHCy2r-1791855070      |     2
 v-kubernet-notifier-6Pg3hzllTydv3B0zDB5f-1791855059 |     1
(5 rows)
~~~

One login per Pod, each a member of `runway_api` or `runway_notifier`, each with a `VALID UNTIL` an hour away (`\du v-*` shows it). Jobs go through as before.

**Webhook secrets.** Acme's secret from step 6 was stored in plain text, and now the notifier refuses it:

~~~text
{"result":"failed","tenant":"acme","error":"webhook secret: open: not sealed by transit"}
~~~

That's the intended failure: no silent fallback to reading plain text. Register again (or rotate) and the new secret is stored sealed, and delivered:

~~~text
$ psql -c "SELECT tenant, secret FROM webhooks"
acme|vault:v1:BIeZIruyBLRoWCk/4iJxQP4d0iRaPisQ/otbVMo0KGIc7bvgUq1W8ZINFJYMXN/+Q4ZCLsdtbk8cA0F97GdN8uIJ32NVjFbUCidfh2Mp
{"result":"delivered","tenant":"acme"}
~~~

Then try to open it as each service, with a token made for each policy (`bao token create -policy=api -ttl=2m`, in the `bao-0` Pod, as root). Use `printf`, not `<<<`, for the context: `<<<` adds a newline, and `acme` plus a newline is another tenant.

~~~text
$ bao write transit/decrypt/webhooks ciphertext=vault:v1:... context=$(printf acme | base64)   # as api
Code: 403. Errors:
$ bao write transit/decrypt/webhooks ciphertext=vault:v1:... context=$(printf acme | base64)   # as notifier
d2hzZWNf... (base64 of whsec_...)
$ ... context=$(printf globex | base64)                                                     # as notifier, the wrong tenant
Code: 400. Errors:
* cipher: message authentication failed
~~~

The API can't read what it sealed. The notifier can, but only for the tenant it was sealed for.

**Watch the rotation.** Set logins to last two minutes (`deploy/bao/setup.sh ~/.runway/bao 2m`), restart the API, and send a job and a read every second for six minutes:

~~~text
# every 20 s: logins (roles v-...) and sessions per login
01:36:27  api logins 3  api sessions 7  notifier logins 1
01:37:29  api logins 5  api sessions 10  notifier logins 2
01:37:50  api logins 6  api sessions 12  notifier logins 2
01:38:11  api logins 3  api sessions 12  notifier logins 1
...
# responses over 6 minutes:
   1785 GET 200
   1785 POST 201
# one API Pod's log:
01:37:31	database login	v-kubernet-api-2hGQ5KgwkYUP6OiwBXiW-1791855451
01:38:31	database login revoked	v-kubernet-api-0DOhikV6tYyIv3IJoxui-1791855370
01:38:51	database login	v-kubernet-api-B44HvJE46YGfnszqrXup-1791855531
01:39:51	database login revoked	v-kubernet-api-2hGQ5KgwkYUP6OiwBXiW-1791855451
~~~

Every 80 seconds (two thirds of two minutes) a new login; a minute later the old one revoked. Each Pod held at most two at once, and 3,570 requests saw no errors. Set it back to `1h` afterwards.

**Break it: a token shorter than its login.** Make the API role's OpenBao token last one minute while logins last two:

~~~bash
kubectl -n runway exec -i bao-0 -c bao -- ...  write auth/kubernetes/role/api ... token_ttl=1m token_max_ttl=1m
~~~

~~~text
# 3 minutes of 5 jobs a second; responses per 10 s:
18:56:00 60×201
18:56:10 50×201 5×500
18:56:20 48×201 5×500 7×503
18:56:30 1×201 4×500 55×503
18:56:40 34×201 1×500 25×503
18:56:50 60×201
...
# totals:
    694 201
     28 500
    178 503
~~~

Twice in three minutes, about 20 seconds of failures. Each login was revoked when its one-minute *token* expired, halfway through the login's own life, so the database dropped the role and terminated its sessions, and new connections failed until the next fetch. The circuit breaker turned most failures into fast 503s. This is the measurement in `ReadWithNewToken`'s comment, at full scale: a lease's TTL isn't the only clock that ends it. Put the TTL back (`token_ttl=2m`).

**Break it: a leaked login.** Make a login as root (`bao read database/creds/api`) and use it as an attacker would:

~~~text
intruder$ psql $LEAKED -c "SELECT count(*) FROM jobs"
    4
intruder$ psql $LEAKED -c "CREATE TEMP TABLE out (line text); COPY out FROM PROGRAM 'id'"
    ERROR:  permission denied to COPY to or from an external program
intruder$ psql $LEAKED -c "ALTER TABLE jobs DISABLE ROW LEVEL SECURITY"
    ERROR:  must be owner of table jobs
intruder$ psql $LEAKED -c "SET ROLE runway_tenant; SELECT count(*) FROM jobs"
    ERROR:  app.tenant is not set: no tenant for this transaction
~~~

It sees the running jobs (the sweep's view, and nothing finished), no programs, no switching off RLS, and as a tenant only an error. Now revoke its lease while the intruder holds a session open:

~~~text
$ bao lease revoke database/creds/api/...
All revocation operations queued successfully!
the open session:
    FATAL:  terminating connection due to administrator command
a new one:
    psql: error: ... FATAL:  password authentication failed for user "v-root-api-FERHtJW7a2TngZYcaBW2-1791856781"
~~~

Gone, open session and all. And the superuser? Its password is still in the old `DATABASE_URL`. Take the URL out of the Secret, and the password off the role:

~~~bash
kubectl apply -f deploy/k8s/config.yaml
kubectl -n runway get secret runway -o json | jq -r ".data | keys[]"
~~~

~~~text
AMQP_URL
DATABASE_URL
POSTGRES_PASSWORD
RABBITMQ_DEFAULT_PASS
RABBITMQ_DEFAULT_USER
~~~

Still there. `stringData` is merged into `data` when a Secret is written, and a key you remove from the manifest is never removed from `data`. Remove it explicitly, then the password:

~~~bash
kubectl -n runway patch secret runway --type=json -p '[{"op": "remove", "path": "/data/DATABASE_URL"}]'
kubectl -n runway exec postgres-0 -- psql -U runway -c "ALTER ROLE runway PASSWORD NULL"
~~~

Now the superuser can't log in over the network at all, and break-glass access is `kubectl exec` into `postgres-0`, where it logs in over the local socket. Who may do *that* is a question for Kubernetes RBAC (step 12).

**Encrypt Secrets at rest:**

~~~bash
deploy/kind-encrypt-secrets.sh
etcdctl get /registry/secrets/runway/runway --print-value-only | head -c 60 | strings
~~~

~~~text
restarting the API server...
every Secret rewritten, encrypted
k8s:enc:secretbox:v1:key1:
~~~

etcd now holds ciphertext. Through the API, nothing changed. The encryption key is a file on the control-plane node, so this protects etcd's data and backups, not the node.

**Break it: seal OpenBao.** Delete `bao-0`. It comes back sealed:

~~~text
02:04:59 api-7c6fdb7d75-47hqf: , expires +54 s
02:04:59 $ kubectl -n runway delete pod bao-0
02:05:05 bao-0 is back: {"sealed":true}
02:06:06 api-7c6fdb7d75-47hqf: , expires -13 s
02:07:07 api-7c6fdb7d75-47hqf: , expires -74 s
02:08:08 $ kubectl -n runway delete pod api-7c6fdb7d75-7qbc6   # a new API Pod, while sealed
    api-7c6fdb7d75-zpk56 1/2 CrashLoopBackOff 2
database login from database/creds/api: log in as role "api": Post "https://bao.runway:8200/v1/auth/kubernetes/login": dial tcp 10.96.18.150:8200: connect: connection refused
02:08:50 $ deploy/bao/init.sh KEYDIR   # unseal
# responses per 30 s:
02:07:30 96×201
02:08:00 91×201 2×500
02:08:30 78×201 12×500 6×503
02:09:00 9×201 3×500 63×503
~~~

Three surprises, each worth knowing before it happens in production.
- **The API kept working after its login expired**, for over two minutes. PostgreSQL checks `VALID UNTIL` only when a session *starts*; open connections live on. New connections began failing ("expired password") about two minutes in.
- **A new API Pod couldn't start at all** while OpenBao was sealed. The sealed server fails its readiness probe, the Service has no endpoints, and the connection is refused.
- **Unsealing made it worse, briefly.** Within 100 ms of unsealing, OpenBao revoked every lease that had expired while it was sealed, which terminated the old logins' sessions, the ones still working. The API had no login until its renewal backoff (up to 30 seconds) came round. Hence the burst of 503s *after* the fix.

The alert `DatabaseLoginNotRenewed` fires a minute after a renewal is missed, long before the login expires. And in production, OpenBao unseals itself with a cloud KMS key (auto-unseal), so a restart isn't an outage.

**Break it: a migration that owns its tables.** Make a migrate role *without* `ALTER ROLE ... SET role = 'runway_owner'`, run a migration that creates a table, and revoke the login:

~~~text
                   tableowner                    
-------------------------------------------------
 v-root-migrate--f4xQUMQkBhyiJhUNsV8Y-1791857959
ERROR: role \"v-root-migrate--f4xQUMQkBhyiJhUNsV8Y-1791857959\" cannot be dropped because some objects depend on it (SQLSTATE 2BP01)" attempts=1 next_attempt=12.747330627s
~~~

The table belongs to a login that was meant to last ten minutes, and now can't be dropped. OpenBao retries the revocation forever.

**On AWS.** Each piece has a managed equivalent, and the design carries over: RDS IAM authentication gives the same per-Pod, short-lived database login through the same `BeforeConnect` hook (the token is the password); Secrets Manager rotates stored secrets on a schedule; KMS's encryption context does what the derived transit key does; EKS encrypts Secrets with a KMS key; and IAM Roles for Service Accounts is the Kubernetes login.

**Explain it:** how does a Pod prove who it is to OpenBao without a secret? Why does each fetch log in afresh? Why does revocation terminate sessions before dropping the role? What does `INHERIT FALSE` change, and why did the test server hide it? Why can't the API open the webhook secrets it seals? What happened at each stage of the sealed-OpenBao experiment, and what does auto-unseal fix?

**Read.** The OpenBao (or Vault) documentation on the [database secrets engine](https://openbao.org/docs/secrets/databases/) and [Kubernetes auth](https://openbao.org/docs/auth/kubernetes/). Then the PostgreSQL documentation on `GRANT` role membership (`INHERIT`, `SET`, `ADMIN`, PostgreSQL 16). Then Adi Shamir, *How to Share a Secret* (1979): two pages, and the idea behind the unseal keys. Then the Kubernetes documentation, *Encrypting Confidential Data at Rest*: why is a KMS provider better than `secretbox`?

---
## Step 10: A tamper-evident audit log

**The problem.** Phase 3 gave Runway an audit log: `klog`, the Rust Bridge's append-only file, written by `auditfeed` from the job-events stream. Each record has a CRC-32C checksum, which catches a disk's mistakes. It doesn't catch a person's (T15). Here's `tamper`, a short Python script standing in for anyone with write access to the file. It rewrites a record and its checksum together:

~~~bash
klog cat audit.log
python3 deploy/chaos/klog-tamper.py audit.log edit 3 '{"job":2,"tenant":"globex","state":"completed"}'
klog check audit.log
python3 deploy/chaos/klog-tamper.py audit.log drop 1
klog check audit.log
klog cat audit.log
~~~

~~~text
0: {"job":1,"tenant":"acme","state":"queued"}
1: {"job":1,"tenant":"acme","state":"completed"}
2: {"job":2,"tenant":"globex","state":"queued"}
3: {"job":2,"tenant":"globex","state":"failed","reason":"disk full"}
4: {"job":3,"tenant":"acme","state":"queued"}
5 records, all checksums valid
4 records, all checksums valid
0: {"job":1,"tenant":"acme","state":"queued"}
1: {"job":1,"tenant":"acme","state":"completed"}
2: {"job":2,"tenant":"globex","state":"queued"}
3: {"job":2,"tenant":"globex","state":"completed"}
~~~

(Make a small log to try it on with `klog append`, using the `klog` you build from `audit/` with `cargo build --release`; the tamper script is below, so type it first.) Globex's failed job now says it completed, and acme's last job never happened, and `klog check` is perfectly happy. A single bit flipped by the disk would have been caught at once (`checksum mismatch`). A checksum protects against accidents; against someone who can recompute it, it does nothing. The tool itself, the attacker's whole kit, is `deploy/chaos/klog-tamper.py`:

<!-- file: deploy/chaos/klog-tamper.py -->
~~~python
"""An attacker with write access to a klog file (Phase 6, step 10).

  deploy/chaos/klog-tamper.py FILE edit INDEX TEXT   replace record INDEX's payload, with a correct CRC
  deploy/chaos/klog-tamper.py FILE drop N            remove the last N records

It understands only klog's v1 framing: length (4 bytes LE), CRC-32C (4 bytes LE), payload.
"""
import struct
import sys


def crc32c(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
    return crc ^ 0xFFFFFFFF


def records(data: bytes):
    out, off = [], 0
    while off + 8 <= len(data):
        length, _ = struct.unpack_from("<II", data, off)
        out.append(data[off + 8 : off + 8 + length])
        off += 8 + length
    return out


def frame(payload: bytes) -> bytes:
    return struct.pack("<II", len(payload), crc32c(payload)) + payload


path, op = sys.argv[1], sys.argv[2]
recs = records(open(path, "rb").read())
if op == "edit":
    recs[int(sys.argv[3])] = sys.argv[4].encode()
elif op == "drop":
    recs = recs[: len(recs) - int(sys.argv[3])]
open(path, "wb").write(b"".join(frame(r) for r in recs))
~~~

**New ideas.**

- **A hash chain** (each record includes the hash of the one before) is the usual first answer, and it's not enough. The attacker who rewrote record 3 recomputes the chain from 3 onwards, and every hash checks. A chain proves records are in order; it doesn't prove nobody rewrote the whole thing since. What's missing is a commitment the attacker *can't* recompute.
- **A Merkle tree** hashes the records in pairs, then the pairs in pairs, up to one **root**: 32 bytes that depend on every record. Change, add, remove or reorder anything, and the root changes. And a tree gives short proofs, about log₂(n) hashes:
  - **inclusion**: record *i* is in the log whose root is *R*;
  - **consistency**: the log whose root is *R₂* is the log whose root was *R₁*, with records added at the end and nothing else changed.
- **Signed checkpoints.** Periodically the log signs a statement, "I have *n* records, and their root is *R*", with a key it doesn't hold itself (OpenBao's transit engine, step 9). That's a promise about history, in a standard format (C2SP's *tlog-checkpoint*), used by Go's checksum database and by Sigstore.
- **A witness.** The log's own signature isn't enough either: whoever runs the log can ask OpenBao to sign a rewritten history too. A **witness** is a second party, run by someone else, that keeps the last checkpoint it co-signed and co-signs a new one only with a consistency proof from the old. A rewritten history has no such proof, so it can never get the witness's signature. This is how Certificate Transparency keeps certificate authorities honest.
- **Two implementations.** The tree is built in Rust (by `klog`, which owns the file) and checked in Go (with `golang.org/x/mod/sumdb/tlog`, the code behind Go's checksum database). A bug in one shows up as a disagreement with the other.

### The tree, in Rust

Create `audit/src/merkle.rs`:

<!-- file: audit/src/merkle.rs -->
~~~
//! A Merkle tree over the log's records (Phase 6, step 10), as RFC 9162
//! (Certificate Transparency, version 2) defines it.
//!
//! A checksum catches the disk's mistakes, not a person's: anyone who can
//! write the file can change a record and its checksum together. A Merkle
//! tree reduces the whole log to one 32-byte root. Change, add, remove or
//! reorder any record and the root changes. Publish the root somewhere the
//! log's writer can't reach, and a change to history can be detected.
//!
//! The tree also gives short proofs, about log2(size) hashes each:
//!
//! - inclusion: record i is in the log whose root is R;
//! - consistency: the log with root R2 is the log with root R1, with
//!   records added at the end and nothing changed.
//!
//! Leaves and inner nodes are hashed with different first bytes (0 and 1),
//! so an inner node can never be passed off as a record.

use sha2::{Digest, Sha256};

pub type Hash = [u8; 32];

/// The hash of one record.
pub fn leaf_hash(record: &[u8]) -> Hash {
    let mut h = Sha256::new();
    h.update([0u8]);
    h.update(record);
    h.finalize().into()
}

/// The hash of an inner node, from its two children.
pub fn node_hash(left: &Hash, right: &Hash) -> Hash {
    let mut h = Sha256::new();
    h.update([1u8]);
    h.update(left);
    h.update(right);
    h.finalize().into()
}

/// The largest power of two smaller than n (n > 1): where the tree splits.
fn split(n: usize) -> usize {
    let mut k = 1;
    while k * 2 < n {
        k *= 2;
    }
    k
}

/// The root of the tree over these leaf hashes (RFC 9162, 2.1.1). The left
/// subtree is always full: its size is the largest power of two below n.
pub fn root(leaves: &[Hash]) -> Hash {
    match leaves.len() {
        0 => Sha256::digest([]).into(),
        1 => leaves[0],
        n => {
            let k = split(n);
            node_hash(&root(&leaves[..k]), &root(&leaves[k..]))
        }
    }
}

/// The hashes that prove leaf `index` is in the tree over `leaves`, from
/// the bottom up (RFC 9162, 2.1.3.1).
pub fn inclusion_proof(index: usize, leaves: &[Hash]) -> Vec<Hash> {
    let n = leaves.len();
    if n <= 1 {
        return Vec::new();
    }
    let k = split(n);
    let (mut proof, sibling) = if index < k {
        (inclusion_proof(index, &leaves[..k]), root(&leaves[k..]))
    } else {
        (inclusion_proof(index - k, &leaves[k..]), root(&leaves[..k]))
    };
    proof.push(sibling);
    proof
}

/// The hashes that prove the tree over the first `old` leaves is a prefix
/// of the tree over all of `leaves` (RFC 9162, 2.1.4.1).
pub fn consistency_proof(old: usize, leaves: &[Hash]) -> Vec<Hash> {
    fn sub(m: usize, leaves: &[Hash], whole: bool) -> Vec<Hash> {
        let n = leaves.len();
        if m == n {
            // The old tree is this whole subtree. The verifier knows its
            // root already, unless it is only part of the old tree.
            return if whole {
                Vec::new()
            } else {
                vec![root(leaves)]
            };
        }
        let k = split(n);
        let (mut proof, other) = if m <= k {
            (sub(m, &leaves[..k], whole), root(&leaves[k..]))
        } else {
            (sub(m - k, &leaves[k..], false), root(&leaves[..k]))
        };
        proof.push(other);
        proof
    }
    if old == 0 || old >= leaves.len() {
        return Vec::new();
    }
    sub(old, leaves, true)
}

/// Checks an inclusion proof (RFC 9162, 2.1.3.2): that `leaf` is leaf
/// `index` of a tree of `size` leaves with this root.
pub fn verify_inclusion(
    index: usize,
    size: usize,
    leaf: &Hash,
    proof: &[Hash],
    root: &Hash,
) -> bool {
    if index >= size {
        return false;
    }
    let (mut fn_, mut sn) = (index, size - 1);
    let mut r = *leaf;
    for p in proof {
        if sn == 0 {
            return false;
        }
        if fn_ & 1 == 1 || fn_ == sn {
            r = node_hash(p, &r);
            while fn_ & 1 == 0 && fn_ != 0 {
                fn_ >>= 1;
                sn >>= 1;
            }
        } else {
            r = node_hash(&r, p);
        }
        fn_ >>= 1;
        sn >>= 1;
    }
    sn == 0 && r == *root
}

/// Checks a consistency proof (RFC 9162, 2.1.4.2): that the tree of `new`
/// leaves with `new_root` extends the tree of `old` leaves with `old_root`.
pub fn verify_consistency(
    old: usize,
    new: usize,
    old_root: &Hash,
    new_root: &Hash,
    proof: &[Hash],
) -> bool {
    if old > new {
        return false;
    }
    if old == new {
        return proof.is_empty() && old_root == new_root;
    }
    if old == 0 {
        return proof.is_empty(); // the empty tree is a prefix of every tree
    }
    let mut path: Vec<Hash> = Vec::with_capacity(proof.len() + 1);
    if old.is_power_of_two() {
        path.push(*old_root); // the old tree is one whole subtree
    }
    path.extend_from_slice(proof);
    let (mut fn_, mut sn) = (old - 1, new - 1);
    while fn_ & 1 == 1 {
        fn_ >>= 1;
        sn >>= 1;
    }
    let Some((first, rest)) = path.split_first() else {
        return false;
    };
    let (mut fr, mut sr) = (*first, *first);
    for c in rest {
        if sn == 0 {
            return false;
        }
        if fn_ & 1 == 1 || fn_ == sn {
            fr = node_hash(c, &fr);
            sr = node_hash(c, &sr);
            while fn_ & 1 == 0 && fn_ != 0 {
                fn_ >>= 1;
                sn >>= 1;
            }
        } else {
            sr = node_hash(&sr, c);
        }
        fn_ >>= 1;
        sn >>= 1;
    }
    fr == *old_root && sr == *new_root && sn == 0
}

/// The roots of the full subtrees a log of any size is made of: one per
/// set bit of its size, largest first. A log of 13 records (8 + 4 + 1)
/// keeps three hashes. That is all it needs to add a record and know its
/// new root, without keeping, or reading, the records before.
#[derive(Default)]
pub struct CompactRange {
    size: usize,
    subtrees: Vec<Hash>,
}

impl CompactRange {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn size(&self) -> usize {
        self.size
    }

    /// Adds a leaf. Two full subtrees of the same size merge into one
    /// twice as big, as a binary counter carries.
    pub fn push(&mut self, leaf: Hash) {
        let mut h = leaf;
        let mut carry = self.size;
        while carry & 1 == 1 {
            let left = self.subtrees.pop().expect("one subtree per set bit");
            h = node_hash(&left, &h);
            carry >>= 1;
        }
        self.subtrees.push(h);
        self.size += 1;
    }

    /// The root of the whole log: the subtrees joined from the right.
    pub fn root(&self) -> Hash {
        let mut iter = self.subtrees.iter().rev();
        let Some(last) = iter.next() else {
            return Sha256::digest([]).into();
        };
        iter.fold(*last, |acc, left| node_hash(left, &acc))
    }
}

/// Hex, for printing hashes.
pub fn hex(h: &Hash) -> String {
    h.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn leaves(n: usize) -> Vec<Hash> {
        (0..n)
            .map(|i| leaf_hash(format!("event {i}").as_bytes()))
            .collect()
    }

    #[test]
    fn known_roots() {
        // The empty tree, and one record, as RFC 9162 defines them.
        assert_eq!(
            hex(&root(&[])),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(root(&leaves(1)), leaf_hash(b"event 0"));
        // Three: the left subtree holds two, the largest power of two below 3.
        let l = leaves(3);
        assert_eq!(root(&l), node_hash(&node_hash(&l[0], &l[1]), &l[2]));
    }

    #[test]
    fn the_compact_range_knows_every_root() {
        let l = leaves(40);
        let mut range = CompactRange::new();
        for n in 0..=l.len() {
            assert_eq!(range.root(), root(&l[..n]), "size {n}");
            assert_eq!(range.subtrees.len(), n.count_ones() as usize);
            if n < l.len() {
                range.push(l[n]);
            }
        }
    }

    #[test]
    fn every_inclusion_proof_checks() {
        for n in 1..=33 {
            let l = leaves(n);
            let r = root(&l);
            for i in 0..n {
                let proof = inclusion_proof(i, &l);
                assert!(verify_inclusion(i, n, &l[i], &proof, &r), "leaf {i} of {n}");
                assert!(proof.len() <= usize::BITS as usize - (n - 1).leading_zeros() as usize);
                // Another record, or the same one at another place, fails.
                assert!(!verify_inclusion(i, n, &leaf_hash(b"forged"), &proof, &r));
                if n > 1 {
                    assert!(!verify_inclusion((i + 1) % n, n, &l[i], &proof, &r));
                }
            }
        }
    }

    #[test]
    fn every_consistency_proof_checks() {
        for n in 1..=33 {
            let l = leaves(n);
            let new_root = root(&l);
            for m in 0..=n {
                let old_root = root(&l[..m]);
                let proof = consistency_proof(m, &l);
                assert!(
                    verify_consistency(m, n, &old_root, &new_root, &proof),
                    "{m} -> {n}"
                );
            }
        }
    }

    #[test]
    fn a_rewritten_history_is_inconsistent() {
        let l = leaves(20);
        let old_root = root(&l[..13]);
        let mut rewritten = l.clone();
        rewritten[6] = leaf_hash(b"event 6, edited");
        let proof = consistency_proof(13, &rewritten);
        assert!(!verify_consistency(
            13,
            20,
            &old_root,
            &root(&rewritten),
            &proof
        ));
        // A log cut back to fewer records can't be consistent either.
        assert!(!verify_consistency(13, 10, &old_root, &root(&l[..10]), &[]));
    }
}
~~~

Three things to notice. Leaves and inner nodes are hashed with different first bytes (0 and 1), so an inner node's hash can never be passed off as a record's. The tree's shape is fixed by RFC 9162: the left subtree is always the largest power of two smaller than *n*, so every implementation computes the same root. And `CompactRange` keeps only the tree's right edge, about log₂(n) hashes, which is all an appending writer needs for the next root.

In `audit/Cargo.toml`, add SHA-256 (or run `cargo add sha2@0.11.1` in `audit/`):

<!-- edit: audit/Cargo.toml -->
~~~toml
[dependencies]
~~~

to:

~~~toml
[dependencies]
sha2 = "0.11.1"
~~~

In `audit/src/lib.rs`:

Change:

<!-- edit: audit/src/lib.rs -->
~~~
pub mod log;
pub mod record;
~~~

to:

~~~
pub mod log;
pub mod merkle;
pub mod record;
~~~


The log keeps the tree's edge as it appends, so it knows its root at every moment. In `audit/src/log.rs`:

Change:

<!-- edit: audit/src/log.rs -->
~~~

use crate::record::{self, HEADER_LEN, RecordError};
~~~

to:

~~~

use crate::merkle::{self, CompactRange};
use crate::record::{self, HEADER_LEN, RecordError};
~~~

Change:

<!-- edit: audit/src/log.rs -->
~~~
    end: u64,
}
~~~

to:

~~~
    end: u64,
    tree: CompactRange, // the Merkle tree's edge, for its root (step 10)
}
~~~

Change:

<!-- edit: audit/src/log.rs -->
~~~
        };
        Ok((
~~~

to:

~~~
        };
        let mut tree = CompactRange::new();
        for payload in &scan.payloads {
            tree.push(merkle::leaf_hash(payload));
        }
        Ok((
~~~

Change:

<!-- edit: audit/src/log.rs -->
~~~
                end: scan.valid_len as u64,
            },
~~~

to:

~~~
                end: scan.valid_len as u64,
                tree,
            },
~~~

Change:

<!-- edit: audit/src/log.rs -->
~~~
        self.end += record.len() as u64;
        Ok(offset)
    }
~~~

to:

~~~
        self.end += record.len() as u64;
        self.tree.push(merkle::leaf_hash(payload));
        Ok(offset)
    }

    /// How many records the log holds.
    pub fn size(&self) -> usize {
        self.tree.size()
    }

    /// The root of the Merkle tree over every record: the whole log's
    /// history in 32 bytes (step 10).
    pub fn root(&self) -> merkle::Hash {
        self.tree.root()
    }
~~~


And `klog` gains three commands, `root`, `prove` and `consistency`, and its ingest answer now says the log's size and root after each record. In `audit/src/main.rs`:

Change:

<!-- edit: audit/src/main.rs -->
~~~
//!   klog ingest FILE

~~~

to:

~~~
//!   klog ingest FILE
//!   klog root FILE [SIZE]              the Merkle root of the first SIZE records (step 10)
//!   klog prove FILE INDEX SIZE         record INDEX is in the first SIZE records
//!   klog consistency FILE OLD NEW      the first OLD records are a prefix of the first NEW

~~~

Change:

<!-- edit: audit/src/main.rs -->
~~~
use klog::log::{Log, Recovery, read_all};

~~~

to:

~~~
use klog::log::{Log, Recovery, read_all};
use klog::merkle::{self, Hash, hex};

~~~

Change:

<!-- edit: audit/src/main.rs -->
~~~
        [command, path] if command == "ingest" => ingest(path)?,
        _ => {
~~~

to:

~~~
        [command, path] if command == "ingest" => ingest(path)?,
        [command, path, rest @ ..] if command == "root" && rest.len() <= 1 => {
            let leaves = leaves(path)?;
            let size = match rest.first() {
                Some(s) => within(s, leaves.len())?,
                None => leaves.len(),
            };
            println!("{size} {}", hex(&merkle::root(&leaves[..size])));
        }
        [command, path, index, size] if command == "prove" => {
            let leaves = leaves(path)?;
            let size = within(size, leaves.len())?;
            let index: usize = index.parse()?;
            if index >= size {
                return Err(format!("record {index} is not among the first {size}").into());
            }
            print_hashes(&merkle::inclusion_proof(index, &leaves[..size]));
        }
        [command, path, old, new] if command == "consistency" => {
            let leaves = leaves(path)?;
            let new = within(new, leaves.len())?;
            let old = within(old, new)?;
            print_hashes(&merkle::consistency_proof(old, &leaves[..new]));
        }
        _ => {
~~~

Change:

<!-- edit: audit/src/main.rs -->
~~~
                "usage: klog append FILE TEXT... | klog cat FILE | klog check FILE | klog ingest FILE"
~~~

to:

~~~
                "usage: klog append FILE TEXT... | cat FILE | check FILE | ingest FILE | root FILE [SIZE] | prove FILE INDEX SIZE | consistency FILE OLD NEW"
~~~

Change:

<!-- edit: audit/src/main.rs -->
~~~

/// Appends each line of standard input as one record. Once a record is on
/// disk, it prints "ok OFFSET", so the sender knows that line is safe and
/// can move on. The sender waits for each answer before sending the next
~~~

to:

~~~

/// The leaf hashes of every record in the log.
fn leaves(path: &str) -> Result<Vec<Hash>, Box<dyn Error>> {
    Ok(read_all(path)?
        .iter()
        .map(|p| merkle::leaf_hash(p))
        .collect())
}

/// Parses a size, which may not be over limit.
fn within(text: &str, limit: usize) -> Result<usize, Box<dyn Error>> {
    let n: usize = text.parse()?;
    if n > limit {
        return Err(format!("{n} is more than the {limit} records there are").into());
    }
    Ok(n)
}

fn print_hashes(hashes: &[Hash]) {
    for h in hashes {
        println!("{}", hex(h));
    }
}

/// Appends each line of standard input as one record. Once a record is on
/// disk, it prints "ok OFFSET SIZE ROOT": where the record starts, how many
/// records the log now holds, and their Merkle root (step 10). The sender
/// then knows the line is safe, and what the log now says. The sender waits for each answer before sending the next
~~~

Change:

<!-- edit: audit/src/main.rs -->
~~~
        writeln!(out, "ok {offset}")?;
~~~

to:

~~~
        writeln!(out, "ok {offset} {} {}", log.size(), hex(&log.root()))?;
~~~


<!-- run: cd audit && cargo fmt --check && cargo test -q && cargo build --release -q -->

### The tree, in Go

Get the module the Go side uses. Pin the version, so your tree is checked by the same code as mine:

~~~bash
go get golang.org/x/mod@v0.42.0
~~~

<!-- run: go get golang.org/x/mod@v0.42.0 -->

Create `internal/audit/tree.go`:

<!-- file: internal/audit/tree.go -->
~~~go
package audit

import (
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"os"

	"golang.org/x/mod/sumdb/tlog"
)

// Tree is the Merkle tree over a log's records (Phase 6, step 10), built
// with golang.org/x/mod/sumdb/tlog: the code behind Go's checksum
// database, a public tamper-evident log. klog builds the same tree in
// Rust; this is the second, independent implementation the verifier uses,
// so a bug in one shows up as a disagreement with the other.
//
// tlog keeps every inner hash, not only the edge klog keeps, so any root
// or proof is a few lookups.
type Tree struct {
	hashes []tlog.Hash
	size   int64
}

// Add appends a record.
func (t *Tree) Add(record []byte) error {
	hs, err := tlog.StoredHashes(t.size, record, t)
	if err != nil {
		return err
	}
	t.hashes = append(t.hashes, hs...)
	t.size++
	return nil
}

// Size is how many records the tree holds.
func (t *Tree) Size() int64 { return t.size }

// ReadHashes makes Tree a tlog.HashReader over its own stored hashes.
func (t *Tree) ReadHashes(indexes []int64) ([]tlog.Hash, error) {
	out := make([]tlog.Hash, len(indexes))
	for i, x := range indexes {
		if x < 0 || x >= int64(len(t.hashes)) {
			return nil, fmt.Errorf("no stored hash %d", x)
		}
		out[i] = t.hashes[x]
	}
	return out, nil
}

// Root is the root of the tree over the first n records.
func (t *Tree) Root(n int64) (tlog.Hash, error) { return tlog.TreeHash(n, t) }

// ProveRecord proves record i is among the first n.
func (t *Tree) ProveRecord(i, n int64) (tlog.RecordProof, error) { return tlog.ProveRecord(n, i, t) }

// ProveTree proves the first old records are a prefix of the first n.
func (t *Tree) ProveTree(old, n int64) (tlog.TreeProof, error) { return tlog.ProveTree(n, old, t) }

// ReadLog reads every record of a klog file, checking each one's CRC, as
// klog does. A torn last record (a crash mid-write) is left out.
func ReadLog(path string) ([][]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	castagnoli := crc32.MakeTable(crc32.Castagnoli)
	var records [][]byte
	for off := 0; off < len(data); {
		if len(data)-off < 8 {
			break // torn header
		}
		length := int(binary.LittleEndian.Uint32(data[off:]))
		sum := binary.LittleEndian.Uint32(data[off+4:])
		end := off + 8 + length
		if end > len(data) {
			break // torn payload
		}
		payload := data[off+8 : end]
		if crc32.Checksum(payload, castagnoli) != sum {
			if end == len(data) {
				break // a torn last record of full length
			}
			return nil, fmt.Errorf("%s: corrupt record at byte %d", path, off)
		}
		records = append(records, payload)
		off = end
	}
	return records, nil
}

// TreeOf builds the tree over records.
func TreeOf(records [][]byte) (*Tree, error) {
	t := &Tree{}
	for _, r := range records {
		if err := t.Add(r); err != nil {
			return nil, err
		}
	}
	return t, nil
}
~~~

`ReadLog` parses klog's file format itself, in Go, so the verifier doesn't trust klog to read its own file.

Create `internal/audit/tree_test.go`:

<!-- file: internal/audit/tree_test.go -->
~~~go
package audit

import (
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"golang.org/x/mod/sumdb/tlog"
)

// klog builds its Merkle tree in Rust; Tree builds it with Go's tlog. They
// must agree on every root and every proof, and tlog must accept klog's
// proofs. Needs the real klog: KLOG_BIN (cargo build --release in audit/).
func TestKlogAgreesWithGosTlog(t *testing.T) {
	bin := os.Getenv("KLOG_BIN")
	if bin == "" {
		t.Skip("set KLOG_BIN to a built klog to compare it with tlog")
	}
	path := filepath.Join(t.TempDir(), "audit.log")
	klog := func(args ...string) []string {
		t.Helper()
		out, err := exec.Command(bin, append([]string{args[0], path}, args[1:]...)...).Output()
		if err != nil {
			t.Fatalf("klog %v: %v", args, err)
		}
		return strings.Fields(string(out))
	}
	hashes := func(hexes []string) []tlog.Hash {
		t.Helper()
		out := make([]tlog.Hash, len(hexes))
		for i, h := range hexes {
			b, err := hex.DecodeString(h)
			if err != nil || len(b) != tlog.HashSize {
				t.Fatalf("hash %q: %v", h, err)
			}
			copy(out[i][:], b)
		}
		return out
	}
	const n = 37
	tree := &Tree{}
	for i := range n {
		record := fmt.Sprintf("event %d", i)
		klog("append", record)
		tree.Add([]byte(record))
	}

	roots := make([]tlog.Hash, n+1)
	for size := int64(1); size <= n; size++ {
		got := klog("root", strconv.FormatInt(size, 10))
		want, _ := tree.Root(size)
		if hashes(got[1:])[0] != want {
			t.Fatalf("root of %d: klog %s, tlog %x", size, got[1], want)
		}
		roots[size] = want
	}
	for _, size := range []int64{1, 2, 3, 8, 13, 16, 37} {
		for i := range size {
			proof := hashes(klog("prove", strconv.FormatInt(i, 10), strconv.FormatInt(size, 10)))
			if err := tlog.CheckRecord(proof, size, roots[size], i, tlog.RecordHash(fmt.Appendf(nil, "event %d", i))); err != nil {
				t.Fatalf("record %d of %d: tlog rejects klog's proof: %v", i, size, err)
			}
			want, _ := tree.ProveRecord(i, size)
			if fmt.Sprint(proof) != fmt.Sprint(want) {
				t.Fatalf("record %d of %d: klog's proof differs from tlog's", i, size)
			}
		}
		for old := int64(1); old <= size; old++ {
			proof := hashes(klog("consistency", strconv.FormatInt(old, 10), strconv.FormatInt(size, 10)))
			if err := tlog.CheckTree(proof, size, roots[size], old, roots[old]); err != nil {
				t.Fatalf("%d -> %d: tlog rejects klog's proof: %v", old, size, err)
			}
		}
	}

	// Go reads klog's file format too.
	records, err := ReadLog(path)
	if err != nil || len(records) != n {
		t.Fatalf("ReadLog: %d records, %v", len(records), err)
	}
}
~~~

`TestKlogAgreesWithGosTlog` builds logs of many sizes with the real `klog` binary and checks that its roots and proofs are byte-for-byte the ones Go computes. It needs `KLOG_BIN` set to the release build (`audit/target/release/klog`), and skips without it.

### Checkpoints and their signer

OpenBao's transit engine can sign as well as encrypt. In `internal/secrets/transit.go`:

Change:

<!-- edit: internal/secrets/transit.go -->
~~~go
	"context"
	"encoding/base64"
~~~

to:

~~~go
	"context"
	"crypto/ed25519"
	"encoding/base64"
~~~

Change:

<!-- edit: internal/secrets/transit.go -->
~~~go
	"fmt"
	"strings"
~~~

to:

~~~go
	"fmt"
	"strconv"
	"strings"
~~~

Add this at the end of the file:

<!-- append: internal/secrets/transit.go -->
~~~go
// Sign signs message with the transit key, which must be one that signs,
// such as an Ed25519 key, and returns the raw signature. The private key
// never leaves OpenBao: whoever can call this can sign, but can't take the
// key away and sign later, elsewhere, unseen (step 10).
func (t *Transit) Sign(ctx context.Context, message []byte) ([]byte, error) {
	s, err := t.client.Write(ctx, "transit/sign/"+t.key, map[string]string{
		"input": base64.StdEncoding.EncodeToString(message),
	})
	if err != nil {
		return nil, fmt.Errorf("sign: %w", err)
	}
	sig, _ := s.Data["signature"].(string)
	rest, ok := strings.CutPrefix(sig, Prefix)
	_, b64, found := strings.Cut(rest, ":") // past the key version
	if !ok || !found {
		return nil, errors.New("sign: no signature in the reply")
	}
	return base64.StdEncoding.DecodeString(b64)
}

// PublicKey returns the public half of the latest version of an Ed25519
// transit key: what anyone needs to check its signatures.
func (t *Transit) PublicKey(ctx context.Context) (ed25519.PublicKey, error) {
	s, err := t.client.Read(ctx, "transit/keys/"+t.key)
	if err != nil {
		return nil, fmt.Errorf("public key: %w", err)
	}
	latest, _ := s.Data["latest_version"].(float64)
	keys, _ := s.Data["keys"].(map[string]any)
	version, _ := keys[strconv.Itoa(int(latest))].(map[string]any)
	b64, _ := version["public_key"].(string)
	key, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(key) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("public key: key %q has no Ed25519 public key", t.key)
	}
	return key, nil
}
~~~


Create `internal/audit/checkpoint.go`:

<!-- file: internal/audit/checkpoint.go -->
~~~go
package audit

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"golang.org/x/mod/sumdb/note"
	"golang.org/x/mod/sumdb/tlog"

	"runway/internal/secrets"
)

// DefaultOrigin names Runway's audit log in its checkpoints.
const DefaultOrigin = "runway.example/audit"

// Checkpoint is what a log says about itself at one moment (Phase 6, step
// 10): its name, how many records it holds, and their Merkle root. Signed,
// it is a promise: "these were my first Size records". A later checkpoint
// must keep that promise, which a consistency proof shows.
//
// The text is the C2SP tlog-checkpoint format, used by Go's checksum
// database and by Sigstore, and signed as a C2SP signed note:
//
//	runway.example/audit
//	1042
//	2Z6h...base64 of the root...=
//
//	— runway.example/audit Az3f...signature...
type Checkpoint struct {
	Origin string
	Size   int64
	Root   tlog.Hash
}

// Text is the checkpoint's body, the part that is signed.
func (c Checkpoint) Text() string {
	return fmt.Sprintf("%s\n%d\n%s\n", c.Origin, c.Size, base64.StdEncoding.EncodeToString(c.Root[:]))
}

// ParseCheckpoint reads a checkpoint's body.
func ParseCheckpoint(text string) (Checkpoint, error) {
	lines := strings.SplitN(text, "\n", 4)
	if len(lines) < 4 || lines[0] == "" {
		return Checkpoint{}, errors.New("checkpoint: want origin, size and root, one per line")
	}
	size, err := strconv.ParseInt(lines[1], 10, 64)
	if err != nil || size < 0 {
		return Checkpoint{}, fmt.Errorf("checkpoint: bad size %q", lines[1])
	}
	root, err := base64.StdEncoding.DecodeString(lines[2])
	if err != nil || len(root) != tlog.HashSize {
		return Checkpoint{}, fmt.Errorf("checkpoint: bad root %q", lines[2])
	}
	c := Checkpoint{Origin: lines[0], Size: size}
	copy(c.Root[:], root)
	return c, nil
}

// OpenCheckpoint checks a signed checkpoint and returns it. Every one of
// required must have signed it: the log's own key, and a witness's when
// the caller wants proof that someone else saw it too.
func OpenCheckpoint(signed []byte, required ...note.Verifier) (Checkpoint, error) {
	n, err := note.Open(signed, note.VerifierList(required...))
	if err != nil {
		return Checkpoint{}, err
	}
	for _, v := range required {
		if !signedBy(n, v) {
			return Checkpoint{}, fmt.Errorf("checkpoint not signed by %s", v.Name())
		}
	}
	return ParseCheckpoint(n.Text)
}

func signedBy(n *note.Note, v note.Verifier) bool {
	for _, s := range n.Sigs {
		if s.Name == v.Name() && s.Hash == v.KeyHash() {
			return true
		}
	}
	return false
}

// TransitSigner signs notes with an Ed25519 key in OpenBao's transit
// engine, so the log's signing key never reaches the machine the log is
// on. Someone who takes that machine can sign while they hold it, but
// can't copy the key and sign forever after; and every signature they ask
// for is in OpenBao's audit log.
type TransitSigner struct {
	transit *secrets.Transit
	name    string
	hash    uint32
}

// NewTransitSigner signs as name with the transit key behind t. It also
// returns the verifier key that checks its signatures, the line to give
// witnesses and auditors.
func NewTransitSigner(ctx context.Context, t *secrets.Transit, name string) (*TransitSigner, string, error) {
	pub, err := t.PublicKey(ctx)
	if err != nil {
		return nil, "", err
	}
	vkey, err := note.NewEd25519VerifierKey(name, pub)
	if err != nil {
		return nil, "", err
	}
	v, err := note.NewVerifier(vkey)
	if err != nil {
		return nil, "", err
	}
	return &TransitSigner{transit: t, name: name, hash: v.KeyHash()}, vkey, nil
}

func (s *TransitSigner) Name() string    { return s.name }
func (s *TransitSigner) KeyHash() uint32 { return s.hash }

// Sign is note.Signer's: it has no context, so it sets its own deadline.
func (s *TransitSigner) Sign(msg []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return s.transit.Sign(ctx, msg)
}
~~~

Create `internal/audit/checkpoint_test.go`:

<!-- file: internal/audit/checkpoint_test.go -->
~~~go
package audit

import (
	"context"
	"crypto/rand"
	"strings"
	"testing"

	"golang.org/x/mod/sumdb/note"
	"golang.org/x/mod/sumdb/tlog"

	"runway/internal/secrets"
	"runway/internal/secrets/baotest"
)

func TestCheckpointText(t *testing.T) {
	c := Checkpoint{Origin: "runway.example/audit", Size: 1042, Root: tlog.RecordHash([]byte("x"))}
	back, err := ParseCheckpoint(c.Text())
	if err != nil || back != c {
		t.Fatalf("round trip: %+v, %v", back, err)
	}
	if lines := strings.Split(c.Text(), "\n"); len(lines) != 4 || lines[1] != "1042" {
		t.Fatalf("text %q", c.Text())
	}
}

// A checkpoint signed through OpenBao opens with the verifier key made from
// the transit key's public half; edited, it doesn't.
func TestTransitSignedCheckpoints(t *testing.T) {
	ctx := context.Background()
	bao := baotest.Client(t)
	key := baotest.Name()
	if _, err := bao.Write(ctx, "transit/keys/"+key, map[string]any{"type": "ed25519"}); err != nil {
		t.Fatal(err)
	}
	signer, vkey, err := NewTransitSigner(ctx, secrets.NewTransit(bao, key), "runway.example/audit")
	if err != nil {
		t.Fatal(err)
	}
	verifier, err := note.NewVerifier(vkey)
	if err != nil {
		t.Fatal(err)
	}
	c := Checkpoint{Origin: "runway.example/audit", Size: 7, Root: tlog.RecordHash([]byte("x"))}
	signed, err := note.Sign(&note.Note{Text: c.Text()}, signer)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := OpenCheckpoint(signed, verifier); err != nil || got != c {
		t.Fatalf("open: %+v, %v", got, err)
	}
	forged := strings.Replace(string(signed), "\n7\n", "\n8\n", 1)
	if _, err := OpenCheckpoint([]byte(forged), verifier); err == nil {
		t.Fatal("an edited checkpoint opened")
	}
	// A witness's signature is required too: without it, refused.
	_, wvkey, _ := note.GenerateKey(rand.Reader, "witness.example")
	witness, _ := note.NewVerifier(wvkey)
	if _, err := OpenCheckpoint(signed, verifier, witness); err == nil {
		t.Fatal("opened without the witness's signature")
	}
}
~~~

`Append` now returns the log's head after each record: its size and root, from klog's answer. In `internal/audit/audit.go`:

Change:

<!-- edit: internal/audit/audit.go -->
~~~go
	"time"

~~~

to:

~~~go
	"time"

	"golang.org/x/mod/sumdb/tlog"

~~~

Change:

<!-- edit: internal/audit/audit.go -->
~~~go
// Append sends one line and waits until klog confirms it is on disk.
func (l *Log) Append(line string) error {
~~~

to:

~~~go
// Head is the log after an append (step 10): how many records it holds,
// and their Merkle root.
type Head struct {
	Size int64
	Root tlog.Hash
}

// Append sends one line and waits until klog confirms it is on disk. klog
// answers "ok OFFSET SIZE ROOT"; Append returns the size and root.
func (l *Log) Append(line string) (Head, error) {
~~~

Change:

<!-- edit: internal/audit/audit.go -->
~~~go
		return errors.New("an audit line must not contain a line break")
~~~

to:

~~~go
		return Head{}, errors.New("an audit line must not contain a line break")
~~~

Change:

<!-- edit: internal/audit/audit.go -->
~~~go
		return fmt.Errorf("write to klog: %w", err)
~~~

to:

~~~go
		return Head{}, fmt.Errorf("write to klog: %w", err)
~~~

Change:

<!-- edit: internal/audit/audit.go -->
~~~go
		return fmt.Errorf("klog stopped before confirming a line: %w", err)
~~~

to:

~~~go
		return Head{}, fmt.Errorf("klog stopped before confirming a line: %w", err)
~~~

Change:

<!-- edit: internal/audit/audit.go -->
~~~go
	if answer := l.acks.Text(); !strings.HasPrefix(answer, "ok ") {
		return fmt.Errorf("klog answered %q", answer)
	}
	return nil
}
~~~

to:

~~~go
	answer := l.acks.Text()
	var offset int64
	var head Head
	var root []byte
	if _, err := fmt.Sscanf(answer, "ok %d %d %x", &offset, &head.Size, &root); err != nil || len(root) != tlog.HashSize {
		return Head{}, fmt.Errorf("klog answered %q", answer)
	}
	copy(head.Root[:], root)
	return head, nil
}
~~~

Change:

<!-- edit: internal/audit/audit.go -->
~~~go
// recognised as a duplicate when the log is read.
~~~

to:

~~~go
// recognised as a duplicate when the log is read; and, from step 10, the
// tenant, whose job it was (forgotten in step 4).
~~~

Change:

<!-- edit: internal/audit/audit.go -->
~~~go
	line := fmt.Sprintf("%s job=%d state=%s", msg.OccurredAt.UTC().Format(time.RFC3339Nano), event.JobID, event.State)
~~~

to:

~~~go
	line := fmt.Sprintf("%s tenant=%s job=%d state=%s", msg.OccurredAt.UTC().Format(time.RFC3339Nano), msg.Tenant, event.JobID, event.State)
~~~


In `internal/audit/audit_test.go`:

Change:

<!-- edit: internal/audit/audit_test.go -->
~~~go
	lines := bufio.NewScanner(os.Stdin)
	for n := 0; lines.Scan(); n++ {
~~~

to:

~~~go
	lines := bufio.NewScanner(os.Stdin)
	tree := &Tree{} // the root, as klog would report it
	for n := 0; lines.Scan(); n++ {
~~~

Change:

<!-- edit: internal/audit/audit_test.go -->
~~~go
		fmt.Printf("ok %d\n", n)
~~~

to:

~~~go
		tree.Add(lines.Bytes())
		root, _ := tree.Root(tree.Size())
		fmt.Printf("ok %d %d %x\n", n, tree.Size(), root[:])
~~~

Change:

<!-- edit: internal/audit/audit_test.go -->
~~~go
	log, path := start(t)
	for _, line := range []string{"first", "second"} {
		if err := log.Append(line); err != nil {
~~~

to:

~~~go
	log, path := start(t)
	var head Head
	for _, line := range []string{"first", "second"} {
		var err error
		if head, err = log.Append(line); err != nil {
~~~

Change:

<!-- edit: internal/audit/audit_test.go -->
~~~go
		}
	}
~~~

to:

~~~go
		}
	}
	if want, _ := TreeOf([][]byte{[]byte("first"), []byte("second")}); head.Size != 2 || head.Root != must(want.Root(2)) {
		t.Fatalf("head after two lines: %+v", head)
	}
~~~

Change:

<!-- edit: internal/audit/audit_test.go -->
~~~go
	if err := log.Append("first"); err != nil {
~~~

to:

~~~go
	if _, err := log.Append("first"); err != nil {
~~~

Change:

<!-- edit: internal/audit/audit_test.go -->
~~~go
	err := log.Append("second")
~~~

to:

~~~go
	_, err := log.Append("second")
~~~

Change:

<!-- edit: internal/audit/audit_test.go -->
~~~go
	if err := log.Append("one\ntwo"); err == nil {
~~~

to:

~~~go
	if _, err := log.Append("one\ntwo"); err == nil {
~~~

Change:

<!-- edit: internal/audit/audit_test.go -->
~~~go
	msg, _ := messages.New(messages.TypeJobChanged, messages.JobChanged{JobID: 7, State: "failed", Reason: "disk full"}, at)
	line, err := Line(msg)
	want := `2026-10-05T12:00:00Z job=7 state=failed reason="disk full" id=` + msg.ID
~~~

to:

~~~go
	msg, _ := messages.New(messages.TypeJobChanged, messages.JobChanged{JobID: 7, State: "failed", Reason: "disk full"}, at)
	msg.Tenant = "acme"
	line, err := Line(msg)
	want := `2026-10-05T12:00:00Z tenant=acme job=7 state=failed reason="disk full" id=` + msg.ID
~~~

Add this at the end of the file:

<!-- append: internal/audit/audit_test.go -->
~~~go
func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}
~~~


The checkpointer runs beside the writer: every few seconds it signs the latest head, asks klog for a consistency proof from the last witnessed checkpoint, and sends both to the witness. Create `internal/audit/checkpointer.go`:

<!-- file: internal/audit/checkpointer.go -->
~~~go
package audit

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/mod/sumdb/note"
	"golang.org/x/mod/sumdb/tlog"
)

// Checkpointer signs the log's head every so often, and has a witness
// co-sign it (step 10). Between checkpoints, records are only as safe as
// the machine they are on: the interval is the window in which recent
// history could be rewritten unseen.
type Checkpointer struct {
	Origin  string
	Signer  note.Signer
	Witness string // its URL
	Path    string // where the latest witnessed checkpoint is kept
	// Prove proves the first old records are a prefix of the first n.
	Prove  func(ctx context.Context, old, n int64) (tlog.TreeProof, error)
	HTTP   *http.Client
	Logger *slog.Logger

	mu        sync.Mutex
	head      Head
	witnessed int64 // the size of the witness's latest checkpoint, as far as we know
}

// Observe records the log's head after an append.
func (c *Checkpointer) Observe(h Head) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if h.Size > c.head.Size {
		c.head = h
	}
}

// Run checkpoints every interval until ctx ends.
func (c *Checkpointer) Run(ctx context.Context, every time.Duration) {
	if data, err := os.ReadFile(c.Path); err == nil {
		if body, _, ok := bytes.Cut(data, []byte("\n\n")); ok {
			if cp, err := ParseCheckpoint(string(body) + "\n"); err == nil {
				c.witnessed = cp.Size
			}
		}
	}
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := c.Once(ctx); err != nil {
				c.Logger.Error("checkpoint", "error", err)
			}
		}
	}
}

// Once signs the current head and has the witness co-sign it, if the log
// has grown since the last one.
func (c *Checkpointer) Once(ctx context.Context) error {
	c.mu.Lock()
	head, old := c.head, c.witnessed
	c.mu.Unlock()
	if head.Size == 0 || head.Size == old {
		return nil
	}
	signed, err := note.Sign(&note.Note{Text: Checkpoint{Origin: c.Origin, Size: head.Size, Root: head.Root}.Text()}, c.Signer)
	if err != nil {
		return fmt.Errorf("sign: %w", err)
	}
	// Twice at most: a 409 tells us where the witness really is.
	for range 2 {
		var proof tlog.TreeProof
		if old > 0 && old < head.Size {
			if proof, err = c.Prove(ctx, old, head.Size); err != nil {
				return fmt.Errorf("prove %d -> %d: %w", old, head.Size, err)
			}
		}
		status, body, err := c.post(ctx, old, proof, signed)
		if err != nil {
			return err
		}
		switch status {
		case http.StatusOK:
			if err := writeAtomically(c.Path, append(signed, body...)); err != nil {
				return err
			}
			c.mu.Lock()
			c.witnessed = head.Size
			c.mu.Unlock()
			c.Logger.Info("checkpoint witnessed", "size", head.Size, "root", fmt.Sprintf("%x", head.Root[:8]))
			return nil
		case http.StatusConflict:
			size, err := strconv.ParseInt(strings.TrimSpace(string(body)), 10, 64)
			if err != nil || size > head.Size {
				return fmt.Errorf("witness has %q records, more than the log's %d: was the log cut short?", body, head.Size)
			}
			old = size
		default:
			// The witness refused a history it can't reconcile with the
			// one it saw: the log was changed under us. An alarm, not a
			// retry.
			return fmt.Errorf("WITNESS REFUSED checkpoint of %d records: %d %s", head.Size, status, strings.TrimSpace(string(body)))
		}
	}
	return errors.New("the witness's checkpoint kept changing")
}

func (c *Checkpointer) post(ctx context.Context, old int64, proof tlog.TreeProof, signed []byte) (int, []byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	body := bytes.NewReader(WitnessRequest(old, proof, signed))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.Witness+"/add-checkpoint", body)
	if err != nil {
		return 0, nil, err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("witness: %w", err)
	}
	defer resp.Body.Close()
	reply, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	return resp.StatusCode, reply, err
}

// WitnessRequest is the body of a witness's POST /add-checkpoint: the size
// of the witness's checkpoint the proof starts from, the proof's hashes in
// base64, one a line, a blank line, then the signed checkpoint.
func WitnessRequest(old int64, proof tlog.TreeProof, signed []byte) []byte {
	var b bytes.Buffer
	fmt.Fprintf(&b, "old %d\n", old)
	for _, h := range proof {
		b.WriteString(base64.StdEncoding.EncodeToString(h[:]) + "\n")
	}
	b.WriteString("\n")
	b.Write(signed)
	return b.Bytes()
}

// ParseWitnessRequest reads what WitnessRequest wrote.
func ParseWitnessRequest(body []byte) (old int64, proof tlog.TreeProof, signed []byte, err error) {
	head, signed, ok := bytes.Cut(body, []byte("\n\n"))
	if !ok {
		return 0, nil, nil, errors.New("want old SIZE, the proof, a blank line, then the checkpoint")
	}
	lines := strings.Split(string(head), "\n")
	size, found := strings.CutPrefix(lines[0], "old ")
	if old, err = strconv.ParseInt(size, 10, 64); !found || err != nil || old < 0 {
		return 0, nil, nil, fmt.Errorf("bad first line %q", lines[0])
	}
	for _, line := range lines[1:] {
		b, err := base64.StdEncoding.DecodeString(line)
		if err != nil || len(b) != tlog.HashSize {
			return 0, nil, nil, fmt.Errorf("bad proof hash %q", line)
		}
		proof = append(proof, tlog.Hash(b))
	}
	return old, proof, signed, nil
}

// KlogProver proves consistency with `klog consistency FILE OLD NEW`, the
// log's own tool.
func KlogProver(bin, path string) func(context.Context, int64, int64) (tlog.TreeProof, error) {
	return func(ctx context.Context, old, n int64) (tlog.TreeProof, error) {
		out, err := exec.CommandContext(ctx, bin, "consistency", path, strconv.FormatInt(old, 10), strconv.FormatInt(n, 10)).Output()
		if err != nil {
			return nil, err
		}
		var proof tlog.TreeProof
		for _, line := range strings.Fields(string(out)) {
			b, err := hex.DecodeString(line)
			if err != nil || len(b) != tlog.HashSize {
				return nil, fmt.Errorf("klog consistency: bad hash %q", line)
			}
			proof = append(proof, tlog.Hash(b))
		}
		return proof, nil
	}
}

func writeAtomically(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".checkpoint-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
~~~

Create `internal/audit/checkpointer_test.go`:

<!-- file: internal/audit/checkpointer_test.go -->
~~~go
package audit_test

import (
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/mod/sumdb/note"
	"golang.org/x/mod/sumdb/tlog"

	"runway/internal/audit"
	"runway/internal/witness"
)

func newKey(t *testing.T, name string) (note.Signer, note.Verifier, string) {
	t.Helper()
	skey, vkey, err := note.GenerateKey(rand.Reader, name)
	if err != nil {
		t.Fatal(err)
	}
	s, _ := note.NewSigner(skey)
	v, _ := note.NewVerifier(vkey)
	return s, v, vkey
}

// log is records, with the head and proofs klog would give.
type log struct{ tree *audit.Tree }

func newLog(t *testing.T, records ...string) *log {
	t.Helper()
	l := &log{tree: &audit.Tree{}}
	for _, r := range records {
		l.tree.Add([]byte(r))
	}
	return l
}

func (l *log) head(t *testing.T, n int64) audit.Head {
	t.Helper()
	root, err := l.tree.Root(n)
	if err != nil {
		t.Fatal(err)
	}
	return audit.Head{Size: n, Root: root}
}

func (l *log) prove(_ context.Context, old, n int64) (tlog.TreeProof, error) {
	return l.tree.ProveTree(old, n)
}

func events(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("event %d", i)
	}
	return out
}

func TestCheckpointsAreWitnessed(t *testing.T) {
	ctx := context.Background()
	logSigner, logVerifier, logKey := newKey(t, audit.DefaultOrigin)
	witnessSigner, witnessVerifier, _ := newKey(t, "witness.example")
	w, err := witness.New(witnessSigner, t.TempDir(), logKey)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(w.Handler())
	defer srv.Close()
	dir := t.TempDir()
	checkpointer := func(l *log) *audit.Checkpointer {
		return &audit.Checkpointer{Origin: audit.DefaultOrigin, Signer: logSigner, Witness: srv.URL,
			Path: filepath.Join(dir, "audit.checkpoint"), Prove: l.prove, HTTP: srv.Client(),
			Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	}
	saved := func() int64 {
		t.Helper()
		data, err := os.ReadFile(filepath.Join(dir, "audit.checkpoint"))
		if err != nil {
			t.Fatal(err)
		}
		c, err := audit.OpenCheckpoint(data, logVerifier, witnessVerifier)
		if err != nil {
			t.Fatal(err)
		}
		return c.Size
	}

	l := newLog(t, events(20)...)
	c := checkpointer(l)
	for _, n := range []int64{5, 9} {
		c.Observe(l.head(t, n))
		if err := c.Once(ctx); err != nil {
			t.Fatal(err)
		}
		if got := saved(); got != n {
			t.Fatalf("saved checkpoint of %d records, want %d", got, n)
		}
	}

	// A restart that lost its state: it thinks the witness has nothing,
	// learns it has 9 (409), and proves from there.
	fresh := checkpointer(l)
	fresh.Observe(l.head(t, 12))
	if err := fresh.Once(ctx); err != nil {
		t.Fatal(err)
	}
	if got := saved(); got != 12 {
		t.Fatalf("after the restart: %d, want 12", got)
	}

	// The log was rewritten underneath: record 4 edited, then more added.
	edited := events(20)
	edited[4] = "event 4, edited"
	rewritten := newLog(t, edited...)
	c = checkpointer(rewritten)
	c.Observe(rewritten.head(t, 14))
	err = c.Once(ctx)
	if err == nil || !strings.Contains(err.Error(), "WITNESS REFUSED") {
		t.Fatalf("rewritten log: %v, want the witness to refuse", err)
	}
	if got := saved(); got != 12 {
		t.Fatalf("the refused checkpoint was saved: %d", got)
	}
}
~~~

### The witness

Create `internal/witness/witness.go`:

<!-- file: internal/witness/witness.go -->
~~~go
// Package witness is a transparency-log witness (Phase 6, step 10): a
// second party that remembers the latest checkpoint of each log it watches
// and co-signs a new one only if the log has only grown since.
//
// A log's own signature says only "the log's key signed this". Whoever
// holds the log and can use its key can sign a rewritten history too. The
// witness can't be fooled that way: it has kept the old checkpoint, and a
// rewritten log has no consistency proof from it. And it can't be
// rewritten along with the log, because it runs somewhere else, for
// someone else. A checkpoint with the witness's signature means: this
// history is the one the witness saw grow, and no other.
//
// The protocol follows C2SP's tlog-witness, simplified: no timestamps in
// the co-signature, one log key per origin.
package witness

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"golang.org/x/mod/sumdb/note"
	"golang.org/x/mod/sumdb/tlog"

	"runway/internal/audit"
)

// Witness co-signs checkpoints with signer, for the logs whose keys it
// knows.
type Witness struct {
	signer note.Signer
	logs   map[string]note.Verifier // origin: the log's key
	dir    string                   // one file per log: its latest co-signed checkpoint

	mu sync.Mutex
}

// New watches the logs whose verifier keys are given, keeping its state in
// dir.
func New(signer note.Signer, dir string, logKeys ...string) (*Witness, error) {
	w := &Witness{signer: signer, logs: map[string]note.Verifier{}, dir: dir}
	for _, vkey := range logKeys {
		v, err := note.NewVerifier(vkey)
		if err != nil {
			return nil, fmt.Errorf("log key %q: %w", vkey, err)
		}
		w.logs[v.Name()] = v
	}
	return w, os.MkdirAll(dir, 0o700)
}

// The ways Add refuses, each with its HTTP status in cmd/witness.
var (
	ErrUnknownLog   = errors.New("not a log this witness watches")             // 404
	ErrBadSignature = errors.New("the log's signature does not check")         // 403
	ErrInconsistent = errors.New("not consistent with the checkpoint I have")  // 422: a rewritten history
	ErrRollback     = errors.New("smaller than the checkpoint I already have") // 400
)

// ConflictError says the caller's idea of the last checkpoint is wrong:
// the witness has one of Size records (409). The caller proves again, from
// there.
type ConflictError struct{ Size int64 }

func (e *ConflictError) Error() string {
	return fmt.Sprintf("my latest checkpoint has %d records", e.Size)
}

// Add takes a signed checkpoint and a proof that it extends the one of old
// records, the latest the caller knows the witness has. If all is well it
// keeps the checkpoint and returns its own signature lines, to append to
// the note.
func (w *Witness) Add(old int64, proof tlog.TreeProof, signed []byte) ([]byte, error) {
	origin, _, _ := strings.Cut(string(signed), "\n")
	v, ok := w.logs[origin]
	if !ok {
		return nil, ErrUnknownLog
	}
	c, err := audit.OpenCheckpoint(signed, v)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrBadSignature, err)
	}

	w.mu.Lock()
	defer w.mu.Unlock()
	prev, err := w.latest(origin, v)
	if err != nil {
		return nil, err
	}
	switch {
	case old != prev.Size:
		return nil, &ConflictError{Size: prev.Size}
	case c.Size < prev.Size:
		return nil, ErrRollback
	case c.Size == prev.Size && c.Root != prev.Root:
		return nil, fmt.Errorf("%w: same size, %d records, another root", ErrInconsistent, c.Size)
	case prev.Size > 0 && c.Size > prev.Size:
		if err := tlog.CheckTree(proof, c.Size, c.Root, prev.Size, prev.Root); err != nil {
			return nil, fmt.Errorf("%w: %v", ErrInconsistent, err)
		}
	}

	cosigned, err := note.Sign(&note.Note{Text: c.Text()}, w.signer)
	if err != nil {
		return nil, err
	}
	_, sigs, _ := bytes.Cut(cosigned, []byte("\n\n"))
	if err := w.save(origin, append(bytes.Clone(signed), sigs...)); err != nil {
		return nil, err
	}
	return sigs, nil
}

// Latest returns the latest checkpoint of origin the witness has
// co-signed, with both signatures, or nil if it has none.
func (w *Witness) Latest(origin string) ([]byte, error) {
	if _, ok := w.logs[origin]; !ok {
		return nil, ErrUnknownLog
	}
	data, err := os.ReadFile(w.path(origin))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	return data, err
}

// latest is the checkpoint the witness holds for origin, or size 0.
func (w *Witness) latest(origin string, v note.Verifier) (audit.Checkpoint, error) {
	data, err := w.Latest(origin)
	if err != nil || data == nil {
		return audit.Checkpoint{Origin: origin}, err
	}
	return audit.OpenCheckpoint(data, v)
}

func (w *Witness) path(origin string) string {
	return filepath.Join(w.dir, strings.NewReplacer("/", "_", ".", "_").Replace(origin))
}

// save writes the checkpoint so a crash leaves the old one or the new one,
// never half of either: to a temporary file, flushed, renamed over the
// old one.
func (w *Witness) save(origin string, data []byte) error {
	tmp, err := os.CreateTemp(w.dir, "checkpoint-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), w.path(origin)); err != nil {
		return err
	}
	// The rename is a change to the directory: flush that too, or a crash
	// can forget it (Phase 3).
	dir, err := os.Open(w.dir)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
~~~

It answers four ways: co-signed (the log only grew), `409` (it has a different size, and says which, so the log can prove again from there), `422` (the proof fails, or the same size has another root: a rewritten history or a fork), and `400` (the log shrank). Create `internal/witness/http.go`:

<!-- file: internal/witness/http.go -->
~~~go
package witness

import (
	"errors"
	"fmt"
	"io"
	"net/http"

	"runway/internal/audit"
)

// Handler serves the witness over HTTP.
//
//	POST /add-checkpoint   body: audit.WitnessRequest's: "old SIZE", one
//	                       proof hash per line in base64, a blank line, then
//	                       the signed checkpoint.
//	                       200: the witness's signature lines.
//	                       409: the size the witness has, as text.
//	GET /checkpoint?origin=O   the latest co-signed checkpoint of log O.
func (w *Witness) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /add-checkpoint", func(rw http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<16))
		if err != nil {
			http.Error(rw, err.Error(), http.StatusBadRequest)
			return
		}
		old, proof, signed, err := audit.ParseWitnessRequest(body)
		if err != nil {
			http.Error(rw, err.Error(), http.StatusBadRequest)
			return
		}
		sigs, err := w.Add(old, proof, signed)
		var conflict *ConflictError
		switch {
		case err == nil:
			rw.Write(sigs)
		case errors.As(err, &conflict):
			rw.WriteHeader(http.StatusConflict)
			fmt.Fprintf(rw, "%d\n", conflict.Size)
		case errors.Is(err, ErrUnknownLog):
			http.Error(rw, err.Error(), http.StatusNotFound)
		case errors.Is(err, ErrBadSignature):
			http.Error(rw, err.Error(), http.StatusForbidden)
		case errors.Is(err, ErrInconsistent):
			http.Error(rw, err.Error(), http.StatusUnprocessableEntity)
		case errors.Is(err, ErrRollback):
			http.Error(rw, err.Error(), http.StatusBadRequest)
		default:
			http.Error(rw, err.Error(), http.StatusInternalServerError)
		}
	})
	mux.HandleFunc("GET /checkpoint", func(rw http.ResponseWriter, r *http.Request) {
		data, err := w.Latest(r.URL.Query().Get("origin"))
		switch {
		case errors.Is(err, ErrUnknownLog):
			http.Error(rw, err.Error(), http.StatusNotFound)
		case err != nil:
			http.Error(rw, err.Error(), http.StatusInternalServerError)
		case data == nil:
			http.Error(rw, "no checkpoint yet", http.StatusNotFound)
		default:
			rw.Write(data)
		}
	})
	return mux
}
~~~

Create `internal/witness/witness_test.go`:

<!-- file: internal/witness/witness_test.go -->
~~~go
package witness

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"golang.org/x/mod/sumdb/note"
	"golang.org/x/mod/sumdb/tlog"

	"runway/internal/audit"
)

const origin = "runway.example/audit"

func keys(t *testing.T, name string) (note.Signer, note.Verifier, string) {
	t.Helper()
	skey, vkey, err := note.GenerateKey(rand.Reader, name)
	if err != nil {
		t.Fatal(err)
	}
	s, _ := note.NewSigner(skey)
	v, _ := note.NewVerifier(vkey)
	return s, v, vkey
}

// history is a log's records; edits make a rewritten copy.
type history [][]byte

func records(n int) history {
	h := make(history, n)
	for i := range h {
		h[i] = fmt.Appendf(nil, "event %d", i)
	}
	return h
}

func (h history) tree(t *testing.T) *audit.Tree {
	t.Helper()
	tree, err := audit.TreeOf(h)
	if err != nil {
		t.Fatal(err)
	}
	return tree
}

// checkpoint signs the checkpoint of the first n records with signer.
func (h history) checkpoint(t *testing.T, n int64, signer note.Signer) []byte {
	t.Helper()
	root, err := h.tree(t).Root(n)
	if err != nil {
		t.Fatal(err)
	}
	signed, err := note.Sign(&note.Note{Text: audit.Checkpoint{Origin: origin, Size: n, Root: root}.Text()}, signer)
	if err != nil {
		t.Fatal(err)
	}
	return signed
}

func (h history) proof(t *testing.T, old, n int64) tlog.TreeProof {
	t.Helper()
	if old == 0 {
		return nil
	}
	p, err := h.tree(t).ProveTree(old, n)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestTheWitnessAcceptsOnlyGrowth(t *testing.T) {
	logSigner, logVerifier, logKey := keys(t, origin)
	witnessSigner, witnessVerifier, _ := keys(t, "witness.example")
	w, err := New(witnessSigner, t.TempDir(), logKey)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(w.Handler())
	defer srv.Close()
	add := func(old int64, proof tlog.TreeProof, signed []byte) (int, string) {
		t.Helper()
		resp, err := http.Post(srv.URL+"/add-checkpoint", "text/plain", bytes.NewReader(audit.WitnessRequest(old, proof, signed)))
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(body)
	}
	log := records(20)

	// The first checkpoint is taken on trust: there is nothing to check
	// it against. Then each one must extend the last.
	for _, step := range []struct{ old, n int64 }{{0, 5}, {5, 9}, {9, 9}, {9, 13}} {
		if code, body := add(step.old, log.proof(t, step.old, step.n), log.checkpoint(t, step.n, logSigner)); code != http.StatusOK {
			t.Fatalf("%d -> %d: %d %s", step.old, step.n, code, body)
		}
	}
	latest, err := w.Latest(origin)
	if err != nil {
		t.Fatal(err)
	}
	c, err := audit.OpenCheckpoint(latest, logVerifier, witnessVerifier)
	if err != nil || c.Size != 13 {
		t.Fatalf("latest, with both signatures: %+v, %v", c, err)
	}

	rewritten := append(history{}, log...)
	rewritten[3] = []byte("event 3, edited")
	attackerSigner, _, _ := keys(t, origin) // a key of the attacker's own, under the log's name

	refusals := []struct {
		name      string
		old, n    int64
		proof     tlog.TreeProof
		signed    []byte
		code      int
		inMessage string
	}{
		{"a stale view of the witness", 5, 15, log.proof(t, 5, 15), log.checkpoint(t, 15, logSigner), http.StatusConflict, "13"},
		{"history rewritten, signed with the log's real key", 13, 15, rewritten.proof(t, 13, 15), rewritten.checkpoint(t, 15, logSigner), http.StatusUnprocessableEntity, "not consistent"},
		{"a fork: same size, another root", 13, 13, nil, rewritten.checkpoint(t, 13, logSigner), http.StatusUnprocessableEntity, "another root"},
		{"rolled back", 13, 10, nil, log.checkpoint(t, 10, logSigner), http.StatusBadRequest, "smaller"},
		{"signed with someone else's key", 13, 15, log.proof(t, 13, 15), log.checkpoint(t, 15, attackerSigner), http.StatusForbidden, "signature"},
	}
	for _, r := range refusals {
		code, body := add(r.old, r.proof, r.signed)
		if code != r.code || !strings.Contains(body, r.inMessage) {
			t.Errorf("%s: %d %q, want %d containing %q", r.name, code, body, r.code, r.inMessage)
		}
	}
	if c, _ := audit.OpenCheckpoint(must(w.Latest(origin)), logVerifier); c.Size != 13 {
		t.Fatalf("after the refusals the witness holds %d records, want 13", c.Size)
	}
	other := strings.Replace(string(log.checkpoint(t, 15, logSigner)), origin, "elsewhere.example/log", 1)
	if code, _ := add(13, nil, []byte(other)); code != http.StatusNotFound {
		t.Errorf("an unknown log: %d, want 404", code)
	}
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/audit/... ./internal/witness/... ./internal/secrets/... && KLOG_BIN=$PWD/audit/target/release/klog go test -race -count=1 ./internal/audit/... ./internal/witness/... ./internal/secrets/... -->

**Break it.** In `witness.go`, skip the consistency check: make the `tlog.CheckTree` condition never run. The witness tests:

~~~text
--- FAIL: TestTheWitnessAcceptsOnlyGrowth (0.13s)
    witness_test.go:136: history rewritten, signed with the log's real key: 200 "— witness.example /3JqqmmtA2cXd5T+q+3zKdrYOu2J6Jz/7Dri+oJ4H5eKWcgM9Tqx+yJWBkSzNhLaByRRKlxfK4PKx3nQXETPsBvl6ws=\n", want 422 containing "not consistent"
~~~

The witness co-signed a rewritten history, signed with the log's real key. The witness's whole value is that one check. Put it back.

### The commands

The witness as a server, with a key of its own. Create `cmd/witness/main.go`:

<!-- file: cmd/witness/main.go -->
~~~go
// Command witness co-signs the audit log's checkpoints (Phase 6, step 10):
// only if each one extends the last it saw. See internal/witness.
//
//	witness keygen NAME KEYFILE   make a key: the private half to KEYFILE, the
//	                              verifier key (public) to standard output
//	witness                       serve, configured by:
//
//	WITNESS_KEY_FILE   its private key, from keygen
//	WITNESS_LOGS       the verifier keys of the logs it watches, comma-separated
//	WITNESS_DATA       where it keeps each log's latest checkpoint (default witness-data)
//	LISTEN_ADDR        default 127.0.0.1:8090
//
// It should run where the log's operators can't reach: another team,
// another account, another company. A witness the attacker controls
// witnesses nothing.
package main

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"golang.org/x/mod/sumdb/note"

	"runway/internal/envconfig"
	"runway/internal/witness"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Getenv, os.Stdout, nil); err != nil {
		fmt.Fprintln(os.Stderr, "witness:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, getenv envconfig.Getenv, stdout io.Writer, ready func(string)) error {
	if len(args) > 0 {
		if len(args) != 3 || args[0] != "keygen" {
			return errors.New("usage: witness keygen NAME KEYFILE, or no arguments to serve")
		}
		skey, vkey, err := note.GenerateKey(rand.Reader, args[1])
		if err != nil {
			return err
		}
		if err := os.WriteFile(args[2], []byte(skey+"\n"), 0o600); err != nil {
			return err
		}
		fmt.Fprintln(stdout, vkey)
		return nil
	}

	keyFile, logs := getenv("WITNESS_KEY_FILE"), getenv("WITNESS_LOGS")
	if keyFile == "" || logs == "" {
		return errors.New("WITNESS_KEY_FILE and WITNESS_LOGS are required")
	}
	skey, err := os.ReadFile(keyFile)
	if err != nil {
		return err
	}
	signer, err := note.NewSigner(strings.TrimSpace(string(skey)))
	if err != nil {
		return fmt.Errorf("WITNESS_KEY_FILE: %w", err)
	}
	dir := getenv("WITNESS_DATA")
	if dir == "" {
		dir = "witness-data"
	}
	addr, err := envconfig.HostPort(getenv, "LISTEN_ADDR", "127.0.0.1:8090")
	if err != nil {
		return err
	}
	w, err := witness.New(signer, dir, strings.Split(logs, ",")...)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	server := &http.Server{Handler: logRequests(logger, w.Handler()), ReadHeaderTimeout: 5 * time.Second}
	logger.Info("witnessing", "addr", listener.Addr().String(), "as", signer.Name(), "logs", logs)
	if ready != nil {
		ready(listener.Addr().String())
	}
	errs := make(chan error, 1)
	go func() { errs <- server.Serve(listener) }()
	select {
	case <-ctx.Done():
	case err := <-errs:
		return err
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return server.Shutdown(shutdown)
}

type recorder struct {
	http.ResponseWriter
	status int
	body   strings.Builder
}

func (r *recorder) WriteHeader(code int) { r.status = code; r.ResponseWriter.WriteHeader(code) }
func (r *recorder) Write(b []byte) (int, error) {
	if r.status >= 400 {
		r.body.Write(b)
	}
	return r.ResponseWriter.Write(b)
}

// logRequests logs each request, and why it was refused.
func logRequests(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &recorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		attrs := []any{"method", r.Method, "path", r.URL.Path, "status", rec.status}
		if rec.status >= 400 {
			attrs = append(attrs, "reason", strings.TrimSpace(rec.body.String()))
		}
		logger.Info("request", attrs...)
	})
}
~~~

An investigator's tool, which trusts neither klog nor auditfeed, only the two public keys. Create `cmd/auditctl/main.go`:

<!-- file: cmd/auditctl/main.go -->
~~~go
// Command auditctl checks the audit log (Phase 6, step 10).
//
//	auditctl verify -log FILE -checkpoint SRC -log-key VKEY -witness-key VKEY
//	    Do the log's first records match a checkpoint both the log and the
//	    witness signed? SRC is a file, or the witness's URL for its latest.
//	auditctl prove -log FILE -checkpoint SRC -log-key VKEY -witness-key VKEY INDEX
//	    Prove record INDEX is in that history: the record, and the hashes
//	    that lead from it to the signed root. Anyone holding the checkpoint
//	    can check them without the log.
//	auditctl vkey
//	    Print the log's verifier key, from its OpenBao transit key (BAO_ADDR,
//	    BAO_TOKEN or BAO_ROLE; AUDIT_ORIGIN; AUDIT_SIGNING_KEY, default audit).
//
// It rebuilds the tree in Go (golang.org/x/mod/sumdb/tlog), from the file's
// bytes: it trusts neither klog nor auditfeed, only the two keys.
package main

import (
	"context"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/mod/sumdb/note"
	"golang.org/x/mod/sumdb/tlog"

	"runway/internal/audit"
	"runway/internal/envconfig"
	"runway/internal/secrets"
)

func main() {
	if err := run(context.Background(), os.Args[1:], os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "auditctl:", err)
		os.Exit(1)
	}
}

const usage = "usage: auditctl verify|prove|vkey [flags] (see the package comment)"

func run(ctx context.Context, args []string, getenv envconfig.Getenv, stdout io.Writer) error {
	if len(args) == 0 {
		return errors.New(usage)
	}
	switch args[0] {
	case "vkey":
		return vkey(ctx, getenv, stdout)
	case "verify", "prove":
	default:
		return errors.New(usage)
	}
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	logPath := fs.String("log", "audit.log", "the klog file")
	source := fs.String("checkpoint", "", "a checkpoint file, or the witness's URL")
	logKey := fs.String("log-key", "", "the log's verifier key")
	witnessKey := fs.String("witness-key", "", "the witness's verifier key")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if *source == "" || *logKey == "" || *witnessKey == "" {
		return errors.New("-checkpoint, -log-key and -witness-key are required")
	}
	c, err := checkpoint(ctx, *source, *logKey, *witnessKey)
	if err != nil {
		return err
	}
	records, err := audit.ReadLog(*logPath)
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "checkpoint: %d records, root %x, signed by the log and the witness\n", c.Size, c.Root[:8])
	if int64(len(records)) < c.Size {
		return fmt.Errorf("TAMPERED: the log has %d records; the checkpoint says it had %d: records were removed", len(records), c.Size)
	}
	tree, err := audit.TreeOf(records[:c.Size])
	if err != nil {
		return err
	}
	root, err := tree.Root(c.Size)
	if err != nil {
		return err
	}
	if root != c.Root {
		return fmt.Errorf("TAMPERED: the log's first %d records have root %x, not the checkpoint's: history was changed", c.Size, root[:8])
	}

	if args[0] == "verify" {
		fmt.Fprintf(stdout, "OK: the log's first %d records are the ones checkpointed; %d added since, not yet checkpointed\n",
			c.Size, int64(len(records))-c.Size)
		return nil
	}
	if fs.NArg() != 1 {
		return errors.New("prove needs the record's INDEX")
	}
	index, err := strconv.ParseInt(fs.Arg(0), 10, 64)
	if err != nil || index < 0 || index >= c.Size {
		return fmt.Errorf("INDEX must be from 0 to %d, the checkpoint's records", c.Size-1)
	}
	proof, err := tree.ProveRecord(index, c.Size)
	if err != nil {
		return err
	}
	if err := tlog.CheckRecord(proof, c.Size, c.Root, index, tlog.RecordHash(records[index])); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "record %d: %s\n", index, records[index])
	fmt.Fprintf(stdout, "proof (%d hashes, from the record up to the root):\n", len(proof))
	for _, h := range proof {
		fmt.Fprintf(stdout, "  %s\n", base64.StdEncoding.EncodeToString(h[:]))
	}
	fmt.Fprintln(stdout, "OK: the record is in the checkpointed history")
	return nil
}

// checkpoint reads a checkpoint from a file or the witness, and opens it
// with both keys.
func checkpoint(ctx context.Context, source, logKey, witnessKey string) (audit.Checkpoint, error) {
	var verifiers []note.Verifier
	for _, k := range []string{logKey, witnessKey} {
		v, err := note.NewVerifier(k)
		if err != nil {
			return audit.Checkpoint{}, fmt.Errorf("key %q: %w", k, err)
		}
		verifiers = append(verifiers, v)
	}
	var signed []byte
	var err error
	if strings.HasPrefix(source, "http://") || strings.HasPrefix(source, "https://") {
		signed, err = fetch(ctx, source+"/checkpoint?origin="+url.QueryEscape(verifiers[0].Name()))
	} else {
		signed, err = os.ReadFile(source)
	}
	if err != nil {
		return audit.Checkpoint{}, err
	}
	return audit.OpenCheckpoint(signed, verifiers...)
}

func fetch(ctx context.Context, u string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("witness: %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	return body, err
}

func vkey(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer) error {
	cfg, err := secrets.LoadConfig(getenv)
	if err != nil {
		return err
	}
	if !cfg.Enabled() {
		return errors.New("BAO_ADDR is required")
	}
	client, err := cfg.NewClient(nil)
	if err != nil {
		return err
	}
	origin, key := getenv("AUDIT_ORIGIN"), getenv("AUDIT_SIGNING_KEY")
	if origin == "" {
		origin = audit.DefaultOrigin
	}
	if key == "" {
		key = "audit"
	}
	_, v, err := audit.NewTransitSigner(ctx, secrets.NewTransit(client, key), origin)
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, v)
	return nil
}
~~~

Create `cmd/auditctl/main_test.go`:

<!-- file: cmd/auditctl/main_test.go -->
~~~go
package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/mod/sumdb/note"

	"runway/internal/audit"
)

// writeKlog writes records in klog's format: length, CRC-32C, payload.
func writeKlog(t *testing.T, path string, records []string) {
	t.Helper()
	var data []byte
	for _, r := range records {
		data = binary.LittleEndian.AppendUint32(data, uint32(len(r)))
		data = binary.LittleEndian.AppendUint32(data, crc32.Checksum([]byte(r), crc32.MakeTable(crc32.Castagnoli)))
		data = append(data, r...)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyAndProve(t *testing.T) {
	dir := t.TempDir()
	logPath, cpPath := filepath.Join(dir, "audit.log"), filepath.Join(dir, "audit.checkpoint")
	records := make([]string, 10)
	for i := range records {
		records[i] = fmt.Sprintf("2026-10-13T10:00:0%dZ tenant=acme job=%d state=completed", i, i)
	}
	writeKlog(t, logPath, records)

	// A checkpoint of the first 8, signed by the log and the witness.
	logSkey, logVkey, _ := note.GenerateKey(rand.Reader, audit.DefaultOrigin)
	witnessSkey, witnessVkey, _ := note.GenerateKey(rand.Reader, "witness.example")
	logSigner, _ := note.NewSigner(logSkey)
	witnessSigner, _ := note.NewSigner(witnessSkey)
	tree, _ := audit.TreeOf(func() (out [][]byte) {
		for _, r := range records {
			out = append(out, []byte(r))
		}
		return
	}())
	root, _ := tree.Root(8)
	signed, err := note.Sign(&note.Note{Text: audit.Checkpoint{Origin: audit.DefaultOrigin, Size: 8, Root: root}.Text()}, logSigner, witnessSigner)
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(cpPath, signed, 0o644)

	auditctl := func(args ...string) (string, error) {
		var out strings.Builder
		flags := []string{"-log", logPath, "-checkpoint", cpPath, "-log-key", logVkey, "-witness-key", witnessVkey}
		err := run(context.Background(), append([]string{args[0]}, append(flags, args[1:]...)...), func(string) string { return "" }, &out)
		return out.String(), err
	}
	if out, err := auditctl("verify"); err != nil || !strings.Contains(out, "OK: the log's first 8 records") || !strings.Contains(out, "2 added since") {
		t.Fatalf("verify: %s %v", out, err)
	}
	if out, err := auditctl("prove", "3"); err != nil || !strings.Contains(out, "job=3") || !strings.Contains(out, "OK: the record is in") {
		t.Fatalf("prove 3: %s %v", out, err)
	}
	// Records after the checkpoint can't be proved yet.
	if _, err := auditctl("prove", "9"); err == nil {
		t.Fatal("proved a record the checkpoint doesn't cover")
	}

	edited := append([]string{}, records...)
	edited[3] = strings.Replace(edited[3], "completed", "failed", 1)
	writeKlog(t, logPath, edited)
	if _, err := auditctl("verify"); err == nil || !strings.Contains(err.Error(), "history was changed") {
		t.Fatalf("edited: %v", err)
	}
	writeKlog(t, logPath, records[:6])
	if _, err := auditctl("verify"); err == nil || !strings.Contains(err.Error(), "records were removed") {
		t.Fatalf("cut short: %v", err)
	}
	// Without the witness's signature, the checkpoint isn't accepted.
	logOnly, _ := note.Sign(&note.Note{Text: audit.Checkpoint{Origin: audit.DefaultOrigin, Size: 8, Root: root}.Text()}, logSigner)
	os.WriteFile(cpPath, logOnly, 0o644)
	writeKlog(t, logPath, records)
	if _, err := auditctl("verify"); err == nil || !strings.Contains(err.Error(), "witness.example") {
		t.Fatalf("no witness signature: %v", err)
	}
}
~~~

And `auditfeed` runs the checkpointer when OpenBao is configured. In `cmd/auditfeed/main.go`:

Change:

<!-- edit: cmd/auditfeed/main.go -->
~~~go
// checksummed append-only log from the Rust Bridge.
//
~~~

to:

~~~go
// checksummed append-only log from the Rust Bridge.
//
// From Phase 6, step 10, it also checkpoints the log: every
// CHECKPOINT_EVERY (default 10s) it signs the log's size and Merkle root
// with an OpenBao transit key, and has a witness co-sign it. Settings:
//
//	BAO_ADDR, BAO_TOKEN or BAO_ROLE   OpenBao (internal/secrets); unset: no checkpoints
//	AUDIT_SIGNING_KEY                 the transit key (default audit, Ed25519)
//	AUDIT_ORIGIN                      the log's name (default runway.example/audit)
//	WITNESS_URL                       the witness (cmd/witness); required with OpenBao
//	AUDIT_CHECKPOINT                  where the latest witnessed checkpoint is kept
//	                                  (default AUDIT_LOG + ".checkpoint")
//
~~~

Change:

<!-- edit: cmd/auditfeed/main.go -->
~~~go
	"log/slog"
	"os"
~~~

to:

~~~go
	"log/slog"
	"net/http"
	"os"
~~~

Change:

<!-- edit: cmd/auditfeed/main.go -->
~~~go
	"syscall"

~~~

to:

~~~go
	"syscall"
	"time"

~~~

Change:

<!-- edit: cmd/auditfeed/main.go -->
~~~go
	"runway/internal/messages"
	"runway/internal/stream"
~~~

to:

~~~go
	"runway/internal/messages"
	"runway/internal/secrets"
	"runway/internal/stream"
~~~

Change:

<!-- edit: cmd/auditfeed/main.go -->
~~~go

	auditLog, err := audit.Start(bin, path)
~~~

to:

~~~go

	checkpoints, err := checkpointer(ctx, getenv, bin, path, logger)
	if err != nil {
		return err
	}
	auditLog, err := audit.Start(bin, path)
~~~

Change:

<!-- edit: cmd/auditfeed/main.go -->
~~~go
	logger.Info("auditing", "topic", messages.JobEventsTopic, "log", path)
	runErr := consumer.Run(ctx, func(_ context.Context, msg messages.Envelope) error {
~~~

to:

~~~go
	logger.Info("auditing", "topic", messages.JobEventsTopic, "log", path)
	if checkpoints != nil {
		every, err := envconfig.Duration(getenv, "CHECKPOINT_EVERY", 10*time.Second)
		if err != nil {
			return err
		}
		go checkpoints.Run(ctx, every)
	}
	runErr := consumer.Run(ctx, func(_ context.Context, msg messages.Envelope) error {
~~~

Change:

<!-- edit: cmd/auditfeed/main.go -->
~~~go
		return auditLog.Append(line)
~~~

to:

~~~go
		head, err := auditLog.Append(line)
		if err == nil && checkpoints != nil {
			checkpoints.Observe(head)
		}
		return err
~~~

Add this at the end of the file:

<!-- append: cmd/auditfeed/main.go -->
~~~go
// checkpointer is nil without OpenBao: then there are no checkpoints, and
// the log is only as trustworthy as the disk it is on.
func checkpointer(ctx context.Context, getenv envconfig.Getenv, bin, path string, logger *slog.Logger) (*audit.Checkpointer, error) {
	bao, err := secrets.LoadConfig(getenv)
	if err != nil || !bao.Enabled() {
		logger.Warn("no BAO_ADDR: the audit log is not checkpointed")
		return nil, err
	}
	witnessURL := getenv("WITNESS_URL")
	if witnessURL == "" {
		return nil, errors.New("WITNESS_URL is required with BAO_ADDR: a checkpoint nobody else holds proves nothing")
	}
	client, err := bao.NewClient(nil)
	if err != nil {
		return nil, err
	}
	origin, key, saved := getenv("AUDIT_ORIGIN"), getenv("AUDIT_SIGNING_KEY"), getenv("AUDIT_CHECKPOINT")
	if origin == "" {
		origin = audit.DefaultOrigin
	}
	if key == "" {
		key = "audit"
	}
	if saved == "" {
		saved = path + ".checkpoint"
	}
	signer, vkey, err := audit.NewTransitSigner(ctx, secrets.NewTransit(client, key), origin)
	if err != nil {
		return nil, err
	}
	logger.Info("checkpointing", "witness", witnessURL, "verifier_key", vkey)
	return &audit.Checkpointer{
		Origin: origin, Signer: signer, Witness: witnessURL, Path: saved,
		Prove: audit.KlogProver(bin, path), HTTP: &http.Client{}, Logger: logger,
	}, nil
}
~~~


CI never ran the Rust tests before this step; now klog's Merkle tree matters to Go's tests. In `.github/workflows/ci.yml`:

Change:

<!-- edit: .github/workflows/ci.yml -->
~~~yaml
        run: docker compose up -d --wait
      - run: go vet ./...
~~~

to:

~~~yaml
        run: docker compose up -d --wait
      # klog, the Rust Bridge's log (audit/). The runner has Rust already.
      # The release build is for the Go test that checks klog's Merkle tree
      # against Go's (internal/audit): without KLOG_BIN it is skipped.
      - name: Test and build klog
        working-directory: audit
        run: |
          cargo fmt --check
          cargo test --locked
          cargo build --release --locked
          echo "KLOG_BIN=$PWD/target/release/klog" >> "$GITHUB_ENV"
      - run: go vet ./...
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && KLOG_BIN=$PWD/audit/target/release/klog go test -race -count=1 ./internal/audit/... ./internal/witness/... ./cmd/auditctl/... ./cmd/auditfeed/... ./cmd/witness/... -->

### Run it

The audit pipeline runs in Compose (Kafka isn't on the kind cluster). Build the commands, start OpenBao's signing key, the witness, an API and `auditfeed`, from a scratch directory:

~~~bash
go build -o bin/ ./cmd/api ./cmd/auditfeed ./cmd/witness ./cmd/auditctl
(cd audit && cargo build --release) && cp audit/target/release/klog bin/
export PATH=$PWD/bin:$PATH BAO_ADDR=http://localhost:8200 BAO_TOKEN=runway-dev BAO_ROLE=dev
docker compose exec -e BAO_TOKEN=runway-dev openbao bao write transit/keys/audit type=ed25519
WITNESS_KEY=$(witness keygen witness.example witness.key); echo "$WITNESS_KEY"
LOG_KEY=$(auditctl vkey); echo "$LOG_KEY"
WITNESS_KEY_FILE=witness.key WITNESS_LOGS="$LOG_KEY" WITNESS_DATA=witness-data witness > witness.out 2>&1 &
AUTH_MODE=off DATABASE_URL=postgres://runway:runway@localhost:5432/runway KAFKA_BROKERS=localhost:9092 \
  LISTEN_ADDR=127.0.0.1:18080 GRPC_ADDR=127.0.0.1:19090 BAO_ADDR= api > api.out 2>&1 &
KAFKA_BROKERS=localhost:9092 KLOG_BIN=$PWD/bin/klog AUDIT_LOG=audit.log WITNESS_URL=http://127.0.0.1:8090 \
  CHECKPOINT_EVERY=3s auditfeed >> auditfeed.out 2>&1 &
~~~

~~~text
Key                       Value
latest_version            1
type                      ed25519
witness.example+05447f32+AX7QOeR4a1hHb2m5CKBdcym8jIiZWmzzDyMXJmZLFDpk
runway.example/audit+321805ca+Aec5jBOKn7MW0yCPnoIAf/CTXjl2KjXw/KIUoXKBIk1S
~~~

Compose's OpenBao keeps everything in memory, so a restart loses the transit key: create it again after one. (The API runs here with `BAO_ADDR=` because its database login is the Compose superuser's; only `auditfeed` needs OpenBao.) Send ten jobs (`curl -X POST localhost:18080/jobs ...`), wait for a checkpoint, and look:

~~~bash
grep -E '"msg":"(checkpointing|checkpoint witnessed)"' auditfeed.out | jq -c '{msg, size, root}'
klog cat audit.log | head -3
cat audit.log.checkpoint
auditctl verify -log audit.log -checkpoint http://127.0.0.1:8090 -log-key "$LOG_KEY" -witness-key "$WITNESS_KEY"
auditctl prove -log audit.log -checkpoint http://127.0.0.1:8090 -log-key "$LOG_KEY" -witness-key "$WITNESS_KEY" 4
~~~

~~~text
{"msg":"checkpoint witnessed","size":30,"root":"494748dfeec1008e"}
0: 2026-10-15T13:48:17.620643Z tenant=dev job=17 state=queued id=76HDDFWA32D65BIZPCR2B3BOQS
1: 2026-10-15T13:48:17.696360384Z tenant=dev job=17 state=running id=WI4PNTVI4ZJFFWUEXBB4BXCSGH
2: 2026-10-15T13:48:17.711206725Z tenant=dev job=17 state=completed id=6IEL6KYWX7CCJEM4XKAJN2ZKMR
runway.example/audit
30
SUdI3+7BAI4tGM7poU2iS0YuUUNssW5+UKmQfcSYkZM=

— runway.example/audit MhgFymttpywICan+2Uli7BtyiQOSKHQhEDqVTIk0+a+llXIJTjhzHzPTFkGaED8CfSjjL9JtJjof1BZoCZtLrImF2Ag=
— witness.example BUR/MtlRf7ivsU6oStsSN7AtvGHtAaamqs3CatpXvXEe0xb8nZwgIF1zpridDjCmjgWDxdJ7WHMQUwAtxZk+ssiWGQ4=
checkpoint: 30 records, root 494748dfeec1008e, signed by the log and the witness
OK: the log's first 30 records are the ones checkpointed; 0 added since, not yet checkpointed
checkpoint: 30 records, root 494748dfeec1008e, signed by the log and the witness
record 4: 2026-10-15T13:48:17.807927891Z tenant=dev job=21 state=running id=5RPYEL57ABYHL7RFJMSMPK5I53
proof (5 hashes, from the record up to the root):
  QtwISCzkExzKMBhosFtb3YzSJCN4QEaWn0NwQ60zXRM=
  TnXg/9fF0saUbnOxzSOPn64Or68n7SRJoWpuuktVcNM=
  kWw9lITOO08HZcslkHKvqUJ8jZPLqwmCpmR0k4b0iFM=
  4uNeq/dn4yF1IGNXknT6oRXXDwtPXGhe/kKKWovahHA=
  Qwkvi6087ONSfkOA9IOYN9YNrIRZG1ujaYgl6md/zdg=
OK: the record is in the checkpointed history
~~~

(The jobs are tenant `dev` because authentication is off.) Ten jobs made thirty events; the checkpoint carries two signatures, the log's and the witness's. The proof for record 4 is five hashes, ⌈log₂ 30⌉: anyone with the checkpoint can check that one record without the other 29.

**Break it: edit history, while auditfeed runs.** Change record 2 from `completed` to `failed`, CRC and all, then send three more jobs:

~~~bash
python3 deploy/chaos/klog-tamper.py audit.log edit 2 '2026-10-15T13:48:17.711206725Z tenant=dev job=17 state=failed id=6IEL6KYWX7CCJEM4XKAJN2ZKMR'
klog check audit.log
# three more jobs, then the next checkpoint attempt in auditfeed.out, and the witness's answer
~~~

~~~text
30 records, all checksums valid
WITNESS REFUSED checkpoint of 39 records: 422 not consistent with the checkpoint I have: invalid transparency proof
{"status":422,"reason":"not consistent with the checkpoint I have: invalid transparency proof"}
~~~

klog still sees nothing wrong. The witness does: there is no consistency proof from the 30 records it co-signed to these 39. Restart `auditfeed`, so klog rebuilds its tree from the edited file and the log signs *that* root, as an attacker who controls the log would: the witness refuses again (`checkpoint of 48 records: 422`). And the investigator:

~~~bash
auditctl verify -log audit.log -checkpoint http://127.0.0.1:8090 -log-key "$LOG_KEY" -witness-key "$WITNESS_KEY"
~~~

~~~text
checkpoint: 30 records, root 494748dfeec1008e, signed by the log and the witness
auditctl: TAMPERED: the log's first 30 records have root 46c23b65a004a902, not the checkpoint's: history was changed
~~~

Put the record back (`auditctl verify` says OK again, with 18 records added since), stop `auditfeed`, and cut the last 20 records off instead:

~~~text
$ python3 deploy/chaos/klog-tamper.py audit.log drop 20
$ klog check audit.log
28 records, all checksums valid
checkpoint: 30 records, root 494748dfeec1008e, signed by the log and the witness
auditctl: TAMPERED: the log has 28 records; the checkpoint says it had 30: records were removed
~~~

What this doesn't do: it doesn't *prevent* tampering, it makes it *evident*. An attacker can still edit the file; they can't make the edit unnoticeable to anyone holding a witnessed checkpoint. And it's only as strong as the witness's independence: run it in the same account, with the same administrators, and it witnesses nothing.

**Explain it:** why does a hash chain fail against someone who can rewrite the whole log, and what does a witness add? What does an inclusion proof let someone check, and what do they need? Why can't the log's own signature on a rewritten root fool the witness? Why build the tree twice, in Rust and Go? What is still possible for an attacker after this step?

**Read.** RFC 9162 (Certificate Transparency 2.0), sections 2.1 (the tree and its proofs). Then Russ Cox, *Transparent Logs for Skeptical Clients* (research.swtch.com/tlog, 2019): the clearest explanation there is, from the author of `tlog`. Then the C2SP [tlog-checkpoint](https://c2sp.org/tlog-checkpoint) and [tlog-witness](https://c2sp.org/tlog-witness) specifications: what did this step leave out?

---
## Step 11: Privacy

**The problem.** Everything so far protected data from people who shouldn't *reach* it. Privacy asks a different question: what data do we hold, where do copies of it go, how long does it live, and what can be worked out from what we publish? A job's description is whatever the tenant typed, and tenants type things like "Call Alice back: alice@example.com, +44 7700 900123". That's personal data, and by the end of Phase 5 it was copied into more places than anyone had listed (T16).

**New ideas.**

- **A data inventory.** Before deciding what to do with personal data, find every place it goes. The reliable way is a **canary**: put a distinctive fake value in, then search every store, log and trace for it.
- **Data minimisation.** The best protection for data you don't need is not to have it. Don't send it, don't log it, don't keep it longer than its purpose.
- **Redaction as a safety net.** Code that logs IDs instead of contents is the plan. Redaction catches what slips through anyway, mostly inside error messages, which carry whatever the code that made them put in. It can only catch what has a *shape* (an email address, a token, a URL's query). A name in free text has none.
- **Retention.** Every copy needs an end: a database column, a cache entry, a dead-letter queue, a backup.
- **Aggregates leak too.** A total over fewer than *k* people *is* those people (*k*-anonymity's threshold). And thresholds alone fail against **differencing**: someone who knows every member of a group but one subtracts what they know from the total. **Differential privacy** adds noise calibrated so that any one member's presence changes the published numbers' probabilities by at most a factor of e^ε. Smaller ε means more noise and more privacy, and less useful numbers.

### The inventory

Plant canaries and look everywhere: a job whose description holds an email address and a phone number, a webhook URL with a secret in its query that points at a closed port (so the delivery fails and gets logged), and a read with a browser's user agent and a forged `X-Forwarded-For`:

~~~bash
curl -s -X POST localhost:8000/jobs -H "Authorization: Bearer $ACME" -H 'Content-Type: application/json' \
  -d '{"description":"Call Alice back: alice.canary@example.com, +44 7700 900123","duration_ms":10}'
curl -s -X PUT localhost:8000/webhook -H "Authorization: Bearer $ACME_ADMIN" -H 'Content-Type: application/json' \
  -d '{"url":"http://hookcatcher.partner:9999/hooks?token=hooksecret-canary-51b2"}'
curl -s localhost:8000/jobs/8 -H "Authorization: Bearer $ACME" -H 'X-Forwarded-For: 203.0.113.7' -H "User-Agent: Mozilla/5.0 (Alice's laptop)"
~~~

Then search: every container's log in `runway`, `partner` and `observability`; every span attribute Jaeger stored (its `/api/v3/traces` per service); every table; every Redis key's value; every non-empty queue. What I found:

~~~text
## Logs
runway/notifier-698d94bc4d-d5mcf         hooksecret-canary-51b2     2 lines
{"msg":"webhook","result":"failed","tenant":"acme","error":"failed after 3 attempts: Post \"http://hookcatcher.partner:9999/hooks?token=hooksecret-canary-51b2\": context deadline exceeded (Client.Timeout exceeded while awaiting headers)"}

## Traces
alice.canary@example.com: 0 attributes
# attributes that say who or where a caller is:
      2 client.address
      2 network.peer.address
      3 user_agent.original
      1 api GET /jobs/{id}: client.address=172.18.0.2 user_agent=Mozilla/5.0 (Alice's laptop)

## Stores
$ psql: rows that contain the email, per table
jobs|4
outbox|4
webhooks (url)|1
$ redis: keys whose value contains the email
  redis-0 runway:job:v2:acme:8 ttl 3567s
$ rabbitmqctl list_queues name messages   # non-empty
webhooks.deliveries.dead	6
$ psql: how long finished jobs have been kept
completed|9|2026-10-13
~~~

(Trimmed to the findings.) Read it as a list of jobs to do:
- **The webhook URL's secret is in the notifier's log**, inside an error message from Go's HTTP client, which quotes the whole URL. Nobody wrote "log the URL"; the error did it.
- **Traces carry the caller's address and user agent**, which `otelhttp` records by itself. (The forged `X-Forwarded-For` wasn't believed: the address is the node's.) Nothing in Runway reads either.
- **The description is in four places**: the job, the outbox row (the `RunJob` command), a cached copy in Redis, and the dead-letter queues, whose messages (failed `RunJob` commands, failed webhooks) are kept forever.
- **Finished jobs are kept forever**, descriptions and all.
- The description is *not* in any log or span. Phase 2's habit, log IDs not contents, held. And it was never in the Kafka events either: `JobChanged` carries the state, not the description. I'd assumed it did. The canary is how you find out.

### Redaction

Create `internal/redact/redact.go`:

<!-- file: internal/redact/redact.go -->
~~~go
// Package redact keeps secrets and personal data out of logs (Phase 6,
// step 11).
//
// It is a safety net, not the plan. The plan is not to log such things:
// log IDs, not contents (Phase 2), and give sensitive types a LogValue
// that hides them (jobs.Description). The net catches what slips through
// anyway, mostly inside error messages, which carry whatever the code that
// made them put in: a URL with a token in its query, an email address in
// a database error. It can only catch what has a shape. A name or a phone
// number in free text has none, which is why the plan comes first.
package redact

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"regexp"
	"strings"
)

// Redacted replaces the value of an attribute whose name says it's secret.
const Redacted = "[redacted]"

// sensitiveKeys are attribute names whose values are never logged, at any
// depth. Matched in lower case, as substrings: "client_secret" and
// "refresh_token" too.
var sensitiveKeys = []string{"password", "secret", "token", "authorization", "cookie", "description"}

// shapes are what a secret or a piece of personal data looks like, and
// what replaces it.
var shapes = []struct {
	re   *regexp.Regexp
	with string
}{
	// A JSON Web Token: three base64url parts, the first a JSON object.
	{regexp.MustCompile(`eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*`), "[jwt]"},
	// A webhook signing secret (internal/webhook).
	{regexp.MustCompile(`whsec_[A-Za-z0-9+/=]+`), "[webhook secret]"},
	// A URL's query: where API keys, tokens and signatures travel.
	{regexp.MustCompile(`(https?://[^\s"'?#]+)\?[^\s"'#]*`), "${1}?" + Redacted},
	{regexp.MustCompile(`[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`), "[email]"},
}

// String scrubs every shape from s.
func String(s string) string {
	for _, shape := range shapes {
		s = shape.re.ReplaceAllString(s, shape.with)
	}
	return s
}

// URL returns raw without its query, fragment or user info: safe to log,
// and still enough to tell which endpoint it was.
func URL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return String(raw)
	}
	hidden := u.RawQuery != "" || u.Fragment != "" || u.User != nil
	u.RawQuery, u.Fragment, u.User = "", "", nil
	if hidden {
		return u.String() + "?" + Redacted
	}
	return u.String()
}

// Handler wraps another slog.Handler and scrubs every record on its way
// through: the message, and every attribute value, at any depth.
type Handler struct {
	next slog.Handler
}

func NewHandler(next slog.Handler) *Handler { return &Handler{next: next} }

// NewJSONLogger is what every Runway service logs with.
func NewJSONLogger(w io.Writer) *slog.Logger {
	return slog.New(NewHandler(slog.NewJSONHandler(w, nil)))
}

func (h *Handler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level)
}

func (h *Handler) Handle(ctx context.Context, r slog.Record) error {
	clean := slog.NewRecord(r.Time, r.Level, String(r.Message), r.PC)
	r.Attrs(func(a slog.Attr) bool {
		clean.AddAttrs(attr(a))
		return true
	})
	return h.next.Handle(ctx, clean)
}

func (h *Handler) WithAttrs(attrs []slog.Attr) slog.Handler {
	clean := make([]slog.Attr, len(attrs))
	for i, a := range attrs {
		clean[i] = attr(a)
	}
	return &Handler{next: h.next.WithAttrs(clean)}
}

func (h *Handler) WithGroup(name string) slog.Handler {
	return &Handler{next: h.next.WithGroup(name)}
}

func attr(a slog.Attr) slog.Attr {
	if sensitive(a.Key) {
		return slog.String(a.Key, Redacted)
	}
	return slog.Attr{Key: a.Key, Value: value(a.Value)}
}

func sensitive(key string) bool {
	key = strings.ToLower(key)
	for _, s := range sensitiveKeys {
		if strings.Contains(key, s) {
			return true
		}
	}
	return false
}

func value(v slog.Value) slog.Value {
	v = v.Resolve() // a LogValuer has its say first
	switch v.Kind() {
	case slog.KindString:
		return slog.StringValue(String(v.String()))
	case slog.KindGroup:
		group := v.Group()
		clean := make([]slog.Attr, len(group))
		for i, a := range group {
			clean[i] = attr(a)
		}
		return slog.GroupValue(clean...)
	case slog.KindAny:
		return anyValue(v.Any())
	default: // numbers, booleans, times, durations: nothing to hide
		return v
	}
}

// anyValue scrubs what the JSON handler would have written for x: an
// error's or a Stringer's text, or else x as JSON, which is how a struct
// logged whole would otherwise leak every field it has.
func anyValue(x any) slog.Value {
	switch x := x.(type) {
	case error:
		return slog.StringValue(String(x.Error()))
	case fmt.Stringer:
		return slog.StringValue(String(x.String()))
	}
	b, err := json.Marshal(x)
	if err != nil {
		return slog.StringValue(String(fmt.Sprintf("%+v", x)))
	}
	var tree any
	if err := json.Unmarshal(b, &tree); err != nil {
		return slog.StringValue(String(string(b)))
	}
	return slog.AnyValue(scrubJSON("", tree))
}

// scrubJSON walks a decoded JSON value, applying the same rules as to
// attributes: names first, then shapes.
func scrubJSON(key string, x any) any {
	if key != "" && sensitive(key) {
		return Redacted
	}
	switch x := x.(type) {
	case string:
		return String(x)
	case map[string]any:
		for k, v := range x {
			x[k] = scrubJSON(k, v)
		}
		return x
	case []any:
		for i, v := range x {
			x[i] = scrubJSON("", v)
		}
		return x
	default:
		return x
	}
}
~~~

It works at two levels. By *name*: an attribute called `password`, `secret`, `token`, `authorization`, `cookie` or `description` is replaced whatever its value. By *shape*: inside every string, at any depth, JWTs, webhook secrets, URL queries and email addresses are replaced. Look at `anyValue`. An error or a `Stringer` is scrubbed as the text the JSON handler would have written; a struct is turned into JSON and walked, so a struct logged whole can't leak a field through its name.

Create `internal/redact/redact_test.go`:

<!-- file: internal/redact/redact_test.go -->
~~~go
package redact

import (
	"bytes"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"strings"
	"testing"
)

const (
	email = "alice.canary@example.com"
	token = "eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiJhY21lIn0.c2lnbmF0dXJl"
	hook  = "hooksecret-canary-51b2"
)

// Every way a canary could reach a log line: as a value, inside an error,
// in a struct logged whole, in a group, in the message itself.
func TestCanariesNeverReachTheLog(t *testing.T) {
	type request struct {
		Path    string
		Headers map[string]string
		Owner   string
	}
	urlErr := &url.Error{Op: "Post", URL: "https://hooks.example/in?token=" + hook, Err: errors.New("connection refused")}

	var out bytes.Buffer
	logger := NewJSONLogger(&out)
	logger.Info("job for "+email, "job_id", 42)
	logger.Warn("webhook", "error", fmt.Errorf("failed after 3 attempts: %w", urlErr))
	logger.Warn("rejected", "header", "Bearer "+token)
	logger.Info("request", "req", request{Path: "/jobs", Headers: map[string]string{"Authorization": "Bearer x"}, Owner: email})
	logger.Info("signup", slog.Group("user", "email", email, "password", "hunter2"))
	logger.With("client_secret", "s3cr3t").Info("login")
	logger.Info("job", "description", "anything at all")

	for _, canary := range []string{email, token, hook, "hunter2", "s3cr3t", "Bearer x", "anything at all"} {
		if strings.Contains(out.String(), canary) {
			t.Errorf("%q reached the log:\n%s", canary, out.String())
		}
	}
	// What makes a line useful must survive.
	for _, kept := range []string{`"job_id":42`, `https://hooks.example/in?[redacted]`, `connection refused`, `"Path":"/jobs"`} {
		if !strings.Contains(out.String(), kept) {
			t.Errorf("%s is missing:\n%s", kept, out.String())
		}
	}
}

func TestURL(t *testing.T) {
	for raw, want := range map[string]string{
		"https://hooks.example/in?token=abc": "https://hooks.example/in?[redacted]",
		"https://hooks.example/in#frag":      "https://hooks.example/in?[redacted]",
		"https://user:pw@hooks.example/in":   "https://hooks.example/in?[redacted]",
		"https://hooks.example/in":           "https://hooks.example/in",
	} {
		if got := URL(raw); got != want {
			t.Errorf("URL(%q) = %q, want %q", raw, got, want)
		}
	}
}

// A shape can't be found where there is none: a phone number in free text
// goes straight through. Hence jobs.Description's LogValue.
func TestFreeTextHasNoShape(t *testing.T) {
	if got := String("call +44 7700 900123"); got != "call +44 7700 900123" {
		t.Errorf("got %q", got)
	}
}
~~~

The plan comes first, though: a description should never reach a log at all. A `LogValue` method on the type decides what any log line shows for it, wherever it's logged. In `internal/jobs/job.go`:

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
	"fmt"
	"strings"
~~~

to:

~~~go
	"fmt"
	"log/slog"
	"strings"
~~~

Change:

<!-- edit: internal/jobs/job.go -->
~~~go

// Job is an entity: it has an identity that stays the same while its state
~~~

to:

~~~go

// LogValue keeps a description out of logs (Phase 6, step 11). It is
// whatever the tenant typed, names and phone numbers included, which no
// pattern can find. A log line gets its length.
func (d Description) LogValue() slog.Value {
	return slog.StringValue(fmt.Sprintf("[%d characters]", utf8.RuneCountInString(string(d))))
}

// Job is an entity: it has an identity that stays the same while its state
~~~

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
	UpdatedAt     time.Time
}
~~~

to:

~~~go
	UpdatedAt     time.Time
}

// LogValue is what a job logged whole shows: what it is, not what it says.
func (j Job) LogValue() slog.Value {
	return slog.GroupValue(slog.Int64("id", int64(j.ID)), slog.String("tenant", string(j.Tenant)), slog.String("state", string(j.State)))
}
~~~


In `internal/jobs/job_test.go`:

Change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
import (
	"errors"
	"strings"
~~~

to:

~~~go
import (
	"bytes"
	"errors"
	"log/slog"
	"strings"
~~~

Add this at the end of the file:

<!-- append: internal/jobs/job_test.go -->
~~~go
// A description never reaches a log, even through a plain handler with no
// redaction, logged alone or inside its job (Phase 6, step 11).
func TestDescriptionsStayOutOfLogs(t *testing.T) {
	d, _ := NewDescription("Call Alice back: +44 7700 900123")
	job, _ := New(d, time.Second, t0)
	job.ID, job.Tenant = 7, "acme"
	var out bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&out, nil))
	logger.Info("created", "description", d, "job", job)
	if strings.Contains(out.String(), "Alice") {
		t.Fatalf("the description was logged:\n%s", out.String())
	}
	for _, want := range []string{`"description":"[32 characters]"`, `"job":{"id":7,"tenant":"acme","state":"queued"}`} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("%s is missing:\n%s", want, out.String())
		}
	}
}
~~~


And the webhook sender's errors carry its URL: make it say which endpoint without the query. In `internal/webhook/sender.go`:

Change:

<!-- edit: internal/webhook/sender.go -->
~~~go
	"net/http"
	"time"
)
~~~

to:

~~~go
	"net/http"
	"net/url"
	"time"

	"runway/internal/redact"
)
~~~

Change:

<!-- edit: internal/webhook/sender.go -->
~~~go
	resp, err := s.Client.Do(req)
	if err != nil {
		return err
	}
~~~

to:

~~~go
	resp, err := s.Client.Do(req)
	if err != nil {
		// The error repeats the whole URL, and tenants put tokens in
		// query strings. It will be logged: keep only where it went.
		if urlErr, ok := errors.AsType[*url.Error](err); ok {
			urlErr.URL = redact.URL(urlErr.URL)
		}
		return err
	}
~~~


In `internal/webhook/webhook_test.go`:

Change:

<!-- edit: internal/webhook/webhook_test.go -->
~~~go

func TestSenderReportsNon2xx(t *testing.T) {
~~~

to:

~~~go

// A failed request's error names the URL, and is logged. A token in its
// query must not be (Phase 6, step 11).
func TestSenderErrorsHideTheQuery(t *testing.T) {
	server := httptest.NewServer(http.NotFoundHandler())
	server.Close() // nothing listens there now
	s := Sender{Client: Policy{AllowHosts: []string{"127.0.0.1"}}.Client(time.Second)}
	err := s.Send(context.Background(), Endpoint{URL: server.URL + "/in?token=canary", Secrets: []Secret{NewSecret()}}, "m", Event{})
	if err == nil || strings.Contains(err.Error(), "canary") || !strings.Contains(err.Error(), server.URL+"/in?[redacted]") {
		t.Fatalf("got %v, want the URL without its query", err)
	}
}

func TestSenderReportsNon2xx(t *testing.T) {
~~~


<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/redact/ ./internal/jobs/... ./internal/webhook/ && go test -race -count=1 ./internal/redact/ ./internal/jobs/... ./internal/webhook/ -->

**Break it.** Rename `Description.LogValue` to anything else, so the type no longer has one, and run the `jobs` tests:

~~~text
--- FAIL: TestDescriptionsStayOutOfLogs (0.00s)
    job_test.go:128: the description was logged:
~~~

The redaction handler would still have caught the email in it. It would not have caught the phone number, or the name.

Every Runway command logs through the redacting handler. One line in each, in `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"log/slog"
	"net"
~~~

to:

~~~go
	"log/slog"
	"math"
	"net"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"os/signal"
	"strings"
~~~

to:

~~~go
	"os/signal"
	"strconv"
	"strings"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/outbox"
	"runway/internal/pgstore"
~~~

to:

~~~go
	"runway/internal/outbox"
	"runway/internal/peerstats"
	"runway/internal/pgstore"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/ratelimit"
	"runway/internal/secrets"
~~~

to:

~~~go
	"runway/internal/ratelimit"
	"runway/internal/redact"
	"runway/internal/secrets"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	AbandonAfter     time.Duration
	DBMaxConns       int
~~~

to:

~~~go
	AbandonAfter     time.Duration
	KeepDescriptions time.Duration
	DBMaxConns       int
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	Bao secrets.Config
}
~~~

to:

~~~go
	Bao secrets.Config
	// Step 11: what all tenants together did on a day (GET /stats/peers).
	// Each tenant adds at most StatsClamp jobs; StatsEpsilon 0
	// (STATS_EPSILON=off) publishes the totals without noise.
	StatsEpsilon    float64
	StatsClamp      int
	StatsMinTenants int
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	if cfg.AbandonAfter, err = envconfig.Duration(getenv, "ABANDON_AFTER", 2*time.Minute); err != nil {
		return config{}, err
	}
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
~~~

to:

~~~go
	if cfg.AbandonAfter, err = envconfig.Duration(getenv, "ABANDON_AFTER", 2*time.Minute); err != nil {
		return config{}, err
	}
	// How long a finished job's description is kept (Phase 6, step 11).
	if cfg.KeepDescriptions, err = envconfig.Duration(getenv, "DESCRIPTION_RETENTION", 30*24*time.Hour); err != nil {
		return config{}, err
	}
	cfg.StatsEpsilon = 1
	if v := getenv("STATS_EPSILON"); v == "off" {
		cfg.StatsEpsilon = 0
	} else if v != "" {
		if cfg.StatsEpsilon, err = strconv.ParseFloat(v, 64); err != nil || !(cfg.StatsEpsilon > 0) || math.IsInf(cfg.StatsEpsilon, 1) {
			return config{}, fmt.Errorf("STATS_EPSILON must be a positive number, or off, got %q", v)
		}
	}
	if cfg.StatsClamp, err = envconfig.PositiveInt(getenv, "STATS_CLAMP", 100); err != nil {
		return config{}, err
	}
	if cfg.StatsMinTenants, err = envconfig.PositiveInt(getenv, "STATS_MIN_TENANTS", 3); err != nil || cfg.StatsMinTenants < 3 {
		return config{}, fmt.Errorf("STATS_MIN_TENANTS must be 3 or more: the database adds up no fewer")
	}
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
	logger := redact.NewJSONLogger(stdout)
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	}
	if cfg.ServedBy != "" {
~~~

to:

~~~go
	}
	if store != nil {
		options = append(options, httpapi.WithPeerStats(&peerstats.Publisher{
			Store: store, MinTenants: cfg.StatsMinTenants, Clamp: cfg.StatsClamp, Epsilon: cfg.StatsEpsilon, Now: time.Now,
		}))
	}
	if cfg.ServedBy != "" {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		}},
	}
~~~

to:

~~~go
		}},
		// A copy may outlive this in the cache, for at most its FinishedTTL.
		{Name: "expire-descriptions", Every: time.Minute, Run: func(ctx context.Context) (int, error) {
			return store.ExpireDescriptions(ctx, time.Now().Add(-cfg.KeepDescriptions), 1000)
		}},
	}
~~~


The API's change also brings the retention task and the statistics endpoint, both below. The others are just the logger. In `cmd/auditfeed/main.go`:

Change:

<!-- edit: cmd/auditfeed/main.go -->
~~~go
	"runway/internal/messages"
	"runway/internal/secrets"
~~~

to:

~~~go
	"runway/internal/messages"
	"runway/internal/redact"
	"runway/internal/secrets"
~~~

Change:

<!-- edit: cmd/auditfeed/main.go -->
~~~go
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
	logger := redact.NewJSONLogger(stdout)
~~~


In `cmd/autoscaler/main.go`:

Change:

<!-- edit: cmd/autoscaler/main.go -->
~~~go
	"io"
	"log/slog"
~~~

to:

~~~go
	"io"
~~~

Change:

<!-- edit: cmd/autoscaler/main.go -->
~~~go
	"runway/internal/envconfig"
)
~~~

to:

~~~go
	"runway/internal/envconfig"
	"runway/internal/redact"
)
~~~

Change:

<!-- edit: cmd/autoscaler/main.go -->
~~~go
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
	logger := redact.NewJSONLogger(stdout)
~~~


In `cmd/gateway/main.go`:

Change:

<!-- edit: cmd/gateway/main.go -->
~~~go
	"io"
	"log/slog"
~~~

to:

~~~go
	"io"
~~~

Change:

<!-- edit: cmd/gateway/main.go -->
~~~go
	"runway/internal/pki"
)
~~~

to:

~~~go
	"runway/internal/pki"
	"runway/internal/redact"
)
~~~

Change:

<!-- edit: cmd/gateway/main.go -->
~~~go
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
	logger := redact.NewJSONLogger(stdout)
~~~


In `cmd/idp/main.go`:

Change:

<!-- edit: cmd/idp/main.go -->
~~~go
	"runway/internal/pki"
)
~~~

to:

~~~go
	"runway/internal/pki"
	"runway/internal/redact"
)
~~~

Change:

<!-- edit: cmd/idp/main.go -->
~~~go
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
	logger := redact.NewJSONLogger(stdout)
~~~


In `cmd/metad/main.go`:

Change:

<!-- edit: cmd/metad/main.go -->
~~~go
	"runway/internal/raft/raftnode"
)
~~~

to:

~~~go
	"runway/internal/raft/raftnode"
	"runway/internal/redact"
)
~~~

Change:

<!-- edit: cmd/metad/main.go -->
~~~go
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
	logger := redact.NewJSONLogger(stdout)
~~~


In `cmd/migrate/main.go`:

Change:

<!-- edit: cmd/migrate/main.go -->
~~~go
	"io"
	"log/slog"
~~~

to:

~~~go
	"io"
~~~

Change:

<!-- edit: cmd/migrate/main.go -->
~~~go
	"runway/internal/pki"
	"runway/internal/secrets"
~~~

to:

~~~go
	"runway/internal/pki"
	"runway/internal/redact"
	"runway/internal/secrets"
~~~

Change:

<!-- edit: cmd/migrate/main.go -->
~~~go
		logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
		logger := redact.NewJSONLogger(stdout)
~~~


In `cmd/notifier/main.go`:

Change:

<!-- edit: cmd/notifier/main.go -->
~~~go
	"io"
	"log/slog"
~~~

to:

~~~go
	"io"
~~~

Change:

<!-- edit: cmd/notifier/main.go -->
~~~go
	"runway/internal/rabbit"
	"runway/internal/retry"
~~~

to:

~~~go
	"runway/internal/rabbit"
	"runway/internal/redact"
	"runway/internal/retry"
~~~

Change:

<!-- edit: cmd/notifier/main.go -->
~~~go
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
	logger := redact.NewJSONLogger(stdout)
~~~


In `cmd/projector/main.go`:

Change:

<!-- edit: cmd/projector/main.go -->
~~~go
	"io"
	"log/slog"
~~~

to:

~~~go
	"io"
~~~

Change:

<!-- edit: cmd/projector/main.go -->
~~~go
	"runway/internal/projection"
	"runway/internal/stream"
~~~

to:

~~~go
	"runway/internal/projection"
	"runway/internal/redact"
	"runway/internal/stream"
~~~

Change:

<!-- edit: cmd/projector/main.go -->
~~~go
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
	logger := redact.NewJSONLogger(stdout)
~~~


In `cmd/tlsproxy/main.go`:

Change:

<!-- edit: cmd/tlsproxy/main.go -->
~~~go
	"io"
	"log/slog"
~~~

to:

~~~go
	"io"
~~~

Change:

<!-- edit: cmd/tlsproxy/main.go -->
~~~go
	"runway/internal/pki"
	"runway/internal/tlsproxy"
~~~

to:

~~~go
	"runway/internal/pki"
	"runway/internal/redact"
	"runway/internal/tlsproxy"
~~~

Change:

<!-- edit: cmd/tlsproxy/main.go -->
~~~go
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
	logger := redact.NewJSONLogger(stdout)
~~~


In `cmd/witness/main.go`:

Change:

<!-- edit: cmd/witness/main.go -->
~~~go
	"runway/internal/envconfig"
	"runway/internal/witness"
~~~

to:

~~~go
	"runway/internal/envconfig"
	"runway/internal/redact"
	"runway/internal/witness"
~~~

Change:

<!-- edit: cmd/witness/main.go -->
~~~go
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
	logger := redact.NewJSONLogger(stdout)
~~~


In `cmd/worker/main.go`:

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	"runway/internal/rabbit"
	"runway/internal/sqsbus"
~~~

to:

~~~go
	"runway/internal/rabbit"
	"runway/internal/redact"
	"runway/internal/sqsbus"
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
~~~

to:

~~~go
	logger := redact.NewJSONLogger(stdout)
~~~


(`hookcatcher` keeps its plain logger on purpose: it's the tenant's side, and it logs whole requests so you can replay one.)

### Traces

Spans pass through the OpenTelemetry collector on their way to Jaeger, which makes it the one place to scrub every service's spans, ours and our libraries'. The `transform` processor deletes the user agent and an IPv6 caller address, and cuts an IPv4 one to its /24 network: enough to see that requests came from one place, not enough to say who. The `redaction` processor masks any value shaped like an email address or a token, whatever its key. Both are in the collector's *contrib* image, not the core one. In `deploy/k8s/tracing.yaml`:

Change:

<!-- edit: deploy/k8s/tracing.yaml -->
~~~yaml
        spike_limit_percentage: 25
      batch: {}
~~~

to:

~~~yaml
        spike_limit_percentage: 25
      # Privacy (Phase 6, step 11). Spans keep what helps find a fault,
      # not who caused the request. The caller's address keeps its
      # network (/24), enough to see that requests came from one place;
      # an IPv6 one, and the user agent, which nothing here reads, go.
      # This is the one place every service's spans pass, ours and our
      # libraries' alike: otelhttp records both of these by itself.
      # ($$1 is the regexp's $1: the collector expands $ in its config.)
      transform/privacy:
        error_mode: ignore
        trace_statements:
          - context: span
            statements:
              - delete_key(attributes, "user_agent.original")
              - delete_key(attributes, "client.address") where IsMatch(attributes["client.address"], ":")
              - replace_pattern(attributes["client.address"], "^(\\d+\\.\\d+\\.\\d+)\\.\\d+$", "$$1.0")
      # The safety net, as internal/redact is for logs: any value shaped
      # like an email address or a token is masked, whatever its key.
      redaction/privacy:
        allow_all_keys: true
        blocked_values:
          - "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
          - "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*"
        summary: silent
      batch: {}
~~~

Change:

<!-- edit: deploy/k8s/tracing.yaml -->
~~~yaml
          processors: [memory_limiter, batch]
~~~

to:

~~~yaml
          processors: [memory_limiter, transform/privacy, redaction/privacy, batch]
~~~

Change:

<!-- edit: deploy/k8s/tracing.yaml -->
~~~yaml
        config-version: "1"
~~~

to:

~~~yaml
        config-version: "2"
~~~

Change:

<!-- edit: deploy/k8s/tracing.yaml -->
~~~yaml
          image: otel/opentelemetry-collector:0.162.0
~~~

to:

~~~yaml
          # contrib: the core image has no transform or redaction processor.
          image: otel/opentelemetry-collector-contrib:0.162.0
~~~


### Retention

A finished job keeps its ID, state and times, which history and the audit log refer to, and loses its description after a while. The API blanks them, in every tenant, which no tenant policy allows. Rather than grant it `UPDATE` on all jobs, it gets one function that does one thing. Create `internal/pgstore/migrations/0011_retention.sql`:

<!-- file: internal/pgstore/migrations/0011_retention.sql -->
~~~sql
-- +goose Up
-- A job's description is whatever its tenant typed: it may name people
-- (Phase 6, step 11). The worker needs it while the job runs; once the job
-- is finished, nothing does. Keep it for a while, so the tenant can still
-- read it, then blank it. The job itself stays: its ID, state and times
-- are what history and the audit log refer to.
ALTER TABLE jobs DROP CONSTRAINT jobs_description_check;
ALTER TABLE jobs ADD CONSTRAINT jobs_description_check CHECK (
    char_length(description) BETWEEN 1 AND 200
    OR (description = '' AND state IN ('completed', 'failed')));

-- The sweep reads only the finished jobs whose descriptions are still kept.
CREATE INDEX jobs_descriptions_kept ON jobs (updated_at)
    WHERE description <> '' AND state IN ('completed', 'failed');

-- The API blanks descriptions in every tenant, which no tenant policy
-- allows. Rather than grant it UPDATE on jobs, and a policy wide enough to
-- read them all, it gets this one function: it runs as its owner, which
-- policies skip, and does one thing.
-- +goose StatementBegin
CREATE FUNCTION expire_descriptions(finished_before timestamptz, max_rows int) RETURNS bigint
    LANGUAGE sql SECURITY DEFINER AS $$
    WITH expired AS (
        UPDATE jobs SET description = ''
        WHERE id IN (
            SELECT id FROM jobs
            WHERE description <> '' AND state IN ('completed', 'failed') AND updated_at < finished_before
            ORDER BY updated_at
            LIMIT max_rows)
        RETURNING 1)
    SELECT count(*) FROM expired
$$;
-- +goose StatementEnd
-- SECURITY DEFINER code must not find its tables through the caller's
-- search_path: the caller could put a jobs table of its own first. Even a
-- temporary one, which any role may create, and which is searched before
-- everything else unless the path says where. So pin the path: the schema
-- this migration runs in, then pg_temp, last.
-- +goose StatementBegin
DO $$
BEGIN
    EXECUTE format('ALTER FUNCTION expire_descriptions(timestamptz, int) SET search_path = %I, pg_temp', current_schema());
END
$$;
-- +goose StatementEnd
-- It runs as its owner, so the owner must be runway_owner, as in 0010:
-- not whoever ran the migrations, who may be a superuser.
ALTER FUNCTION expire_descriptions(timestamptz, int) OWNER TO runway_owner;
REVOKE ALL ON FUNCTION expire_descriptions(timestamptz, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION expire_descriptions(timestamptz, int) TO runway_api;

-- +goose Down
DROP FUNCTION expire_descriptions(timestamptz, int);
DROP INDEX jobs_descriptions_kept;
-- What was blanked is gone; the old rule needs some text there.
UPDATE jobs SET description = '(expired)' WHERE description = '';
ALTER TABLE jobs DROP CONSTRAINT jobs_description_check;
ALTER TABLE jobs ADD CONSTRAINT jobs_description_check CHECK (char_length(description) BETWEEN 1 AND 200);
~~~

`SECURITY DEFINER` makes the function run as its owner, which policies skip. That's powerful, and it has a classic hole. The function finds `jobs` through the *caller's* `search_path`, and any role can create a temporary table, which is searched first. A caller with its own temporary `jobs` would have the function act on that instead. So the migration pins the path: the schema it runs in, then `pg_temp`, last.

In `internal/pgstore/pgstore.go`:

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go

// History returns a job's events, oldest first.
~~~

to:

~~~go

// ExpireDescriptions blanks the descriptions of up to limit jobs that
// finished before before, in every tenant, oldest first, and reports how
// many (Phase 6, step 11). It calls expire_descriptions (migration 0011):
// the API's role may do that, and may not update jobs itself.
func (s *Store) ExpireDescriptions(ctx context.Context, before time.Time, limit int) (int, error) {
	var n int
	if err := s.pool.QueryRow(ctx, `SELECT expire_descriptions($1, $2)`, before, limit).Scan(&n); err != nil {
		return 0, fmt.Errorf("expire descriptions: %w", err)
	}
	return n, nil
}

// History returns a job's events, oldest first.
~~~


In `internal/pgstore/pgstore_test.go`, a test makes exactly that temporary table:

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go

// The second wall (Phase 6): even a query that forgets the tenant filter
~~~

to:

~~~go

// Descriptions of finished jobs are blanked once old enough, in every
// tenant; anything that may still run keeps its own (step 11).
func TestExpireDescriptionsOfOldFinishedJobs(t *testing.T) {
	store := New(asAPI(t))
	add := func(owner tenant.ID, at time.Time, finish bool) jobs.ID {
		ctx := tenant.With(context.Background(), owner)
		job, _ := jobs.New("call Alice back", time.Second, at)
		job, err := store.Create(ctx, job)
		if err != nil {
			t.Fatal(err)
		}
		_ = job.Start(at)
		if finish {
			_ = job.Complete(at)
		}
		if err := store.Update(ctx, job, jobs.StateQueued); err != nil {
			t.Fatal(err)
		}
		return job.ID
	}
	acmeOld := add("acme", t0, true)
	globexOld := add("globex", t0, true)
	recent := add("acme", t0.Add(2*time.Hour), true) // finished, but recently
	running := add("acme", t0, false)                // old, but not finished

	n, err := store.ExpireDescriptions(context.Background(), t0.Add(time.Hour), 10)
	if err != nil || n != 2 {
		t.Fatalf("expired %d, %v; want 2", n, err)
	}
	for _, c := range []struct {
		owner tenant.ID
		id    jobs.ID
		want  jobs.Description
	}{{"acme", acmeOld, ""}, {"globex", globexOld, ""}, {"acme", recent, "call Alice back"}, {"acme", running, "call Alice back"}} {
		job, err := store.Get(tenant.With(context.Background(), c.owner), c.id)
		if err != nil || job.Description != c.want {
			t.Errorf("job %d: description %q, %v; want %q", c.id, job.Description, err, c.want)
		}
	}
	if n, err := store.ExpireDescriptions(context.Background(), t0.Add(time.Hour), 10); err != nil || n != 0 {
		t.Fatalf("second sweep expired %d, %v; want 0", n, err)
	}
}

// expire_descriptions runs with its owner's rights, so it must not act on
// a table the caller chose. A temporary table is searched first, and any
// role may make one; the function's pinned search_path ignores it.
func TestExpireDescriptionsUsesOnlyItsOwnTables(t *testing.T) {
	ctx := context.Background()
	pool := asAPI(t)
	store := New(pool)
	job, _ := jobs.New("call Alice back", time.Second, t0)
	job, err := store.Create(acme, job)
	if err != nil {
		t.Fatal(err)
	}
	_ = job.Start(t0)
	_ = job.Complete(t0)
	if err := store.Update(acme, job, jobs.StateQueued); err != nil {
		t.Fatal(err)
	}

	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `CREATE TEMP TABLE jobs (id bigint, description text, state text, updated_at timestamptz)`); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := conn.QueryRow(ctx, `SELECT expire_descriptions($1, 10)`, t0.Add(time.Hour)).Scan(&n); err != nil || n != 1 {
		t.Fatalf("expired %d, %v; want the real job's 1", n, err)
	}
}

// The second wall (Phase 6): even a query that forgets the tenant filter
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
		`CREATE ROLE intruder LOGIN SUPERUSER`,
	} {
~~~

to:

~~~go
		`CREATE ROLE intruder LOGIN SUPERUSER`,
		`UPDATE jobs SET description = 'rewritten'`, // only expire_descriptions may (step 11)
	} {
~~~


**Break it.** In `0011_retention.sql`, replace the `ALTER FUNCTION ... SET search_path` statement with `NULL;`:

~~~text
--- FAIL: TestExpireDescriptionsUsesOnlyItsOwnTables (0.39s)
    pgstore_test.go:240: expired 0, ERROR: permission denied for table jobs (SQLSTATE 42501); want the real job's 1
~~~

The function went for the caller's temporary `jobs`. Here it failed only because its owner has no rights on someone else's temporary table. A function written to *read* would have read the attacker's rows, and believed them.

Dead letters need an end too. A RabbitMQ **policy** applies settings to every queue whose name matches, including ones declared later, and can be changed at any time (a queue's own arguments can't). Create `deploy/rabbitmq/policies.sh`:

<!-- file: deploy/rabbitmq/policies.sh -->
~~~bash
#!/usr/bin/env bash
# RabbitMQ policies (Phase 6, step 11). A policy applies settings to every
# queue whose name matches, including queues declared later, and can be
# changed at any time. A queue's own arguments can't: declare the same
# queue with different ones and RabbitMQ refuses (PRECONDITION_FAILED).
# The broker keeps policies on its volume, so run this once per cluster,
# and again after changing it.
#   deploy/rabbitmq/policies.sh [DEAD_LETTER_TTL]   (default 14d; also 1m, 6h)
set -euo pipefail
ttl=${1:-14d}
case $ttl in
  *d) ms=$(( ${ttl%d} * 86400000 )) ;;
  *h) ms=$(( ${ttl%h} * 3600000 )) ;;
  *m) ms=$(( ${ttl%m} * 60000 )) ;;
  *) echo "usage: $0 [TTL such as 14d, 6h or 1m]" >&2; exit 2 ;;
esac
rabbitmqctl() { kubectl -n runway exec rabbitmq-0 -- rabbitmqctl "$@"; }

# Dead letters are kept for a person to look at, and to replay. Not for
# ever: a dead RunJob command holds its job's description, which the
# database blanks after privacy.keepDescriptions (30 days). Keep them for
# less, so the queue isn't where it lives on.
#
# A quorum queue expires messages only from its head, and only those that
# arrived while a TTL applied. A message that came before this policy
# never expires, and every message behind it waits too (measured in step
# 11). So the first time, look at what the dead-letter queues hold, deal
# with it, and empty them: rabbitmqctl purge_queue NAME.
rabbitmqctl set_policy --apply-to queues --priority 1 dead-letters '\.dead$' "{\"message-ttl\": $ms}" >/dev/null
rabbitmqctl list_policies -q
rabbitmqctl list_queues -q name messages | awk 'NR == 1 || /\.dead\t/'
~~~

The smoke test sets it. In `deploy/smoke.sh`:

Change:

<!-- edit: deploy/smoke.sh -->
~~~bash
  kubectl -n runway rollout status "statefulset/$store" --timeout=300s
done

# OpenBao (step 9): unseal it, the first time initialising it, then set it
~~~

to:

~~~bash
  kubectl -n runway rollout status "statefulset/$store" --timeout=300s
done
# Dead letters don't stay for ever (step 11).
deploy/rabbitmq/policies.sh

# OpenBao (step 9): unseal it, the first time initialising it, then set it
~~~


### Statistics that don't give tenants away

Tenants want to compare themselves with everyone else: how many jobs did all tenants run yesterday, how many failed? Answering that safely takes three rules, one per way of attacking it. Create `internal/pgstore/migrations/0012_peer_stats.sql`:

<!-- file: internal/pgstore/migrations/0012_peer_stats.sql -->
~~~sql
-- +goose Up
-- What all tenants together did on a day (Phase 6, step 11): the numbers a
-- tenant compares its own with. No tenant policy lets the API add up every
-- tenant's jobs, so, as with expire_descriptions, it gets one function
-- that returns only totals. Each tenant adds at most clamp jobs to them:
-- that bounds how much any one tenant can move a total, which is what the
-- noise added later is measured against. And with fewer than three
-- tenants there are no totals at all, whatever the caller asks: a leaked
-- API login must not get one tenant's numbers by calling this directly.
-- +goose StatementBegin
CREATE FUNCTION day_totals(day_start timestamptz, clamp int)
    RETURNS TABLE (tenants bigint, jobs bigint, failed bigint)
    LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT count(*),
           CASE WHEN count(*) >= 3 THEN sum(least(n, greatest(clamp, 1))) END,
           CASE WHEN count(*) >= 3 THEN sum(least(f, greatest(clamp, 1))) END
    FROM (
        SELECT tenant, count(*) AS n, count(*) FILTER (WHERE state = 'failed') AS f
        FROM jobs
        WHERE created_at >= day_start AND created_at < day_start + interval '1 day'
        GROUP BY tenant) AS per_tenant
$$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$
BEGIN
    EXECUTE format('ALTER FUNCTION day_totals(timestamptz, int) SET search_path = %I, pg_temp', current_schema());
END
$$;
-- +goose StatementEnd
ALTER FUNCTION day_totals(timestamptz, int) OWNER TO runway_owner;
REVOKE ALL ON FUNCTION day_totals(timestamptz, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION day_totals(timestamptz, int) TO runway_api;

-- A day's numbers are published once, and kept: asked again, the answer
-- is the same, noise and all. Fresh noise for every request could be
-- averaged away by asking often enough.
CREATE TABLE peer_stats (
    day          date             PRIMARY KEY,
    suppressed   boolean          NOT NULL,
    jobs         bigint,
    failed       bigint,
    epsilon      double precision NOT NULL, -- 0: published without noise
    clamp        int              NOT NULL,
    published_at timestamptz      NOT NULL DEFAULT now()
);
ALTER TABLE peer_stats OWNER TO runway_owner;
GRANT SELECT, INSERT ON peer_stats TO runway_api;

-- +goose Down
DROP TABLE peer_stats;
DROP FUNCTION day_totals(timestamptz, int);
~~~

The database adds up only across three or more tenants, whatever the caller asks, so even a leaked API login can't get one tenant's numbers from it. It caps each tenant's contribution at `clamp`, which bounds how far one tenant can move a total. And a day is published once and kept: fresh noise for every request could be averaged away by asking often enough.

Create `internal/pgstore/peerstats.go`:

<!-- file: internal/pgstore/peerstats.go -->
~~~go
package pgstore

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"runway/internal/peerstats"
)

// The Store is a peerstats.Store (Phase 6, step 11), through the
// day_totals function and the peer_stats table (migration 0012).

func (s *Store) DayTotals(ctx context.Context, day time.Time, clamp int) (peerstats.Totals, error) {
	var t peerstats.Totals
	var jobs, failed *int64 // NULL: too few tenants to add up
	err := s.pool.QueryRow(ctx, `SELECT tenants, jobs, failed FROM day_totals($1, $2)`, day, clamp).Scan(&t.Tenants, &jobs, &failed)
	if err != nil {
		return t, fmt.Errorf("day totals: %w", err)
	}
	if jobs != nil && failed != nil {
		t.Jobs, t.Failed = *jobs, *failed
	}
	return t, nil
}

func (s *Store) PublishedDay(ctx context.Context, day time.Time) (peerstats.Published, bool, error) {
	p := peerstats.Published{Day: day}
	var jobs, failed *int64
	err := s.pool.QueryRow(ctx, `SELECT suppressed, jobs, failed, epsilon, clamp FROM peer_stats WHERE day = $1`, day).
		Scan(&p.Suppressed, &jobs, &failed, &p.Epsilon, &p.Clamp)
	if errors.Is(err, pgx.ErrNoRows) {
		return peerstats.Published{}, false, nil
	}
	if err != nil {
		return p, false, fmt.Errorf("published day: %w", err)
	}
	if jobs != nil && failed != nil {
		p.Jobs, p.Failed = *jobs, *failed
	}
	return p, true, nil
}

func (s *Store) PublishDay(ctx context.Context, p peerstats.Published) (peerstats.Published, error) {
	var jobs, failed *int64
	if !p.Suppressed {
		jobs, failed = &p.Jobs, &p.Failed
	}
	_, err := s.pool.Exec(ctx, `
		INSERT INTO peer_stats (day, suppressed, jobs, failed, epsilon, clamp) VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (day) DO NOTHING`, p.Day, p.Suppressed, jobs, failed, p.Epsilon, p.Clamp)
	if err != nil {
		return p, fmt.Errorf("publish day: %w", err)
	}
	kept, _, err := s.PublishedDay(ctx, p.Day)
	return kept, err
}
~~~

Create `internal/pgstore/peerstats_test.go`:

<!-- file: internal/pgstore/peerstats_test.go -->
~~~go
package pgstore

import (
	"context"
	"testing"
	"time"

	"runway/internal/jobs"
	"runway/internal/peerstats"
	"runway/internal/tenant"
)

// day_totals caps each tenant's jobs, and adds up nothing for fewer than
// three tenants, even when the API's own role calls it (step 11).
func TestDayTotals(t *testing.T) {
	store := New(asAPI(t))
	day := time.Date(2026, 10, 5, 0, 0, 0, 0, time.UTC)
	add := func(owner tenant.ID, at time.Time, n, failed int) {
		ctx := tenant.With(context.Background(), owner)
		for i := range n {
			job, _ := jobs.New("resize", time.Second, at)
			job, err := store.Create(ctx, job)
			if err != nil {
				t.Fatal(err)
			}
			if i < failed {
				_ = job.Start(at)
				_ = job.Fail("disk full", at)
				if err := store.Update(ctx, job, jobs.StateQueued); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	add("acme", day.Add(time.Hour), 25, 2) // over the clamp: counts as 20
	add("globex", day.Add(23*time.Hour), 3, 0)
	add("initech", day.Add(12*time.Hour), 1, 1)
	add("initech", day.Add(24*time.Hour), 7, 0) // the next day
	add("globex", day.Add(25*time.Hour), 1, 0)

	got, err := store.DayTotals(context.Background(), day, 20)
	if want := (peerstats.Totals{Tenants: 3, Jobs: 24, Failed: 3}); err != nil || got != want {
		t.Fatalf("day 1: %+v, %v; want %+v", got, err, want)
	}
	got, err = store.DayTotals(context.Background(), day.AddDate(0, 0, 1), 20)
	if want := (peerstats.Totals{Tenants: 2}); err != nil || got != want {
		t.Fatalf("day 2: %+v, %v; want %+v (two tenants: no totals)", got, err, want)
	}
}

func TestADayIsKeptAsFirstPublished(t *testing.T) {
	store := New(asAPI(t))
	day := time.Date(2026, 10, 5, 0, 0, 0, 0, time.UTC)
	first := peerstats.Published{Day: day, Jobs: 31, Failed: 4, Epsilon: 1, Clamp: 20}
	if got, err := store.PublishDay(context.Background(), first); err != nil || got != first {
		t.Fatalf("publish: %+v, %v", got, err)
	}
	second := peerstats.Published{Day: day, Jobs: 99, Failed: 0, Epsilon: 1, Clamp: 20}
	if got, err := store.PublishDay(context.Background(), second); err != nil || got != first {
		t.Fatalf("publish again: %+v, %v; want the first, %+v", got, err, first)
	}
	quiet := peerstats.Published{Day: day.AddDate(0, 0, 1), Suppressed: true, Epsilon: 1, Clamp: 20}
	if got, err := store.PublishDay(context.Background(), quiet); err != nil || got != quiet {
		t.Fatalf("suppressed: %+v, %v", got, err)
	}
}
~~~

The noise. Create `internal/peerstats/peerstats.go`:

<!-- file: internal/peerstats/peerstats.go -->
~~~go
// Package peerstats publishes what all tenants together did on a day: how
// many jobs they ran and how many failed (Phase 6, step 11). A tenant
// compares its own numbers with these. It must not learn from them what
// any other one tenant did.
//
// Three rules keep it from that, each against a different way of asking:
//
//   - A day with fewer than MinTenants tenants is not published at all. A
//     total of one tenant is that tenant.
//   - Each tenant adds at most Clamp jobs to a day, and the totals get
//     noise on that scale. Without noise, a tenant that controls all but
//     one of the others (accounts are cheap) subtracts its own numbers and
//     has the last one's exactly; the minimum alone can't stop that.
//   - A day is published once, after it ends, and never again: asking
//     again gets the same noise, so averaging many answers gains nothing.
//
// The noise is differential privacy's two-sided geometric mechanism: for
// any one tenant, the published numbers are about as likely with its jobs
// as without them, within a factor of e^Epsilon.
package peerstats

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"math"
	"time"
)

// Totals are a day's numbers as the database adds them up.
type Totals struct {
	Tenants      int64 // how many tenants ran jobs
	Jobs, Failed int64 // each tenant's counts capped at the clamp
}

// Published is what a day's numbers became.
type Published struct {
	Day          time.Time
	Suppressed   bool    // fewer than MinTenants tenants: no numbers
	Jobs, Failed int64   // with noise
	Epsilon      float64 // 0: published without noise
	Clamp        int
}

// Store is where totals come from and published days are kept.
type Store interface {
	DayTotals(ctx context.Context, day time.Time, clamp int) (Totals, error)
	PublishedDay(ctx context.Context, day time.Time) (Published, bool, error)
	// PublishDay keeps p unless the day was published already, and returns
	// whichever is kept: two instances publishing at once agree.
	PublishDay(ctx context.Context, p Published) (Published, error)
}

// ErrNotOver means the day hasn't ended yet, so its numbers would change.
var ErrNotOver = errors.New("that day is not over yet")

// Publisher publishes days.
type Publisher struct {
	Store      Store
	MinTenants int
	Clamp      int
	Epsilon    float64        // per day, shared by both counts; 0 adds no noise
	Uniform    func() float64 // in (0, 1]; crypto/rand when nil
	Now        func() time.Time
}

// Day returns the numbers for the UTC day that day falls in.
func (p *Publisher) Day(ctx context.Context, day time.Time) (Published, error) {
	y, m, d := day.UTC().Date()
	start := time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
	if p.Now().Before(start.AddDate(0, 0, 1)) {
		return Published{}, ErrNotOver
	}
	if pub, ok, err := p.Store.PublishedDay(ctx, start); err != nil || ok {
		return pub, err
	}
	totals, err := p.Store.DayTotals(ctx, start, p.Clamp)
	if err != nil {
		return Published{}, err
	}
	pub := Published{Day: start, Epsilon: p.Epsilon, Clamp: p.Clamp}
	if totals.Tenants < int64(max(p.MinTenants, 3)) { // the database won't add up fewer than 3 either
		pub.Suppressed = true
	} else {
		pub.Jobs, pub.Failed = p.noisy(totals.Jobs), p.noisy(totals.Failed)
		// Noise can put more failures than jobs. Fixing what was
		// published, using nothing but what was published, costs no
		// privacy (measured in step 11: 56 failed of 37).
		pub.Failed = min(pub.Failed, pub.Jobs)
	}
	return p.Store.PublishDay(ctx, pub)
}

// noisy adds two-sided geometric noise to n. One tenant moves each count
// by at most Clamp, and the two counts share the day's Epsilon, so each
// gets Epsilon/2: the noise's scale is Clamp/(Epsilon/2). Rounding and
// "never below zero" happen after the noise, and cost no privacy.
func (p *Publisher) noisy(n int64) int64 {
	if p.Epsilon == 0 {
		return n
	}
	uniform := p.Uniform
	if uniform == nil {
		uniform = cryptoUniform
	}
	// A geometric variable counts failures before a success that comes
	// with probability 1-q. The difference of two is the discrete Laplace.
	q := math.Exp(-(p.Epsilon / 2) / float64(p.Clamp))
	geometric := func() int64 { return int64(math.Floor(math.Log(uniform()) / math.Log(q))) }
	return max(0, n+geometric()-geometric())
}

// cryptoUniform is in (0, 1]. Noise that an observer could predict would
// be subtracted as easily as a tenant's own numbers.
func cryptoUniform() float64 {
	var b [8]byte
	_, _ = rand.Read(b[:]) // never fails (crypto/rand, Go 1.24 and later)
	return float64(binary.LittleEndian.Uint64(b[:])>>11+1) / (1 << 53)
}
~~~

It uses the **two-sided geometric mechanism**, the integer form of the Laplace mechanism, with randomness from `crypto/rand`: with a predictable generator, the noise could be subtracted. Each count's scale is `clamp / (epsilon / 2)`, because the two counts share the day's ε. Failures are capped at the jobs total after the noise: my first version published "56 failed of 37", which is not just nonsense but a hint about which way the noise went.

Create `internal/peerstats/peerstats_test.go`:

<!-- file: internal/peerstats/peerstats_test.go -->
~~~go
package peerstats

import (
	"context"
	"errors"
	"math"
	"testing"
	"time"
)

var now = time.Date(2026, 10, 15, 9, 0, 0, 0, time.UTC)

type fakeStore struct {
	totals    Totals
	published map[time.Time]Published
	sums      int // how often totals were added up
}

func (f *fakeStore) DayTotals(_ context.Context, _ time.Time, _ int) (Totals, error) {
	f.sums++
	return f.totals, nil
}

func (f *fakeStore) PublishedDay(_ context.Context, day time.Time) (Published, bool, error) {
	p, ok := f.published[day]
	return p, ok, nil
}

func (f *fakeStore) PublishDay(_ context.Context, p Published) (Published, error) {
	if old, ok := f.published[p.Day]; ok {
		return old, nil
	}
	f.published[p.Day] = p
	return p, nil
}

func publisher(store *fakeStore, epsilon float64) *Publisher {
	return &Publisher{Store: store, MinTenants: 3, Clamp: 20, Epsilon: epsilon, Now: func() time.Time { return now }}
}

func TestADayIsPublishedOnceAfterItEnds(t *testing.T) {
	store := &fakeStore{totals: Totals{Tenants: 4, Jobs: 50, Failed: 5}, published: map[time.Time]Published{}}
	p := publisher(store, 1)
	if _, err := p.Day(context.Background(), now); !errors.Is(err, ErrNotOver) {
		t.Fatalf("today: %v, want ErrNotOver", err)
	}
	yesterday := now.AddDate(0, 0, -1)
	first, err := p.Day(context.Background(), yesterday)
	if err != nil || first.Suppressed || !first.Day.Equal(time.Date(2026, 10, 14, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("got %+v, %v", first, err)
	}
	store.totals.Jobs = 1000 // the day's jobs can't change; if they did, it's too late
	for range 10 {
		again, _ := p.Day(context.Background(), yesterday.Add(5*time.Hour))
		if again != first {
			t.Fatalf("asked again: %+v, first %+v", again, first)
		}
	}
	if store.sums != 1 {
		t.Fatalf("totals added up %d times, want once", store.sums)
	}
}

func TestFewTenantsAreNotPublished(t *testing.T) {
	store := &fakeStore{totals: Totals{Tenants: 2, Jobs: 30, Failed: 3}, published: map[time.Time]Published{}}
	got, err := publisher(store, 0).Day(context.Background(), now.AddDate(0, 0, -1))
	if err != nil || !got.Suppressed || got.Jobs != 0 || got.Failed != 0 {
		t.Fatalf("got %+v, %v; want suppressed", got, err)
	}
}

// The noise is unbiased, and on the scale it claims: Clamp/(Epsilon/2).
// The two-sided geometric's variance is 2q/(1-q)^2.
func TestNoiseHasTheRightScale(t *testing.T) {
	p := publisher(nil, 1)
	const n, runs = 1000, 20000
	var sum, squares float64
	for range runs {
		d := float64(p.noisy(n) - n)
		sum += d
		squares += d * d
	}
	mean, variance := sum/runs, squares/runs
	q := math.Exp(-0.5 / 20)
	want := 2 * q / ((1 - q) * (1 - q))
	if math.Abs(mean) > 2 || math.Abs(variance-want)/want > 0.1 {
		t.Fatalf("mean %.2f, variance %.0f; want 0 and %.0f", mean, variance, want)
	}
}

func TestNoNoiseWithoutEpsilon(t *testing.T) {
	if got := publisher(nil, 0).noisy(42); got != 42 {
		t.Fatalf("got %d", got)
	}
}

func TestNoMoreFailuresThanJobs(t *testing.T) {
	store := &fakeStore{totals: Totals{Tenants: 4, Jobs: 30, Failed: 0}, published: map[time.Time]Published{}}
	p := publisher(store, 1)
	// Uniform draws: two for the jobs' noise (1, 1: none), two for the
	// failures' (0.001 then 1: a large positive draw).
	draws := []float64{1, 1, 0.001, 1}
	p.Uniform = func() float64 { u := draws[0]; draws = draws[1:]; return u }
	got, err := p.Day(context.Background(), now.AddDate(0, 0, -1))
	if err != nil || got.Jobs != 30 || got.Failed != 30 {
		t.Fatalf("got %+v, %v; want 30 jobs and failures capped at 30", got, err)
	}
}
~~~

The endpoint, for readers and admins. In `internal/authz/authz.go`:

Change:

<!-- edit: internal/authz/authz.go -->
~~~go
	ManageWebhooks Action = "webhooks.manage" // step 6
)
~~~

to:

~~~go
	ManageWebhooks Action = "webhooks.manage" // step 6
	ReadStats      Action = "stats.read"      // step 11
)
~~~

Change:

<!-- edit: internal/authz/authz.go -->
~~~go
	"reader":    {ReadJob},
	"admin":     {CreateJob, ReadJob, ManageWebhooks},
~~~

to:

~~~go
	"reader":    {ReadJob, ReadStats},
	"admin":     {CreateJob, ReadJob, ManageWebhooks, ReadStats},
~~~


In `internal/authz/authz_test.go`:

Change:

<!-- edit: internal/authz/authz_test.go -->
~~~go
		{"a submitter can't", as("submitter", "reader"), ManageWebhooks, false},
		{"no roles: nothing", as(), ReadJob, false},
~~~

to:

~~~go
		{"a submitter can't", as("submitter", "reader"), ManageWebhooks, false},
		{"a reader reads the peer statistics", as("reader"), ReadStats, true},
		{"a submitter alone doesn't", as("submitter"), ReadStats, false},
		{"no roles: nothing", as(), ReadJob, false},
~~~


Create `internal/httpapi/peerstats.go`:

<!-- file: internal/httpapi/peerstats.go -->
~~~go
package httpapi

import (
	"context"
	"errors"
	"net/http"
	"time"

	"runway/internal/peerstats"
)

// PeerStats is what GET /stats/peers needs: a peerstats.Publisher.
type PeerStats interface {
	Day(ctx context.Context, day time.Time) (peerstats.Published, error)
}

// WithPeerStats adds GET /stats/peers?day=YYYY-MM-DD (Phase 6, step 11):
// what all tenants together did that day, for a tenant to compare its own
// jobs with.
func WithPeerStats(stats PeerStats) Option {
	return func(c *config) { c.peerStats = stats }
}

type peerStatsResponse struct {
	Day string `json:"day"`
	// Suppressed: too few tenants that day to say anything.
	Suppressed bool   `json:"suppressed,omitempty"`
	Jobs       *int64 `json:"jobs,omitempty"`
	Failed     *int64 `json:"failed,omitempty"`
	// How the numbers were protected, so a reader knows how far to trust
	// them. Differential privacy doesn't depend on keeping this secret.
	Epsilon float64 `json:"epsilon"`
	Clamp   int     `json:"clamp"`
}

func (h *handlers) getPeerStats(stats PeerStats) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		day, err := time.Parse(time.DateOnly, r.URL.Query().Get("day"))
		if err != nil {
			writeError(w, http.StatusBadRequest, "day must be a date, such as 2026-10-14")
			return
		}
		p, err := stats.Day(r.Context(), day)
		switch {
		case errors.Is(err, peerstats.ErrNotOver):
			writeError(w, http.StatusNotFound, err.Error())
			return
		case err != nil:
			h.writeDomainError(w, r, err)
			return
		}
		resp := peerStatsResponse{Day: p.Day.Format(time.DateOnly), Suppressed: p.Suppressed, Epsilon: p.Epsilon, Clamp: p.Clamp}
		if !p.Suppressed {
			resp.Jobs, resp.Failed = &p.Jobs, &p.Failed
		}
		writeJSON(w, http.StatusOK, resp)
	}
}
~~~

In `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	webhooks       Webhooks
}
~~~

to:

~~~go
	webhooks       Webhooks
	peerStats      PeerStats
}
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
		mux.Handle("DELETE /webhook", protect(allow(authz.ManageWebhooks, h.deleteWebhook(hooks))))
	}
~~~

to:

~~~go
		mux.Handle("DELETE /webhook", protect(allow(authz.ManageWebhooks, h.deleteWebhook(hooks))))
	}
	if stats := cfg.peerStats; stats != nil {
		mux.Handle("GET /stats/peers", protect(allow(authz.ReadStats, h.getPeerStats(stats))))
	}
~~~


Create `internal/httpapi/peerstats_test.go`:

<!-- file: internal/httpapi/peerstats_test.go -->
~~~go
package httpapi

import (
	"context"
	"net/http"
	"testing"
	"time"

	"runway/internal/authz"
	"runway/internal/peerstats"
)

type fixedStats map[string]peerstats.Published

func (f fixedStats) Day(_ context.Context, day time.Time) (peerstats.Published, error) {
	p, ok := f[day.Format(time.DateOnly)]
	if !ok {
		return p, peerstats.ErrNotOver
	}
	return p, nil
}

func TestPeerStatsRoute(t *testing.T) {
	d1, d2 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC), time.Date(2026, 10, 14, 0, 0, 0, 0, time.UTC)
	h := newTestHandler(WithPeerStats(fixedStats{
		"2026-10-13": {Day: d1, Suppressed: true, Epsilon: 1, Clamp: 20},
		"2026-10-14": {Day: d2, Jobs: 31, Failed: 4, Epsilon: 1, Clamp: 20},
	}))
	for _, c := range []struct {
		path, want string
		code       int
	}{
		{"/stats/peers?day=2026-10-14", `{"day":"2026-10-14","jobs":31,"failed":4,"epsilon":1,"clamp":20}`, 200},
		{"/stats/peers?day=2026-10-13", `{"day":"2026-10-13","suppressed":true,"epsilon":1,"clamp":20}`, 200},
		{"/stats/peers?day=2026-10-15", `{"error":"that day is not over yet"}`, 404},
		{"/stats/peers?day=yesterday", `{"error":"day must be a date, such as 2026-10-14"}`, 400},
	} {
		got := do(t, h, http.MethodGet, c.path, "")
		if got.Code != c.code || got.Body.String() != c.want+"\n" {
			t.Errorf("GET %s = %d %s; want %d %s", c.path, got.Code, got.Body, c.code, c.want)
		}
	}
}

func TestPeerStatsAreAuthorized(t *testing.T) {
	var asked []authz.Action
	deny := func(_ context.Context, a authz.Action) error {
		asked = append(asked, a)
		return authz.ErrDenied
	}
	h := newTestHandler(WithPeerStats(fixedStats{}), WithAuthorizer(deny))
	if got := do(t, h, http.MethodGet, "/stats/peers?day=2026-10-14", ""); got.Code != http.StatusForbidden || len(asked) != 1 || asked[0] != authz.ReadStats {
		t.Fatalf("got %d, asked %v; want 403 after asking about %s", got.Code, asked, authz.ReadStats)
	}
}
~~~

And the chart. In `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
  tenants: {} # a different limit for some tenants, such as { acme: "50:100" }

~~~

to:

~~~yaml
  tenants: {} # a different limit for some tenants, such as { acme: "50:100" }

# Privacy (Phase 6, step 11).
privacy:
  # How long a finished job's description is kept. Then it is blanked:
  # it may name people, and nothing needs it once the job has run.
  keepDescriptions: 720h # 30 days
  # GET /stats/peers: what all tenants together did on a day. A day with
  # fewer than minTenants tenants isn't published. Each tenant adds at
  # most clamp jobs to the totals, which get noise of scale
  # clamp / (epsilon / 2): smaller epsilon, more noise, more privacy.
  # "off" publishes them exactly, which a tenant controlling all the
  # others but one can subtract its way through.
  stats:
    epsilon: "1"
    clamp: 100
    minTenants: 3

~~~


In `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        - { name: RATE_LIMIT_TENANTS, value: {{ join "," $tenants | quote }} }
        - { name: WEBHOOKS_ENABLED, value: {{ $root.Values.webhooks.enabled | quote }} }
~~~

to:

~~~yaml
        - { name: RATE_LIMIT_TENANTS, value: {{ join "," $tenants | quote }} }
        - { name: DESCRIPTION_RETENTION, value: {{ $root.Values.privacy.keepDescriptions | quote }} }
        - { name: STATS_EPSILON, value: {{ $root.Values.privacy.stats.epsilon | quote }} }
        - { name: STATS_CLAMP, value: {{ $root.Values.privacy.stats.clamp | quote }} }
        - { name: STATS_MIN_TENANTS, value: {{ $root.Values.privacy.stats.minTenants | quote }} }
        - { name: WEBHOOKS_ENABLED, value: {{ $root.Values.webhooks.enabled | quote }} }
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

### Run it

Rebuild and roll out, apply `deploy/k8s/tracing.yaml`, and run the canaries again:

~~~text
## Logs
{"msg":"webhook","result":"failed","tenant":"acme","error":"failed after 3 attempts: Post \"http://hookcatcher.partner:9999/hooks?[redacted]\": context deadline exceeded (Client.Timeout exceeded while awaiting headers)"}

## Traces
alice.canary@example.com: 0 attributes
hooksecret-canary-51b2: 0 attributes
# attributes that say who or where a caller is:
      2 client.address
      2 network.peer.address
      1 user_agent.original
# which spans, from where:
      2 api GET /jobs/{id}: client.address=172.18.0.0 user_agent=null
      2 api POST /jobs: client.address=172.18.0.0 user_agent=null
      1 api PUT /webhook: client.address=172.18.0.0 user_agent=null
# a careless span, sent straight to the collector with mail.to = the canary email:
{"name":"send email","attributes":{"mail.subject":"Your job finished","mail.to":"****"}}
~~~

The URL's query is gone from the log. Addresses end in `.0`, and the user agent is gone from Runway's spans. The one `user_agent.original` left belongs to Jaeger's own spans, which it records itself and never sends through the collector. And a span from an imaginary careless library, carrying the email in `mail.to`, was masked by shape on its way through.

**Retention, watched.** Set the dead letters to expire after a minute (`deploy/rabbitmq/policies.sh 1m`; normally `14d`), the descriptions to two minutes (`--set privacy.keepDescriptions=2m`), and make two jobs while acme's webhook still points at the closed port:

~~~text
$ psql -c "SELECT id, state, description, updated_at FROM jobs WHERE id IN (19, 20)"
 id |   state   |                description                |          updated_at           
----+-----------+-------------------------------------------+-------------------------------
 19 | completed | Call Alice back: alice.canary@example.com | 2026-10-15 15:11:14.938347+00
 20 | completed | Call Bob back: bob.canary@example.com     | 2026-10-15 15:11:15.006191+00
# 15:12:32: the notifier gave up (5 deliveries of 3 tries each)
webhooks.deliveries.dead	dead-letters	2
# a few minutes later
{"time":"15:13:46","msg":"background task done","task":"expire-descriptions","items":2}
# 15:13:50: the dead letters are gone
 19 | completed |             | 2026-10-15 15:11:14.938347+00
 20 | completed |             | 2026-10-15 15:11:15.006191+00
webhooks.deliveries.dead	dead-letters	0
# through the API:
{"id":19,"state":"completed","description":"Call Alice back: alice.canary@example.com"}
{"id":20,"state":"completed","description":""}
~~~

Both descriptions blanked in the database, and both dead letters expired. But look at job 19 through the API: its description is still there. The dashboard read job 19 earlier, so a copy sits in Redis, and Redis keeps finished jobs for up to an hour (Phase 3's `FinishedTTL`). Retention is only as short as the longest-lived copy. Here that's an honest, bounded hour, and the README of a real product would say so.

**Break it: old dead letters.** RabbitMQ quorum queues expire messages only from the head of the queue, and only those that arrived while a TTL applied. A message from *before* the policy never expires, and everything behind it waits:

~~~text
policy message-ttl 5 s set; probe1 holds an older message, probe2 doesn't
t+0s: probe1.dead 2 messages, probe2.dead 0
t+10s: probe1.dead 2 messages, probe2.dead 0
t+20s: probe1.dead 2 messages, probe2.dead 0
# take probe1's oldest message off the head (as someone inspecting dead letters would)
10 s later: probe1.dead 0 messages
~~~

(I measured it in Compose, with two scratch queues.) So the first time you set the policy, look at what the dead-letter queues hold, deal with it, and purge them.

**Statistics, attacked.** To see days end, I moved jobs back to past days with the owner's `psql`, and set `--set privacy.stats.clamp=20` so the numbers are small. Acme also runs initech and hooli, as an attacker with three cheap accounts would:

~~~text
    day     | tenant  | count 
------------+---------+-------
 2026-10-06 | acme    |     6
 2026-10-06 | globex  |     9
 2026-10-07 | acme    |    12
 2026-10-07 | globex  |     9
 2026-10-07 | hooli   |     4
 2026-10-07 | initech |     5
 2026-10-08 | acme    |    12
 2026-10-08 | globex  |     9
 2026-10-08 | hooli   |     4
 2026-10-08 | initech |     5
~~~

~~~bash
curl -s "localhost:8000/stats/peers?day=2026-10-06" -H "Authorization: Bearer $ACME"   # two tenants
curl -s "localhost:8000/stats/peers?day=2026-10-15" -H "Authorization: Bearer $ACME"   # today
~~~

~~~text
{"day":"2026-10-06","suppressed":true,"epsilon":0,"clamp":20}
{"error":"that day is not over yet"}
~~~

With noise off (`--set privacy.stats.epsilon=off`), the attack:

~~~text
$ curl localhost:8000/stats/peers?day=2026-10-07   # as acme
{"day":"2026-10-07","jobs":30,"failed":0,"epsilon":0,"clamp":20}
acme subtracts what it knows: 30 - 12 (acme) - 5 (initech) - 4 (hooli) = 9: globex's jobs on 2026-10-07
~~~

Four tenants, past the threshold, and globex's exact number in one subtraction. The threshold alone protects nobody against a tenant that controls the rest. Now with `epsilon=1`:

~~~text
$ curl localhost:8000/stats/peers?day=2026-10-08   # as acme, three times, then as globex
{"day":"2026-10-08","jobs":0,"failed":0,"epsilon":1,"clamp":20}
{"day":"2026-10-08","jobs":0,"failed":0,"epsilon":1,"clamp":20}
{"day":"2026-10-08","jobs":0,"failed":0,"epsilon":1,"clamp":20}
{"day":"2026-10-08","jobs":0,"failed":0,"epsilon":1,"clamp":20}
acme subtracts again: 0 - 21 = -21; globex ran 9. The noise's scale: clamp/(epsilon/2) = 20/0.5 = 40 jobs
~~~

The attack learns nothing: -21 jobs. And the same answer every time, for everyone, so asking again gains nothing. But be honest about the other side: the *true* total was 30, and the published one is 0. With four tenants and a scale of 40 jobs, the noise swamps the signal. Differential privacy is a trade, and on small numbers it's mostly noise. It becomes useful with many tenants, where 40 jobs is a rounding error.

**Break it: a rollout that publishes too early.** This one I didn't plan. The first time I switched ε on, I asked for a new day right after `helm upgrade` returned:

~~~text
$ helm upgrade ... --set privacy.stats.epsilon=1
$ curl localhost:8000/stats/peers?day=2026-10-11   # as acme, three times, then as globex
{"day":"2026-10-11","jobs":30,"failed":0,"epsilon":0,"clamp":20}
~~~

No noise. `helm upgrade --wait` returns when the *new* Pods are ready, but old Pods, still draining, kept answering on the gateway's open connections, and one of them published the day under the old setting. Publish-once then kept that answer for good. The response's `epsilon` field is what exposed it. A privacy setting is only in force when *every* instance has it. Wait for the old Pods to be gone before relying on it, or make publication a job that runs once, from one place.

**Explain it:** why plant canaries instead of reading the code? Which findings came from code nobody wrote (errors, libraries)? Why does redaction come second to not logging? What's the `search_path` attack on a `SECURITY DEFINER` function? Why does a threshold fail against differencing, and what does the noise cost? Why publish each day once?

**Read.** The GDPR's Article 5 (the principles: minimisation, storage limitation) and Article 25 (data protection by design): one page each. Then Cynthia Dwork and Aaron Roth, *The Algorithmic Foundations of Differential Privacy*, chapters 1–3. Then Ilya Mironov, *On Significance of the Least Significant Bits for Differential Privacy* (CCS 2012): why floating-point noise can leak, and why this step's noise is integers. Then the PostgreSQL documentation, *Writing SECURITY DEFINER Functions Safely*.

---
## Step 12: Cluster hardening

**The problem.** Each step so far protected one door. The cluster underneath still lets anything talk to anything. A Pod in a namespace of its own, standing in for a compromised dependency or a teammate's test Pod, can open a connection to every port Runway has (T6). Nothing stops a Pod from running as root (T14). And most Pods carry a token for the Kubernetes API that they never use (T13). Look first. Make the foothold:

~~~bash
kubectl create namespace np-test
kubectl -n np-test run probe --image=curlimages/curl:8.17.0 --restart=Never --command -- sleep 86400
tcp() { if kubectl -n np-test exec probe -- nc -z -w 3 $1 $2 2>/dev/null; then echo open; else echo closed; fi; }
for t in postgres.runway:5432 rabbitmq.runway:5672 rabbitmq.runway:15672 bao.runway:8200 redis.runway:6380 metad.runway:7001 \
         api-pods.runway:8080 idp.runway:8081 gateway.runway:8000 gateway.runway:8001 prometheus.observability:9090 \
         grafana.observability:3000 jaeger.observability:16686 otel-collector.observability:4318; do
  printf '%-36s %s\n' $t $(tcp ${t%:*} ${t#*:})
done
~~~

~~~text
postgres.runway:5432                 open
rabbitmq.runway:5672                 open
rabbitmq.runway:15672                open
bao.runway:8200                      open
redis.runway:6380                    open
metad.runway:7001                    open
api-pods.runway:8080                 open
idp.runway:8081                      open
gateway.runway:8000                  open
gateway.runway:8001                  open
prometheus.observability:9090        open
grafana.observability:3000           open
jaeger.observability:16686           open
otel-collector.observability:4318    open
~~~

Every port is open. Mutual TLS (steps 7 to 9) means most of them refuse to *talk* without the right certificate, but "can connect" is the first step of every attack on the server behind a port. And some don't need a certificate at all:

~~~text
$ curl prometheus.observability:9090/api/v1/query?query=count by (job) (up)
{"status":"success","data":{"resultType":"vector","result":[{"metric":{"job":"worker"},"value":[1792148703.491,"2"]},{"metric":{"job":"rabbitmq"},...
$ curl grafana.observability:3000/api/datasources   # an admin-only API
200
$ curl jaeger.observability:16686/api/v3/services
{"services":["jaeger","api","worker","mailer"]}
$ curl -X POST otel-collector.observability:4318/v1/traces -d <a made-up span>
200
~~~

Prometheus maps the whole system for an attacker, Grafana hands out its administrator's API to anonymous visitors (T17), Jaeger lists every service, and the collector accepts forged spans. From *inside* an API Pod (`kubectl debug` adds an ephemeral container that shares its network), the API server and the internet are reachable too. And Pod Security:

~~~text
$ kubectl label --dry-run=server --overwrite ns runway pod-security.kubernetes.io/enforce=restricted
existing pods in namespace "runway" violate the new PodSecurity enforce level "restricted:latest"
api-5955d59f75-jckwb (and 13 other pods): seccompProfile
postgres-0 (and 4 other pods): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
~~~

And tokens: the gateway, the workers, `metad`, PostgreSQL and RabbitMQ each mount a token for the default service account. The default account can do little, but a token that isn't there can't be stolen, and the cluster's defaults can change.

**New ideas.**

- **NetworkPolicy** is a firewall per Pod, written as labels. Once any policy selects a Pod for a direction (ingress or egress), only what some policy allows gets through in that direction. The usual design: **default deny** for the whole namespace, then one policy per component saying exactly who may reach it and where it may go. The network plugin enforces it; I measured that kind's own plugin, kindnet, does.
- **Defence in depth, literally.** mTLS asks "who are you?" at the handshake. Network policy asks "may you even connect?" before that. A mistake in one (step 8's forgotten `--bind`) is caught by the other.
- **Pod Security Standards.** `privileged`, `baseline` and `restricted` are three levels of what a Pod may ask for. A namespace label makes the API server refuse Pods above the level. `restricted` means: not root, no privilege escalation, every capability dropped, and a seccomp profile (a filter on which system calls a process may make).
- **Service-account tokens.** Every Pod gets one unless told otherwise. Turn the default off, and give one only to Pods that call the Kubernetes API (the autoscaler, OpenBao's token reviews), with RBAC limited to what they call.
- **Fuzzing.** A fuzzer feeds a function random inputs, mutated from seeds toward new code paths, and reports any that break a property you state. Parsers of untrusted input (tokens, webhook headers, config strings, files) are where it pays.

### Default deny, and DNS

In `deploy/k8s/config.yaml`, the namespace enforces `restricted`, the default service account stops handing out tokens, and every Pod starts with no traffic at all, except DNS:

Change:

<!-- edit: deploy/k8s/config.yaml -->
~~~yaml
  name: runway
---
~~~

to:

~~~yaml
  name: runway
  # Pod Security (step 12): refuse any Pod that runs as root, may gain
  # privileges, keeps capabilities, or has no seccomp profile.
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
---
# Every Pod without a service account of its own gets "default", and with
# it, a token for the Kubernetes API (step 12's "before": the gateway, the
# workers, metad, PostgreSQL and RabbitMQ all had one, and used none). Off
# unless a Pod asks for it.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: runway
automountServiceAccountToken: false
---
# Network policy (step 12). Every Pod in the namespace starts with no
# traffic at all, in or out. Each component's manifest (or the chart)
# then says who may reach it and where it may go: postgres.yaml, for one,
# admits the API, the notifier, the migration and OpenBao, and nobody else.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: runway
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
# Except names: every Pod may ask the cluster's DNS.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dns
  namespace: runway
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
---
~~~


DNS is its own policy for a reason found the hard way, below. Each store's manifest then says who may reach it, and only that, and its Pod meets `restricted`. In `deploy/k8s/postgres.yaml`:

Change:

<!-- edit: deploy/k8s/postgres.yaml -->
~~~yaml
    spec:
      containers:
~~~

to:

~~~yaml
    spec:
      # Pod Security "restricted" (step 12): not root. The image's postgres
      # user (999) owns the data; no fsGroup, whose recursive group change
      # would make it group-writable, which PostgreSQL refuses to start on.
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        seccompProfile: { type: RuntimeDefault }
      automountServiceAccountToken: false
      containers:
~~~

Change:

<!-- edit: deploy/k8s/postgres.yaml -->
~~~yaml
            limits: { memory: 512Mi }
          volumeMounts:
~~~

to:

~~~yaml
            limits: { memory: 512Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          volumeMounts:
~~~

At the end of the file, change:

<!-- edit: deploy/k8s/postgres.yaml -->
~~~yaml
    - { name: postgres, port: 5432, targetPort: postgres }
~~~

to:

~~~yaml
    - { name: postgres, port: 5432, targetPort: postgres }
---
# Who may reach the database (step 12): the services that use it, the
# migration, and OpenBao, which makes and drops their logins. Going out,
# it has config.yaml's default: nothing but DNS.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres
  namespace: runway
spec:
  podSelector: { matchLabels: { app: postgres } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app: api } }
        - podSelector: { matchLabels: { app: notifier } }
        - podSelector: { matchLabels: { app: migrate } }
        - podSelector: { matchLabels: { app: bao } }
      ports: [{ port: 5432 }]
~~~


PostgreSQL's image starts as root and switches to its own user. Under `restricted` it must start as that user (999), and *without* `fsGroup`: PostgreSQL refuses a data directory that other members of its group can write to, which is what `fsGroup` makes it. In `deploy/k8s/rabbitmq.yaml`:

Change:

<!-- edit: deploy/k8s/rabbitmq.yaml -->
~~~yaml
        fsGroup: 999
      containers:
~~~

to:

~~~yaml
        fsGroup: 999
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault } # step 12
      automountServiceAccountToken: false
      containers:
~~~

Change:

<!-- edit: deploy/k8s/rabbitmq.yaml -->
~~~yaml
            limits: { memory: 512Mi }
          volumeMounts:
~~~

to:

~~~yaml
            limits: { memory: 512Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          volumeMounts:
~~~

At the end of the file, change:

<!-- edit: deploy/k8s/rabbitmq.yaml -->
~~~yaml
    - { name: prometheus, port: 15692, targetPort: prometheus }
~~~

to:

~~~yaml
    - { name: prometheus, port: 15692, targetPort: prometheus }
---
# AMQP for the services; the management API for the autoscaler, which
# reads queue depths there; metrics for Prometheus (step 12).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rabbitmq
  namespace: runway
spec:
  podSelector: { matchLabels: { app: rabbitmq } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app: api } }
        - podSelector: { matchLabels: { app: worker } }
        - podSelector: { matchLabels: { app: notifier } }
      ports: [{ port: 5672 }]
    - from:
        - podSelector: { matchLabels: { app: autoscaler } }
      ports: [{ port: 15672 }]
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: observability } }
          podSelector: { matchLabels: { app: prometheus } }
      ports: [{ port: 15692 }]
~~~


In `deploy/k8s/redis.yaml`:

Change:

<!-- edit: deploy/k8s/redis.yaml -->
~~~yaml
        fsGroup: 65532 # the sidecar's group, so it can read its certificate
      automountServiceAccountToken: false
~~~

to:

~~~yaml
        fsGroup: 65532 # the sidecar's group, so it can read its certificate
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault } # step 12
      automountServiceAccountToken: false
~~~

Change:

<!-- edit: deploy/k8s/redis.yaml -->
~~~yaml
            limits: { memory: 128Mi }
      volumes:
~~~

to:

~~~yaml
            limits: { memory: 128Mi }
          securityContext:
            runAsUser: 999 # the image's redis user
            runAsGroup: 999
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
      volumes:
~~~

At the end of the file, change:

<!-- edit: deploy/k8s/redis.yaml -->
~~~yaml
    - { name: tls, port: 6380, targetPort: tls }
~~~

to:

~~~yaml
    - { name: tls, port: 6380, targetPort: tls }
---
# Only the API, through the sidecar's port; and its metrics (step 12).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: redis
  namespace: runway
spec:
  podSelector: { matchLabels: { app: redis } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app: api } }
      ports: [{ port: 6380 }]
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: observability } }
          podSelector: { matchLabels: { app: prometheus } }
      ports: [{ port: 9901 }]
~~~


OpenBao also needs to *send*: to PostgreSQL (its database engine) and to the Kubernetes API server (token reviews). In `deploy/k8s/bao.yaml`:

Change:

<!-- edit: deploy/k8s/bao.yaml -->
~~~yaml
        fsGroup: 1000 # its data volume; and every container's extra group, so the sidecar can read its certificate
      initContainers:
~~~

to:

~~~yaml
        fsGroup: 1000 # its data volume; and every container's extra group, so the sidecar can read its certificate
        seccompProfile: { type: RuntimeDefault } # step 12
      initContainers:
~~~

At the end of the file, change:

<!-- edit: deploy/k8s/bao.yaml -->
~~~yaml
    - { name: https, port: 8200, targetPort: https }
~~~

to:

~~~yaml
    - { name: https, port: 8200, targetPort: https }
---
# OpenBao (step 12): reached by the services that log in or seal webhook
# secrets, and the migration; its sidecar's metrics by Prometheus. It goes
# out to PostgreSQL, where it makes and drops logins, and to the Kubernetes
# API, to check the service-account tokens it is shown (TokenReview). The
# API server isn't a Pod: on kind it listens on the nodes' network, port
# 6443. On another cluster: kubectl get endpointslice -n default -l
# kubernetes.io/service-name=kubernetes.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: bao
  namespace: runway
spec:
  podSelector: { matchLabels: { app: bao } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app: api } }
        - podSelector: { matchLabels: { app: notifier } }
        - podSelector: { matchLabels: { app: migrate } }
      ports: [{ port: 8200 }]
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: observability } }
          podSelector: { matchLabels: { app: prometheus } }
      ports: [{ port: 9901 }]
  egress:
    - to:
        - podSelector: { matchLabels: { app: postgres } }
      ports: [{ port: 5432 }]
    - to:
        - ipBlock: { cidr: 172.18.0.0/16 } # kind's node network
      ports: [{ port: 6443 }]
~~~


Look at the API server rule: an `ipBlock` for the *nodes'* network, port 6443, not the Service address `10.96.0.1:443` that Pods dial. kindnet evaluates policies after the Service's address has been translated to the real one (DNAT), so a rule for the Service address matches nothing. I found that by watching OpenBao's token reviews time out.

### The app tier

The chart writes one policy per component. Create `deploy/helm/runway/templates/networkpolicy.yaml`:

<!-- file: deploy/helm/runway/templates/networkpolicy.yaml -->
~~~yaml
{{- /*
Network policy for the app tier (Phase 6, step 12). deploy/k8s/config.yaml
denies all traffic in the namespace, apart from DNS; each policy here lets
one component's Pods receive from, and send to, exactly what they use.
The stores' manifests say who may reach the stores.
*/ -}}
{{- if .Values.networkPolicy.enabled }}
{{- $nodes := .Values.networkPolicy.nodeCIDR }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  podSelector: { matchLabels: { app: api } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app: gateway } }
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: observability } }
          podSelector: { matchLabels: { app: prometheus } }
      ports: [{ port: 8080 }]
    # The NodePorts (step 4), for operators with a client certificate:
    # that traffic arrives from a node's address.
    - from:
        - ipBlock: { cidr: {{ $nodes }} }
      ports: [{ port: 8080 }, { port: 9090 }]
  egress:
    - to: [{ podSelector: { matchLabels: { app: postgres } } }]
      ports: [{ port: 5432 }]
    - to: [{ podSelector: { matchLabels: { app: rabbitmq } } }]
      ports: [{ port: 5672 }]
    - to: [{ podSelector: { matchLabels: { app: bao } } }]
      ports: [{ port: 8200 }]
    - to: [{ podSelector: { matchLabels: { app: idp } } }] # the issuer's keys
      ports: [{ port: 8081 }]
    - to: [{ podSelector: { matchLabels: { app: redis } } }] # through the sidecars
      ports: [{ port: 6380 }]
    {{- include "runway.toCollector" . | nindent 4 }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: gateway
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  podSelector: { matchLabels: { app: gateway } }
  policyTypes: [Ingress, Egress]
  ingress:
    - ports: [{ port: 8000 }] # the front door: from anywhere
    {{- include "runway.fromPrometheus" 8001 | nindent 4 }}
  egress:
    - to: [{ podSelector: { matchLabels: { app: api } } }]
      ports: [{ port: 8080 }]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: worker
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  podSelector: { matchLabels: { app: worker } }
  policyTypes: [Ingress, Egress]
  ingress:
    {{- include "runway.fromPrometheus" 9100 | nindent 4 }}
  egress:
    - to: [{ podSelector: { matchLabels: { app: rabbitmq } } }]
      ports: [{ port: 5672 }]
    {{- include "runway.toCollector" . | nindent 4 }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: notifier
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  podSelector: { matchLabels: { app: notifier } }
  policyTypes: [Ingress, Egress]
  ingress:
    {{- include "runway.fromPrometheus" 8082 | nindent 4 }}
  egress:
    - to: [{ podSelector: { matchLabels: { app: postgres } } }]
      ports: [{ port: 5432 }]
    - to: [{ podSelector: { matchLabels: { app: rabbitmq } } }]
      ports: [{ port: 5672 }]
    - to: [{ podSelector: { matchLabels: { app: bao } } }]
      ports: [{ port: 8200 }]
    # Webhooks go to tenants' servers: the internet, and nothing private.
    # The same rule as webhook.Policy's (step 6), now also below the code,
    # where a bug in it can't reach.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 127.0.0.0/8]
    {{- range .Values.networkPolicy.webhookNamespaces }}
    # webhooks.allowHosts lets it post here too.
    - to: [{ namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: {{ . }} } } }]
    {{- end }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: idp
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  podSelector: { matchLabels: { app: idp } }
  policyTypes: [Ingress, Egress]
  ingress:
    # The API fetches its keys. Clients asking for tokens would come
    # through an ingress; on kind, through kubectl port-forward.
    - from: [{ podSelector: { matchLabels: { app: api } } }]
      ports: [{ port: 8081 }]
  egress: [] # it calls nothing
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: autoscaler
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  podSelector: { matchLabels: { app: autoscaler } }
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
    - to: [{ podSelector: { matchLabels: { app: rabbitmq } } }] # queue depths
      ports: [{ port: 15672 }]
    - to: [{ ipBlock: { cidr: {{ $nodes }} } }] # the Kubernetes API, to scale workers
      ports: [{ port: 6443 }]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: metad
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  podSelector: { matchLabels: { app: metad } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from: [{ podSelector: { matchLabels: { app: metad } } }] # Raft, among members
      ports: [{ port: 7001 }]
  egress:
    - to: [{ podSelector: { matchLabels: { app: metad } } }]
      ports: [{ port: 7001 }]
---
# The migration runs as a hook, before Helm creates anything else in the
# release, this file's other policies included. So its policy is a hook
# too, made just before it; and kept, for the next upgrade's migration.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: migrate
  labels:
    {{- include "runway.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-2"
    "helm.sh/hook-delete-policy": before-hook-creation
spec:
  podSelector: { matchLabels: { app: migrate } }
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
    - to: [{ podSelector: { matchLabels: { app: postgres } } }]
      ports: [{ port: 5432 }]
    - to: [{ podSelector: { matchLabels: { app: bao } } }] # its login
      ports: [{ port: 8200 }]
{{- end }}
~~~

A few rules deserve a second look:
- **The notifier** may reach the internet, *except* private address ranges: webhooks go to tenants' servers (step 6), and nothing inside the cluster is one, except the namespaces listed in `webhookNamespaces` (the demo receiver's `partner`). Step 6's dial-time check, and now the network itself, both say no to `redis-0`.
- **The NodePort rule** lets the API take connections from the nodes' addresses: that's where operators' traffic through a NodePort comes from. The kubelet's probes come from the node too, which is why they work under default-deny.
- **The migration's policy is a Helm hook**, with a lower weight than the migration Job. Ordinary resources are created *after* pre-install hooks run, so as an ordinary resource it wouldn't exist yet when the migration needed it.

The helpers for "Prometheus may scrape this port" and "this Pod may send spans", and the Pods without a use for a Kubernetes token losing theirs. In `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
{{/* Locked down as in step 1: no root, no new privileges, no writes. */}}
~~~

to:

~~~yaml
{{/*
Locked down as in step 1: no root, no new privileges, no writes. And
(step 12) only the system calls the container runtime's default seccomp
profile allows: what Pod Security's "restricted" level requires.
*/}}
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
  capabilities: { drop: [ALL] }
{{- end }}
~~~

to:

~~~yaml
  capabilities: { drop: [ALL] }
  seccompProfile: { type: RuntimeDefault }
{{- end }}
~~~

Add this at the end of the file:

<!-- append: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
{{/* Network policy rules (step 12): Prometheus may scrape this port. */}}
{{- define "runway.fromPrometheus" -}}
- from:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: observability } }
      podSelector: { matchLabels: { app: prometheus } }
  ports: [{ port: {{ . }} }]
{{- end }}

{{/* ...and spans may go to the collector (Phase 5, step 9). */}}
{{- define "runway.toCollector" -}}
- to:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: observability } }
      podSelector: { matchLabels: { app: otel-collector } }
  ports: [{ port: 4318 }]
{{- end }}
~~~


In `deploy/helm/runway/templates/gateway.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/gateway.yaml -->
~~~yaml
        fsGroup: 65532
      containers:
~~~

to:

~~~yaml
        fsGroup: 65532
      automountServiceAccountToken: false # it never calls the Kubernetes API (step 12)
      containers:
~~~


In `deploy/helm/runway/templates/metad.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/metad.yaml -->
~~~yaml
        fsGroup: 65532
      affinity:
~~~

to:

~~~yaml
        fsGroup: 65532
      automountServiceAccountToken: false # it never calls the Kubernetes API (step 12)
      affinity:
~~~


In `deploy/helm/runway/templates/worker.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/worker.yaml -->
~~~yaml
        runAsNonRoot: true
      containers:
~~~

to:

~~~yaml
        runAsNonRoot: true
      automountServiceAccountToken: false # it never calls the Kubernetes API (step 12)
      containers:
~~~


In `deploy/helm/runway/values.yaml`:

Add this at the end of the file:

<!-- append: deploy/helm/runway/values.yaml -->
~~~yaml
# Network policy for the app tier (Phase 6, step 12); deploy/k8s/config.yaml
# denies everything else. The API server, the kubelets and NodePort traffic
# aren't Pods, so they are named by address: kind's node network here. On
# another cluster, see kubectl get nodes -o wide.
networkPolicy:
  enabled: true
  nodeCIDR: 172.18.0.0/16
  # Namespaces the notifier may post webhooks into, besides the internet:
  # the in-cluster receivers that webhooks.allowHosts names.
  webhookNamespaces: []
~~~


### Observability and the partner

The observability namespace gets the same treatment: default deny, and each component reachable only by what uses it. Grafana's anonymous visitors become viewers. Images whose user is a *name* (Prometheus's is `nobody`) fail `runAsNonRoot`, because the kubelet can't check that a name isn't root without the image's files, so they get numeric users. In `deploy/k8s/monitoring.yaml`:

Change:

<!-- edit: deploy/k8s/monitoring.yaml -->
~~~yaml
      serviceAccountName: prometheus
~~~

to:

~~~yaml
      serviceAccountName: prometheus # its token finds and scrapes targets
      # Pod Security "restricted" (step 12). The image names its user "nobody",
      # which the kubelet can't check is not root: give the number.
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile: { type: RuntimeDefault }
~~~

Change:

<!-- edit: deploy/k8s/monitoring.yaml -->
~~~yaml
            limits: { memory: 1Gi }
          volumeMounts:
~~~

to:

~~~yaml
            limits: { memory: 1Gi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          volumeMounts:
~~~

Change:

<!-- edit: deploy/k8s/monitoring.yaml -->
~~~yaml
    spec:
      containers:
~~~

to:

~~~yaml
    spec:
      # Pod Security "restricted" (step 12). Grafana's image user.
      securityContext:
        runAsNonRoot: true
        runAsUser: 472
        seccompProfile: { type: RuntimeDefault }
      automountServiceAccountToken: false
      containers:
~~~

Change:

<!-- edit: deploy/k8s/monitoring.yaml -->
~~~yaml
            # No login, for a local cluster only: anyone who can reach the
            # port can change anything.
~~~

to:

~~~yaml
            # No login, for a local cluster only. As Admin, anything that
            # could reach the port could change anything, and read every
            # data source's settings (step 12's "before"). Viewer only reads
            # dashboards, and its NetworkPolicy lets no Pod reach it: people
            # come in through kubectl port-forward.
~~~

Change:

<!-- edit: deploy/k8s/monitoring.yaml -->
~~~yaml
            - { name: GF_AUTH_ANONYMOUS_ORG_ROLE, value: Admin }
~~~

to:

~~~yaml
            - { name: GF_AUTH_ANONYMOUS_ORG_ROLE, value: Viewer }
~~~

Change:

<!-- edit: deploy/k8s/monitoring.yaml -->
~~~yaml
            limits: { memory: 512Mi }
          volumeMounts:
~~~

to:

~~~yaml
            limits: { memory: 512Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          volumeMounts:
~~~

At the end of the file, change:

<!-- edit: deploy/k8s/monitoring.yaml -->
~~~yaml
    - { name: http, port: 3000, targetPort: http }
~~~

to:

~~~yaml
    - { name: http, port: 3000, targetPort: http }
---
# Prometheus (step 12): Grafana queries it. It scrapes Runway's Pods (each
# Pod's own policy says which port), and the kubelets' cAdvisor; and asks
# the Kubernetes API where its targets are. The last two aren't Pods: on
# kind they listen on the nodes' network.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: prometheus
  namespace: observability
spec:
  podSelector: { matchLabels: { app: prometheus } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from: [{ podSelector: { matchLabels: { app: grafana } } }]
      ports: [{ port: 9090 }]
  egress:
    - to: [{ namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: runway } } }]
    - to: [{ ipBlock: { cidr: 172.18.0.0/16 } }] # kind's node network
      ports: [{ port: 10250 }, { port: 6443 }]
---
# Grafana: people only, through kubectl port-forward. It asks Prometheus.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: grafana
  namespace: observability
spec:
  podSelector: { matchLabels: { app: grafana } }
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
    - to: [{ podSelector: { matchLabels: { app: prometheus } } }]
      ports: [{ port: 9090 }]
~~~


In `deploy/k8s/tracing.yaml`:

Change:

<!-- edit: deploy/k8s/tracing.yaml -->
~~~yaml
  name: observability
---
~~~

to:

~~~yaml
  name: observability
  # Pod Security (step 12): refuse any Pod that runs as root, may gain
  # privileges, keeps capabilities, or has no seccomp profile.
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
---
~~~

Change:

<!-- edit: deploy/k8s/tracing.yaml -->
~~~yaml
        config-version: "2"
    spec:
      containers:
        - name: otel-collector
~~~

to:

~~~yaml
        config-version: "2"
    spec:
      # Pod Security "restricted" (step 12). The image's user.
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile: { type: RuntimeDefault }
      automountServiceAccountToken: false
      containers:
        - name: otel-collector
~~~

Change:

<!-- edit: deploy/k8s/tracing.yaml -->
~~~yaml
            limits: { memory: 256Mi }
          volumeMounts:
~~~

to:

~~~yaml
            limits: { memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          volumeMounts:
~~~

Change:

<!-- edit: deploy/k8s/tracing.yaml -->
~~~yaml
      labels: { app: jaeger }
    spec:
      containers:
        - name: jaeger
~~~

to:

~~~yaml
      labels: { app: jaeger }
    spec:
      # Pod Security "restricted" (step 12). The image's user.
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile: { type: RuntimeDefault }
      automountServiceAccountToken: false
      containers:
        - name: jaeger
~~~

Change:

<!-- edit: deploy/k8s/tracing.yaml -->
~~~yaml
            limits: { memory: 512Mi }
---
~~~

to:

~~~yaml
            limits: { memory: 512Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
---
~~~

At the end of the file, change:

<!-- edit: deploy/k8s/tracing.yaml -->
~~~yaml
    - { name: ui, port: 16686, targetPort: ui }
~~~

to:

~~~yaml
    - { name: ui, port: 16686, targetPort: ui }
---
# Network policy (step 12): nothing in or out but DNS, unless a policy
# below allows it.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: observability
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dns
  namespace: observability
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
---
# Spans come from Runway's services only: before step 12, any Pod could post
# made-up ones. They go on to Jaeger, and only there.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: otel-collector
  namespace: observability
spec:
  podSelector: { matchLabels: { app: otel-collector } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: runway } }
      ports: [{ port: 4317 }, { port: 4318 }]
  egress:
    - to: [{ podSelector: { matchLabels: { app: jaeger } } }]
      ports: [{ port: 4317 }]
---
# Jaeger takes spans from the collector. Its UI (16686) is for people, who
# reach it with kubectl port-forward; no Pod may.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: jaeger
  namespace: observability
spec:
  podSelector: { matchLabels: { app: jaeger } }
  policyTypes: [Ingress]
  ingress:
    - from: [{ podSelector: { matchLabels: { app: otel-collector } } }]
      ports: [{ port: 4317 }]
~~~


And the partner's receiver takes requests from the notifier alone. In `deploy/k8s/hookcatcher.yaml`:

Change:

<!-- edit: deploy/k8s/hookcatcher.yaml -->
~~~yaml
  name: partner
---
~~~

to:

~~~yaml
  name: partner
  # Pod Security (step 12): refuse any Pod that runs as root, may gain
  # privileges, keeps capabilities, or has no seccomp profile.
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
---
~~~

Change:

<!-- edit: deploy/k8s/hookcatcher.yaml -->
~~~yaml
        runAsNonRoot: true
      automountServiceAccountToken: false
~~~

to:

~~~yaml
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault } # step 12
      automountServiceAccountToken: false
~~~

At the end of the file, change:

<!-- edit: deploy/k8s/hookcatcher.yaml -->
~~~yaml
    - { name: http, port: 8080, targetPort: http }
~~~

to:

~~~yaml
    - { name: http, port: 8080, targetPort: http }
---
# Network policy (step 12): nothing in or out but DNS, unless a policy
# below allows it.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: partner
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dns
  namespace: partner
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
---
# The partner's receiver takes requests from Runway's notifier, and
# nothing else (step 12).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: hookcatcher
  namespace: partner
spec:
  podSelector: { matchLabels: { app: hookcatcher } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: runway } }
          podSelector: { matchLabels: { app: notifier } }
      ports: [{ port: 8080 }]
~~~


One more fix, from rebuilding the cluster for this step. `smoke.sh` with the wrong `BAO_KEYS` directory ran `init.sh`, which found no `init.json` and tried to initialise an OpenBao that already was. That failed, but only after the shell had created an *empty* `init.json`, which the next run "found". In `deploy/bao/init.sh`:

Change:

<!-- edit: deploy/bao/init.sh -->
~~~bash
if [[ ! -f $dir/init.json ]]; then
~~~

to:

~~~bash
if [[ ! -s $dir/init.json ]]; then
  # No keys here. If OpenBao was initialised before, they are somewhere
  # else, and initialising again is refused: say so, rather than try to
  # unseal with nothing (found in step 12, with the wrong BAO_KEYS).
  if [[ $(bao status -format=json 2>/dev/null | jq -r .initialized || true) == true ]]; then
    echo "OpenBao is initialised already, and $dir holds no keys: pass the directory that does" >&2
    exit 1
  fi
~~~

Change:

<!-- edit: deploy/bao/init.sh -->
~~~bash
  (umask 077 && bao operator init -key-shares=5 -key-threshold=3 -format=json >"$dir/init.json")
~~~

to:

~~~bash
  # Into a new file, moved into place only once it is complete: a failed
  # init must not leave an empty init.json behind, to be "found" next time.
  (umask 077 && bao operator init -key-shares=5 -key-threshold=3 -format=json >"$dir/init.json.new")
  mv "$dir/init.json.new" "$dir/init.json"
~~~


<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway | grep -q 'kind: NetworkPolicy' && helm template runway deploy/helm/runway --set networkPolicy.enabled=false | grep -vq 'kind: NetworkPolicy' && bash -n deploy/bao/init.sh -->

### Run it

Apply `config.yaml` *first*, so the DNS policy exists before any egress policy does. Then the stores, the observability manifests, the receiver, and the chart:

~~~bash
kubectl apply -f deploy/k8s/config.yaml
kubectl apply -f deploy/k8s/postgres.yaml -f deploy/k8s/rabbitmq.yaml -f deploy/k8s/redis.yaml -f deploy/k8s/bao.yaml
deploy/bao/init.sh ~/.runway/bao                       # bao-0 restarts sealed
kubectl apply -f deploy/k8s/tracing.yaml -f deploy/k8s/monitoring.yaml -f deploy/k8s/hookcatcher.yaml
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --set 'networkPolicy.webhookNamespaces={partner}' --wait
~~~

My first attempt at this order failed: the migration hook got `403 permission denied` from OpenBao. OpenBao's audit log said its Kubernetes login had failed, because its token review to the API server had timed out after 27 seconds. The first egress policy on OpenBao's Pod had removed *all* its egress, DNS included, and the DNS policy wasn't applied yet. With `config.yaml` first, it worked. And `--reset-then-reuse-values` once more: plain `--reuse-values` left `networkPolicy` undefined, and the template failed.

The same probe, from `np-test`:

~~~text
postgres.runway:5432                 closed
rabbitmq.runway:5672                 closed
rabbitmq.runway:15672                closed
bao.runway:8200                      closed
redis.runway:6380                    closed
metad.runway:7001                    closed
api-pods.runway:8080                 closed
idp.runway:8081                      closed
gateway.runway:8000                  open
gateway.runway:8001                  closed
prometheus.observability:9090        closed
grafana.observability:3000           closed
jaeger.observability:16686           closed
otel-collector.observability:4318    closed
~~~

One door, the gateway's front, and everything else closed. (`curl https://example.com` from `np-test` still works: `np-test` has no policies of its own, and egress is a Pod's own namespace's business.) From inside an API Pod:

~~~text
$ kubectl -n runway debug api-66c9d84d85-4p64w --image=curlimages/curl:8.17.0 --target=api -- sh -c '...'
metad.runway:7001                  closed
rabbitmq.runway:15672              closed
prometheus.observability:9090      closed
grafana.observability:3000         closed
kubernetes.default:443             closed
https://example.com                000
~~~

A compromised API can reach what the API uses and nothing else: not `metad`, not the broker's management port, not the API server, not the internet. Pod Security's dry run now says nothing (`namespace/runway not labeled`, because the label is already there), and the service-account tokens:

~~~text
api-66c9d84d85-4p64w         sa=api         token=baotoken
autoscaler-659c9f59bd-kjg8n  sa=autoscaler  token=token
bao-0                        sa=bao         token=token
gateway-55585968b4-5ftpw     sa=default     token=none
metad-0                      sa=default     token=none
notifier-79fdc474b5-ntxmb    sa=notifier    token=baotoken
postgres-0                   sa=default     token=none
worker-66f766d677-kttsc      sa=default     token=none
~~~

(Trimmed to one Pod per component.) Only the autoscaler and OpenBao hold a Kubernetes API token; the API and the notifier hold one for OpenBao alone (step 9). `kubectl auth can-i --list --as=system:serviceaccount:runway:autoscaler -n runway` shows the autoscaler may `get` and `update` the scale of one Deployment, `worker`, and nothing else.

**Break it: no DNS.** Delete the `dns` policy and replace one API Pod:

~~~text
$ kubectl -n runway delete networkpolicy dns
$ kubectl -n runway delete pod api-578cf4f585-lqn6l   # its replacement starts with no DNS
t+ 10s  1/2 Running restarts=0  
t+ 30s  1/2 Running restarts=0  connect to RabbitMQ: dial tcp: lookup rabbitmq: i/o timeout
t+ 40s  1/2 Running restarts=1  
t+ 60s  1/2 Running restarts=2  
t+ 90s  1/2 Running restarts=3  
$ kubectl apply -f dns.yaml   # put it back
api-578cf4f585-n2zkp 2/2 Running restarts=3
api-578cf4f585-n4d48 2/2 Running restarts=0
api-578cf4f585-pbrkq 2/2 Running restarts=0
~~~

(`dns.yaml` is that one policy, cut from `config.yaml`.) The new Pod can't resolve `rabbitmq` and restarts; the two old Pods keep serving, because they resolved their names before. A policy mistake hurts new Pods first, which makes it look like a bad deploy, not a network problem.

**Break it: run as root.**

~~~text
$ kubectl -n runway run shell --image=curlimages/curl:8.17.0 --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' -- sleep 60
Error from server (Forbidden): pods "shell" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "shell" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "shell" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "shell" must set securityContext.runAsNonRoot=true), runAsUser=0 (pod must not set runAsUser=0), seccompProfile (pod or container "shell" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
~~~

Five reasons, and the Pod never exists.

### Fuzzing the parsers

Every parser of something an attacker sends gets a fuzz test that states a property. Create `internal/tlsproxy/fuzz_test.go`:

<!-- file: internal/tlsproxy/fuzz_test.go -->
~~~go
package tlsproxy

import (
	"strings"
	"testing"
)

// A listener spec that parses names an address, a target, and only real
// identities: an empty one, from a stray comma, must not reach the
// identity check, where it would match a certificate that names nobody.
func FuzzParseInbound(f *testing.F) {
	f.Add("0.0.0.0:6380,127.0.0.1:6379,spiffe://runway/api")
	f.Add("0.0.0.0:6380,127.0.0.1:6379,spiffe://runway/api,")
	f.Fuzz(func(t *testing.T, s string) {
		in, err := ParseInbound(s)
		if err != nil {
			return
		}
		if in.Listen == "" || in.Target == "" || len(in.Allowed) == 0 {
			t.Fatalf("ParseInbound(%q) = %+v", s, in)
		}
		for _, id := range in.Allowed {
			if !strings.HasPrefix(id, "spiffe://") || len(id) == len("spiffe://") {
				t.Fatalf("ParseInbound(%q) allows %q", s, id)
			}
		}
	})
}

func FuzzParseOutbound(f *testing.F) {
	f.Add("127.0.0.1:16379,redis-0.redis.runway:6380,spiffe://runway/redis")
	f.Add(",,") // the fuzzer's first find
	f.Fuzz(func(t *testing.T, s string) {
		out, err := ParseOutbound(s)
		if err != nil {
			return
		}
		if out.Listen == "" || out.Target == "" || !strings.HasPrefix(out.Server, "spiffe://") || len(out.Server) == len("spiffe://") {
			t.Fatalf("ParseOutbound(%q) = %+v", s, out)
		}
	})
}
~~~

That second seed, `",,"`, is a find. Before this step, `ParseOutbound(",,")` succeeded, with an empty address, an empty target and an *empty identity*. An empty expected identity would be compared with the empty identity of a certificate that names nobody. Run the fuzzer against the old parser and it finds it at once:

~~~bash
go test ./internal/tlsproxy -run '^$' -fuzz '^FuzzParseOutbound$' -fuzztime 60s
~~~

~~~text
fuzz: minimizing 32-byte failing input file
--- FAIL: FuzzParseOutbound (0.50s)
    --- FAIL: FuzzParseOutbound (0.00s)
        fuzz_test.go:38: ParseOutbound(",,") = {Listen: Target: Server:}
    
    Failing input written to testdata/fuzz/FuzzParseOutbound/74498b2a8282174d
    To re-run:
    go test -run=FuzzParseOutbound/74498b2a8282174d
~~~

Half a second. The fix, in `internal/tlsproxy/tlsproxy.go`:

Change:

<!-- edit: internal/tlsproxy/tlsproxy.go -->
~~~go
	"net"
	"strings"
~~~

to:

~~~go
	"net"
	"slices"
	"strings"
~~~

Change:

<!-- edit: internal/tlsproxy/tlsproxy.go -->
~~~go
	if len(parts) < 3 {
		return Inbound{}, fmt.Errorf("inbound %q: want LISTEN,TARGET,ID[,ID...]", s)
~~~

to:

~~~go
	if len(parts) < 3 || !filled(parts) || !identities(parts[2:]) {
		return Inbound{}, fmt.Errorf("inbound %q: want LISTEN,TARGET,ID[,ID...], each ID spiffe://...", s)
~~~

Change:

<!-- edit: internal/tlsproxy/tlsproxy.go -->
~~~go
	if len(parts) != 3 {
		return Outbound{}, fmt.Errorf("outbound %q: want LISTEN,TARGET,ID", s)
~~~

to:

~~~go
	if len(parts) != 3 || !filled(parts) || !identities(parts[2:]) {
		return Outbound{}, fmt.Errorf("outbound %q: want LISTEN,TARGET,ID, the ID spiffe://...", s)
~~~

Change:

<!-- edit: internal/tlsproxy/tlsproxy.go -->
~~~go
	return Outbound{Listen: parts[0], Target: parts[1], Server: parts[2]}, nil
}
~~~

to:

~~~go
	return Outbound{Listen: parts[0], Target: parts[1], Server: parts[2]}, nil
}

// filled and identities refuse what a stray comma makes (found by fuzzing,
// step 12): an empty address, or an empty identity, which the identity
// check would compare with the empty ID of a certificate that names nobody.
func filled(parts []string) bool {
	return !slices.Contains(parts, "")
}

func identities(ids []string) bool {
	for _, id := range ids {
		if rest, ok := strings.CutPrefix(id, "spiffe://"); !ok || rest == "" {
			return false
		}
	}
	return true
}
~~~


Create `internal/ratelimit/fuzz_test.go`:

<!-- file: internal/ratelimit/fuzz_test.go -->
~~~go
package ratelimit

import (
	"math"
	"testing"
	"time"
)

// Whatever ParseLimit accepts must be a limit the bucket can work with:
// a real, positive rate, and a refusal that says to wait a while, not
// for a negative or endless time (step 12).
func FuzzParseLimit(f *testing.F) {
	// Seeds at the edges of what a float can say. Without the last three,
	// 200,000 runs found nothing: the fuzzer never wrote "NaN".
	for _, s := range []string{"10:20", "0.5:1", "1e9:1", "-1:1", "Inf:1", "x:y", "NaN:1", "1e-320:1", "1:9999999999999"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		l, err := ParseLimit(s)
		if err != nil {
			return
		}
		if math.IsNaN(l.Rate) || math.IsInf(l.Rate, 0) || l.Rate <= 0 || l.Burst < 1 {
			t.Fatalf("ParseLimit(%q) = %+v", s, l)
		}
		now := time.Unix(0, 0)
		b := bucket{tokens: 0, at: now} // empty: the next request is refused
		d := b.take(now, l)
		if d.Allowed || d.RetryAfter <= 0 {
			t.Fatalf("ParseLimit(%q) = %+v; an empty bucket says %+v", s, l, d)
		}
	})
}
~~~

The fuzzer did *not* find this one in 214,000 runs; a direct probe with edge cases did. `ParseLimit("NaN:1")` succeeded, because NaN fails every comparison, `r <= 0` included. And a rate of `1e-320` made `RetryAfter` overflow `time.Duration` into a negative number of hours. The fix bounds both ends, and the seeds now include the edge cases, so the fuzz test fails on the old code from its first run. In `internal/ratelimit/ratelimit.go`:

Change:

<!-- edit: internal/ratelimit/ratelimit.go -->
~~~go

// ParseLimit reads "RATE:BURST", such as "10:20".
~~~

to:

~~~go

const (
	minRate  = 1.0 / (24 * 60 * 60) // one a day
	maxRate  = 1e6
	maxBurst = 1_000_000
)

// ParseLimit reads "RATE:BURST", such as "10:20".
~~~

Change:

<!-- edit: internal/ratelimit/ratelimit.go -->
~~~go
	}
	r, err := strconv.ParseFloat(rate, 64)
	if err != nil || r <= 0 || math.IsInf(r, 0) {
		return Limit{}, fmt.Errorf("limit %q: rate must be a positive number", s)
~~~

to:

~~~go
	}
	// Bounded both ways (step 12). "NaN" parses as a float and fails every
	// comparison, "r <= 0" included; and a rate so small that refilling
	// one token takes longer than a time.Duration holds made Retry-After
	// negative. Fuzzing with edge-case seeds found both.
	r, err := strconv.ParseFloat(rate, 64)
	if err != nil || !(r >= minRate && r <= maxRate) {
		return Limit{}, fmt.Errorf("limit %q: rate must be from one a day to %g a second", s, maxRate)
~~~

Change:

<!-- edit: internal/ratelimit/ratelimit.go -->
~~~go
	if err != nil || b < 1 {
		return Limit{}, fmt.Errorf("limit %q: burst must be at least 1", s)
~~~

to:

~~~go
	if err != nil || b < 1 || b > maxBurst {
		return Limit{}, fmt.Errorf("limit %q: burst must be from 1 to %d", s, maxBurst)
~~~


Create `internal/auth/fuzz_test.go`:

<!-- file: internal/auth/fuzz_test.go -->
~~~go
package auth

import (
	"context"
	"strings"
	"testing"
	"time"
)

// A token verifies only if it is, byte for byte, one the issuer signed
// (Phase 6, step 12). Anything else that verifies is a second spelling of
// the same token: harmless to the signature, but not to anything that
// keys on the token's text, such as a list of revoked tokens.
func FuzzOnlyTheSignedTokenVerifies(f *testing.F) {
	key, err := NewSigningKey(time.Now())
	if err != nil {
		f.Fatal(err)
	}
	token, err := Sign(validClaims(), key)
	if err != nil {
		f.Fatal(err)
	}
	v := verifierFor(key)
	f.Add(token)
	f.Add(token + "x")
	f.Add("e30.e30.")
	f.Fuzz(func(t *testing.T, candidate string) {
		if _, err := v.Verify(context.Background(), candidate); err == nil && candidate != token {
			t.Fatalf("verified a token that was never signed:\n  signed %s\n  got    %s", token, candidate)
		}
	})
}

// The fuzzer above ran 400,000 inputs and found nothing; by hand, in step
// 11, a token with its last character changed still verified. A signature
// is 64 bytes: 86 base64url characters carry 516 bits, so the last one has
// 4 spare bits, which a lenient decoder ignores. Try every character there.
func TestATokenHasOneSpelling(t *testing.T) {
	key, err := NewSigningKey(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	token, err := Sign(validClaims(), key)
	if err != nil {
		t.Fatal(err)
	}
	v := verifierFor(key)
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	var others []string
	for _, c := range alphabet {
		other := token[:len(token)-1] + string(c)
		if _, err := v.Verify(context.Background(), other); err == nil && other != token {
			others = append(others, other[len(other)-3:])
		}
	}
	if len(others) > 0 {
		t.Fatalf("%d other spellings verify, ending ...%s", len(others), strings.Join(others, ", ..."))
	}
}
~~~

Again the fuzzer found nothing in 400,000 runs, and the direct test below it found something. A base64 character carries 6 bits, and the last character of a 64-byte signature uses only 2 of them; a lenient decoder ignores the other 4. So every token had sixteen spellings that all verified. That's not a forgery (the signature is unchanged), but it breaks anything that treats a token's text as its identity, such as a cache or a "seen before" list. Undo the fix to see it:

~~~text
--- FAIL: TestATokenHasOneSpelling (0.01s)
    fuzz_test.go:57: 15 other spellings verify, ending ...2DB, ...2DC, ...2DD, ...2DE, ...2DF, ...2DG, ...2DH, ...2DI, ...2DJ, ...2DK, ...2DL, ...2DM, ...2DN, ...2DO, ...2DP
~~~

The fix is one word, in `internal/auth/jwt.go`:

Change:

<!-- edit: internal/auth/jwt.go -->
~~~go
var b64 = base64.RawURLEncoding
~~~

to:

~~~go
// Strict (step 12): a lenient decoder ignores the spare bits of the last
// character, so one signature had sixteen spellings that all verified.
// Strict refuses all but the one the encoder writes.
var b64 = base64.RawURLEncoding.Strict()
~~~


Create `internal/webhook/fuzz_test.go`:

<!-- file: internal/webhook/fuzz_test.go -->
~~~go
package webhook

import (
	"net/http"
	"strconv"
	"testing"
	"time"
)

// What a receiver accepts must be what was signed: the same message ID,
// the same moment, the same body (Phase 6, step 12). The headers' text
// may differ ("+1760000000" is the same moment), never their meaning.
func FuzzOnlySignedWebhooksVerify(f *testing.F) {
	secret := NewSecret()
	at := time.Unix(1760000000, 0)
	h := http.Header{}
	body := []byte(`{"type":"job.completed","data":{"id":7}}`)
	Sign(h, "msg_7", at, body, secret)
	f.Add(h.Get(HeaderID), h.Get(HeaderTimestamp), h.Get(HeaderSignature), body)
	f.Add("msg_7", "+1760000000", h.Get(HeaderSignature), body)
	f.Fuzz(func(t *testing.T, id, ts, sig string, b []byte) {
		got := http.Header{}
		got.Set(HeaderID, id)
		got.Set(HeaderTimestamp, ts)
		got.Set(HeaderSignature, sig)
		if Verify(got, b, at, secret) != nil {
			return
		}
		n, _ := strconv.ParseInt(ts, 10, 64)
		if got.Get(HeaderID) != "msg_7" || n != at.Unix() || string(b) != string(body) {
			t.Fatalf("verified id %q, timestamp %q, body %q", id, ts, b)
		}
	})
}
~~~

And the audit log's parsers, including a **differential** fuzz test: the same random file read by Go's `ReadLog` and by `klog check`, which must agree on how many records it holds. Create `internal/audit/fuzz_test.go`:

<!-- file: internal/audit/fuzz_test.go -->
~~~go
package audit

import (
	"encoding/binary"
	"hash/crc32"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The same file read by two readers (Phase 6, step 12): ReadLog in Go, for
// auditctl, and klog in Rust, which wrote it. They must agree on every
// file, damaged or not: the same records, so the same root, or both
// refuse it. Needs KLOG_BIN, as TestKlogAgreesWithGosTlog does.
func FuzzReadLogAgreesWithKlog(f *testing.F) {
	bin := os.Getenv("KLOG_BIN")
	if bin == "" {
		f.Skip("set KLOG_BIN to a built klog")
	}
	record := func(payload string) []byte {
		b := binary.LittleEndian.AppendUint32(nil, uint32(len(payload)))
		b = binary.LittleEndian.AppendUint32(b, crc32.Checksum([]byte(payload), crc32.MakeTable(crc32.Castagnoli)))
		return append(b, payload...)
	}
	two := append(record("tenant=acme job=1 state=queued"), record("tenant=acme job=1 state=running")...)
	f.Add(two)
	f.Add(two[:len(two)-3]) // torn
	f.Add([]byte{})
	dir := f.TempDir()
	f.Fuzz(func(t *testing.T, data []byte) {
		path := filepath.Join(dir, "audit.log")
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		out, klogErr := exec.Command(bin, "root", path).Output()
		records, goErr := ReadLog(path)
		if (klogErr == nil) != (goErr == nil) {
			t.Fatalf("klog: %q, %v; ReadLog: %d records, %v", out, klogErr, len(records), goErr)
		}
		if goErr != nil {
			return
		}
		tree, err := TreeOf(records)
		if err != nil {
			t.Fatal(err)
		}
		root, err := tree.Root(int64(len(records)))
		if err != nil {
			t.Fatal(err)
		}
		size, hash, _ := strings.Cut(strings.TrimSpace(string(out)), " ")
		if size != strconv.Itoa(len(records)) || hash != hexOf(root[:]) {
			t.Fatalf("klog: %s; ReadLog: %d records, root %x", out, len(records), root)
		}
	})
}

func hexOf(b []byte) string {
	const digits = "0123456789abcdef"
	s := make([]byte, 0, 2*len(b))
	for _, c := range b {
		s = append(s, digits[c>>4], digits[c&15])
	}
	return string(s)
}

// A checkpoint has one spelling (C2SP tlog-checkpoint: the size in
// decimal, no leading zeros; the root in standard base64). What parses
// must print back the same.
func FuzzParseCheckpoint(f *testing.F) {
	f.Add("runway.example/audit\n30\nOjmcLxz6Pu4v/l75TfOlijVnTHeOLLG2Iqgzd+c12Zk=\n")
	f.Fuzz(func(t *testing.T, text string) {
		c, err := ParseCheckpoint(text)
		if err != nil {
			return
		}
		if body, _, _ := cutAfterThirdLine(text); body != c.Text() {
			t.Fatalf("ParseCheckpoint(%q) = %+v, which prints as %q", text, c, c.Text())
		}
	})
}

func cutAfterThirdLine(s string) (string, string, bool) {
	n := 0
	for i, r := range s {
		if r == '\n' {
			if n++; n == 3 {
				return s[:i+1], s[i+1:], true
			}
		}
	}
	return s, "", false
}

// The witness parses what anyone on the network sends it.
func FuzzParseWitnessRequest(f *testing.F) {
	f.Add([]byte("old 3\nOjmcLxz6Pu4v/l75TfOlijVnTHeOLLG2Iqgzd+c12Zk=\n\nrunway.example/audit\n5\n"))
	f.Fuzz(func(t *testing.T, body []byte) {
		old, proof, _, err := ParseWitnessRequest(body)
		if err == nil && (old < 0 || len(proof) > 64) {
			t.Fatalf("old %d, %d proof hashes", old, len(proof))
		}
	})
}
~~~

It found that Go and Rust disagreed about a header claiming a payload over klog's 1 MiB limit: klog called the file corrupt, Go called it torn (a crash mid-write, safe to cut off). Klog never writes a record that large, so no crash could leave one. It's damage. In `internal/audit/tree.go`:

Change:

<!-- edit: internal/audit/tree.go -->
~~~go

// ReadLog reads every record of a klog file, checking each one's CRC, as
~~~

to:

~~~go

// maxPayload is klog's limit on a record (audit/src/record.rs).
const maxPayload = 1 << 20

// ReadLog reads every record of a klog file, checking each one's CRC, as
~~~

Change:

<!-- edit: internal/audit/tree.go -->
~~~go
		length := int(binary.LittleEndian.Uint32(data[off:]))
		sum := binary.LittleEndian.Uint32(data[off+4:])
~~~

to:

~~~go
		length := int(binary.LittleEndian.Uint32(data[off:]))
		if length > maxPayload {
			// klog never writes one this large, so no crash could have
			// left it: it is damage, wherever it is (found by fuzzing
			// this against klog, step 12; it had been taken for torn).
			return nil, fmt.Errorf("%s: corrupt record at byte %d: %d bytes is over klog's limit", path, off, length)
		}
		sum := binary.LittleEndian.Uint32(data[off+4:])
~~~


And checkpoints had several spellings too: a size of `05` or `+5`, and a root with spare bits. In `internal/audit/checkpoint.go`:

Change:

<!-- edit: internal/audit/checkpoint.go -->
~~~go
	}
	size, err := strconv.ParseInt(lines[1], 10, 64)
	if err != nil || size < 0 {
~~~

to:

~~~go
	}
	// One spelling only (step 12): ParseInt also takes "+5" and "05", and
	// a lenient decoder ignores a root's spare bits. Fuzzing found both.
	size, err := strconv.ParseInt(lines[1], 10, 64)
	if err != nil || size < 0 || strconv.FormatInt(size, 10) != lines[1] {
~~~

Change:

<!-- edit: internal/audit/checkpoint.go -->
~~~go
	root, err := base64.StdEncoding.DecodeString(lines[2])
~~~

to:

~~~go
	root, err := base64.StdEncoding.Strict().DecodeString(lines[2])
~~~


The fuzzer saves each failing input in `testdata/fuzz`, and `go test` replays them on every run from then on, which makes them regression tests. Keep the two it found. Create `internal/audit/testdata/fuzz/FuzzReadLogAgreesWithKlog/93d6f7bc0d93f998`:

<!-- file: internal/audit/testdata/fuzz/FuzzReadLogAgreesWithKlog/93d6f7bc0d93f998 -->
~~~text
go test fuzz v1
[]byte("00000000")
~~~

Create `internal/audit/testdata/fuzz/FuzzParseCheckpoint/7a76d1c0045e35fa`:

<!-- file: internal/audit/testdata/fuzz/FuzzParseCheckpoint/7a76d1c0045e35fa -->
~~~text
go test fuzz v1
string("0\n00\n0000000000000000000000000000000000000000000=\n")
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && KLOG_BIN=$PWD/audit/target/release/klog go test -race -count=1 ./internal/tlsproxy/... ./internal/ratelimit/... ./internal/auth/... ./internal/webhook/... ./internal/audit/... -->

Run each fuzz target for a few minutes (`go test ./internal/audit -run '^$' -fuzz '^FuzzReadLogAgreesWithKlog$' -fuzztime 3m`, and so on). After the fixes, mine ran clean: 996,000 inputs for `ParseOutbound`, 642,000 for the token check, 190,000 for the klog differential, 1.4 million for checkpoints. The fuzzer found three of the bugs in this section: `",,"`, the klog disagreement, and the checkpoint's `00` size. A seed I wrote, or a direct probe, found the rest: the empty identity, `NaN`, `1e-320`, and the token's sixteen spellings. Do both.

**Explain it:** what does default-deny change, and why must DNS be allowed separately? Why did a rule for `10.96.0.1:443` not let OpenBao reach the API server? Why is the migration's policy a hook? What does each part of `restricted` stop? Why remove tokens a Pod doesn't use, if its account can do almost nothing? What did fuzzing find, what did it miss, and why?

**Read.** The Kubernetes documentation on [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) and [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/). Then the NSA/CISA *Kubernetes Hardening Guide*: which of its recommendations does Runway now meet, and which not? Then the Go fuzzing tutorial, and Google's *OSS-Fuzz* documentation on what makes a good fuzz target.

---
## Step 13: A security game day

**The problem.** Step 1 asked four questions, and one is still open: *did we do a good job?* Each step tested its own control, on its own day. Nobody has checked them all together, on the system as it runs now, after twelve steps of changes that could have undone each other. And each step's checks were written by the person who built the control, who knows where to look, which is exactly the problem.

**New ideas.**

- **A game day** (Phase 5) breaks a system on purpose to learn how it fails. A *security* game day attacks it, using the threat model as the plan: every row is a claim, and the day tests each claim with evidence, the same kind of evidence step 1 gathered.
- **Held or open.** Each check states what it expects and prints what it got. Write the expectation down before running it, so a surprise can't be explained away afterwards.
- **Controls for the checks themselves.** A check that finds nothing proves the control works only if it *could* have found something. A port probe that reports "closed" proves nothing if the probe can't connect to anything; a log search that finds no secrets proves nothing if no secret was ever logged. So some checks need a positive control: something that *must* succeed, run first, so its success shows the check can see.
- **A findings report** says what held, what's open, what each open one would take to close, and which risks are *accepted*, on purpose, with the reason.
- **Red teams.** In a real organisation, the attack comes from people who didn't build the system and are rewarded for breaking it. A game day run by the builders is the cheaper, weaker version. It still finds things, as you'll see.

### The checks

One script, one check per row of the threat model. Create `deploy/security/gameday.sh`:

<!-- file: deploy/security/gameday.sh -->
~~~bash
#!/usr/bin/env bash
# The security game day (Phase 6, step 13): does each control in
# docs/security/threat-model.md hold, on the running cluster, today? One
# check per row: what it expected, what it got, and HELD or OPEN.
#
#   deploy/security/gameday.sh
#
#   CA        the CA directory, with the operator's certificate (~/.runway/ca)
#   CLIENTS   the issuer's clients, id:secret:tenant:roles,... (~/.runway/idp-clients.txt)
#
# Needs the clients acme-ci, globex-ci and acme-admin, the release's
# webhooks.allowHosts including hookcatcher.partner, and the gateway and the
# API's NodePort on localhost:8000 and localhost:8080, as the guide sets up.
set -u
cd "$(dirname "$0")/../.."
CA=${CA:-$HOME/.runway/ca}
CLIENTS=${CLIENTS:-$HOME/.runway/idp-clients.txt}

secret() { tr ',' '\n' <"$CLIENTS" | grep "^$1:" | cut -d: -f2; }
kubectl -n runway port-forward svc/idp 18081:8081 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 2
token() {
  curl -s --cacert "$CA/tls.crt" --resolve idp.runway:18081:127.0.0.1 -u "$1:$(secret "$1")" \
    -d grant_type=client_credentials https://idp.runway:18081/token | jq -r .access_token
}
ACME=$(token acme-ci) GLOBEX=$(token globex-ci) ACME_ADMIN=$(token acme-admin)
START=$(date -u +%FT%TZ)
psql() { kubectl -n runway exec postgres-0 -- psql -U runway -d runway -Atc "$1"; }
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }
check() { # ID, what, expected, got
  local r=OPEN
  [ "$3" = "$4" ] && r=HELD
  printf '%-4s %-58s want %-14s got %-14s %s\n' "$1" "$2" "$3" "$4" "$r"
}
# A check that shows another one can see: if it fails, the ones it backs mean nothing.
control() {
  local r="BLIND: ignore the checks below"
  [ "$3" = "$4" ] && r=SEES
  printf '%-4s %-58s want %-14s got %-14s %s\n' "" "$2" "$3" "$4" "$r"
}
job() {
  curl -s -X POST localhost:8000/jobs -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d '{"description":"game day","duration_ms":10}' | jq -r .id
}

# The foothold: a Pod in a namespace of its own (step 12). Its sleep runs
# out after a day, so make it again when it has.
kubectl get namespace np-test >/dev/null 2>&1 || kubectl create namespace np-test >/dev/null
if [ "$(kubectl -n np-test get pod probe -o jsonpath='{.status.phase}' 2>/dev/null)" != Running ]; then
  kubectl -n np-test delete pod probe --ignore-not-found >/dev/null
  kubectl -n np-test run probe --image=curlimages/curl:8.17.0 --restart=Never --command -- sleep 86400 >/dev/null
  kubectl -n np-test wait pod/probe --for=condition=Ready --timeout=180s >/dev/null
fi
probe() { if kubectl -n np-test exec probe -- nc -z -w 3 "$1" "$2" 2>/dev/null; then echo open; else echo closed; fi; }

A=$(job "$ACME")
# Canaries for T16, planted now: a 0 later means the redaction worked
# today, not that nothing was logged.
curl -s -o /dev/null -X POST localhost:8000/jobs -H "Authorization: Bearer $ACME" -H 'Content-Type: application/json' \
  -d '{"description":"Call Alice back: alice.canary@example.com","duration_ms":10}'
curl -s -o /dev/null -X PUT localhost:8000/webhook -H "Authorization: Bearer $ACME_ADMIN" -H 'Content-Type: application/json' \
  -d '{"url":"http://hookcatcher.partner:9999/hooks?token=hooksecret-canary-13"}' # nothing listens there: the delivery fails, and is logged
job "$ACME" >/dev/null

check T1 "create a job with no token" 401 \
  "$(code -X POST localhost:8000/jobs -H 'Content-Type: application/json' -d '{"description":"x","duration_ms":1}')"
check T1 "create a job with a token whose signature is changed" 401 \
  "$(code -X POST localhost:8000/jobs -H "Authorization: Bearer ${ACME:0:60}X${ACME:61}" -H 'Content-Type: application/json' -d '{"description":"x","duration_ms":1}')"
check T2 "globex reads acme's job $A" 404 "$(code localhost:8000/jobs/$A -H "Authorization: Bearer $GLOBEX")"
check T3 "row-level security on jobs, job_events, webhooks" "true true true" \
  "$(psql "SELECT string_agg(relrowsecurity::text, ' ' ORDER BY relname) FROM pg_class WHERE relname IN ('jobs', 'job_events', 'webhooks') AND relkind = 'r' AND relnamespace = 'public'::regnamespace")"
export ACME
n429=$(seq 60 | xargs -P 30 -I{} sh -c 'curl -s -o /dev/null -m 10 -w "%{http_code}\n" -X POST localhost:8000/jobs -H "Authorization: Bearer $ACME" -H "Content-Type: application/json" -d "{\"description\":\"burst\",\"duration_ms\":1}"' | grep -c 429)
check T4 "60 creates, 30 at a time, by one tenant: $n429 got 429" yes "$([ "$n429" -gt 0 ] && echo yes || echo no)"
check T4 "...while another tenant still gets in" 201 \
  "$(code -X POST localhost:8000/jobs -H "Authorization: Bearer $GLOBEX" -H 'Content-Type: application/json' -d '{"description":"x","duration_ms":1}')"
check T5 "unit tests: expired tokens, one spelling, replayed webhooks" "5 passed" \
  "$(go test -count=1 -v -run '^(TestRejected|TestATokenHasOneSpelling|TestVerify|TestTheTimestampIsSigned|TestReceiverDropsDuplicatesButNotRetriesOfFailures)$' ./internal/auth ./internal/webhook 2>&1 | grep -c '^--- PASS') passed"
control T6 "control: a Pod in another namespace reaches the gateway" open "$(probe gateway.runway 8000)"
for t in postgres.runway:5432 rabbitmq.runway:5672 redis.runway:6380 metad.runway:7001 bao.runway:8200; do
  check T6 "a Pod in another namespace reaches ${t%%.*}" closed "$(probe "${t%:*}" "${t#*:}")"
done
check T7 "the API's NodePort without a client certificate" 403 \
  "$(code --cacert "$CA/tls.crt" --resolve api.runway:8080:127.0.0.1 https://api.runway:8080/jobs/$A -H "Authorization: Bearer $ACME")"
check T7 "the API's NodePort in plain HTTP" 400 "$(code http://localhost:8080/jobs/$A -H "Authorization: Bearer $ACME")"
check T8 "Pods that may reach the broker's AMQP port" "api notifier worker" \
  "$(kubectl -n runway get networkpolicy rabbitmq -o json | jq -r '[.spec.ingress[] | select(.ports[0].port == 5672) | .from[].podSelector.matchLabels.app] | sort | join(" ")')"
users=$(kubectl -n runway exec rabbitmq-0 -- rabbitmqctl list_users -q --no-table-headers 2>/dev/null | wc -l)
check T8 "broker logins, per service or shared ($users user)" per-service "$([ "$users" -gt 1 ] && echo per-service || echo shared)"
check T9 "metad from the operator certificate's peers only" closed "$(probe metad.runway 7001)"
check T10 "Redis listens on the loopback only" 127.0.0.1 \
  "$(kubectl -n runway get sts redis -o jsonpath='{.spec.template.spec.containers[0].args[1]}')"
check T11 "API database logins: superuser, bypass RLS" "f f" \
  "$(psql "SELECT DISTINCT rolsuper || ' ' || rolbypassrls FROM pg_roles WHERE rolname LIKE 'v-kubernet-api-%'" | sed 's/true/t/g; s/false/f/g' | head -1)"
check T12 "Secrets encrypted at rest in etcd" yes \
  "$(docker exec runway-control-plane grep -q -- '--encryption-provider-config' /etc/kubernetes/manifests/kube-apiserver.yaml && echo yes || echo no)"
check T12 "API Pods take a whole Secret (envFrom secretRef)" no \
  "$(kubectl -n runway get deploy api -o json | jq -r '[.spec.template.spec.containers[].envFrom[]?.secretRef | select(. != null)] | if length > 0 then "yes" else "no" end')"
check T13 "Pods with a Kubernetes API token" "autoscaler bao" \
  "$(kubectl -n runway get pods -o json | jq -r '[.items[] | select(any(.spec.volumes[]?; .projected.sources[]?.serviceAccountToken | select(. != null and .audience == null))) | .metadata.labels.app] | unique | join(" ")')"
check T14 "Pod Security enforced in runway" restricted \
  "$(kubectl get ns runway -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
check T14 "a Pod that runs as root" Forbidden \
  "$(kubectl -n runway run t14 --image=curlimages/curl:8.17.0 --restart=Never --dry-run=server --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' -- true 2>&1 | grep -o Forbidden | head -1)"
# The audit pipeline runs in Compose (step 10); its tests edit and cut a
# log and expect auditctl and the witness to notice.
check T15 "unit tests: an edited or cut log, a rewritten history" "2 passed" \
  "$(go test -count=1 -v -run '^(TestVerifyAndProve|TestTheWitnessAcceptsOnlyGrowth)$' ./cmd/auditctl ./internal/witness 2>&1 | grep -c '^--- PASS') passed"
sleep 25 # the failed delivery is retried 3 times
curl -s -o /dev/null -X DELETE localhost:8000/webhook -H "Authorization: Bearer $ACME_ADMIN"
control T16 "control: failed deliveries were logged, since the start" yes \
  "$(kubectl -n runway logs -l app=notifier --tail=-1 --since-time="$START" | grep -q '"result":"failed"' && echo yes || echo no)"
check T16 "the webhook URL's secret in the notifier's log" 0 \
  "$(kubectl -n runway logs -l app=notifier --tail=-1 --since-time="$START" | grep -c 'hooksecret-canary-13')"
check T16 "the description's email in any runway Pod's log" 0 \
  "$(for p in $(kubectl -n runway get pods -o name); do kubectl -n runway logs "$p" --all-containers --since-time="$START" 2>/dev/null; done | grep -c 'alice.canary@example.com')"
check T17 "Grafana's anonymous role" Viewer \
  "$(kubectl -n observability get deploy grafana -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name == "GF_AUTH_ANONYMOUS_ORG_ROLE") | .value')"
check T17 "a Pod reaches Grafana" closed "$(probe grafana.observability 3000)"
day=$(psql "SELECT created_at::date FROM jobs WHERE created_at < current_date GROUP BY 1 HAVING count(DISTINCT tenant) < 3 ORDER BY 1 DESC LIMIT 1")
check T18 "peer statistics for ${day:-(no such day)}, under 3 tenants" true \
  "$(curl -s "localhost:8000/stats/peers?day=$day" -H "Authorization: Bearer $ACME" | jq -r .suppressed)"
# Found during the phase, not in step 1's table:
n=$(seq 100 | xargs -P 30 -I{} curl -s -o /dev/null -m 10 -w "%{http_code}\n" -X POST localhost:8000/jobs -H "Content-Type: application/json" -d '{"description":"x","duration_ms":1}' | grep -c 429)
check T19 "100 requests with no token, 30 at a time: $n got 429" yes "$([ "$n" -gt 0 ] && echo yes || echo no)"
check T20 "an alert before certificates expire" yes \
  "$(grep -qiE 'cert.*expir|expir.*cert' deploy/prometheus/rules.yml && echo yes || echo no)"
~~~

Some checks hit the cluster (a request, a probe from `np-test`, a query), some read configuration (a label, a policy, a manifest), and two run the unit tests that cover what can't be shown on a live system in a minute: expired tokens, replayed webhooks, an edited audit log. Look at the two `control` lines. The first proves the foothold can reach *something* (the gateway, which everyone may reach) before five "closed" results count. The second proves a failed webhook delivery really was logged since the script started before it searches those logs for the secret in the URL.

My first version didn't have them. Its T16 searched the last day's logs for step 11's canaries, found none, and said HELD. But the notifier's Pods had been replaced since step 11, so their logs held nothing at all, and an empty log passes. It would have said HELD with the redaction removed. Now the script plants its own canaries, and checks that the log line that would carry one exists.

<!-- run: chmod +x deploy/security/gameday.sh && bash -n deploy/security/gameday.sh -->

### Run it

The script needs the clients from earlier steps (`acme-ci`, `globex-ci`, `acme-admin`), the receiver allowed as a webhook host, and your CA:

~~~bash
chmod +x deploy/security/gameday.sh
deploy/security/gameday.sh
~~~

~~~text
T1   create a job with no token                                 want 401            got 401            HELD
T1   create a job with a token whose signature is changed       want 401            got 401            HELD
T2   globex reads acme's job 710                                want 404            got 404            HELD
T3   row-level security on jobs, job_events, webhooks           want true true true got true true true HELD
T4   60 creates, 30 at a time, by one tenant: 15 got 429        want yes            got yes            HELD
T4   ...while another tenant still gets in                      want 201            got 201            HELD
T5   unit tests: expired tokens, one spelling, replayed webhooks want 5 passed       got 5 passed       HELD
     control: a Pod in another namespace reaches the gateway    want open           got open           SEES
T6   a Pod in another namespace reaches postgres                want closed         got closed         HELD
T6   a Pod in another namespace reaches rabbitmq                want closed         got closed         HELD
T6   a Pod in another namespace reaches redis                   want closed         got closed         HELD
T6   a Pod in another namespace reaches metad                   want closed         got closed         HELD
T6   a Pod in another namespace reaches bao                     want closed         got closed         HELD
T7   the API's NodePort without a client certificate            want 403            got 403            HELD
T7   the API's NodePort in plain HTTP                           want 400            got 400            HELD
T8   Pods that may reach the broker's AMQP port                 want api notifier worker got api notifier worker HELD
T8   broker logins, per service or shared (1 user)              want per-service    got shared         OPEN
T9   metad from the operator certificate's peers only           want closed         got closed         HELD
T10  Redis listens on the loopback only                         want 127.0.0.1      got 127.0.0.1      HELD
T11  API database logins: superuser, bypass RLS                 want f f            got f f            HELD
T12  Secrets encrypted at rest in etcd                          want yes            got yes            HELD
T12  API Pods take a whole Secret (envFrom secretRef)           want no             got no             HELD
T13  Pods with a Kubernetes API token                           want autoscaler bao got autoscaler bao HELD
T14  Pod Security enforced in runway                            want restricted     got restricted     HELD
T14  a Pod that runs as root                                    want Forbidden      got Forbidden      HELD
T15  unit tests: an edited or cut log, a rewritten history      want 2 passed       got 2 passed       HELD
     control: failed deliveries were logged, since the start    want yes            got yes            SEES
T16  the webhook URL's secret in the notifier's log             want 0              got 0              HELD
T16  the description's email in any runway Pod's log            want 0              got 0              HELD
T17  Grafana's anonymous role                                   want Viewer         got Viewer         HELD
T17  a Pod reaches Grafana                                      want closed         got closed         HELD
T18  peer statistics for 2026-10-15, under 3 tenants            want true           got true           HELD
T19  100 requests with no token, 30 at a time: 0 got 429        want yes            got no             OPEN
T20  an alert before certificates expire                        want yes            got no             OPEN
~~~

**29 held, 3 open**, and both controls saw. T4's count of refusals varies from run to run (8, 12, 13 and 15 in mine), because it depends on how fast thirty parallel `curl`s arrive. That's why the check is "some were refused", not a number. I also ran step 10's Compose pipeline on the day and edited a record: `auditctl` said `TAMPERED`, as in step 10.

### The open three

None of them is a surprise once you see it, and that's the point of looking.
- **T8: one broker login for every service.** Network policy (step 12) limits who can *reach* RabbitMQ to the API, the notifier and the workers. But they all log in as the same user. Whoever has that password, from any of the three, can publish an event the API will believe, such as "job 7 completed". Step 9 gave the database per-Pod, short-lived logins; the broker's are neither. OpenBao's RabbitMQ secrets engine makes them the same way.
- **T19: requests with no token aren't limited.** Rate limits are per tenant (step 5), and a request without a token has no tenant, so it's refused (`401`) but never counted. Each refusal is cheap, one failed signature check, but nothing bounds how many arrive. A limit per client address at the gateway, *before* authentication, is the fix.
- **T20: nothing warns before certificates expire.** This one happened, not in a test. Certificates last a day by default (step 7). After my machine was off overnight, every one had expired, and the API and the notifier sat in `CrashLoopBackOff` until I renewed them. Nothing had warned. Export each certificate's expiry as a metric and alert a few hours ahead; then automate the renewal.

All three are exercises from earlier steps (9, 5 and 7), and the report says so.

### The report

Write down what the day found, for whoever runs the system next. Create `docs/security/gameday-2026-10-16.md` (with your own date in the title, if you like):

<!-- file: docs/security/gameday-2026-10-16.md -->
~~~markdown
# Security game day, 2026-10-16

Step 1's [threat model](threat-model.md) ended with a question: did we do a good job? This is the answer. Each row of its table names a control that steps 2 to 12 built. Today every control was checked against the running cluster, one command per row, by a script that prints what it expected and what it got. A control **held** if the result matched, and is **open** if it didn't.

A check that finds nothing proves something only if it could have found something. So two rows are **controls**, not checks: before the foothold Pod reports the database "closed", it must reach the one thing it is allowed to (the gateway); before the logs are searched for a canary, they must contain the failed delivery that would have carried it.

**Scope:** the kind cluster as deployed after step 12 (chart defaults, `networkPolicy.webhookNamespaces=[partner]`), and Compose for the audit pipeline, which runs only there. A Pod in a namespace of its own (`np-test`) stands for a foothold in the cluster: a compromised dependency, or a teammate's test Pod.

**Not in scope:** anyone with administrative access to the cluster or the cloud account (a non-goal from step 1); the supply chain, which the capstone's hardening stage takes on.

## Result: 29 held, 3 open (32 checks, and 2 controls that saw)

| # | Threat | Check | Result |
|---|---|---|---|
| T1 | No identity | create a job with no token; with a token whose signature is changed | Held: 401, 401 |
| T2 | Guessable IDs | globex reads acme's job by its number | Held: 404 |
| T3 | No tenants | row-level security on `jobs`, `job_events`, `webhooks` | Held |
| T4 | One tenant starves the rest | 60 creates by acme, 30 at a time; then one by globex | Held: some refused with 429 (between 8 and 15 of the 60 in my runs: it depends on how fast the burst arrives); globex 201 |
| T5 | Replay | unit tests: expired tokens, one spelling per token, replayed and stale webhooks | Held |
| T6 | Flat network | from `np-test`: PostgreSQL, RabbitMQ, Redis, `metad`, OpenBao | Held: all closed, while the gateway was open (the control) |
| T7 | Plain text between services | the API without a client certificate; in plain HTTP | Held: 403, 400 |
| T8 | One broker credential | who may reach AMQP; how many broker users | **Open:** only the API, notifier and workers can reach it, but they share one login |
| T9 | `metad` unauthenticated | reachable from `np-test` | Held: closed (and mutual TLS behind it, step 7) |
| T10 | Redis open | bound to the loopback, behind the sidecar | Held |
| T11 | Superuser database login | the API's logins: superuser, bypass RLS | Held: neither |
| T12 | Secrets everywhere | encryption at rest in etcd; whole Secrets in Pods | Held: encrypted; per-key only |
| T13 | Unused API tokens | Pods holding a Kubernetes API token | Held: only the autoscaler and OpenBao |
| T14 | No Pod Security | the namespace's level; a Pod that runs as root | Held: restricted; refused |
| T15 | Rewritable history | step 10's tests: an edited and a cut log, a rewritten history; and in Compose, an edited record | Held: both tests pass; `auditctl` said `TAMPERED` |
| T16 | Data in telemetry | plant an email in a description and a secret in a webhook URL whose delivery fails, then search the logs | Held: neither found, though the failed delivery was logged (the control) |
| T17 | Grafana admin for all | its anonymous role; reachable from a Pod | Held: Viewer; closed |
| T18 | Small groups in statistics | a past day with fewer than three tenants | Held: suppressed |
| T19 | Unauthenticated floods (new) | 100 creates with no token, 30 at a time | **Open:** none refused |
| T20 | Certificates expire unnoticed (new) | an alert before certificates expire | **Open:** none |

## The open three

**T8: one broker login for every service.** Network policy now limits who can *reach* RabbitMQ: the API, the notifier and the workers. But they log in as one user. Whoever has that password, from any of the three, can publish events the API will believe, such as "job 7 completed". Step 9 made database logins per Pod and short-lived; the broker's are neither. *Next:* OpenBao's RabbitMQ secrets engine makes per-Pod broker users the same way. Give each service only the permissions it uses (the workers read commands and write events; only the API consumes events).

**T19: requests with no token aren't limited.** Rate limits are per tenant (step 5), and a request without a token has no tenant, so it is refused (401) but never counted. Each refusal is cheap (one signature check fails), but nothing bounds how many arrive. *Next:* a limit per client address at the gateway, before authentication, which step 5 listed as an exercise.

**T20: nothing warns before certificates expire.** This happened this week, not in a test. Certificates last 24 hours by default (step 7). After the machine had been off overnight, on 2026-10-15, every one had expired, and the API and the notifier sat in CrashLoopBackOff until the certificates were renewed and the Pods restarted. Nothing had warned. Renewal is a command an operator must remember (`deploy/certs.sh`). *Next:* export each certificate's expiry as a metric and alert a few hours ahead; then automate renewal (a CronJob, cert-manager, or SPIFFE's SPIRE). Both are step 7 exercises.

## What else the phase taught

These held, but only after a first attempt failed. Each one is a prediction that was wrong.

| Step | Prediction | What happened |
|---|---|---|
| 10 | A file edit is caught at the next checkpoint | Right, but my first capture said otherwise: the script matched a log line from *before* the edit |
| 11 | Kafka events carry the job's description | They never did; it travels only in the RunJob command and its outbox row |
| 11 | Old dead letters expire under a new TTL policy | On quorum queues they never do, and they hold back newer ones behind them |
| 11 | Changing the noise setting takes effect when Helm returns | Old Pods, still draining, answered first and published a day without noise |
| 12 | kind needs Calico to enforce NetworkPolicy | kindnet enforces it |
| 12 | OpenBao logins broke on how policies see Service addresses | They broke on DNS: an egress policy removes it, unless a rule allows it |
| 12 | Fuzzing finds parser bugs | It found three (tlsproxy's `,,`, klog against Go's reader, a checkpoint's `00` size); it missed the ones a direct probe found (`NaN:1`, `1e-320`, a token's 16 spellings) |
| 13 | A check that finds nothing shows the control works | Not if it couldn't have found anything. The first T16 searched the last 24 hours of logs for step 11's canaries, but those Pods had restarted since: an empty log passes. Now the script plants its own canaries and checks that the delivery carrying one was logged |

## Accepted, for now

- **Operators are trusted.** Anyone who can `kubectl exec` or `kubectl debug` can enter a Pod's network and read what it reads. That's a non-goal from step 1; it calls for separation of duties and audited access.
- **OpenBao unseals by hand.** Every restart seals it (twice this week), and services can't get new logins until someone unseals it. Auto-unseal with a cloud KMS is the production answer.
- **A cached job may show its description for up to an hour after it is blanked** (step 11): the cache's own retention.
- **Pods may resolve any name through the cluster's DNS.** An egress-filtering DNS setup would narrow that.

## Evidence

The checks are one script, `deploy/security/gameday.sh`, run in about five minutes; run it again after any change, and after every restart. Its output, and each step's own before-and-after captures, are in this phase's guide.
~~~

Its last two sections matter as much as the table. *What else the phase taught* lists every prediction from this phase that turned out wrong; a team that records those gets better at predicting. *Accepted, for now* names the risks left open on purpose, with the reason, so nobody mistakes a decision for an oversight.

### Close the loop

The threat model keeps its starting point, so you can see how far the phase came, and gains a column for where each threat stands now, two rows for the threats the phase found, and an after for each actor. In `docs/security/threat-model.md`:

Change:

<!-- edit: docs/security/threat-model.md -->
````markdown
Written at the start of Phase 6, before adding any security control, and updated as each step lands. A threat model answers four questions (Shostack): what are we building, what can go wrong, what are we going to do about it, and did we do a good job?
````

to:

````markdown
Written at the start of Phase 6, before adding any security control. The tables keep that starting point, so you can see how far the phase came; the last column of section 2 says where each threat stood at the [game day](gameday-2026-10-16.md) of step 13. A threat model answers four questions (Shostack): what are we building, what can go wrong, what are we going to do about it, and did we do a good job?
````

Change:

<!-- edit: docs/security/threat-model.md -->
````markdown
   operators: kubectl, Helm, CI (GitHub Actions), the AWS account (step 13)
~~~

````

to:

````markdown
   operators: kubectl, Helm, CI (GitHub Actions), the AWS account (Phase 5)
~~~

Phase 6 added to this picture: an identity provider (`idp`, step 2); a notifier sending signed webhooks out to partners (step 6); a certificate authority and mutual TLS on every arrow inside the cluster (steps 7 and 8); OpenBao for logins and keys (step 9); a witness for the audit log (step 10, Compose only).

````

Change:

<!-- edit: docs/security/threat-model.md -->
````markdown
| Actor | Trust | Today they can |
|---|---|---|
| A customer (tenant) | Their own jobs only | Do anything, to anyone's jobs: there are no identities |
| An anonymous caller | Nothing | The same as a customer |
| A compromised Pod | Its own job | Reach every service in the cluster |
| An operator | Administrative, audited | Everything, unaudited |
````

to:

````markdown
| Actor | Trust | At the start they could | After Phase 6 they can |
|---|---|---|---|
| A customer (tenant) | Their own jobs only | Do anything, to anyone's jobs: there are no identities | Act on their own jobs, as far as their role allows, at a limited rate |
| An anonymous caller | Nothing | The same as a customer | Be refused (401), as often as they like (T19) |
| A compromised Pod | Its own job | Reach every service in the cluster | Reach what its network policy allows, with its own certificate and short-lived logins |
| An operator | Administrative, audited | Everything, unaudited | Still everything (a non-goal); the audit log shows rewritten history |
````

Change:

<!-- edit: docs/security/threat-model.md -->
````markdown
| # | Element | STRIDE | Threat | Evidence today | Fixed in |
|---|---|---|---|---|---|
| T1 | API (HTTP and gRPC) | S, E | Anyone can create and read jobs; there is no identity at all | `POST /jobs` with no credentials returns 201 | Steps 2, 3 |
| T2 | API | I | Job IDs are sequential: any job can be read by guessing its number | `GET /jobs/1`, `/jobs/2`, ... | Steps 3, 4 |
| T3 | API, workers, database | I, T | No tenants: one customer's jobs are mixed with everyone's | One `jobs` table, no owner column | Step 4 |
| T4 | API, queue | D | One client can fill the commands queue and starve everyone else | Phase 5, step 11: a burst filled the queue in seconds | Step 5 |
| T5 | API | S, T | A captured request or token can be replayed | No expiry, no nonce | Steps 2, 6 |
| T6 | Network inside the cluster | S, T, I | Every Pod can reach every other: a compromised Pod can talk to the database, the broker, Redis and `metad` directly | `kubectl get networkpolicies -A`: none | Steps 7, 12 |
| T7 | Service-to-service traffic | S, I | Plain text, and nothing proves which service is calling | No TLS between services | Steps 7, 8 |
| T8 | Broker | S, T | Every service shares one broker credential; anything holding it can publish events the API will believe | One `RABBITMQ_DEFAULT_USER` in one Secret | Steps 7, 9, 12 |
| T9 | `metad` | S, T, E | Its HTTP API, including locks, has no authentication | `PUT /kv/{key}` needs nothing | Steps 7, 12 |
| T10 | Redis | I, T | No password; cached jobs are readable and writable by any Pod | No `requirepass` | Steps 9, 12 |
| T11 | Database | E | The application connects as a superuser that bypasses row-level security | `rolsuper = t`, `rolbypassrls = t` | Steps 4, 9 |
| T12 | Secrets | I | Kubernetes Secrets are base64, and every key reaches every service through `envFrom` | `deploy/k8s/config.yaml` | Step 9 |
| T13 | Pods | E | API Pods mount a service-account token they never use | `automountServiceAccountToken` unset | Step 12 |
| T14 | Namespace | E | No Pod Security standard is enforced: a privileged Pod could be created here | No `pod-security.kubernetes.io` labels | Step 12 |
| T15 | Audit trail | R | The audit log is append-only and checksummed, but anyone with write access can rewrite history undetected | Phase 3's log has no chaining | Step 10 |
| T16 | Telemetry | I | Job descriptions appear in logs, traces and the cache | Phase 5's traces and logs | Step 11 |
| T17 | Grafana | E, I | Anonymous visitors are administrators | `GF_AUTH_ANONYMOUS_ORG_ROLE=Admin` | Step 12 |
| T18 | Statistics | I | Per-tenant counts over small groups can reveal individuals | Not built yet; designed in step 11 | Step 11 |
````

to:

````markdown
| # | Element | STRIDE | Threat | Evidence at the start | Planned for | At the game day |
|---|---|---|---|---|---|---|
| T1 | API (HTTP and gRPC) | S, E | Anyone can create and read jobs; there is no identity at all | `POST /jobs` with no credentials returns 201 | Steps 2, 3 | Held |
| T2 | API | I | Job IDs are sequential: any job can be read by guessing its number | `GET /jobs/1`, `/jobs/2`, ... | Steps 3, 4 | Held |
| T3 | API, workers, database | I, T | No tenants: one customer's jobs are mixed with everyone's | One `jobs` table, no owner column | Step 4 | Held |
| T4 | API, queue | D | One client can fill the commands queue and starve everyone else | Phase 5, step 11: a burst filled the queue in seconds | Step 5 | Held |
| T5 | API | S, T | A captured request or token can be replayed | No expiry, no nonce | Steps 2, 6 | Held |
| T6 | Network inside the cluster | S, T, I | Every Pod can reach every other: a compromised Pod can talk to the database, the broker, Redis and `metad` directly | `kubectl get networkpolicies -A`: none | Steps 7, 12 | Held |
| T7 | Service-to-service traffic | S, I | Plain text, and nothing proves which service is calling | No TLS between services | Steps 7, 8 | Held |
| T8 | Broker | S, T | Every service shares one broker credential; anything holding it can publish events the API will believe | One `RABBITMQ_DEFAULT_USER` in one Secret | Steps 7, 9, 12 | **Open**: network limited, but one shared login |
| T9 | `metad` | S, T, E | Its HTTP API, including locks, has no authentication | `PUT /kv/{key}` needs nothing | Steps 7, 12 | Held |
| T10 | Redis | I, T | No password; cached jobs are readable and writable by any Pod | No `requirepass` | Steps 9, 12 | Held |
| T11 | Database | E | The application connects as a superuser that bypasses row-level security | `rolsuper = t`, `rolbypassrls = t` | Steps 4, 9 | Held |
| T12 | Secrets | I | Kubernetes Secrets are base64, and every key reaches every service through `envFrom` | `deploy/k8s/config.yaml` | Step 9 | Held |
| T13 | Pods | E | API Pods mount a service-account token they never use | `automountServiceAccountToken` unset | Step 12 | Held |
| T14 | Namespace | E | No Pod Security standard is enforced: a privileged Pod could be created here | No `pod-security.kubernetes.io` labels | Step 12 | Held |
| T15 | Audit trail | R | The audit log is append-only and checksummed, but anyone with write access can rewrite history undetected | Phase 3's log has no chaining | Step 10 | Held (Compose) |
| T16 | Telemetry | I | Job descriptions appear in logs, traces and the cache | Phase 5's traces and logs | Step 11 | Held |
| T17 | Grafana | E, I | Anonymous visitors are administrators | `GF_AUTH_ANONYMOUS_ORG_ROLE=Admin` | Step 12 | Held |
| T18 | Statistics | I | Per-tenant counts over small groups can reveal individuals | Not built yet; designed in step 11 | Step 11 | Held |
| T19 | API | D | Requests with no token are refused but never counted: the rate limit is per tenant | Found at the game day | Not yet | **Open** |
| T20 | Certificates | D | Certificates expire with no warning, and services stop | Happened on 2026-10-15 | Not yet | **Open** |
````

Change:

<!-- edit: docs/security/threat-model.md -->
````markdown
Step 13 attacks the system using this table as the plan, and records what got through.
````

to:

````markdown
Step 13 checked every row against the running system: **29 checks held, 3 are open** (T8, T19, T20). The [game day report](gameday-2026-10-16.md) has each result and what to do next.
````


`Fixed in` became `Planned for`: T8 was planned, and isn't fixed. A column that says otherwise would be the kind of claim this step exists to check.

### What the OWASP API Top 10 looks like now

The phase started with a question from step 1's reading: which of the ten does Runway cover?

| OWASP API Security Top 10 (2023) | Where | Status |
|---|---|---|
| API1 Broken object level authorization | Step 4: tenants, row-level security, the cache key | Covered, tested both ways |
| API2 Broken authentication | Step 2: token verification, step 7: the issuer's keys over mTLS | Covered |
| API3 Broken object property level authorization | The webhook secret is shown once; responses are fixed structs | Partly: nothing checks a response for fields a role shouldn't see |
| API4 Unrestricted resource consumption | Step 5: per-tenant limits | Partly: T19 is open |
| API5 Broken function level authorization | Step 3: one decision point, every route checked | Covered |
| API6 Unrestricted access to sensitive business flows | — | Not covered: Runway has no flow worth automating abuse of yet |
| API7 Server-side request forgery | Step 6: dial-time checks; step 12: the notifier's egress | Covered, twice |
| API8 Security misconfiguration | Steps 7, 9, 12; the chart's `fail` guards | Covered for what's listed; the game day is the check |
| API9 Improper inventory management | Step 1's diagram; step 11's canaries | Partly: no list of every endpoint and version |
| API10 Unsafe consumption of APIs | Step 7: keys only from the real issuer; step 6: the receiver's checks | Covered for the one API Runway consumes |

**Explain it:** why does a check need a control? What did the first T16 prove, and what didn't it? Why is T4's expectation "some" and not a number? For each open finding, what's the smallest change that closes it, and what does it cost? Which of the accepted risks would you not accept, and why?

**Read.** Shostack, *Threat Modeling*, Ch. 9 (validating the model). Then the OWASP API Security Top 10 (2023) in full, against the table above. Then Google's *Building Secure and Reliable Systems* (Adkins et al., 2020), on red teams: what does a real one do that a game day doesn't?

---
## Rebuild it yourself

Close the guide. In your own `runway` repository, rebuild Phase 6 from these contracts:
- the threat model: a data-flow diagram with its trust boundaries, assets, actors, and one row per threat with the evidence that it's real;
- a token's checks, in order (algorithm, key by ID from the issuer, signature, issuer, audience, time), and the rotation of the issuer's keys without breaking anyone;
- one decision point, deny by default, asked by every route and RPC, between authentication and everything else;
- the tenant: from the token only; in the context, the transaction (`SET LOCAL ROLE`, `app.tenant`), the messages, the cache key, the idempotency key; `404` for another tenant's job;
- a token bucket per tenant, shared through an atomic Redis script, charged only for allowed work, failing open to local buckets;
- webhooks signed over ID, timestamp and body, a replay window, two signatures during rotation, and the address checked when dialling;
- a CA with a name constraint, certificates naming SPIFFE identities, mutual TLS checked by identity, reloading without restarts, connections recycled so new certificates are used, and a CA rotated in three phases;
- a layer-4 sidecar for a program that can't speak mTLS, and what it costs;
- logins made per Pod by OpenBao, renewed and revoked; roles with only the grants their code uses; secrets sealed with a key the database never sees;
- a Merkle tree over the audit log, signed checkpoints, and a witness that co-signs only growth;
- redaction by name and by shape, retention for every copy, and statistics with a threshold, a clamp, and noise, published once;
- default-deny network policy, `restricted` Pods, no unused tokens, and a fuzz test for every parser of untrusted input.

Then attack *your* system, writing each prediction down first:
1. forge tokens: `alg: none`, another audience, an expired one, one signed by a key the issuer never published;
2. read another tenant's job through the API, the cache, and the idempotency store;
3. flood as one tenant while another works, and measure the other's wait;
4. replay a captured webhook, change its body, and register an internal address;
5. send a forged Raft vote to `metad`, with and without a certificate;
6. reach Redis from another Pod, then forget the `--bind`;
7. leak a database login and see what it can do, then revoke it while it's in use;
8. edit and truncate the audit log, and see who notices;
9. plant canaries, and search everything for them;
10. probe every port from another namespace, then run the game day.

## Checkpoint

You're ready for Phase 7 when you can, without the guide:

1. Answer Shostack's four questions for Runway, and name the trust boundaries the diagram crosses.
2. Explain each check a JWT verifier makes, the attack it stops, and why the issuer's keys must come from the real issuer.
3. Explain the difference between authentication and authorization, between `401` and `403`, and why one decision point.
4. Explain BOLA, and list every place Runway keys data by ID and how each is scoped to a tenant.
5. Explain row-level security, why it applies to `runway_tenant` and not the owner, and why `current_tenant()` raises.
6. Explain a token bucket, why the Redis version is a Lua script, and why 309 successes didn't prove the bucket was shared.
7. Explain what a webhook signature covers and why, the replay window, and SSRF with DNS rebinding.
8. Explain the head-of-line blocking in the outbox relay, and its fix.
9. Explain mutual TLS with SPIFFE identities, why `ClientConfig` checks identity itself, and why the gateway never reloaded its certificate at first.
10. Explain the three phases of a CA rotation, and what happened without them.
11. Explain what a sidecar costs, where the cost comes from, and what a layer-4 proxy can't see.
12. Explain dynamic database logins, why each fetch logs in afresh, and what happens when OpenBao is sealed.
13. Explain why a hash chain isn't enough for an audit log, what a Merkle tree and a witness add, and what still isn't prevented.
14. Explain the `SECURITY DEFINER` search-path attack, the differencing attack, and what the noise costs.
15. Explain default-deny, why DNS needs its own policy, and why kindnet needed the API server's real address.
16. Explain why a check needs a control, using T16.

## If it goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| The API won't start: `AUTH_ISSUER is required` | Authentication is on by default, and nothing says where the issuer is | Set `AUTH_ISSUER`; or `AUTH_MODE=off`, on a laptop only |
| `idp` crashes: `open /keys/...: permission denied` | The Secret's files are root's, mode `0400` | `fsGroup: 65532` and `defaultMode: 0440` |
| A new signing key isn't used for a minute or more | The kubelet updates mounted Secrets about once a minute; the issuer re-reads every 30 s | Wait; publish new keys before signing with them |
| `helm upgrade` fails: `nil pointer evaluating interface {}.enabled` | `--reuse-values` ignores the chart's new defaults | `--reset-then-reuse-values` |
| The guide's `curl` to the issuer prints `000` | HTTPS from step 7, and `curl` doesn't trust your CA | `--cacert ~/.runway/ca/tls.crt --resolve idp.runway:8081:127.0.0.1` |
| The API answers `Client sent an HTTP request to an HTTPS server` | Plain HTTP to a TLS listener | Use the gateway (`:8000`), or HTTPS with the operator's certificate |
| `502` through the gateway; the API logs `peer identity not allowed` | The gateway has a certificate for another service | `deploy/certs.sh` with the right CA |
| Pods `CrashLoopBackOff` after the machine was off | Certificates expired (a day by default), or OpenBao is sealed | `deploy/certs.sh ~/.runway/ca`; `deploy/bao/init.sh ~/.runway/bao`; then `rollout restart` |
| `kube-proxy` crashes: `fsnotify watcher init: too many open files` | inotify instances exhausted | `sudo sysctl -w fs.inotify.max_user_instances=512`, and persist it |
| The notifier logs `open: not sealed by transit` | A webhook secret stored before step 9 | Rotate the secret (`POST /webhook/secret`) |
| A database login vanishes halfway through its life | The OpenBao token that fetched it expired first | The role's `token_ttl` must be at least the login's TTL |
| `cannot be dropped because some objects depend on it` in OpenBao's log | A migration login created objects it owns | The migrate role's `ALTER ROLE ... SET role = 'runway_owner'` |
| A key removed from a Secret's `stringData` is still there | `stringData` is merged into `data` and never removed | `kubectl patch secret ... -p '[{"op":"remove","path":"/data/KEY"}]'` |
| Tests pass on your machine and fail in CI (or the other way round) around roles | Roles are server-wide, and an old membership hides a change | Test against a fresh PostgreSQL container |
| The migration hook gets `403` from OpenBao after adding network policies | OpenBao's egress lost DNS, so its token reviews time out | Apply `config.yaml`'s `dns` policy before any egress policy |
| A new Pod logs `lookup rabbitmq: i/o timeout`; old Pods are fine | No DNS policy | `kubectl apply -f deploy/k8s/config.yaml` |
| An egress rule to `10.96.0.1:443` doesn't reach the API server | kindnet matches policies after DNAT | Allow the nodes' network on port 6443 |
| `pods "..." is forbidden: violates PodSecurity "restricted:latest"` | A Pod runs as root, keeps capabilities, or has no seccomp profile | Set the `securityContext` the error lists |
| `container has runAsNonRoot and image has non-numeric user` | The image's user is a name | A numeric `runAsUser` |
| PostgreSQL won't start: data directory has invalid permissions | `fsGroup` made the data group-writable | `runAsUser: 999`, and no `fsGroup` |
| Dead letters never expire after setting a TTL policy | Quorum queues expire only from the head, and only messages that arrived under the TTL | Look at them, then `rabbitmqctl purge_queue` once |
| `internal/stream` fails once with `UNKNOWN_SERVER_ERROR` joining a group | Kafka's group coordinator, just after topics or groups were deleted | Run it again |

## Reading list for this phase

| When | Reading | Question to carry in |
|---|---|---|
| Step 1 | Shostack, *Threat Modeling*, Ch. 1–3; the OWASP API Security Top 10 (2023) | Which threats did your last system's design never write down? |
| Step 2 | RFC 8725; McLean, *Critical vulnerabilities in JSON Web Token libraries*; RFC 6749 §4.4; OIDC Discovery | Which of the five checks would a library's defaults skip? |
| Step 3 | NIST SP 800-162; Pang et al., *Zanzibar* (ATC 2019) | When does RBAC stop being enough? |
| Step 4 | OWASP API1:2023; PostgreSQL row security; AWS, *SaaS Tenant Isolation Strategies* | Where would one large tenant go, and how? |
| Step 5 | Stripe, *Scaling your API with rate limiters*; the RateLimit header draft; Amazon Builders' Library on fairness | What does a rate limit not protect? |
| Step 6 | Standard Webhooks; OWASP SSRF cheat sheet; RFC 8705 | What else in your systems makes requests to addresses users choose? |
| Step 7 | Ristić, *Bulletproof TLS and PKI*; SPIFFE concepts; *BeyondCorp*; RFC 5280 §4.2.1.10 | What does a certificate prove, and for how long? |
| Step 8 | Istio's architecture; Linkerd on proxies; native sidecars; CFS quota throttling | What would a mesh cost Runway, in CPUs? |
| Step 9 | OpenBao's database engine and Kubernetes auth; PostgreSQL `GRANT` (16); Shamir, *How to Share a Secret*; encryption at rest | Which secret in your last job lived longest, and why? |
| Step 10 | RFC 9162 §2.1; Cox, *Transparent Logs for Skeptical Clients*; C2SP checkpoint and witness | Who would run Runway's witness? |
| Step 11 | GDPR Art. 5 and 25; Dwork and Roth, Ch. 1–3; Mironov (CCS 2012); PostgreSQL on `SECURITY DEFINER` | What would you publish about your users, and what could be subtracted? |
| Step 12 | Kubernetes network policies and Pod Security Standards; NSA/CISA *Kubernetes Hardening Guide*; Go fuzzing; OSS-Fuzz | Which of your parsers has never seen a hostile input? |
| Step 13 | Shostack, Ch. 9; the OWASP API Top 10 in full; *Building Secure and Reliable Systems* on red teams | What would someone paid to break Runway try first? |
| After the phase | Anderson, *Security Engineering* (3rd ed.), Ch. 1–3 and the chapters on access control and cryptographic protocols | Which of this phase's controls rests on an assumption nobody checked? |
