# Phase 8: Defend the design and publish reproducible evidence

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: full code in `steps/`, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This is the final self-study lesson. It turns the working KESTREL prototype and the evidence from Phases 0–7 into a reviewable research artifact. The goal is clear claims with reproducible evidence and stated limits, not a claim that a prototype is production-ready.

## The goal

A technically capable reader should be able to build the system from a clean checkout, reproduce the key experiment, follow the threat model, observe one controlled failure, and decide whether the claims are supported.

## Before you start

Finish Phases 0–7. Bring the phase evidence, architecture and decision records, tests, threat model, runbooks, experiment manifest, raw results, and limitations. If an earlier gate is missing, complete it first; the capstone consolidates evidence rather than hiding gaps.

## 1. Build a claim/evidence table

Write each statement you want to make as a row:

| Claim | Scope/assumptions | Evidence | Remaining limit |
|---|---|---|---|
| Example: committed metadata survives one-node loss | three crash-fault nodes; majority available | partition test and history checker | not Byzantine-safe; not a WAN production study |

Remove claims that have no evidence. Prefer a narrow claim that is demonstrated over a broad claim that sounds impressive. Separate “tested in this configuration” from “guaranteed by the protocol.”

## 2. Review the security design

Update the threat model with assets, actors, trust boundaries, attacker capability, failure assumptions, mitigations, and residual risks. Check request validation, object-level authorization, service identity, TLS/mTLS, secrets, least privilege, log contents, backup handling, query leakage, and failure defaults.

Use the current OWASP API Security Top 10 as an awareness checklist and selected OWASP ASVS requirements as verification prompts. This is a project review, not an audit certification. For each control, attach a test or mark it as unverified.

For the container controls, inspect the Phase 5 Dockerfile and Deployment: record the configured non-root UID, dropped Linux capabilities, read-only root filesystem, privilege-escalation setting, and seccomp profile. Mark a declared setting as configuration evidence; claim runtime enforcement only if you have an observation that tests it.

## 3. Review dependencies and artifacts

Install and run Go's govulncheck from every Go module used by the completed lessons:

~~~bash
go install golang.org/x/vuln/cmd/govulncheck@latest
(cd lessons/00-request-service && govulncheck ./...)
(cd lessons/01-reliable-service/practice && govulncheck ./...)
(cd lessons/02-connected-services/practice && govulncheck ./...)
(cd lessons/03-durable-auditable-data/practice && govulncheck ./...)
(cd lessons/04-replicated-state/practice/6.5840 && govulncheck ./...)
(cd lessons/05-constrained-operations/practice && govulncheck ./...)
(cd lessons/06-safe-shared-queries/practice && govulncheck ./...)
(cd lessons/07-utility-evaluation/practice && govulncheck ./...)
~~~

Build the Phase 5 image from the repository root, then scan it with Trivy and generate an SBOM with Syft:

~~~bash
mkdir -p artifacts
docker build -t kestrel-api:phase5 lessons/05-constrained-operations/practice
docker image inspect kestrel-api:phase5 --format '{{.Id}}'
trivy image --scanners vuln kestrel-api:phase5
syft kestrel-api:phase5 -o cyclonedx-json > artifacts/kestrel-api.cdx.json
~~~

Record tool versions, image ID/digest, source commit, scan date, SBOM path, and findings. Evaluate each finding: reachable or not, affected version, fix, and residual risk. Do not equate “zero findings” with “secure.”

Generate a software bill of materials (SBOM), which is a machine-readable inventory of included components. If signing the release artifact, sign a digest and verify it from a clean environment; document key custody. Keep signing keys and live secrets out of the repository and CI logs.

## 4. Run the adversarial and failure review

Use synthetic inputs to attempt: invalid object IDs, wrong-site access, expired or replayed query, oversized body, malformed versioned record, corrupt log record, duplicate message, missing policy service, lost Raft quorum, and constrained network. For each attempt record expected behavior, actual behavior, logs/metrics, data released, and recovery.

