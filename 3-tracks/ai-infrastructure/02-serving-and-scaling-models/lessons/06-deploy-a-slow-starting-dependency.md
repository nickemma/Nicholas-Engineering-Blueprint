# 06 Deploy a slow-starting dependency

A model server isn't like the Switchyard API. Its image is hundreds of megabytes, its weights are hundreds more, and it can take seconds or minutes before it can answer. Kubernetes' defaults assume a process that's ready in a second and can be replaced at any moment. This lesson deploys the model into a kind cluster and measures what those differences cost:

| You'll measure | Why it matters |
|---|---|
| Whether the weights in the cluster are the ones you verified | A model is code you didn't write; the bytes must match the digest from lesson 02 |
| Cold start and warm start, phase by phase | Scaling up only helps if a new copy is ready before the queue overflows |
| What users see while the model Pod is replaced | "Graceful shutdown" is a claim; measure it |
| What a too-short startup allowance does | The most common way to turn a slow start into an outage |
| Scaling on queue depth | CPU use says little about a decoder; waiting requests say a lot |

## A cluster for the lesson

This lesson runs on its own kind cluster, built the way [Kubernetes and delivery](../../../shared-units/kubernetes-and-delivery/README.md) taught: a namespace that refuses privileged Pods and denies all traffic until a policy allows it, and Prometheus in a namespace of its own. One control-plane node and one worker:

<!-- file: deploy/cluster/kind.yaml -->
~~~yaml
# The lesson's cluster: a control plane and one worker, where the model runs.
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
~~~

The `switchyard` namespace enforces the **restricted** Pod Security level and starts with every connection denied. Pods may still look up names, so DNS gets its own rule:

<!-- file: deploy/cluster/namespace.yaml -->
~~~yaml
apiVersion: v1
kind: Namespace
metadata:
  name: switchyard
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
# Nothing in, nothing out, until a policy says otherwise.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: switchyard }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
# Every Pod may ask the cluster's DNS for names, and nothing else by this rule.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: dns, namespace: switchyard }
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports: [{ port: 53, protocol: UDP }, { port: 53, protocol: TCP }]
~~~

Prometheus finds Pods through the Kubernetes API and scrapes those annotated `prometheus.io/scrape: "true"`, adding each series' `namespace` and `pod` labels. Only Grafana may query it:

<!-- file: deploy/cluster/prometheus.yaml -->
~~~yaml
apiVersion: v1
kind: Namespace
metadata: { name: observability }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: prometheus, namespace: observability }
---
# Read-only access to Pods, the one thing it needs to find its targets.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: prometheus-pods }
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: prometheus-pods }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: prometheus-pods }
subjects: [{ kind: ServiceAccount, name: prometheus, namespace: observability }]
---
apiVersion: v1
kind: ConfigMap
metadata: { name: prometheus, namespace: observability }
data:
  prometheus.yml: |
    global: { scrape_interval: 5s }
    scrape_configs:
      - job_name: pods
        kubernetes_sd_configs: [{ role: pod }]
        relabel_configs:
          # Only Pods that ask to be scraped, on the port and path they name.
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            regex: "true"
            action: keep
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            regex: (.+)
            target_label: __metrics_path__
          - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
            target_label: __address__
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: prometheus, namespace: observability }
spec:
  replicas: 1
  selector: { matchLabels: { app: prometheus } }
  template:
    metadata: { labels: { app: prometheus } }
    spec:
      serviceAccountName: prometheus
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: prometheus
          image: prom/prometheus:v3.15.0
          args: ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.path=/prometheus",
                 "--storage.tsdb.retention.time=1d"]
          ports: [{ name: http, containerPort: 9090 }]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { memory: 512Mi }
          volumeMounts:
            - { name: config, mountPath: /etc/prometheus }
            - { name: data, mountPath: /prometheus }
      volumes:
        - { name: config, configMap: { name: prometheus } }
        - { name: data, emptyDir: {} }
---
apiVersion: v1
kind: Service
metadata: { name: prometheus, namespace: observability }
spec:
  selector: { app: prometheus }
  ports: [{ name: http, port: 9090, targetPort: http }]
---
# Only Grafana may query Prometheus. Scraping is outbound, so it isn't affected.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: prometheus, namespace: observability }
spec:
  podSelector: { matchLabels: { app: prometheus } }
  policyTypes: [Ingress]
  ingress:
    - from: [{ podSelector: { matchLabels: { app: grafana } } }]
      ports: [{ port: 9090 }]
~~~

