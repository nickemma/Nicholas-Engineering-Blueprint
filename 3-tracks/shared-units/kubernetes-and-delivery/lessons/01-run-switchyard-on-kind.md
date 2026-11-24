# 01 Run Switchyard on kind

## The problem

A successful image build says little about when the process can receive traffic. Kubernetes needs distinct signals for process startup, readiness for new work, and liveness.

The first release runs the Core 03 API in memory. Binaries are compiled before building the runtime image. The image runs as a dedicated non-root user. A Deployment replaces a failed Pod, while a Service provides an address for its selected endpoints.

## Build it

### Step 1. Stage the exact binaries

Compile the API and worker from jobs, the metadata peer and gateway from core, and the unit's small deployable helpers. Build the jobs stage first. Later stages add the helper packages as you type them.

<details>
<summary>Hint</summary>

Build in a temporary directory and pass only the runtime files to Docker.

</details>

<details>
<summary>Type-along files</summary>

Create `ops/build-image.sh`.

<!-- file: ops/build-image.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
image=$1
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/context/bin"
mode=${2:-full}
entries=(jobs:switchyard jobs:worker)
case "$mode" in
  jobs) ;;
  frontend) entries+=(delivery:frontend) ;;
  metadata) entries+=(delivery:frontend core:metad core:ship-gateway delivery:peer-bridge) ;;
  full) entries+=(delivery:frontend core:metad core:ship-gateway delivery:peer-bridge delivery:scale-worker) ;;
  *) echo "expected stage jobs, frontend, metadata, or full" >&2; exit 2 ;;
esac
for entry in "${entries[@]}"; do
  dir=${entry%:*}
  cmd=${entry#*:}
  (cd "$dir" && CGO_ENABLED=0 go build -buildvcs=false -trimpath -o "$work/context/bin/$cmd" "./cmd/$cmd")
done
if [[ "$mode" == metadata || "$mode" == full ]]; then
  cargo build --manifest-path core/klog/Cargo.toml --offline --release --target-dir "$work/rust" --bin metad-wal
  cp "$work/rust/release/metad-wal" "$work/context/bin/"
fi
cp ops/runtime.Dockerfile "$work/context/Dockerfile"
docker build --provenance=false -t "$image" "$work/context"
~~~

Create `ops/runtime.Dockerfile`.

<!-- file: ops/runtime.Dockerfile -->
~~~text
FROM ubuntu:24.04
COPY bin/ /app/
USER 65532:65532
ENTRYPOINT ["/app/switchyard"]
~~~

</details>
### Step 2. Declare the base release

Create the Helm shell so you can render the first workload with PostgreSQL disabled. Match the Deployment and Service labels and add startup, readiness, and liveness probes.

<details>
<summary>Hint</summary>

Give the coordinator one replica and use Recreate, matching Core 03's startup ownership of job recovery.

</details>

<details>
<summary>Type-along files</summary>

Create `chart/Chart.yaml`.

<!-- file: chart/Chart.yaml -->
~~~yaml
apiVersion: v2
name: switchyard-delivery
description: Local Switchyard delivery lab
type: application
version: 0.1.0
~~~

Create `chart/values.yaml`.

<!-- file: chart/values.yaml -->
~~~yaml
image: switchyard-delivery:lab
stableImage: ""
canaryImage: ""
canaryFault: false
frontendStartupDelay: 0s
database:
  enabled: true
  image: postgres:17
  secret: switchyard-db
metadata:
  enabled: false
  domain: cluster.local
  peerSecret: switchyard-peers
  gatewaySecret: switchyard-gateway
observability:
  enabled: false
  collectorImage: otel/opentelemetry-collector:0.162.0
  prometheusImage: prom/prometheus:v3.15.0
  grafanaImage: grafana/grafana:13.2.3
scaler:
  enabled: false
networkPolicy: false
~~~

Create `chart/templates/_helpers.tpl`.

<!-- file: chart/templates/_helpers.tpl -->
~~~text
{{- define "delivery.security" -}}
allowPrivilegeEscalation: false
capabilities: {drop: [ALL]}
{{- end -}}
{{- define "delivery.podSecurity" -}}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
fsGroup: 65532
seccompProfile: {type: RuntimeDefault}
{{- end -}}
~~~

Create `chart/templates/jobs.yaml`.

<!-- file: chart/templates/jobs.yaml -->
~~~yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: jobs}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: jobs}}
  template:
    metadata: {labels: {app: jobs}}
    spec:
      automountServiceAccountToken: false
      securityContext: {{- include "delivery.podSecurity" . | nindent 8 }}
      containers:
      - name: jobs
        image: {{ .Values.image | quote }}
        imagePullPolicy: IfNotPresent
        securityContext: {{- include "delivery.security" . | nindent 10 }}
        command: [/app/switchyard]
        env:
        - {name: LISTEN_ADDR, value: "0.0.0.0:8080"}
        - {name: GRPC_ADDR, value: "0.0.0.0:9090"}
        - {name: QUEUE_CAPACITY, value: "100"}
        {{- if .Values.database.enabled }}
        - name: SWITCHYARD_DATABASE_URL
          valueFrom:
            secretKeyRef: {name: {{ .Values.database.secret }}, key: url}
        {{- end }}
        ports:
        - {name: http, containerPort: 8080}
        - {name: worker, containerPort: 9090}
        startupProbe:
          httpGet: {path: /health, port: http}
          failureThreshold: 25
          periodSeconds: 2
        readinessProbe:
          httpGet: {path: /health, port: http}
          periodSeconds: 2
        livenessProbe:
          httpGet: {path: /health, port: http}
          periodSeconds: 10
        resources:
          requests: {cpu: 40m, memory: 48Mi}
          limits: {memory: 256Mi}
