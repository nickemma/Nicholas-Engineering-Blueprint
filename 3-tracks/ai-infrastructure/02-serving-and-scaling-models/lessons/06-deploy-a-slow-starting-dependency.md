# 06 Deploy a slow-starting dependency

A model server isn't like the Switchyard API. Its image is hundreds of megabytes, its weights are hundreds more, and it can take seconds or minutes before it can answer. Kubernetes' defaults assume a process that's ready in a second and can be replaced at any moment. This step deploys the model into Phase 5's cluster and measures what those differences cost:

| You'll measure | Why it matters |
|---|---|
| Whether the weights in the cluster are the ones you verified | A model is code you didn't write; the bytes must match the digest from Step 2 |
| Cold start and warm start, phase by phase | Scaling up only helps if a new copy is ready before the queue overflows |
| What users see while the model Pod is replaced | "Graceful shutdown" is a claim; measure it |
| What a too-short startup allowance does | The most common way to turn a slow start into an outage |
| Scaling on queue depth | CPU use says little about a decoder; waiting requests say a lot |

You need Phase 5's kind cluster, with Phase 5's Prometheus in `observability` and Phase 6's default-deny policies in `runway`.

## Weights into the cluster

The model needs a volume, and something to copy the file into it:

<!-- file: deploy/inference/weights.yaml -->
~~~yaml
# A volume for the model weights, and a short-lived Pod to copy them in.
# Delete the loader once the copy is verified; the volume stays.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: phase8-weights
  namespace: runway
spec:
  accessModes: [ReadWriteOnce] # one node at a time: every replica lands on that node
  resources:
    requests: { storage: 1Gi }
---
apiVersion: v1
kind: Pod
metadata:
  name: weights-loader
  namespace: runway
spec:
  # The namespace refuses root Pods (Phase 5's "restricted" Pod Security).
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
      persistentVolumeClaim: { claimName: phase8-weights }
~~~

Phase 5 set the `runway` namespace to the **restricted** Pod Security level, so every Pod must say it runs as a non-root user, can't gain privileges, drops all Linux capabilities and uses the default seccomp filter. Leave those settings out and the namespace refuses the Pod:

~~~text
Error from server (Forbidden): pods "pss-check" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "pss-check" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "pss-check" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "pss-check" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "pss-check" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
~~~

Copy the verified file in, then check its digest *inside* the cluster:

~~~bash
kubectl apply -f deploy/inference/weights.yaml
kubectl -n runway wait --for=condition=Ready pod/weights-loader --timeout=3m
kubectl -n runway cp models/qwen2.5-0.5b-instruct-q4_k_m.gguf weights-loader:/models/model.gguf
kubectl -n runway exec weights-loader -- sha256sum /models/model.gguf
~~~

~~~text
74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db  /models/model.gguf
~~~

That's the digest Step 2 recorded. The copy took 9 s. Delete the loader; the volume and the file stay:

~~~bash
kubectl -n runway delete pod weights-loader
~~~

The volume is `ReadWriteOnce`: it can be mounted on one node at a time. kind's storage puts it on one node (`runway-worker`, for me), so every replica of the model must run on that node. On a real cluster, that's the first thing that stops scaling. Weight distribution (a read-only copy per node, or an image that contains the weights) is part of the design, not a detail.

## The model Deployment

<!-- file: deploy/inference/llm.yaml -->
~~~yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm
  namespace: runway
spec:
  replicas: 1
  strategy:
    type: Recreate # the laptop has room for few copies of the weights
  selector:
    matchLabels: { app: llm }
  template:
    metadata:
      labels: { app: llm }
      annotations: # Phase 5's Prometheus scrapes Pods that ask for it
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
          persistentVolumeClaim: { claimName: phase8-weights, readOnly: true }
---
apiVersion: v1
kind: Service
metadata: { name: llm, namespace: runway }
spec:
  selector: { app: llm }
  ports: [{ name: http, port: 8080, targetPort: http }]
~~~

Three probes, three questions:

- The **startup probe** asks "has it finished loading?" It allows up to 120 × 5 s = 10 minutes. Until it passes, Kubernetes runs no other probe, so a slow load isn't mistaken for a hang.
- The **readiness probe** asks "should it get traffic right now?" A Pod that fails it is taken out of the Service but not restarted.
- There's no **liveness probe**. One that's too strict would restart a model that's busy decoding a long answer. A restart costs a reload, so add one only for a failure you've actually seen, with a generous threshold.

The annotations ask Phase 5's Prometheus to scrape the server's `/metrics`. `readOnlyRootFilesystem` works because llama-server writes nothing to disk.

