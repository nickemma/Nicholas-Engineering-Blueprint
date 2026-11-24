# Follow a Deployment, DaemonSet and Job through Kubernetes

After [Kubernetes and delivery](../README.md), use a small HTTP workload to observe reconciliation without the full Switchyard chart. A Deployment keeps two ready replicas, a Service gives callers a stable address, a DaemonSet identifies the node running it, and a finite Job checks the Service by DNS.

## 1. Create the lab cluster and verify the context

~~~~bash
kind create cluster --name blueprint-platform-build --kubeconfig "$PWD/platform.kubeconfig"
export KUBECONFIG="$PWD/platform.kubeconfig"
kubectl config current-context
kubectl get nodes
kubectl -n kube-system get pods
~~~~

The API server accepts the YAML. The scheduler selects a node for each Pod. The kubelet on that node starts the containers and evaluates probes. `kubectl get pods,rs` in the lab namespace will show how the Deployment works through a ReplicaSet. A remote sandbox uses a different kubeconfig and context. Inspect it with `kubectl --context YOUR_SANDBOX get nodes` before running write commands there. [Cluster architecture](https://kubernetes.io/docs/concepts/architecture/)

## 2. Declare the workloads and the Service

The ConfigMap provides the HTTP response. Deployment labels connect the Pods to their ReplicaSet and the Service selector. The annotation describes the rollout for humans and tools. The liveness probe checks whether the process can serve HTTP. The readiness probe also checks a deliberate fault toggle. That difference lets you observe a live process that receives no Service traffic.

Create `workloads.yaml`.

<!-- file: workloads.yaml -->
~~~~yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: message
data:
  index.html: "switchyard platform lab"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  annotations:
    blueprint.example/purpose: "Follow a rolling update"
spec:
  replicas: 2
  progressDeadlineSeconds: 30
  strategy:
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app: platform-api
  template:
    metadata:
      labels:
        app: platform-api
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsUser: 10001
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: http
          image: busybox:1.37
          command: [httpd, -f, -p, "8080", -h, /www]
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: BROKEN
              value: "0"
          readinessProbe:
            exec:
              command: [sh, -c, 'test "$BROKEN" = 0 && wget -qO /dev/null http://127.0.0.1:8080/']
            periodSeconds: 2
          livenessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 5
          resources:
            requests:
              cpu: 20m
              memory: 8Mi
            limits:
              cpu: 100m
              memory: 32Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: content
              mountPath: /www
              readOnly: true
      volumes:
        - name: content
          configMap:
            name: message
---
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: platform-api
  ports:
    - port: 8080
      targetPort: http
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-marker
spec:
  selector:
    matchLabels:
      app: node-marker
  template:
    metadata:
      labels:
        app: node-marker
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsUser: 10001
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: marker
          image: busybox:1.37
          command: [sh, -c, 'echo "running on $NODE_NAME"; exec sleep 3600']
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
~~~~

Create `probe.yaml`.

<!-- file: probe.yaml -->
~~~~yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: probe
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 20
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsUser: 10001
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: probe
          image: busybox:1.37
          command: [sh, -ec, 'body=$(wget -T 5 -qO- http://api:8080/); test "$body" = "switchyard platform lab"; echo "$body"']
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
~~~~

## 3. Run the rollout and recovery check

The check uses a fresh restricted namespace. It applies YAML, waits for the rollouts, and calls the Service from a Job. It then scales imperatively and reconciles from the declared replica count. The negative control starts a new replica with failing readiness and expects the rollout to time out. A fresh Job must still reach a healthy replica by the same DNS name. Finally the script rolls the bad revision back.

Create `check-workloads.sh`.

<!-- file: check-workloads.sh -->
~~~~bash
#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?Point KUBECONFIG at the disposable kind cluster}"
context="$(kubectl config current-context)"
[[ "$context" == kind-blueprint-platform-build ]] || {
  echo "Expected the kind-blueprint-platform-build context" >&2
  exit 1
}

namespace="platform-lab-${RANDOM}-$$"
kubectl create namespace "$namespace"
cleanup() { kubectl delete namespace "$namespace" --wait=false >/dev/null; }
trap cleanup EXIT
k() { kubectl -n "$namespace" "$@"; }

probe() {
  k delete -f probe.yaml --ignore-not-found >/dev/null
  k create -f probe.yaml >/dev/null
  k wait --for=condition=complete job/probe --timeout=40s >/dev/null
  k logs job/probe
}

kubectl label namespace "$namespace" pod-security.kubernetes.io/enforce=restricted >/dev/null
k apply -f workloads.yaml >/dev/null
k rollout status deploy/api --timeout=60s
k rollout status daemonset/node-marker --timeout=60s
k get pods,rs
probe

k scale deploy/api --replicas=3 >/dev/null
k rollout status deploy/api --timeout=60s
test "$(k get deploy/api -o jsonpath='{.status.readyReplicas}')" = 3
k apply -f workloads.yaml >/dev/null
k rollout status deploy/api --timeout=60s
test "$(k get deploy/api -o jsonpath='{.spec.replicas}')" = 2
echo "imperative scale reached 3, declarative apply restored 2"

k set env deploy/api BROKEN=1 >/dev/null
if k rollout status deploy/api --timeout=50s > bad-rollout.txt 2>&1; then
  echo "broken rollout unexpectedly became ready" >&2
  exit 1
fi
grep -F 'exceeded its progress deadline' bad-rollout.txt
probe
k rollout undo deploy/api >/dev/null
k rollout status deploy/api --timeout=60s
probe
echo "healthy replicas served throughout the failed rollout and rollback"
~~~~

<!-- run: bash -n check-workloads.sh -->
~~~~bash
bash -n check-workloads.sh
~~~~

~~~~bash
docker pull busybox:1.37
kind load docker-image busybox:1.37 --name blueprint-platform-build
bash check-workloads.sh
~~~~

If kind on a Docker image store complains of a missing platform digest, import just the lab node's platform. The captured run used Linux amd64.

~~~~bash
docker save --platform linux/amd64 busybox:1.37 |
  docker exec -i blueprint-platform-build-control-plane \
    ctr -n k8s.io images import --platform linux/amd64 -
~~~~

The kind run showed two Deployment Pods and one DaemonSet Pod on one node. These lines came from the client checks.

~~~~text
switchyard platform lab
imperative scale reached 3, declarative apply restored 2
error: deployment "api" exceeded its progress deadline
switchyard platform lab
deployment "api" successfully rolled out
switchyard platform lab
healthy replicas served throughout the failed rollout and rollback
~~~~

For a manual run, apply both manifests in a fresh namespace and inspect `kubectl get endpointslices`, `kubectl describe pod`, `kubectl logs job/probe`, `kubectl logs --previous POD` after a restart, and the DaemonSet's node name. Start with a ClusterIP Service. A NodePort publishes a port on nodes, a LoadBalancer relies on an implementation to provision a load balancer, and a headless Service exposes endpoint addresses through DNS. Create a copy of the Service with `clusterIP: None` and compare its DNS answer with that of the original Service.


## 4. Route HTTP through an Ingress

Install an Ingress controller in the disposable cluster. This chart configures a ClusterIP Service for the local proxy. The Ingress resource selects its class and sends traffic for one host to the application's Service.

~~~~bash
helm upgrade --install platform-edge traefik --repo https://traefik.github.io/charts \
  --version 34.4.1 --namespace platform-edge --create-namespace \
  --set service.type=ClusterIP --set providers.kubernetesCRD.enabled=false --wait
~~~~

Create `ingress.yaml`.

<!-- file: ingress.yaml -->
~~~~yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: platform
spec:
  ingressClassName: platform-edge-traefik
  rules:
    - host: platform.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api
                port:
                  number: 8080
~~~~

Create `check-ingress.sh`.

<!-- file: check-ingress.sh -->
~~~~bash
#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?Point KUBECONFIG at the disposable kind cluster}"
test "$(kubectl config current-context)" = kind-blueprint-platform-build
namespace="ingress-lab-${RANDOM}-$$"
kubectl create namespace "$namespace"
cleanup() {
  if [[ -n "${forward:-}" ]]; then
    kill "$forward" 2>/dev/null || true
    wait "$forward" 2>/dev/null || true
  fi
  kubectl delete namespace "$namespace" --wait=false >/dev/null
}
trap cleanup EXIT
kubectl -n "$namespace" apply -f workloads.yaml -f ingress.yaml
kubectl -n "$namespace" rollout status deploy/api --timeout=60s
kubectl -n platform-edge port-forward svc/platform-edge-traefik :80 > forward.txt 2>&1 &
forward=$!
for _ in {1..30}; do
  port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) ->.*/\1/p' forward.txt)"
  [[ -z "$port" ]] || break
  sleep 0.2
done
test -n "$port"
for _ in {1..30}; do
  body="$(curl -fsS --max-time 2 -H 'Host: platform.local' "http://127.0.0.1:$port/" 2>/dev/null || true)"
  [[ "$body" != "switchyard platform lab" ]] || break
  sleep 0.2
done
test "$body" = "switchyard platform lab"
test "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 -H 'Host: other.local' "http://127.0.0.1:$port/")" = 404
echo "platform.local routed to the API; unmatched host returned 404"
~~~~

<!-- run: bash -n check-ingress.sh -->
~~~~bash
bash -n check-ingress.sh
~~~~


~~~~bash
bash check-ingress.sh
~~~~

The check opens a local port forward to the Ingress controller. It printed `platform.local routed to the API; unmatched host returned 404`.

Keep the disposable cluster if you will run another platform build. Otherwise remove it with `kind delete cluster --name blueprint-platform-build`.