---
apiVersion: v1
kind: Service
metadata: {name: jobs}
spec:
  selector: {app: jobs}
  ports:
  - {name: http, port: 8080, targetPort: http}
  - {name: worker, port: 9090, targetPort: worker}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: worker}
spec:
  {{- if not .Values.scaler.enabled }}
  replicas: 1
  {{- end }}
  selector: {matchLabels: {app: worker}}
  template:
    metadata: {labels: {app: worker}}
    spec:
      automountServiceAccountToken: false
      securityContext: {{- include "delivery.podSecurity" . | nindent 8 }}
      containers:
      - name: worker
        image: {{ .Values.image | quote }}
        imagePullPolicy: IfNotPresent
        securityContext: {{- include "delivery.security" . | nindent 10 }}
        command: [/app/worker]
        env:
        - {name: CONTROL_PLANE, value: "jobs:9090"}
        resources:
          requests: {cpu: 25m, memory: 32Mi}
          limits: {memory: 256Mi}
~~~

</details>

## Check it

~~~bash
helm lint chart --set database.enabled=false && helm template delivery chart --set database.enabled=false >/dev/null
~~~

<!-- run: helm lint chart --set database.enabled=false && helm template delivery chart --set database.enabled=false >/dev/null -->

The chart renders a jobs Deployment, a worker Deployment, and a jobs Service. The three probes are visible in the rendered Pod template.

## Run locally

Start with the jobs-only image. The runtime layout puts both executables under `/app`.

~~~bash
bash ops/build-image.sh switchyard-delivery:lab jobs
kind load docker-image --name blueprint-delivery switchyard-delivery:lab
kubectl create namespace delivery-steps
helm upgrade --install delivery chart -n delivery-steps --set database.enabled=false
kubectl -n delivery-steps rollout status deploy/jobs
kubectl -n delivery-steps get pods
~~~

Use the configurable startup delay in Lesson 02 to observe a Pod that is live while removed from routing. Inspect events on your own lab Pods before and after a controlled restart. [Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