Run the Rust decoder's generated-input properties from Phase 3, then run the native Go fuzz target from Phase 6:

~~~bash
(cd lessons/03-durable-auditable-data/practice/rust-log && cargo test bounded_arbitrary_bytes_never_panic)
(cd lessons/06-safe-shared-queries/practice && go test -run=^$ -fuzz=FuzzDecodeQueryJSON -fuzztime=30s ./internal/query)
~~~

A fuzz test searches generated inputs for crashes or invariant violations; passing for a fixed run does not prove the absence of all bugs. Repeat the most important Phase 4 and Phase 5 failure tests from their documented runbooks.

## 5. Reproduce the central result

From a clean checkout, follow a single script or numbered command sequence. Use the documented tool versions, synthetic/public dataset, manifest, and seed. Regenerate the tables and plots in a new output directory. Compare the regenerated values to the report and explain any difference.

The reproduction instructions must not rely on a hidden local file or secret. Use example configuration and environment variables. If a step needs credentials, document a local substitute rather than publishing credentials.

## 6. Write the report

Use this structure:

1. Abstract: question, method, main result, main limit.
2. Problem and user context: what was validated and what remains assumed.
3. System model and threat model.
4. Architecture and important data flows.
5. Design decisions and rejected alternatives.
6. Implementation and reproducibility instructions.
7. Evaluation method, baseline, workload, environment, and results.
8. Security/privacy analysis and failure behavior.
9. Limitations, negative results, and open questions.
10. Conclusion and next test that would most change your view.

Every graph needs labeled axes, units, workload, and a source command. Every security claim needs its boundary. Every AI-related result, if any, must distinguish the small optional sampler from the KESTREL core.

## 7. Present and defend

Prepare a short architecture explanation, a live failure demonstration, and answers to reviewer questions: Why local records? Why replicate this metadata? What happens without a quorum? What does an audit event prove? Which data crosses a site boundary? When does the centralized baseline win? What assumptions or results would make you change the design?

Do not memorize a presentation. Use the claim/evidence table and traces to reason from what the system did.

## Completion gate

The capstone is complete when another person can reproduce the build and main result, you can demonstrate a failure and a policy bypass attempt that is rejected, the threat model and limitations are explicit, and the report does not overstate security, privacy, availability, or clinical value.

Complete learned.md. For the final Kestrel transfer, close the lesson and prepare the report and defense from your own phase records. Recreate the release and experiment from the written procedure; do not copy a final answer. Preserve unresolved questions rather than filling them with assumptions.

## Read beside the capstone

Use the reading to check the claim you are reviewing, rather than opening an unrelated reading list.

| When | Read | Carry this question into the review |
|---|---|---|
| While refining the threat model | Anderson, *Security Engineering*, 3rd ed., sections on opponents, distributed systems, secure development, and assurance; van Steen & Tanenbaum sections on distributed-systems security | Which attacker capability does each control address, and what remains exposed? |
| While reviewing authentication and transport | Kurose & Ross, 8th ed., Chapter 8 sections on TLS and firewalls | Which peer is authenticated, and what data is still visible at each endpoint? |
| Before checking dependencies and images | Go's [govulncheck tutorial](https://go.dev/doc/tutorial/govulncheck), [Kubernetes security concepts](https://kubernetes.io/docs/concepts/security/), and the scanner/SBOM tool's official documentation | Which vulnerable component is reachable in this build, and what does the inventory not prove? |
| Before release provenance | Read the [in-toto overview](https://in-toto.io/) and [Sigstore/cosign verification guide](https://docs.sigstore.dev/cosign/verifying/verify/) | Can another person connect this artifact to the source and build that produced it? |
| After choosing the capstone claim | Read the evaluation section of the closest primary paper and record its workload, baseline, and assumptions | Which parts of your result are comparable, and which are not? |

Use the [OWASP API Security Top 10](https://api-security.owasp.org/editions/2023/en/0x00-header/) and [OWASP ASVS](https://owasp.org/www-project-application-security-verification-standard/) as review aids. A checked item records evidence; it does not certify the system.
