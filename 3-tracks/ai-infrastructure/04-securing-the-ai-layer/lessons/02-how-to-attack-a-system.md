# 02 How to attack a system

The threat model is a set of hypotheses. Now turn one into a request, observe which boundary it crosses, and keep enough evidence for someone else to repeat it. Start with the Phase 8 gateway, before adding retrieval or tools.

## Scope and rules

Write the scope before sending requests. A target is an address and a deployment you control, not a product name. For this step:

<!-- file: docs/security/attack-scope.md -->
~~~markdown
# Gateway assessment scope

- Target: this lab's gateway and its scripted model dependency on loopback.
- Optional live target: my own local Runway API and model server from Phase 8.
  Record their exact addresses, source revision and image digest before use.
- Actors: no credentials, and a synthetic tenant user allowed to generate.
- Allowed: single-request mutations of JSON, headers and output limits.
- Limits: sequential requests, body at most 65,537 bytes, output at most
  513 requested tokens (one above the accepted maximum). No load test.
- Stop: unexpected external traffic, real customer data, or an unrelated
  service becoming unhealthy. Save the observation and investigate first.
- Evidence: synthetic payloads, status codes, dependency-call counts and
  test output. Never commit bearer tokens or raw authenticated proxy flows.
- Excluded: public services, third-party webhooks and cloud resources.
~~~

The numerical limits make the exercise reproducible. They are not permission to test a service you don't own. A denial-of-service hypothesis can first be checked by counting one unwanted dependency call; you don't need to exhaust the machine to prove that call happened.

## Map the attack surface

Read `gateway/internal/inference/gateway.go`, `tokenizer.go`, and the Switchyard adapter from Phase 8. Follow one request in order:

| Surface | Who controls it? | Boundary and question |
|---|---|---|
| Bearer token | Caller supplies it; Switchyard verifies it | Can an unauthenticated caller reach tokenization? |
| Tenant header or JSON field | Caller | Does either override the verified tenant? |
| Request body | Caller | Are both its size and its nested shape bounded? |
| `max_tokens` | Caller | Can it exceed 512 or bypass the reservation? |
| `model`, `tools`, backend URL | Caller may try adding them | Does the fresh backend request discard them? |
| `messages` | Caller | Is the nested value checked before calling the template endpoint? |
| Template, tokenizer and model response | Model dependency | Which calls happen before accounting, and what does an error mean? |

Change one thing at a time. First send a valid request and confirm it completes; otherwise an unavailable server can look like a successful defence. Then remove the token, change the tenant header, exceed the size or output limit, and mutate `messages`. Record the expected result *before* sending each payload.

Here's the first hypothesis, **G1** (related to A11, resource abuse): **an authenticated caller can make malformed message data reach the template endpoint before paying a token reservation.** The gateway bounds the body to 64 KiB, but `messages` is a `json.RawMessage`: valid JSON bytes, without a checked message schema. `null` is valid JSON. The tokenizer adapter sends it to `/apply-template`; if that dependency rejects it, the gateway returns 502, making bad caller input look like a broken backend.

The existing queue and deadline still bound concurrent work. The claim to test is an avoidable template call and an incorrect error classification. An outage, a quota bypass for successful generations, and a leak are separate claims requiring separate evidence.

## Reproduce before fixing

Use the actual gateway and `LlamaTokenizer` HTTP adapter with a scripted dependency. The dependency rejects null or empty message lists, returns four synthetic tokens for a valid list, and streams a fixed answer. That makes the boundary test deterministic, without downloading weights. The identity callback is Phase 8's **test-only** callback: these tests do not validate JWT signatures or the API's generator-role policy.

Create the following file. The assertions describe the desired secure behaviour, so the first run must fail on the existing gateway.

<!-- file: gateway/internal/inference/message_boundary_test.go -->
~~~go
package inference

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

// This fixture exercises the real gateway and HTTP tokenizer adapter. The
// model dependency is scripted: these tests make no model-quality claims.
type boundaryLab struct {
	gateway  *Gateway
	template atomic.Int64
	generate atomic.Int64
	reserved atomic.Int64
}