Phase 6's default-deny policy blocks everything until a policy allows it. The model answers the API, Prometheus and, in this lab, a probe Pod; it calls nobody:

<!-- file: deploy/inference/llm-policy.yaml -->
~~~yaml
# The namespace denies all traffic by default (Phase 6). The model answers only
# the API, Prometheus and, in this lab, the probe Pod; it calls nobody.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: llm
  namespace: runway
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
  namespace: runway
spec:
  podSelector: { matchLabels: { role: llm-probe } }
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
    - to: [{ podSelector: { matchLabels: { app: llm } } }]
      ports: [{ port: 8080 }]
~~~

When you wire Step 5's API into the cluster, its own egress policy needs `llm:8080` too.

## Measure start-up

Kubernetes records when each Pod was scheduled, when its container started and when it became ready. This reads them:

<!-- file: serve/src/serve/podtimes.py -->
~~~python
"""How long did a pod take to be scheduled, start and become ready? Ask Kubernetes.

  kubectl -n runway get pods -l app=llm -o json | uv run python -m serve.podtimes

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
kubectl -n runway rollout status deployment/llm --timeout=10m
kubectl -n runway get pods -l app=llm -o json | (cd serve && uv run python -m serve.podtimes)
kubectl -n runway get events --field-selector reason=Pulled -o custom-columns=MESSAGE:.message
~~~

~~~text
pod                        scheduled  started  ready restarts
llm-75974b7f6c-fddvp               0      169    175        0
Successfully pulled image "ghcr.io/ggml-org/llama.cpp@sha256:e67d88af...f78b" in 2m48.799s (2m48.799s including waiting). Image size: 309499562 bytes.
~~~

Of the 175 seconds, 169 were spent pulling a 309 MB image. Loading the model took about 6 seconds. A node pulls an image once, so the next start on the same node skips that part. If a new replica lands on a node that has never run the model, it pays the whole 169 s again. That's why clusters that serve models pre-pull images onto their nodes.

## Probe from inside the cluster

To see what users see, send requests from inside the cluster, through the Service, as the API would. This needs only the standard library and Step 2's `stream.py`:

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
  namespace: runway
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
kubectl -n runway create configmap llm-probe-code \
  --from-file=serve/src/serve/stream.py --from-file=serve/src/serve/probe.py
kubectl apply -f deploy/inference/probe.yaml
kubectl -n runway wait --for=condition=Ready pod/llm-probe --timeout=5m
kubectl -n runway exec llm-probe -- python -m serve.probe http://llm:8080 --seconds 5
~~~

~~~text
{"requests": 6, "completed": 6, "failed": {}, "ttft_p50": 0.55, "ttft_max": 0.63, "outage_seconds": null}
~~~

Check that the policy really is what lets it through. Remove the probe's label, and the same request has nowhere to go:

~~~bash
kubectl -n runway label pod llm-probe role-
kubectl -n runway exec llm-probe -- python -m serve.probe http://llm:8080 --seconds 1
kubectl -n runway label pod llm-probe role=llm-probe
~~~

~~~text
{"requests": 1, "completed": 0, "failed": {"timed out": 1}, "ttft_p50": null, "ttft_max": null, "outage_seconds": null}
~~~

The request waited out its full 60-second timeout: the policy dropped the connection without an answer. Put the label back before going on.

## Replace the model while users wait

Kubernetes replaces Pods all the time: node upgrades, rollouts, evictions. Delete the model Pod while three probe workers keep sending requests:

~~~bash
kubectl -n runway exec llm-probe -- \
  python -m serve.probe http://llm:8080 --seconds 60 --workers 3 --rows > replace.txt &
sleep 10
kubectl -n runway delete pod -l app=llm --wait=false
wait
tail -1 replace.txt
grep -v '"error": ""' replace.txt | head -3
~~~

~~~text
{"requests": 47, "completed": 44, "failed": {"Remote end closed connection without response": 2, "incomplete or empty stream": 1}, "ttft_p50": 1.7, "ttft_max": 2.0, "outage_seconds": 31.76}
{"start": 7.82, "total": 31.5, "error": "incomplete or empty stream", "ttft": 1.71}
{"start": 8.51, "total": 30.82, "error": "Remote end closed connection without response", "ttft": null}
{"start": 9.25, "total": 30.08, "error": "Remote end closed connection without response", "ttft": null}
~~~

The replacement Pod was ready about 5 s after it was created. But the three requests that were on the old Pod when it was deleted, one streaming and two queued behind it, hung for **30 seconds** and then failed. Kubernetes sent the server SIGTERM; it stopped generating but didn't close its connections. Kubernetes waited out the default 30-second grace period, then killed it. For those users, a routine Pod replacement was a 30-second failure.

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
kubectl -n runway rollout status deployment/llm --timeout=5m
~~~

Run the same replacement again, twice:

~~~text
{"requests": 84, "completed": 84, "failed": {}, "ttft_p50": 1.76, "ttft_max": 2.33, "outage_seconds": null}
{"requests": 89, "completed": 89, "failed": {}, "ttft_p50": 1.68, "ttft_max": 1.96, "outage_seconds": null}
~~~

Every request completed, both times. There's a detail of current Kubernetes behind this. When a Service has no ready Pods, it keeps sending traffic to Pods that are shutting down but still pass their readiness probe. With the hook, the old server keeps working, so it carries the traffic until the new Pod is ready. Then it goes idle, the hook exits, and SIGTERM finds nothing to interrupt.

The hook must fit inside the grace period: 2 s plus at most 25 s of waiting, within 30 s. If your longest answer takes longer than that, raise `terminationGracePeriodSeconds`, or the kill arrives mid-answer anyway.

**Break it:** give the model less time to start than it needs. One second, one try:

~~~bash
kubectl -n runway patch deployment llm --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/periodSeconds","value":1},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/failureThreshold","value":1}]'
sleep 100
kubectl -n runway get pods -l app=llm
kubectl -n runway get events --field-selector reason=Unhealthy -o custom-columns=COUNT:.count,MSG:.message
kubectl -n runway exec llm-probe -- python -m serve.probe http://llm:8080 --seconds 5
~~~

~~~text
NAME                  READY   STATUS             RESTARTS      AGE
llm-867bfcbd9-m87xt   0/1     CrashLoopBackOff   4 (38s ago)   98s
1       Startup probe failed: HTTP probe failed with statuscode: 503
6       Readiness probe failed: Get "http://10.244.2.5:8080/health": dial tcp 10.244.2.5:8080: connect: connection refused
5       Startup probe failed: HTTP probe failed with statuscode: 503
{"requests": 1, "completed": 0, "failed": {"timed out": 1}, "ttft_p50": null, "ttft_max": null, "outage_seconds": null}
~~~

The server answers 503 while it loads, so the first check fails, Kubernetes kills it, and it starts loading again: four restarts in 98 seconds, and the back-off between attempts keeps growing. And because the Deployment uses `Recreate`, the old, working Pod was removed *first*, so nothing at all was serving. A bad configuration change became a complete outage. With `RollingUpdate`, the old Pod would have kept serving while the new one failed, but that needs room for a second copy of the weights. Restore the measured allowance:

~~~bash
kubectl apply -f deploy/inference/llm.yaml
kubectl -n runway rollout status deployment/llm --timeout=5m
~~~

Mine was ready again 6 s later, and all six probe requests completed.

## Scale on queue depth

CPU is a poor scaling signal for a decoder. It's limited by memory bandwidth, and it can look much the same idle or swamped. A better signal is how many requests are waiting. llama-server exports that as `llamacpp:requests_deferred`, and Phase 5's Prometheus is already scraping it:

~~~bash
kubectl -n observability port-forward svc/prometheus 19090:9090 &
curl -s 127.0.0.1:19090/api/v1/query --data-urlencode 'query=llamacpp:requests_deferred'
~~~

The result carries `namespace="runway"` and `pod="llm-..."` labels, from Phase 5's scrape configuration. A HorizontalPodAutoscaler can't query Prometheus, though; it reads metrics from the Kubernetes API. The **Prometheus adapter** sits between them: it serves chosen Prometheus series as Kubernetes metrics.

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
    # Requests waiting inside each model server, per Pod. Phase 5's scrape
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

Phase 5 lets only Grafana query Prometheus. Policies add up, so a second one admits the adapter, without editing Phase 5's:

<!-- file: deploy/inference/adapter-policy.yaml -->
~~~yaml
# Phase 5 lets only Grafana query Prometheus. Policies add up, so this one
# admits the adapter as well, without editing Phase 5's file.
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
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/runway/pods/*/llm_requests_waiting"
~~~

After about 20 seconds, the Kubernetes API answers with one item per model Pod: `"metricName": "llm_requests_waiting"` and `"value": "0"`.

Now the autoscaler. It aims for an average of two waiting requests per Pod:

<!-- file: deploy/inference/hpa.yaml -->
~~~yaml
# Scale the model on how many requests wait inside it, not on CPU: a decoder
# is limited by memory bandwidth, and its CPU can look the same idle or swamped.
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: llm, namespace: runway }
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
get() { kubectl -n runway get "$1" -o jsonpath="$2" 2>/dev/null; }
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
kubectl -n runway exec llm-probe -- \
  python -m serve.probe http://llm:8080 --seconds 150 --workers 6 --max-tokens 128
~~~

The watcher, from just before the load started:

~~~text
   9s  waiting/pod=0     desired=1  ready=1
  11s  waiting/pod=0     desired=1  ready=1
  14s  waiting/pod=0     desired=1  ready=1
  17s  waiting/pod=5     desired=2  ready=1
  19s  waiting/pod=5     desired=2  ready=1
  22s  waiting/pod=5     desired=2  ready=2
  25s  waiting/pod=5     desired=2  ready=2
  28s  waiting/pod=5     desired=2  ready=2
  31s  waiting/pod=4     desired=2  ready=2
  34s  waiting/pod=4     desired=2  ready=2
~~~

The load started at about 4 s. By 17 s the adapter reported five requests waiting and the autoscaler asked for a second replica, which was ready at 22 s. That's quick because the image was already on the node and the weights were in its page cache: on a node that had never run the model, add the 169-second pull from earlier. Later samples show values such as `2500m` and `1500m`: Kubernetes' way of writing 2.5 and 1.5, averages across the two Pods.

The load stopped at about 158 s. The autoscaler waited out its 300-second stabilisation window, then removed the second replica:

~~~text
 463s  waiting/pod=0     desired=2  ready=2
 466s  waiting/pod=0     desired=2  ready=2
 468s  waiting/pod=0     desired=1  ready=1
 471s  waiting/pod=0     desired=1  ready=1
 473s  waiting/pod=0     desired=1  ready=1
 475s  waiting/pod=0     desired=1  ready=1
~~~

The probe's summary, then each Pod's token counter, read from inside the cluster (run the loop before the load too, and subtract):

~~~bash
for ip in $(kubectl -n runway get pods -l app=llm -o jsonpath='{.items[*].status.podIP}'); do
  kubectl -n runway exec llm-probe -- python -c "import urllib.request
for line in urllib.request.urlopen('http://$ip:8080/metrics').read().decode().splitlines():
    if line.startswith('llamacpp:tokens_predicted_total'): print('$ip', line)"
done
~~~

~~~text
{"requests": 34, "completed": 34, "failed": {}, "ttft_p50": 25.52, "ttft_max": 56.1, "outage_seconds": null}
10.244.2.14 llamacpp:tokens_predicted_total 1280
10.244.2.13 llamacpp:tokens_predicted_total 5504
~~~

| | Requests started in the first 20 s (mostly one Pod) | Requests started after 60 s (two Pods) |
|---|---|---|
| Median time to decode one 128-token answer | 5.8 s | 8.1 s |
| Tokens per second, all Pods together (128 ÷ decode time × Pods) | about 22 | about 32 |

Before the load, the first Pod's counter read 2,432 and the second Pod didn't exist. So the old Pod generated 3,072 tokens during the run (24 answers of 128 tokens) and the new one 1,280 (10 answers). Every request completed, and both Pods did work. But two things in these numbers matter more than the scaling itself:

- **The second replica added about 40% throughput, not 100%.** Both Pods run on `runway-worker`, because the `ReadWriteOnce` volume is there, so they share its CPUs and memory bandwidth, and each decodes more slowly. A replica on another node wouldn't share them; I couldn't measure that here, because the volume pins every replica to one node. That's the weight-distribution problem from the start of this step, now measured.
- **The target decides the latency, and this one is too loose.** "Two waiting per Pod" means a request waits for about two 8-second answers before its own starts. The median wait for first content was 25.5 s, and the slowest was 56 s. Choose the target the way Step 9 chose the queue length: from the time budget. Waiting requests × time per answer must fit inside your time-to-first-token objective. For Step 5's one second, no number of waiting requests fits, so the honest conclusion is that this laptop can't offer that objective for long answers at this load. Measuring tells you that before users do.

**Done when:** the weights' digest matches inside the cluster, you have cold and warm start timelines, a Pod replacement under load completes every request, and the model scales out on queue depth and back in. Keep the outputs; Step 14's report uses them. Mine are in [evidence/2026-11-13-kubernetes](../evidence/2026-11-13-kubernetes/README.md).

**What this proves, and what it doesn't.** It proves the model runs under the namespace's security rules and network policy, that replacing it no longer drops requests, and that queue depth drives scaling on this cluster. It doesn't prove anything about a cluster with many nodes: here every replica shares one node and one copy of the volume, so a second replica adds a second decoder, not more memory bandwidth from a second machine. Nor does it cover the gateway: in the full system the queue sits in Step 4's admission queue, and you'd scale on the gateway's waiting gauge instead. The [platform report](../evidence/platform-validation/report.md) did that once, through the real API.
