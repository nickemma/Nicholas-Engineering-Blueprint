# 07 Follow a request through the cluster

A successful response spans more than one process. Use the trace ID to find both operations, then use the span IDs to prove the child operation belongs to that entry request.

## Build it

### Step 1. Continue the trace

Compare the incoming trace ID to the child's trace ID. Then compare the Parent ID to the original span's ID.

<details>
<summary>Hint</summary>

Start a new trace if the incoming ID is missing or invalid. Assign a new span ID at each hop.

</details>

<details>
<summary>Type-along files</summary>

Create `delivery/internal/telemetry/trace_test.go`.

<!-- file: delivery/internal/telemetry/trace_test.go -->
~~~go
package telemetry

import (
	"strings"
	"testing"
	"time"
)

func TestTraceContinuesAcrossHop(t *testing.T) {
	root := Begin("", "edge", time.Now())
	next := Begin(root.Header(), "frontend", time.Now())
	if next.TraceID != root.TraceID || next.ParentSpanID != root.SpanID || next.SpanID == root.SpanID {
		t.Fatal("invalid parent linkage", root, next)
	}
	bad := Begin("00-"+strings.Repeat("0", 32)+"-"+root.SpanID+"-01", "frontend", time.Now())
	if bad.ParentSpanID != "" || !validID(bad.TraceID, 16) {
		t.Fatal(bad)
	}
	t.Log("frontend span kept the edge trace ID and used the edge span as its parent")
}
~~~

</details>
### Step 2. Export to the Collector

Install an OTLP/HTTP receiver and debug exporter. Reuse the bounded exporter from Lesson 02 so a slow collector cannot stall the request.

<details>
<summary>Hint</summary>

Read the two exported span records for the same trace.

</details>

<details>
<summary>Type-along files</summary>

Create `chart/files/observability/collector.yaml`.

<!-- file: chart/files/observability/collector.yaml -->
~~~yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
~~~

Create `chart/templates/observability.yaml`.

<!-- file: chart/templates/observability.yaml -->
~~~yaml
{{- if .Values.observability.enabled }}
apiVersion: v1
kind: ConfigMap
metadata: {name: delivery-observability}
data:
{{ (.Files.Glob "files/observability/*").AsConfig | indent 2 }}
{{- range $app := list "collector" "prometheus" "grafana" }}
{{- $images := dict "collector" $.Values.observability.collectorImage "prometheus" $.Values.observability.prometheusImage "grafana" $.Values.observability.grafanaImage }}
{{- $ports := dict "collector" 4318 "prometheus" 9090 "grafana" 3000 }}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: {{ $app }}}
spec:
  replicas: 1
  selector: {matchLabels: {app: {{ $app }}}}
  template:
    metadata: {labels: {app: {{ $app }}}}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: {{ if eq $app "grafana" }}472{{ else }}65532{{ end }}
        runAsGroup: {{ if eq $app "grafana" }}472{{ else }}65532{{ end }}
        fsGroup: {{ if eq $app "grafana" }}472{{ else }}65532{{ end }}
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: {{ $app }}
        image: {{ index $images $app | quote }}
        securityContext: {{- include "delivery.security" $ | nindent 10 }}
        {{- if eq $app "collector" }}
        args: ["--config=/etc/lab/collector.yaml"]
        {{- else if eq $app "prometheus" }}
        args: ["--config.file=/etc/lab/prometheus.yaml", "--storage.tsdb.path=/working"]
        {{- else }}
        env:
        - {name: GF_PATHS_DATA, value: /working}
        - {name: GF_PLUGINS_PREINSTALL_DISABLED, value: "true"}
        - {name: GF_AUTH_ANONYMOUS_ENABLED, value: "true"}
        - {name: GF_AUTH_ANONYMOUS_ORG_ROLE, value: Viewer}
        - {name: GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION, value: "true"}
        {{- end }}
        ports: [{name: http, containerPort: {{ index $ports $app }}}]
        readinessProbe:
          tcpSocket: {port: http}
          periodSeconds: 2
        volumeMounts:
        - {name: config, mountPath: /etc/lab, readOnly: true}
        - {name: working, mountPath: /working}
        {{- if eq $app "grafana" }}
        - {name: config, mountPath: /etc/grafana/provisioning/datasources/lab.yaml, subPath: grafana.yaml, readOnly: true}
        - {name: config, mountPath: /etc/grafana/provisioning/dashboards/lab.yaml, subPath: provider.yaml, readOnly: true}
        {{- end }}
        resources:
          requests: {cpu: 20m, memory: 24Mi}
          limits: {memory: 384Mi}
      volumes:
      - name: config
        configMap: {name: delivery-observability}
      - {name: working, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata: {name: {{ $app }}}
spec:
  selector: {app: {{ $app }}}
  ports: [{name: http, port: {{ index $ports $app }}, targetPort: http}]
{{- end }}
{{- end }}
~~~

</details>

## Check it

~~~bash
(cd delivery && go test -race -count=1 -v ./internal/telemetry)
~~~

<!-- run: (cd delivery && go test -race -count=1 -v ./internal/telemetry) -->

The test compares exact parent and child identifiers. [Captured Go checks](../evidence/unit-tests.txt)

## Run locally

After adding the remaining observability files in Lesson 08, enable `observability.enabled`. Send `GET /health` through the entry Service port-forward. Find both `frontend-entry` and `frontend-stable` in `kubectl logs deployment/collector` using the returned `X-Lab-Trace`. The stable span's Parent ID equals the entry span's ID. [OTLP/HTTP format](https://opentelemetry.io/docs/specs/otlp/)
