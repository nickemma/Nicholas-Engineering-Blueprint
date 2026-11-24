# Recover Consul and PostgreSQL after losing a leader

Reuse the disposable kind cluster from [the workload build](workloads-and-rollouts.md). Use its kubeconfig for both tests. You'll compare a StatefulSet member using its persistent claim with a database operator moving a writer endpoint.

## 1. Boot a Consul quorum with one claim per identity

A headless Service publishes the set of peer addresses. The StatefulSet gives members the stable identities `consul-0` through `consul-2`. The peers must join before all are ready, so start them in parallel and publish their DNS names during bootstrap.

Each claim template produces a PVC. The default kind StorageClass dynamically provisions the PV. Check the actual claim and class using `kubectl get pvc -o wide`, `kubectl get pv`, and `kubectl get storageclass`. This is a single-node lab quorum. Its evidence applies to replacing a process, while testing a physical node failure needs peers across nodes.

Create `consul.yaml`.

<!-- file: consul.yaml -->
~~~~yaml
apiVersion: v1
kind: Service
metadata:
  name: consul
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: consul
  ports:
    - name: http
      port: 8500
    - name: rpc
      port: 8300
    - name: serf-tcp
      port: 8301
      protocol: TCP
    - name: serf-udp
      port: 8301
      protocol: UDP
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: consul
spec:
  serviceName: consul
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: consul
  template:
    metadata:
      labels:
        app: consul
    spec:
      automountServiceAccountToken: false
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: consul
          image: hashicorp/consul:1.21.5
          command: [consul, agent]
          args:
            - -server
            - -bootstrap-expect=3
            - -node=$(POD_NAME)
            - -bind=$(POD_IP)
            - -client=127.0.0.1
            - -data-dir=/consul/data
            - -retry-join=consul-0.consul
            - -retry-join=consul-1.consul
            - -retry-join=consul-2.consul
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          readinessProbe:
            exec:
              command: [consul, operator, raft, list-peers]
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: data
              mountPath: /consul/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 128Mi
~~~~

Create `check-consul.sh`.

<!-- file: check-consul.sh -->
~~~~bash
#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?Point KUBECONFIG at the disposable kind cluster}"
test "$(kubectl config current-context)" = kind-blueprint-platform-build
namespace="consul-lab-${RANDOM}-$$"
kubectl create namespace "$namespace"
cleanup() { kubectl delete namespace "$namespace" --wait=false >/dev/null; }
trap cleanup EXIT
k() { kubectl -n "$namespace" "$@"; }

k apply -f consul.yaml
k rollout status statefulset/consul --timeout=150s
k get pvc
peer_list="$(k exec consul-0 -- consul operator raft list-peers)"
echo "$peer_list"
leader="$(awk '$4 == "leader" { print $1 }' <<<"$peer_list")"
test -n "$leader"
claim="data-$leader"
before="$(k get pvc "$claim" -o jsonpath='{.metadata.uid}')"
pod_before="$(k get pod "$leader" -o jsonpath='{.metadata.uid}')"
k exec consul-0 -- consul kv put jobs/recovery acknowledged
k delete pod "$leader" --wait=true --timeout=60s
k rollout status statefulset/consul --timeout=120s
test "$(k get pod "$leader" -o jsonpath='{.metadata.uid}')" != "$pod_before"
test "$(k get pvc "$claim" -o jsonpath='{.metadata.uid}')" = "$before"
marker=""
for _ in {1..45}; do
  marker="$(k exec consul-1 -- consul kv get jobs/recovery 2>/dev/null || true)"
  [[ "$marker" != acknowledged ]] || break
  sleep 1
done
test "$marker" = acknowledged
echo "deleted leader $leader, verified replacement Pod reused the claim and read the committed marker"
~~~~

<!-- run: bash -n check-consul.sh -->
~~~~bash
bash -n check-consul.sh
~~~~

~~~~bash
bash check-consul.sh
~~~~

The live run showed three bound `standard` PVCs and three voters. After writing the marker and deleting `consul-0`, it observed a different Pod UID, the original claim UID, and the marker returned by another member. Readiness can return before the lookup route has settled, so the read retries within a fixed window.

## 2. Fail over a PostgreSQL writer

Install CloudNativePG in this same disposable cluster. The operator has a validating admission webhook. Inspect its `clientConfig.service` to identify the destination the API server calls for a Cluster admission request. Compare that with a CRD's schema validation and API aggregation, which serves additional API endpoints. [CloudNativePG installation](https://cloudnative-pg.io/docs/1.27/installation_upgrade/) · [Kubernetes API aggregation](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/)

~~~~bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.27/releases/cnpg-1.27.4.yaml
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=120s
kubectl get validatingwebhookconfiguration cnpg-validating-webhook-configuration \
  -o jsonpath='{range .webhooks[*]}{.name}{" "}{.clientConfig.service.name}{"\n"}{end}'
~~~~

The client uses the operator-generated application Secret and the stable read/write Service. Before killing the primary, verify that every instance can read the first marker. This isolates the promotion and client-routing check from the separate question of losing a recently acknowledged write under asynchronous replication.