Keep the lab's kubeconfig separate from your other clusters, then create the cluster and apply both files:

~~~bash
mkdir -p .lab
export KUBECONFIG="$PWD/.lab/kubeconfig"
kind create cluster --name blueprint-serving --config deploy/cluster/kind.yaml --kubeconfig "$KUBECONFIG"
kubectl apply -f deploy/cluster/namespace.yaml -f deploy/cluster/prometheus.yaml
kubectl -n observability rollout status deployment/prometheus --timeout=3m
~~~

~~~text
deployment "prometheus" successfully rolled out
NAME                              STATUS   ROLES           AGE   VERSION
blueprint-serving-control-plane   Ready    control-plane   85s   v1.37.0
blueprint-serving-worker          Ready    <none>          72s   v1.37.0
~~~

This needs kind v0.33 or later: its built-in network plugin enforces NetworkPolicies. An older kind accepts the policies and ignores them, and every policy check below would wrongly pass.

## Weights into the cluster

The model needs a volume, and something to copy the file into it:

<!-- file: deploy/inference/weights.yaml -->
~~~yaml
# A volume for the model weights, and a short-lived Pod to copy them in.
# Delete the loader once the copy is verified; the volume stays.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-weights
  namespace: switchyard
spec:
  accessModes: [ReadWriteOnce] # one node at a time: every replica lands on that node
  resources:
    requests: { storage: 1Gi }
---
apiVersion: v1
kind: Pod
metadata:
  name: weights-loader
  namespace: switchyard
spec:
  # The namespace refuses root Pods ("restricted" Pod Security).
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: loader
      image: busybox:1.37
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
      volumeMounts:
        - { name: weights, mountPath: /models }
  volumes:
    - name: weights
      persistentVolumeClaim: { claimName: model-weights }
~~~

The `switchyard` namespace enforces the **restricted** Pod Security level, so every Pod must say it runs as a non-root user, can't gain privileges, drops all Linux capabilities and uses the default seccomp filter. Leave those settings out and the namespace refuses the Pod:

~~~text
Error from server (Forbidden): pods "pss-check" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "pss-check" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "pss-check" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "pss-check" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "pss-check" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
~~~

Copy the verified file in, then check its digest *inside* the cluster:

~~~bash
kubectl apply -f deploy/inference/weights.yaml
kubectl -n switchyard wait --for=condition=Ready pod/weights-loader --timeout=3m
kubectl -n switchyard cp models/qwen2.5-0.5b-instruct-q4_k_m.gguf weights-loader:/models/model.gguf
kubectl -n switchyard exec weights-loader -- sha256sum /models/model.gguf
~~~

~~~text
74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db  /models/model.gguf
~~~

That's the digest lesson 02 recorded. The copy took 7 s. Delete the loader; the volume and the file stay:

~~~bash
kubectl -n switchyard delete pod weights-loader
~~~

The volume is `ReadWriteOnce`: it can be mounted on one node at a time. kind's storage puts it on one node (`blueprint-serving-worker`), so every replica of the model must run on that node. On a real cluster, that's the first thing that stops scaling. Weight distribution (a read-only copy per node, or an image that contains the weights) is part of the design, not a detail.

## The model Deployment

<!-- file: deploy/inference/llm.yaml -->
~~~yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm
  namespace: switchyard
spec:
  replicas: 1
  strategy:
    type: Recreate # the laptop has room for few copies of the weights
  selector:
    matchLabels: { app: llm }
  template:
    metadata:
      labels: { app: llm }
      annotations: # Prometheus scrapes Pods that ask for it
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: /metrics
    spec:
      automountServiceAccountToken: false # the model never calls the Kubernetes API
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: server
          image: ghcr.io/ggml-org/llama.cpp@sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b
          args: ["-m", "/models/model.gguf", "--host", "0.0.0.0", "--port", "8080",
                 "-c", "4096", "-t", "2", "--parallel", "1", "--metrics"]
          ports: [{ name: http, containerPort: 8080 }]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          resources:
            requests: { cpu: "1", memory: 768Mi }
            limits: { cpu: "2", memory: 1536Mi }
          # Loading may take minutes: allow up to 120 x 5 s before giving up.
          startupProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
            failureThreshold: 120
          # After start-up: stop routing here while it can't answer.
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
          volumeMounts:
            - { name: weights, mountPath: /models, readOnly: true }
      volumes:
        - name: weights
          persistentVolumeClaim: { claimName: model-weights, readOnly: true }
---
apiVersion: v1
kind: Service
metadata: { name: llm, namespace: switchyard }
spec:
  selector: { app: llm }
  ports: [{ name: http, port: 8080, targetPort: http }]
