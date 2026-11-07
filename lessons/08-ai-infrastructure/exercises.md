# Exercise: modelgate

Build an inference service for a shared documentation assistant. This is an independent project: the specification defines finished behaviour and deliberately provides no solution.

## Contract

- Two tenants, `acme` and `hooli`, authenticate with distinct identities. No caller can select its tenant with request data. The raw model server is unreachable from outside the serving network.
- Accept bounded chat prompts and streamed responses. Reject excessive context before generation, using the deployed tokenizer and template. Describe exactly which settings callers may control.
- Enforce a shared per-tenant token budget across at least two gateway replicas, reserving prompt plus maximum output. Document settlement on success, timeout, disconnect and retry. A concurrent test proves reservations cannot overspend the budget.
- Bound waiting and active generation globally and per tenant. A noisy tenant cannot consume another's reserved capacity indefinitely. Return explicit overload responses with retry guidance. A request deadline includes queueing.
- Client disconnects cancel upstream work; backend slot evidence proves capacity is released. A partially delivered response is never transparently replayed.
- Record time to first content, completion, output-token usage, queue delay and failure for every offered request. Expose bounded-cardinality metrics and traces without prompt or credential contents.

## Release and operations

- Release an immutable image, model artifact and chat template with digests, licenses, SBOMs and provenance. Verify the expected signing identity before deploy and before loading weights.
- Prove unsigned images, modified weights, missing signatures and an unauthorised but correctly signed model revision are refused. Include key rotation and rollback in the runbook.
- Deploy with readiness that reflects model load completion. Measure cold and warm starts. Show what happens to queued requests during replacement; state the spare capacity needed for a zero-downtime rollout.
- Rehearse backend crash, overload, slow consumers and corrupt release. Report detection/recovery times and the all-arrivals objective throughout. Do not infer recovery from pod readiness alone.

## Experiments

Freeze prompts, expected answers/rubric and release thresholds before measuring. Include short/long prompts, mixed output lengths and one adversarial tenant. Compare at least two batching configurations and two precisions, with repeat runs in interleaved order. State the price assumption or invoice, include idle capacity, and report cost per completed output token alongside quality and latency. Keep missing usage and failures visible.

Train a small model with two CPU ranks, prove global-batch update parity against one rank, checkpoint and resume after killing a worker. Explain any repeated training examples. If you use Ray, demonstrate retry-safe external effects, not merely successful scheduling. A GPU is optional for this exercise: record GPU claims as not measured when unavailable.

## Done when

- A fresh checkout can reproduce correctness checks and deployment from the release instructions.
- Automated tests demonstrate tenant isolation, atomic token reservations, bounded queues, deadline/cancellation and truncated-stream detection under concurrency.
- Every release-refusal case and failure rehearsal has a command transcript and observed outcome.
- The benchmark includes raw per-arrival data, seeds, hashes, quality scores, independent-run intervals and cost accounting.
- The report has at least one negative or inconclusive result, explicit unmeasured claims, and a justified configuration choice. A configuration failing quality cannot win on speed alone.
- You can defend the design and its limits without opening the guide.