func newBoundaryLab(t *testing.T) *boundaryLab {
	t.Helper()
	lab := &boundaryLab{}
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/apply-template":
			lab.template.Add(1)
			var input struct {
				Messages []struct {
					Role    string `json:"role"`
					Content string `json:"content"`
				} `json:"messages"`
			}
			if json.NewDecoder(r.Body).Decode(&input) != nil || len(input.Messages) == 0 {
				http.Error(w, "invalid messages", 400)
				return
			}
			io.WriteString(w, `{"prompt":"synthetic template"}`)
		case "/tokenize":
			io.WriteString(w, `{"tokens":[1,2,3,4]}`)
		case "/v1/chat/completions":
			lab.generate.Add(1)
			var input map[string]json.RawMessage
			if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
				t.Error(err)
			}
			for _, key := range []string{"model", "tools", "url", "tenant"} {
				if _, exists := input[key]; exists {
					t.Errorf("caller field %q reached generation", key)
				}
			}
			w.Header().Set("Content-Type", "text/event-stream")
			io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"river\"}}]}\n\ndata: [DONE]\n\n")
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(backend.Close)
	// Test-only identity callback. JWT signatures, expiry and the generator
	// role remain the existing Runway middleware's responsibility.
	lab.gateway = New(backend.URL, identity, LlamaTokenizer(backend.URL), 1, 0, 100)
	lab.gateway.UseReservation(func(_ context.Context, tenant string, cost int) (bool, error) {
		lab.reserved.Add(1)
		if tenant != "acme" || cost != 12 {
			t.Errorf("reservation tenant=%q cost=%d", tenant, cost)
		}
		return true, nil
	})
	return lab
}

func (lab *boundaryLab) request(body string, authenticated bool) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "/v1/chat/completions", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Tenant", "victim")
	if authenticated {
		r.Header.Set("Authorization", "test")
	}
	w := httptest.NewRecorder()
	lab.gateway.ServeHTTP(w, r)
	return w
}

func TestGatewayRejectsMalformedMessages(t *testing.T) {
	cases := []struct{ name, messages string }{
		{"null", `null`},
		{"empty", `[]`},
		{"scalar", `"hello"`},
		{"object", `{"role":"user","content":"hello"}`},
		{"null-entry", `[null]`},
		{"missing-content", `[{"role":"user"}]`},
		{"null-content", `[{"role":"user","content":null}]`},
		{"blank-content", `[{"role":"user","content":" \n\t"}]`},
		{"unknown-role", `[{"role":"root","content":"hello"}]`},
		{"tool-role", `[{"role":"tool","content":"hello"}]`},
		{"nested-tool", `[{"role":"assistant","content":"hello","tool_calls":[]}]`},
		{"image-content", `[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.invalid/image"}}]}]`},
		{"too-many", "[" + strings.Repeat(`{"role":"user","content":"hi"},`, 64) + `{"role":"user","content":"hi"}]`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			lab := newBoundaryLab(t)
			body := `{"messages":` + tc.messages + `,"max_tokens":8,"stream":true}`
			w := lab.request(body, true)
			t.Logf("status=%d template=%d reservation=%d generation=%d", w.Code,
				lab.template.Load(), lab.reserved.Load(), lab.generate.Load())
			if w.Code != 400 || lab.template.Load() != 0 || lab.reserved.Load() != 0 || lab.generate.Load() != 0 {
				t.Fatalf("want 400 before template/reservation/generation; got %d", w.Code)
			}
			if active, admitted := lab.gateway.InFlight(); active != 0 || admitted != 0 {
				t.Fatal("capacity leaked")
			}
		})
	}
}