~~~

Three probes, three questions:

- The **startup probe** asks "has it finished loading?" It allows up to 120 × 5 s = 10 minutes. Until it passes, Kubernetes runs no other probe, so a slow load isn't mistaken for a hang.
- The **readiness probe** asks "should it get traffic right now?" A Pod that fails it is taken out of the Service but not restarted.
- There's no **liveness probe**. One that's too strict would restart a model that's busy decoding a long answer. A restart costs a reload, so add one only for a failure you've actually seen, with a generous threshold.

The annotations ask Prometheus to scrape the server's `/metrics`. `readOnlyRootFilesystem` works because llama-server writes nothing to disk.

The namespace's default-deny policy blocks everything until a policy allows it. The model answers the API, Prometheus and, in this lab, a probe Pod; it calls nobody:

<!-- file: deploy/inference/llm-policy.yaml -->
~~~yaml
# The namespace denies all traffic by default. The model answers only
# the API, Prometheus and, in this lab, the probe Pod; it calls nobody.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: llm
  namespace: switchyard
spec:
  podSelector: { matchLabels: { app: llm } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app: api } }
        - podSelector: { matchLabels: { role: llm-probe } }
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: observability } }
          podSelector: { matchLabels: { app: prometheus } }
      ports: [{ port: 8080 }]
  egress: []
---
# The lab's probe may reach the model, and nothing else.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: llm-probe
  namespace: switchyard
spec:
  podSelector: { matchLabels: { role: llm-probe } }
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
    - to: [{ podSelector: { matchLabels: { app: llm } } }]
      ports: [{ port: 8080 }]
~~~

When you wire lesson 05's API into the cluster, its own egress policy needs `llm:8080` too.

## Measure start-up

Kubernetes records when each Pod was scheduled, when its container started and when it became ready. This reads them:

<!-- file: serve/src/serve/podtimes.py -->
~~~python
"""How long did a pod take to be scheduled, start and become ready? Ask Kubernetes.

  kubectl -n switchyard get pods -l app=llm -o json | uv run python -m serve.podtimes

Times are seconds after the pod was created. Kubernetes stores them to the second,
so differences of a second or two are noise.
"""

import json
import sys
from datetime import datetime


def _at(stamp: str | None) -> datetime | None:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")) if stamp else None


def phases(pod: dict) -> dict:
    created = _at(pod["metadata"]["creationTimestamp"])
    true = {c["type"]: c for c in pod["status"].get("conditions", []) if c["status"] == "True"}
    container = (pod["status"].get("containerStatuses") or [{}])[0]
    running = container.get("state", {}).get("running", {})

    def since(stamp):
        at = _at(stamp)
        return None if at is None else (at - created).total_seconds()

    return {
        "pod": pod["metadata"]["name"],
        "scheduled": since(true.get("PodScheduled", {}).get("lastTransitionTime")),
        "started": since(running.get("startedAt")),  # the latest start, after any restart
        "ready": since(true.get("Ready", {}).get("lastTransitionTime")),
        "restarts": container.get("restartCount", 0),
    }


def main() -> None:
    data = json.load(sys.stdin)
    pods = data["items"] if data.get("kind") == "List" else [data]
    print(f"{'pod':<26} {'scheduled':>9} {'started':>8} {'ready':>6} {'restarts':>8}")
    for p in map(phases, pods):
        cells = [
            ("-" if p[k] is None else f"{p[k]:.0f}") for k in ("scheduled", "started", "ready")
        ]
        print(f"{p['pod']:<26} {cells[0]:>9} {cells[1]:>8} {cells[2]:>6} {p['restarts']:>8}")


if __name__ == "__main__":
    main()
~~~

<!-- file: serve/tests/test_podtimes.py -->
~~~python
from serve.podtimes import phases


def pod(ready=True):
    conditions = [
        {"type": "PodScheduled", "status": "True", "lastTransitionTime": "2026-11-13T10:00:01Z"},
        {
            "type": "Ready",
            "status": "True" if ready else "False",
            "lastTransitionTime": "2026-11-13T10:00:31Z",
        },
    ]
    return {
        "metadata": {"name": "llm-1", "creationTimestamp": "2026-11-13T10:00:00Z"},
        "status": {
            "conditions": conditions,
            "containerStatuses": [
                {"restartCount": 2, "state": {"running": {"startedAt": "2026-11-13T10:00:27Z"}}}
            ],
        },
    }