Create `postgres.yaml`.

<!-- file: postgres.yaml -->
~~~~yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: jobs-db
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:17.9
  failoverDelay: 0
  storage:
    size: 512Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: client
spec:
  restartPolicy: Never
  containers:
    - name: psql
      image: postgres:17-alpine
      command: [sleep, "3600"]
      env:
        - name: PGHOST
          value: jobs-db-rw
        - name: PGDATABASE
          value: app
        - name: PGCONNECT_TIMEOUT
          value: "2"
        - name: PGUSER
          valueFrom:
            secretKeyRef:
              name: jobs-db-app
              key: username
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: jobs-db-app
              key: password
~~~~

Create `check-failover.sh`.

<!-- file: check-failover.sh -->
~~~~bash
#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?Point KUBECONFIG at the disposable kind cluster}"
test "$(kubectl config current-context)" = kind-blueprint-platform-build
namespace="postgres-lab-${RANDOM}-$$"
kubectl create namespace "$namespace"
trap 'kubectl delete namespace "$namespace" --wait=false >/dev/null' EXIT
k() { kubectl -n "$namespace" "$@"; }
sql() { k exec client -- psql -X -qAt -v ON_ERROR_STOP=1 -c "$1"; }
primary() { k get cluster/jobs-db -o jsonpath='{.status.currentPrimary}'; }

k apply -f postgres.yaml
k wait --for=condition=Ready cluster/jobs-db --timeout=240s
k wait --for=condition=Ready pod/client --timeout=90s
old="$(primary)"
test -n "$old"
sql "CREATE TABLE markers (name text PRIMARY KEY); INSERT INTO markers VALUES ('before');"
for pod in $(k get pods -l cnpg.io/cluster=jobs-db -o name); do
  for attempt in {1..30}; do
    marker="$(k exec "$pod" -c postgres -- psql -X -qAt -d app \
      -c "SELECT name FROM markers WHERE name = 'before'" 2>/dev/null || true)"
    if [[ "$marker" == before ]]; then
      break
    fi
    sleep 1
  done
  test "$marker" = before
done

start="$SECONDS"
k delete pod "$old" --wait=false
new="$old"
for _ in {1..120}; do
  current="$(primary)"
  if [[ -n "$current" && "$current" != "$old" ]]; then
    if sql "INSERT INTO markers VALUES ('after') ON CONFLICT DO NOTHING;" 2>/dev/null; then
      new="$current"
      break
    fi
  fi
  sleep 1
done
test "$new" != "$old"
test "$(sql "SELECT string_agg(name, ',' ORDER BY name) FROM markers")" = after,before
echo "writer changed from $old to $new; both markers visible after $((SECONDS - start))s"
k wait --for=condition=Ready cluster/jobs-db --timeout=180s
test "$(k exec "$old" -c postgres -- psql -X -qAt -d app -c 'SELECT pg_is_in_recovery()')" = t
if k exec "$old" -c postgres -- psql -X -qAt -d app -c "INSERT INTO markers VALUES ('wrong-writer')" > old-writer.txt 2>&1; then
  echo "former writer unexpectedly accepted a write" >&2
  exit 1
fi
grep -F 'read-only transaction' old-writer.txt
~~~~

<!-- run: bash -n check-failover.sh -->
~~~~bash
bash -n check-failover.sh
~~~~

~~~~bash
bash check-failover.sh
~~~~

~~~~text
writer changed from jobs-db-1 to jobs-db-2; both markers visible after 7s
ERROR:  cannot execute INSERT in a read-only transaction
~~~~

The first line comes from the client after the write through `jobs-db-rw`. The second comes from a direct write attempt against the recovered former primary. The seven seconds include detection, promotion, routing and client retry in this run. To measure asynchronous data loss, use a separate workload that records acknowledged IDs without first waiting for standby replay, then compare the sets on the new primary. [CloudNativePG failover](https://cloudnative-pg.io/documentation/1.27/failover/)

## 3. Observe admission with the webhook down

After the failover namespace is gone, use a server-side dry run in the dedicated cluster. CloudNativePG installs both a mutating and a validating webhook. Leaving the controller unavailable stops admission. The trap restores the controller when the subshell exits.

~~~~bash
(
  set -e
  test "$(kubectl config current-context)" = kind-blueprint-platform-build
  mgr=deployment/cnpg-controller-manager
  kubectl apply --dry-run=server -f postgres.yaml
  trap 'kubectl -n cnpg-system scale "$mgr" --replicas=1 >/dev/null; kubectl -n cnpg-system rollout status "$mgr" --timeout=90s' EXIT
  kubectl -n cnpg-system scale "$mgr" --replicas=0
  for _ in {1..35}; do
    if ! kubectl apply --dry-run=server -f postgres.yaml > webhook-error.txt 2>&1; then
      break
    fi
    sleep 1
  done
  grep -F 'failed calling webhook' webhook-error.txt
)
~~~~

The healthy dry run succeeded. During the outage the API server reported `failed calling webhook "mcluster.cnpg.io"`. The controller returned to ready after restoration. This is a failure of the admission request path, before a new Cluster object can be persisted.