func TestGatewayMalformedMessagesBeforeAdmission(t *testing.T) {
	lab := newBoundaryLab(t)
	lab.gateway.admitted <- struct{}{}
	lab.gateway.active <- struct{}{}
	defer func() {
		<-lab.gateway.active
		<-lab.gateway.admitted
	}()
	w := lab.request(`{"messages":null,"max_tokens":8,"stream":true}`, true)
	if w.Code != 400 || lab.template.Load() != 0 || lab.reserved.Load() != 0 || lab.generate.Load() != 0 {
		t.Fatalf("invalid messages must be refused even when capacity is occupied: status=%d", w.Code)
	}
	if active, admitted := lab.gateway.InFlight(); active != 1 || admitted != 1 {
		t.Fatal("invalid request changed occupied capacity")
	}
}

func TestGatewayBoundaryControls(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
		auth bool
		want int
	}{
		{"valid", request, true, 200},
		{"no-token", request, false, 401},
		{"oversized", strings.Repeat("x", (64<<10)+1), true, 413},
		{"output-limit", strings.Replace(request, `"max_tokens":8`, `"max_tokens":513`, 1), true, 400},
		{"missing-messages", `{"max_tokens":8,"stream":true}`, true, 400},
		{"allowlist", strings.Replace(request, `"stream":true`, `"stream":true,"tenant":"victim","model":"other","tools":[],"url":"https://example.invalid"`, 1), true, 200},
		{"conversation", `{"messages":[{"role":"system","content":"Be brief"},{"role":"user","content":"hi"},{"role":"assistant","content":"hello"},{"role":"user","content":"again"}],"max_tokens":8,"stream":true}`, true, 200},
		{"64-messages", `{"messages":[` + strings.Repeat(`{"role":"user","content":"hi"},`, 63) + `{"role":"user","content":"hi"}],"max_tokens":8,"stream":true}`, true, 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			lab := newBoundaryLab(t)
			w := lab.request(tc.body, tc.auth)
			if w.Code != tc.want {
				t.Fatalf("want %d; got %d: %s", tc.want, w.Code, w.Body.String())
			}
			wantCalls := int64(0)
			if tc.want == 200 {
				wantCalls = 1
				if !bytes.Contains(w.Body.Bytes(), []byte("data: [DONE]")) {
					t.Fatal("stream did not complete")
				}
			}
			if lab.template.Load() != wantCalls || lab.reserved.Load() != wantCalls || lab.generate.Load() != wantCalls {
				t.Fatalf("template=%d reservation=%d generation=%d; want %d each",
					lab.template.Load(), lab.reserved.Load(), lab.generate.Load(), wantCalls)
			}
		})
	}
}
~~~

Run just the smallest payload first. The command keeps its failing output and checks that the failure came from our assertion. A compiler error is not evidence that an attack worked.

<!-- run: mkdir -p docs/security/evidence && cd gateway && gofmt -w internal/inference/message_boundary_test.go && if go test -count=1 -v -run '^TestGatewayRejectsMalformedMessages/null$' ./internal/inference > ../docs/security/evidence/g1-before.txt 2>&1; then cat ../docs/security/evidence/g1-before.txt; exit 1; else cat ../docs/security/evidence/g1-before.txt; grep -q 'status=502 template=1 reservation=0 generation=0' ../docs/security/evidence/g1-before.txt && grep -q 'want 400 before template/reservation/generation; got 502' ../docs/security/evidence/g1-before.txt; fi -->

Read the four observations together: `502`, one template call, no reservation, no generation. The counter is stronger evidence than the HTTP status alone: it tells you where the request went. The test sends a forged `X-Tenant: victim` too; positive controls later verify that accounting still uses the identity callback's `acme` tenant.

**Your turn:** run the whole `TestGatewayRejectsMalformedMessages` table before reading the fix. Which payloads does the scripted dependency reject? Which does it accept? The fake deliberately validates less than our proposed contract. Its answer cannot establish how a particular real model server treats tool fields or image content. Keep those distinctions in your report.

## Fix the boundary before allocating capacity

Make the gateway's supported contract explicit: 1–64 messages, each with a `system`, `user` or `assistant` role and nonempty text content. This route supports text chat; tool results and multimodal content will need their own schemas when they are introduced. Reject extra message fields. Keep Phase 8's top-level allowlist: unknown outer fields are discarded, not forwarded.