def test_phases_are_seconds_after_creation():
    assert phases(pod()) == {
        "pod": "llm-1",
        "scheduled": 1,
        "started": 27,
        "ready": 31,
        "restarts": 2,
    }


def test_a_pod_that_is_not_ready_has_no_ready_time():
    assert phases(pod(ready=False))["ready"] is None
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_podtimes.py -->

Now deploy. The image isn't on any node yet, so this is a true cold start:

~~~bash
kubectl apply -f deploy/inference/llm-policy.yaml -f deploy/inference/llm.yaml
kubectl -n switchyard rollout status deployment/llm --timeout=10m
kubectl -n switchyard get pods -l app=llm -o json | (cd serve && uv run python -m serve.podtimes)
kubectl -n switchyard get events --field-selector reason=Pulled -o custom-columns=MESSAGE:.message
~~~

~~~text
pod                        scheduled  started  ready restarts
llm-85b6db66cc-4z6kv               0      334    335        0
Successfully pulled image "ghcr.io/ggml-org/llama.cpp@sha256:e67d88af...f78b" in 5m33.456s (5m33.456s including waiting). Image size: 309499562 bytes.
~~~

Of the 335 seconds, 334 went by before the container even started: pulling the 309 MB image took 5 minutes 33 seconds on this connection. Loading the model took about a second, because the copy had just put the weights in the node's page cache. A node pulls an image once, so the next start on the same node skips the pull. If a new replica lands on a node that has never run the model, it pays the whole wait again. That's why clusters that serve models pre-pull images onto their nodes.

## Probe from inside the cluster

To see what users see, send requests from inside the cluster, through the Service, as the API would. This needs only the standard library and lesson 02's `stream.py`:

<!-- file: serve/src/serve/probe.py -->
~~~python
"""Send requests to a model server for a while, and report what users saw.

It needs only the standard library, so it runs in a plain Python container inside
the cluster, where it reaches the model through its Service like the API would.

  python -m serve.probe http://llm:8080 --seconds 60             # one at a time
  python -m serve.probe http://llm:8080 --seconds 120 --workers 6 --max-tokens 128
"""

import argparse
import json
import threading
import time
from collections import Counter

from serve.stream import chat


def outage(rows: list[dict]) -> float | None:
    """Seconds from the first failed request to the next one that succeeded."""
    rows = sorted(rows, key=lambda r: r["start"])
    first = next((r for r in rows if r["error"]), None)
    if first is None:
        return None
    back = next((r for r in rows if r["start"] > first["start"] and not r["error"]), None)
    return None if back is None else round(back["start"] - first["start"], 2)


