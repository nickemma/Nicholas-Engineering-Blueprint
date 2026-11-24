# 10 Enforce the deployment boundary

Confirm that the expected callers still reach the service through the intended ports. Then test both the permission boundary and the release and recovery sequence. API acceptance of a NetworkPolicy only shows that the object exists. An ordinary test Pod exercising the path supplies enforcement evidence.

## Build it

### Step 1. Apply narrow ingress boundaries

Permit the job path from frontends, workers, and the scaler on their required ports. Limit inter-Pod Raft traffic to the voter workload. Apply restricted Pod Security in the lab namespace.

<details>
<summary>Hint</summary>

Use the entry Service as the positive control and an ordinary test Pod for a direct request that should time out.

</details>

<details>
<summary>Type-along files</summary>

Create `chart/templates/policy.yaml`.

<!-- file: chart/templates/policy.yaml -->
~~~yaml
{{- if .Values.networkPolicy }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: jobs-ingress}
spec:
  podSelector: {matchLabels: {app: jobs}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchExpressions: [{key: app, operator: In, values: [frontend-stable, frontend-canary, worker-scaler]}]
    ports: [{protocol: TCP, port: 8080}]
  - from:
    - podSelector: {matchLabels: {app: worker}}
    ports: [{protocol: TCP, port: 9090}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: frontend-ingress}
spec:
  podSelector:
    matchExpressions: [{key: app, operator: In, values: [frontend-stable, frontend-canary]}]
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {matchLabels: {app: frontend-entry}}
    ports: [{protocol: TCP, port: 8080}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: postgres-ingress}
spec:
  podSelector: {matchLabels: {app: postgres}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchExpressions: [{key: app, operator: In, values: [jobs, migrate]}]
    ports: [{protocol: TCP, port: 5432}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: metadata-peer-ingress}
spec:
  podSelector: {matchLabels: {app: metadata}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {matchLabels: {app: metadata}}
    ports: [{protocol: TCP, port: 9443}]
{{- end }}
~~~

</details>
### Step 2. Check the promotion guard

Run the offline failure test with a candidate that is unready, then with an altered promoter that skips waiting.

<details>
<summary>Hint</summary>

The mutation must change the stable image in the test double and fail the assertion.

</details>

### Step 3. Run the release and recovery

Run the live gate with two signed digests and a distinct unsigned control. Look for the canary alert, an unchanged stable client path, the recovered candidate, and a voter that comes back with its existing claim.

<details>
<summary>Hint</summary>

Use a disposable kind cluster with policy enforcement.

</details>


## Check it

~~~bash
bash "$blueprint/3-tracks/shared-units/kubernetes-and-delivery/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/shared-units/kubernetes-and-delivery/gate/run.sh" "$PWD" -->

The offline gate tests the Go packages, chart, and negative control. The [live gate](../gate/README.md) supplies the cluster checks. [Offline capture](../evidence/replay-gate.txt)

## Explain it

1. What shows that the candidate started and failed readiness?
2. What shows that the voter returned with its original storage identity?
3. How does each permission or connectivity assertion distinguish a required path from an unintended one?