`system` remains a supported chat role here. It gives a caller no platform permissions. Later the operations assistant will construct its own model conversation; its trusted instructions and retrieved text must have separate provenance. This input validator does not stop prompt injection inside valid text.

Decode into typed messages and marshal them back once. Both tokenization and generation then use that same representation. Go's [JSON decoder](https://pkg.go.dev/encoding/json#Decoder.DisallowUnknownFields) can reject unknown struct fields, but this does not reject duplicate keys or case variants; decoding and re-encoding normalizes them using this decoder's semantics. Do not put authorization decisions in message fields.

<!-- file: gateway/internal/inference/messages.go -->
~~~go
package inference

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
)

// Validate the text-only contract before acquiring model capacity. Re-encode
// it so tokenization and generation receive the same bounded representation.
func validateMessages(raw json.RawMessage) (json.RawMessage, error) {
	var messages []struct {
		Role    string `json:"role"`
		Content string `json:"content"`
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&messages); err != nil {
		return nil, err
	}
	if len(messages) < 1 || len(messages) > 64 {
		return nil, errors.New("messages must contain 1..64 entries")
	}
	for _, message := range messages {
		switch message.Role {
		case "system", "user", "assistant":
		default:
			return nil, errors.New("unsupported message role")
		}
		if strings.TrimSpace(message.Content) == "" {
			return nil, errors.New("message content must be nonempty text")
		}
	}
	return json.Marshal(messages)
}
~~~

In `gateway/internal/inference/gateway.go`, insert the check immediately before admission:

<!-- edit: gateway/internal/inference/gateway.go -->
~~~go
	// Bound tokenizer work as well as generation. This is bounded admission,
~~~

to:

~~~go
	input.Messages, err = validateMessages(input.Messages)
	if err != nil {
		http.Error(w, "invalid messages", 400)
		return
	}
	// Bound tokenizer work as well as generation. This is bounded admission,
~~~

The original 64 KiB body limit bounds parsing. This new check bounds the shape before either the admitted or active semaphore is acquired. Template failures for *valid* messages still return 502: a dependency can really be unavailable, and that needs different handling from a caller's invalid request.

Now run the same probes, plus Phase 8's existing gateway tests. Keep the output separately from the pre-fix evidence.

<!-- run: cd gateway && gofmt -w internal && go vet ./... && go test -race -timeout=30s -count=1 -v ./... > ../docs/security/evidence/g1-after.txt 2>&1 && cat ../docs/security/evidence/g1-after.txt -->

The [recorded component assessment](../evidence/gateway-assessment/report.md) retains the before/after test output and its limits.

Each malformed-message subtest must now report `status=400 template=0 reservation=0 generation=0`. The positive controls must still stream `[DONE]`, charge the verified tenant, accept the 64-message boundary, and discard forbidden outer fields. The 65-message case must fail. Switchyard's existing JWT and shared-reservation integration test remains a separate live check from Phase 8.

## Inspect and change a live request