def summarise(rows: list[dict]) -> dict:
    ok = sorted(r["ttft"] for r in rows if not r["error"])
    return {
        "requests": len(rows),
        "completed": len(ok),
        "failed": dict(Counter(r["error"] for r in rows if r["error"])),
        "ttft_p50": round(ok[len(ok) // 2], 2) if ok else None,
        "ttft_max": round(ok[-1], 2) if ok else None,
        "outage_seconds": outage(rows),
    }


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("url")
    p.add_argument("--seconds", type=float, default=60)
    p.add_argument("--workers", type=int, default=1)
    p.add_argument("--every", type=float, default=0.25, help="pause between one worker's requests")
    p.add_argument("--max-tokens", type=int, default=4)
    p.add_argument("--rows", action="store_true", help="print every request, then the summary")
    a = p.parse_args()
    prompt = "Count from one to one thousand." if a.max_tokens > 8 else "Say yes."
    epoch = time.monotonic()
    stop = epoch + a.seconds
    rows: list[dict] = []
    lock = threading.Lock()

    def worker():
        while time.monotonic() < stop:
            start = time.monotonic() - epoch
            t = chat(a.url, prompt, a.max_tokens, timeout=60)
            row = {"start": round(start, 2), "total": round(t.total, 2), "error": t.error}
            row["ttft"] = None if t.ttft is None else round(t.ttft, 2)
            with lock:
                rows.append(row)
            time.sleep(a.every)

    threads = [threading.Thread(target=worker) for _ in range(a.workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if a.rows:
        for row in sorted(rows, key=lambda r: r["start"]):
            print(json.dumps(row))
    print(json.dumps(summarise(rows)))


if __name__ == "__main__":
    main()
~~~

<!-- file: serve/tests/test_probe.py -->
~~~python
from serve.probe import outage, summarise


def test_outage_runs_from_first_failure_to_next_success():
    rows = [
        {"start": 0.0, "error": "", "ttft": 0.1},
        {"start": 0.5, "error": "status 503", "ttft": None},
        {"start": 1.0, "error": "[Errno 111] Connection refused", "ttft": None},
        {"start": 4.25, "error": "", "ttft": 0.3},
    ]
    s = summarise(rows)
    assert s["outage_seconds"] == 3.75 and s["completed"] == 2 and s["ttft_max"] == 0.3
    assert s["failed"] == {"status 503": 1, "[Errno 111] Connection refused": 1}
    assert outage(rows[:1]) is None
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_probe.py -->

It runs in a plain Python container. Its code comes from a ConfigMap, so no image needs building:

<!-- file: deploy/inference/probe.yaml -->
~~~yaml
# A Pod that sends requests to the model from inside the cluster.
# Its code comes from a ConfigMap; see the commands in the guide.
apiVersion: v1
kind: Pod
metadata:
  name: llm-probe
  namespace: switchyard
  labels: { role: llm-probe }
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: probe
      image: python:3.12-slim
      command: ["sleep", "infinity"]
      env:
        - { name: PYTHONPATH, value: /code }
        - { name: PYTHONDONTWRITEBYTECODE, value: "1" }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: [ALL] }
      volumeMounts:
        - { name: code, mountPath: /code/serve }
  volumes:
    - name: code
      configMap: { name: llm-probe-code }
~~~

~~~bash
kubectl -n switchyard create configmap llm-probe-code \
  --from-file=serve/src/serve/stream.py --from-file=serve/src/serve/probe.py
kubectl apply -f deploy/inference/probe.yaml
kubectl -n switchyard wait --for=condition=Ready pod/llm-probe --timeout=5m
kubectl -n switchyard exec llm-probe -- python -m serve.probe http://llm:8080 --seconds 5
~~~

~~~text
{"requests": 7, "completed": 7, "failed": {}, "ttft_p50": 0.39, "ttft_max": 0.47, "outage_seconds": null}
~~~

Check that the policy really is what lets it through. Remove the probe's label, and the same request has nowhere to go:

~~~bash
kubectl -n switchyard label pod llm-probe role-
kubectl -n switchyard exec llm-probe -- python -m serve.probe http://llm:8080 --seconds 1
kubectl -n switchyard label pod llm-probe role=llm-probe
~~~

~~~text
{"requests": 1, "completed": 0, "failed": {"timed out": 1}, "ttft_p50": null, "ttft_max": null, "outage_seconds": null}
~~~

The request waited out its full 60-second timeout: the policy dropped the connection without an answer. Put the label back before going on.

## Replace the model while users wait

Kubernetes replaces Pods all the time: node upgrades, rollouts, evictions. Delete the model Pod while three probe workers keep sending requests:

~~~bash
kubectl -n switchyard exec llm-probe -- \
  python -m serve.probe http://llm:8080 --seconds 60 --workers 3 --rows > replace.txt &
sleep 10
kubectl -n switchyard delete pod -l app=llm --wait=false
wait
tail -1 replace.txt
grep -v '"error": ""' replace.txt | head -3
~~~

~~~text
{"requests": 122, "completed": 96, "failed": {"incomplete or empty stream": 1, "[Errno 111] Connection refused": 23, "Remote end closed connection without response": 2}, "ttft_p50": 0.98, "ttft_max": 1.42, "outage_seconds": 7.18}
{"start": 8.51, "total": 1.12, "error": "incomplete or empty stream", "ttft": 1.12}
{"start": 8.98, "total": 30.55, "error": "Remote end closed connection without response", "ttft": null}
{"start": 9.46, "total": 30.07, "error": "Remote end closed connection without response", "ttft": null}
~~~

Kubernetes sent the server SIGTERM at about 8.5 s, and three things went wrong at once. The answer that was streaming stopped mid-way. The two requests queued behind it got no answer at all: they hung for **30 seconds**, the default grace period, until Kubernetes killed the server. And for the 7 seconds until the replacement was ready, every new request was refused, because the old server had stopped listening while the Service still sent traffic its way: 23 more failures. For those users, a routine Pod replacement was an outage.

The fix is a **preStop hook**: a command Kubernetes runs *before* it sends SIGTERM. Wait two seconds for the Service to stop sending new work here, then wait until the server's own counters show nothing in progress and nothing queued:

<!-- edit: deploy/inference/llm.yaml -->
~~~yaml
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
          volumeMounts:
~~~
~~~yaml
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
          # Before Kubernetes sends SIGTERM: wait for the Service to stop sending
          # new work, then for the requests already here to finish. All within
          # the 30 s grace period, after which the container is killed anyway.
          lifecycle:
            preStop:
              exec:
                command:
                  - sh
                  - -c
                  - |
                    sleep 2
                    for i in $(seq 1 50); do
                      curl -s localhost:8080/metrics |
                        grep -qE '^llamacpp:requests_(processing|deferred) [1-9]' || exit 0
                      sleep 0.5
                    done
          volumeMounts:
~~~

~~~bash
kubectl apply -f deploy/inference/llm.yaml
kubectl -n switchyard rollout status deployment/llm --timeout=5m
~~~

Run the same replacement again, twice:

~~~text
{"requests": 130, "completed": 130, "failed": {}, "ttft_p50": 1.03, "ttft_max": 1.46, "outage_seconds": null}
{"requests": 127, "completed": 127, "failed": {}, "ttft_p50": 1.02, "ttft_max": 2.04, "outage_seconds": null}
~~~

Every request completed, both times. There's a detail of current Kubernetes behind this. When a Service has no ready Pods, it keeps sending traffic to Pods that are shutting down but still pass their readiness probe. With the hook, the old server keeps working, so it carries the traffic until the new Pod is ready. Then it goes idle, the hook exits, and SIGTERM finds nothing to interrupt.

The hook must fit inside the grace period: 2 s plus at most 25 s of waiting, within 30 s. If your longest answer takes longer than that, raise `terminationGracePeriodSeconds`, or the kill arrives mid-answer anyway.

**Break it:** give the model less time to start than it needs. One second, one try, while the probe keeps sending requests:

~~~bash
kubectl -n switchyard exec llm-probe -- \
  python -m serve.probe http://llm:8080 --seconds 90 --rows > break.txt &
sleep 5
kubectl -n switchyard patch deployment llm --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/periodSeconds","value":1},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/failureThreshold","value":1}]'
wait
tail -1 break.txt
kubectl -n switchyard get pods -l app=llm
grep -v '"error": ""' break.txt | head -2
~~~

~~~text
{"requests": 40, "completed": 38, "failed": {"[Errno 111] Connection refused": 1, "timed out": 1}, "ttft_p50": 0.4, "ttft_max": 0.47, "outage_seconds": 60.57}
NAME                   READY   STATUS    RESTARTS      AGE
llm-86f69ccbdc-gxm5c   1/1     Running   4 (55s ago)   83s
{"start": 7.31, "total": 0.0, "error": "[Errno 111] Connection refused", "ttft": null}
{"start": 7.56, "total": 60.06, "error": "timed out", "ttft": null}
~~~

The server answers 503 while it loads, so a check one second after the start fails, Kubernetes kills it, and it starts loading again. Here the weights were already in the page cache, so a load took about a second and one attempt in five happened to be quick enough: four restarts, then it stayed up. With a cold cache or a bigger model, no attempt is ever quick enough, and the Pod stays in `CrashLoopBackOff` with a growing back-off. Either way, because the Deployment uses `Recreate`, the old, working Pod was removed *first*, so nothing at all was serving: one request was refused, the next hung for its whole 60-second timeout, and nothing completed for 60.6 seconds. A bad configuration change became a complete outage. With `RollingUpdate`, the old Pod would have kept serving while the new one failed, but that needs room for a second copy of the weights. Restore the measured allowance:

~~~bash
kubectl apply -f deploy/inference/llm.yaml
kubectl -n switchyard rollout status deployment/llm --timeout=5m
~~~

Mine was ready again 9 s later, and all seven probe requests completed.

## Scale on queue depth

CPU is a poor scaling signal for a decoder. It's limited by memory bandwidth, and it can look much the same idle or swamped. A better signal is how many requests are waiting. llama-server exports that as `llamacpp:requests_deferred`, and Prometheus is already scraping it:

~~~bash
kubectl -n observability port-forward svc/prometheus 19090:9090 &
curl -s 127.0.0.1:19090/api/v1/query --data-urlencode 'query=llamacpp:requests_deferred'
~~~

The result carries `namespace="switchyard"` and `pod="llm-..."` labels, from the scrape configuration. A HorizontalPodAutoscaler can't query Prometheus, though; it reads metrics from the Kubernetes API. The **Prometheus adapter** sits between them: it serves chosen Prometheus series as Kubernetes metrics.

<!-- file: deploy/inference/adapter-values.yaml -->
~~~yaml
# Values for the official Prometheus adapter chart (prometheus-community/
# prometheus-adapter 5.4.1). It turns one Prometheus series into a metric the
# Kubernetes API serves, so a HorizontalPodAutoscaler can read it.
prometheus:
  url: http://prometheus.observability.svc
  port: 9090
metricsRelistInterval: 15s # how soon a new Pod's series is found
rules:
  default: false # serve only what we ask for
  custom:
    # Requests waiting inside each model server, per Pod. Prometheus's scrape
    # config adds the namespace and pod labels the adapter maps to objects.
    - seriesQuery: 'llamacpp:requests_deferred{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: { resource: namespace }
          pod: { resource: pod }
      name:
        matches: "^llamacpp:requests_deferred$"
        as: llm_requests_waiting
      metricsQuery: sum(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits: { memory: 384Mi }
~~~

The `observability` namespace lets only Grafana query Prometheus. Policies add up, so a second one admits the adapter, without editing the first:

<!-- file: deploy/inference/adapter-policy.yaml -->
~~~yaml
# Only Grafana may query Prometheus. Policies add up, so this one
# admits the adapter as well, without editing that policy.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: prometheus-from-adapter
  namespace: observability
spec:
  podSelector: { matchLabels: { app: prometheus } }
  policyTypes: [Ingress]
  ingress:
    - from: [{ podSelector: { matchLabels: { app.kubernetes.io/name: prometheus-adapter } } }]
      ports: [{ port: 9090 }]
~~~

~~~bash
kubectl apply -f deploy/inference/adapter-policy.yaml
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install llm-adapter prometheus-community/prometheus-adapter --version 5.4.1 \
  -n observability -f deploy/inference/adapter-values.yaml --wait
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/switchyard/pods/*/llm_requests_waiting"
~~~

Within about 10 seconds, the Kubernetes API answers with one item per model Pod: `"metricName": "llm_requests_waiting"` and `"value": "0"`.

Now the autoscaler. It aims for an average of two waiting requests per Pod:

<!-- file: deploy/inference/hpa.yaml -->
~~~yaml
# Scale the model on how many requests wait inside it, not on CPU: a decoder
# is limited by memory bandwidth, and its CPU can look the same idle or swamped.
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: llm, namespace: switchyard }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: llm }
  minReplicas: 1
  maxReplicas: 2 # the laptop has room for two copies of the weights
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300 # don't drop a replica that took time to load
  metrics:
    - type: Pods
      pods:
        metric: { name: llm_requests_waiting }
        target: { type: AverageValue, averageValue: "2" }
~~~

With one model Pod and six requests in flight, one is processed and five wait. The autoscaler wants `ceil(1 × 5 ÷ 2) = 3` replicas, and is capped at 2. With two Pods, each has about two waiting, which is the target, so it holds there.

This script prints what the autoscaler sees every 2 seconds:

<!-- file: deploy/inference/watch-hpa.sh -->
~~~bash
#!/bin/sh
# Print the autoscaler's view every 2 seconds: what it measured, how many
# replicas it wants, and how many model Pods are ready. Stop with Ctrl-C.
start=$(date +%s)
get() { kubectl -n switchyard get "$1" -o jsonpath="$2" 2>/dev/null; }
while true; do
  waiting=$(get hpa/llm '{.status.currentMetrics[0].pods.current.averageValue}')
  desired=$(get hpa/llm '{.status.desiredReplicas}')
  ready=$(get deployment/llm '{.status.readyReplicas}')
  printf '%4ss  waiting/pod=%-5s desired=%-2s ready=%s\n' \
    "$(( $(date +%s) - start ))" "${waiting:--}" "${desired:--}" "${ready:-0}"
  sleep 2
done
~~~

<!-- run: sh -n deploy/inference/watch-hpa.sh -->

Apply the autoscaler, start the watcher in a second terminal, then offer six long requests at a time for 150 seconds:

~~~bash
kubectl apply -f deploy/inference/hpa.yaml
sh deploy/inference/watch-hpa.sh            # in a second terminal
kubectl -n switchyard exec llm-probe -- \
  python -m serve.probe http://llm:8080 --seconds 150 --workers 6 --max-tokens 128
~~~

The watcher, from just before the load started:

~~~text
   9s  waiting/pod=0     desired=1  ready=1
  11s  waiting/pod=0     desired=1  ready=1
  14s  waiting/pod=0     desired=1  ready=1
  17s  waiting/pod=5     desired=2  ready=1
  20s  waiting/pod=5     desired=2  ready=1
  23s  waiting/pod=5     desired=2  ready=2
  26s  waiting/pod=5     desired=2  ready=2
  29s  waiting/pod=5     desired=2  ready=2
  32s  waiting/pod=2     desired=2  ready=2
  35s  waiting/pod=2     desired=2  ready=2
  38s  waiting/pod=2     desired=2  ready=2
  41s  waiting/pod=2     desired=2  ready=2
  44s  waiting/pod=2     desired=2  ready=2
~~~

The load started at about 8 s. By 17 s the adapter reported five requests waiting and the autoscaler asked for a second replica, which was ready at 23 s. That's quick because the image was already on the node and the weights were in its page cache: on a node that had never run the model, add the 334-second wait from earlier. Later samples show values such as `2500m`, `1500m` and `500m`: Kubernetes' way of writing 2.5, 1.5 and 0.5, averages across the two Pods.

The load stopped at about 158 s. The autoscaler waited out its 300-second stabilisation window, then removed the second replica:

~~~text
 456s  waiting/pod=0     desired=2  ready=2
 459s  waiting/pod=0     desired=2  ready=2
 462s  waiting/pod=0     desired=2  ready=2
 464s  waiting/pod=0     desired=2  ready=2
 467s  waiting/pod=0     desired=1  ready=1
 470s  waiting/pod=0     desired=1  ready=1
 472s  waiting/pod=0     desired=1  ready=1
~~~

The probe's summary, then each Pod's token counter, read from inside the cluster (run the loop before the load too, and subtract):

~~~bash
for ip in $(kubectl -n switchyard get pods -l app=llm -o jsonpath='{.items[*].status.podIP}'); do
  kubectl -n switchyard exec llm-probe -- python -c "import urllib.request
for line in urllib.request.urlopen('http://$ip:8080/metrics').read().decode().splitlines():
    if line.startswith('llamacpp:tokens_predicted_total'): print('$ip', line)"
done
~~~

~~~text
{"requests": 37, "completed": 37, "failed": {}, "ttft_p50": 25.89, "ttft_max": 40.03, "outage_seconds": null}
10.244.1.16 llamacpp:tokens_predicted_total 1664
10.244.1.14 llamacpp:tokens_predicted_total 3072
~~~

| | Requests started in the first 20 s (mostly one Pod) | Requests started after 60 s (two Pods) |
|---|---|---|
| Median time to decode one 128-token answer | 7.6 s | 7.8 s |
| Tokens per second, all Pods together (128 ÷ decode time × Pods) | about 17 | about 33 |

Before the load, the first Pod's counter read 0 and the second Pod didn't exist. So the old Pod generated 3,072 tokens during the run (24 answers of 128 tokens) and the new one 1,664 (13 answers). Every request completed, and both Pods did work. But two things in these numbers matter more than the scaling itself:

- **The second replica nearly doubled throughput here, and that's a property of this machine.** Both Pods run on `blueprint-serving-worker`, because the `ReadWriteOnce` volume is there. This laptop has 16 CPUs and each Pod may use 2, so they didn't compete, and each decoded almost as fast as one alone. On an earlier run, on a node with less to spare, the second replica added only about 40%, because the two shared CPUs and memory bandwidth. Measure it on the node you'll run on. And a replica on another node needs its own copy of the weights: the volume pins every replica to one node. That's the weight-distribution problem from the start of this lesson.
- **The target decides the latency, and this one is too loose.** "Two waiting per Pod" means a request waits for about two 8-second answers before its own starts. The median wait for first content was 25.9 s, and the slowest was 40 s. Choose the target the way lesson 09 chose the queue length: from the time budget. Waiting requests × time per answer must fit inside your time-to-first-token objective. For lesson 05's one second, no number of waiting requests fits, so the honest conclusion is that this laptop can't offer that objective for long answers at this load. Measuring tells you that before users do.

**Done when:** the weights' digest matches inside the cluster, you have cold and warm start timelines, a Pod replacement under load completes every request, and the model scales out on queue depth and back in. Keep the outputs; lesson 14's report uses them. Mine are in [evidence/2026-11-24-kubernetes](../evidence/2026-11-24-kubernetes/README.md).

**What this proves, and what it doesn't.** It proves the model runs under the namespace's security rules and network policy, that replacing it no longer drops requests, and that queue depth drives scaling on this cluster. It doesn't prove anything about a cluster with many nodes: here every replica shares one node and one copy of the volume, so a second replica adds a second decoder, not more memory bandwidth from a second machine. Nor does it cover the gateway: in the full system the queue sits in lesson 04's admission queue, and you'd scale on the gateway's waiting gauge instead. The [platform report](../evidence/platform-validation/report.md) did that once, through the real API.
