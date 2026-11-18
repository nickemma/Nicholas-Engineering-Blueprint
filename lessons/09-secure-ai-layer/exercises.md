# Exercise: incidentdesk

Build an incident assistant for two organizations sharing a support platform. This is an independent project: this specification gives requirements, not a solution.

## Product contract

The assistant answers questions using organization-owned tickets and runbooks. It can propose reopening a ticket, adding a private note, or notifying an organization-approved destination. An ordinary reader may ask questions; an operator may confirm a permitted mutation. Identity and organization come from verified authentication, never request text or model output.

Every answer cites the exact document revisions used. The browser renders output without executing HTML, fetching images or producing automatic previews. Documents and tool results remain untrusted even when imported by a trusted integration.

## Security contract

- Retrieve through a least-privilege database role with row security. An intentionally omitted application filter must not reveal another organization's rows. Show missing-context and pooled-connection behaviour.
- Validate model output with a bounded schema. Expose no arbitrary SQL, shell, filesystem, URL-fetch or executable-plugin tool.
- Authorize each tool call independently. A confirmed action binds user, organization, request, object, action, all arguments, expiry and replay protection. Changing a note after confirmation must invalidate it.
- Commit mutation, replay/idempotency state, audit and notification outbox durably. Kill the service after the commit but before the response; retry must not duplicate the effect. Explain the transaction and recovery boundary.
- Notifications use registered destinations plus content-specific confirmation and the platform's SSRF protections. A permitted destination does not make every message safe.
- Enforce per-organization steps, exact input/output-token reservations and elapsed deadlines across at least two agent processes. On budget-store failure, refuse work. Show what client disconnect means for actual backend capacity.
- Keep credentials out of model context, results and public telemetry. Add a synthetic canary incident and explain what encoded variants your detector misses.
- Release pinned, authorized model and tool-definition artifacts. Verify signatures and digests before loading the same verified bytes; no fallback to unsafe serialization. A valid signature for an unapproved revision must fail.

## Assessment

Freeze at least twelve attacks across direct prompts, poisoned runbooks, ticket output and tool responses. Include a compound attack: a retrieved instruction changes the content or target of an otherwise legitimate proposed action. Keep deliberately vulnerable baselines in isolated test fixtures.

Run the same attacks against a scripted adversarial model and a real CPU model. Include legitimate questions and legitimate confirmed actions, not just attacks. Record proposed actions, unauthorized applied effects, invalid replies, infrastructure failures, legitimate task completion, latency and cost separately. Publish raw synthetic outcomes and a method that can reproduce them without committing credentials or model blobs.

Compare prompt-only instructions with independently enforced controls. State the experimental unit, repeats, seed/order, confidence method and limits. Do not claim broad prompt-injection resistance from zero observed effects on a small fixed corpus.

## Done when

- A clean checkout runs the deterministic suite and provides a separate live profile.
- Negative tests cover tenant separation, exact confirmation, replay, revoked/expired grants, changed artifacts, output rendering, canaries, overload and deadlines.
- Real database evidence uses an unprivileged LOGIN; restart evidence demonstrates durable replay and audit behaviour.
- Each finding has the seven-part record, including the regression that fails when its control is removed.
- The final report maps every threat to evidence, preserves negative results, lists unmeasured deployment claims and names at least three residual risks.
- You can demonstrate a model proposing a malicious action while the platform refuses to perform it, then complete a legitimate action through the same path.
