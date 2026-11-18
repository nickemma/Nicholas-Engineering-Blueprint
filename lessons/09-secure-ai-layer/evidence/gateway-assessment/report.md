# Phase 9 Step 2: gateway assessment

Recorded 2026-11-14 Pacific time, with Go 1.26.6 on linux/amd64. The starting
gateway comes from Phase 8 at repository revision `b077937`; the fix and tests
are inline in the [Phase 9 guide](../../TEACHING.md#step-2-how-to-attack-a-system).

These are component checks using the actual gateway and `LlamaTokenizer`
HTTP adapter with a scripted model dependency on temporary loopback ports.
The identity callback is test-only. No real model, JWT issuer, proxy, Redis,
Kubernetes cluster or GPU was used for this assessment.

## Finding G1

| Probe | Before the fix | After the fix |
|---|---|---|
| `messages: null` | 502; template=1, reservation=0, generation=0 | 400; all three counters=0 |
| All 13 malformed-message cases | All violated the expected boundary; some reached scripted generation | All refused with 400 before any dependency/accounting call |
| Malformed messages with occupied capacity | Not separately measured before the fix | 400; occupied capacity unchanged |
| Valid request and conversation | Not separately measured in this assessment before the fix | Complete streams; reservation uses verified `acme`, despite forged tenant fields |
| 64/65-message boundary | Not separately measured before the fix | 64 accepted; 65 refused before template work |
| Missing token, body and output limits, outer-field allowlist | Existing Phase 8 controls | Positive and negative controls passed |

Raw output: [before](before.txt), [after](after.txt). The failing pre-fix run
is intentional: its assertions describe the required secure behaviour.
The after file includes the original Phase 8 gateway tests and the new
occupied-capacity check, run with the race detector.

The vulnerability was unchecked nested message data crossing into the template
endpoint before token reservation. The fix validates a bounded text-message
schema before admission, then reuses its encoded representation for both
tokenization and generation. The gateway still accepts `system` messages on
its general text-chat route; that role does not confer platform permissions.

The demonstrated impact is avoidable dependency work and error
misclassification. Concurrency and deadlines remained bounded. These tests
do not establish denial of service, a successful-generation quota bypass,
prompt-injection resistance or the behaviour of a particular real model.

## Reproduction

From the repository root:

~~~bash
python3 scripts/check_guides.py --keep lessons/09-secure-ai-layer/TEACHING.md
~~~

The complete replay passed **91 extracted actions**, including the Phase 8
prerequisite and Step 2's expected failing probe followed by the fixed suite.
It creates `docs/security/evidence/g1-before.txt` and `g1-after.txt` in its
scratch directory. The final gateway suite was also run separately with
`go vet ./...` and `go test -race -timeout=30s -count=1 -v ./...` after adding
the occupied-capacity regression. Both passed.

The local sandbox initially blocked HTTP test-server sockets. The retained
before/after measurements come from reruns with loopback networking enabled,
not from that environment failure. The guide's manual proxy and real-model
checks remain learner-run and have no measured results here.
