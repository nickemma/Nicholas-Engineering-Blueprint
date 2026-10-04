# Phase 6 learning record

Answer from your written policy, tests, and audit events. Use synthetic data only.

1. Which data stays at each site? Which exact fields may cross the boundary?
2. Name the trust boundaries and the attacker capabilities in your model.
3. How does authentication differ from authorization? How does mTLS differ from permission to run a query?
4. What inputs are necessary to decide whether the sample query is allowed?
5. What does fail-closed behavior look like when identity or policy is unavailable?
6. What does the audit event record? Which sensitive values are intentionally excluded?
7. Demonstrate one allowed request and one denied request. How do their audit records differ?
8. Show the two synthetic queries that expose a differencing risk.
9. What risk does a minimum group threshold address? What does it fail to address?
10. Why did you choose or reject differential privacy or secure multi-party computation for this workload?

| Claim | Evidence |
|---|---|
| Wrong-site request is denied | test name, response, audit event |
| Expired/replayed request is denied | test name, response |
| Raw rows are not in the response | sample response and schema |
| Policy outage returns no data | fault test |
| Repeated query risk is understood | synthetic differencing example |

## Kestrel transfer

- Which permission did I implement first from the written policy?
- How did I test that identity was verified rather than trusted from the body?
- What was rebuilt without lesson code?
- How does the policy version appear in audit evidence?
- Which privacy claim can I defend, and which can I not make?
- What needs specialist or domain review?
- What remains unclear?