An **intercepting proxy** pauses a request between your client and your service so you can inspect or edit it. Use [mitmproxy's interception tutorial](https://docs.mitmproxy.org/stable/mitmproxytutorial-interceptrequests/) and [request-editing tutorial](https://docs.mitmproxy.org/stable/mitmproxytutorial-modifyrequests/) as references. The exercise below is learner-run; the automated probes above do not require a proxy or a model server.

Copy the updated `internal/inference` package into your existing Switchyard module, preserving its `shared.go` and integration tests, then rebuild the API. Use the existing Phase 8 issuer to mint a short-lived synthetic `generator` token. Start your local model server, Redis and API as in Phase 8. For this exercise expose the development API on `127.0.0.1:8080`; the model's own port is not the target. Keep any existing mTLS listener intact.

In one terminal, start an installed mitmproxy on loopback:

~~~bash
mitmproxy --listen-host 127.0.0.1 --listen-port 8081
~~~

Press `i` and set the interception filter to `~u /v1/chat/completions & ~q`. In another terminal, from the lab directory, send the same valid request. `RUNWAY_TOKEN` is the synthetic token already exported by your Phase 8 setup. `--noproxy ''` makes curl use the proxy even if your environment bypasses loopback addresses.

~~~bash
curl --noproxy '' --proxy http://127.0.0.1:8081 \
  --max-time 60 --no-buffer --include \
  http://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer $RUNWAY_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"messages":[{"role":"user","content":"Say river"}],"max_tokens":8,"stream":true}'
~~~

Select the paused flow, open it with Enter, use `e` to edit the request body, then `a` to resume it. First forward the valid request unchanged and confirm the stream completes. Repeat it and replace `messages` with `null`; expect 400 after the fix. Repeat again, remove the Authorization header, and expect 401. The proxy may update Content-Length when you edit; verify that the forwarded request contains the body you intended.

This loopback exercise uses HTTP, so it needs no interception certificate. For a separate TLS exercise, trust the proxy CA only in the disposable test client and configure upstream verification and any client certificate deliberately. Turning off verification would change the boundary you're testing.

The proxy displays the bearer token. Keep flows local and use synthetic data; save a redacted payload and the status to your report instead of publishing the raw flow. These manual checks must be labelled with your own time, revision and model image digest. A real server can reject more inputs than the scripted dependency; that doesn't undo evidence that the old gateway sent malformed data across its boundary.

## Write the finding

A vulnerability report connects an attacker-controlled input to a violated assumption and a measured effect. It also says what the experiment did not establish. Keep this seven-part record beside the raw output. These observations are from the scripted component test; add live observations only after you run them.

<!-- file: docs/security/g1-message-boundary.md -->
~~~markdown
# G1: unchecked messages consume template work before reservation

Evidence class: deterministic component test with a scripted model dependency.
Related threat: A11 (resource abuse). Preconditions: authenticated caller.

1. Threat: a caller submits malformed messages to consume avoidable
   template work before any token reservation.
2. Security assumption: malformed message structures are refused at the
   gateway before model capacity or model endpoints are used.
3. Test: TestGatewayRejectsMalformedMessages/null sends messages:null
   through the Phase 8 gateway and its real HTTP tokenizer adapter.
4. What happened: before the fix, HTTP 502; template=1, reservation=0,
   generation=0. After the fix, HTTP 400; all three counters are zero.
   Raw output: evidence/g1-before.txt and evidence/g1-after.txt.
5. Vulnerability: messages were retained as unchecked JSON. The template
   endpoint was the first schema validator. Scope: avoidable dependency
   work and error misclassification. The queue and deadline still bounded
   concurrency. No outage, data leak or successful-generation quota bypass
   was demonstrated. Operational severity needs a separate impact test.
6. Mitigation: validate a bounded text-message schema before admission,
   then reuse its canonical encoding for tokenization and generation.
7. Regression: TestGatewayRejectsMalformedMessages checks 13 mutations;
   TestGatewayBoundaryControls checks successful streaming, identity-based
   reservations, discarded caller fields, size/output limits and 64/65
   message boundaries. The original Phase 8 gateway suite still passes.

Remaining: valid text can contain prompt injection. This fix is not a
prompt defence or an authorization policy. Live JWT, model and proxy
checks require the learner's running Phase 8 environment.
~~~

Keep hypotheses that *didn't* find a bug too. The missing-token, forged-tenant and outer-field probes exercise controls Phase 8 already had. A security assessment is allowed to conclude a boundary held.

**Break it:** temporarily remove the `validateMessages` call from `ServeHTTP`, rerun the null-message regression and watch it fail with the original counters. Restore the call and rerun the suite. Do this in the lab copy; keep the fixed guide as the source of truth.

**Explain it:** why isn't a 502 alone enough evidence? Why do these tests use a real tokenizer adapter and a scripted model? What does a forged tenant header prove here, and which JWT checks remain untested? Why can a valid string still carry an injection? What additional experiment would justify claiming denial of service?

**Done when:** you have the scope, a failing pre-fix probe, a passing post-fix suite, and the seven-part finding. You can identify exactly which boundary each observation tests. If you also ran the proxy exercise, keep its redacted evidence and environment details separately. Step 3 adds retrieval.

---

---
