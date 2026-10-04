# Phase 5 learning record

Answer using manifest output, dashboard observations, measurements, and your incident notes.

1. What is the difference between an image, a container, a Pod, a Deployment, and a Service?
2. Which process and resource boundaries did the container provide? Which did it not provide?
3. What does Kubernetes reconcile after you delete one Pod?
4. How do readiness and liveness probes differ? What failure did your incorrect probe create?
5. What does your Terraform plan show? Why did you not apply a paid plan as part of this local exercise?
6. Define your SLO, its workload, and its time period. What is its error budget?
7. Which operator question does each dashboard panel answer?
8. What was the difference among added delay, loss, and a full partition in your measurements?
9. Which measurement changed most under the constrained link, and what is one limit of that result?
10. What happened during the game day? Which runbook instruction helped?

| Evidence | Attach or record |
|---|---|
| Local cluster and workload are reproducible | cluster version, image tag, commit |
| Service is reachable through Kubernetes | curl output |
| Pod replacement is observed | before/after kubectl output |
| Operator dashboard exists | panel names and one observation |
| Constrained test is isolated | network namespace/proxy and cleanup note |
| Measurements can be compared | repeated runs and workload settings |
| Failure response is documented | runbook, timeline, recovery |

## Kestrel transfer

- What did I deploy from scratch without copying manifests?
- What was the first signal I used to diagnose the failure, and why?
- What did the measurements say about usefulness when connectivity degraded?
- What would change in a real cloud environment?
- What needs real on-call practice beyond this project?
- What remains unclear?
