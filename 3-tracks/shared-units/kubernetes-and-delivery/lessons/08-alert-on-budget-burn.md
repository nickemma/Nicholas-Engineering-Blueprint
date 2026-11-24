# 08 Alert on budget burn

Rollout checks need separate signals for a healthy stable path and a failed candidate. The entry proxy counts good and bad responses by track. A 99% objective budgets 1% bad outcomes. In the lab, a bad fraction above 10% represents more than ten times the budget rate. Require it in a short and a longer window. Hold the condition briefly before firing, and keep sending probes during recovery. Use windows sized to your real traffic and objective in production.

## Build it

### Step 1. Scrape the attempts and compute two windows

Scrape the entry proxy. Compute the bad fraction from rates and define one alert grouped by track.

<details>
<summary>Hint</summary>

Put the hold time on the expression that requires both windows.

</details>

<details>
<summary>Type-along files</summary>

Create `chart/files/observability/prometheus.yaml`.

<!-- file: chart/files/observability/prometheus.yaml -->
~~~yaml
global:
  scrape_interval: 2s
  evaluation_interval: 2s
rule_files: [/etc/lab/burn.yaml]
scrape_configs:
  - job_name: delivery
    static_configs:
      - targets: [frontend-entry:8080]
~~~

Create `chart/files/observability/burn.yaml`.

<!-- file: chart/files/observability/burn.yaml -->
~~~yaml
groups:
- name: delivery
  interval: 2s
  rules:
  - alert: DeliveryBudgetBurn
    expr: |
      (
        sum by (track) (rate(delivery_attempts_total{result="bad"}[20s]))
        / clamp_min(sum by (track) (rate(delivery_attempts_total[20s])), 1e-9)
      ) > 0.10
      and
      (
        sum by (track) (rate(delivery_attempts_total{result="bad"}[45s]))
        / clamp_min(sum by (track) (rate(delivery_attempts_total[45s])), 1e-9)
      ) > 0.10
    for: 4s
    labels: {severity: lab}
    annotations:
      summary: "Request budget burning on {{ $labels.track }}"
~~~

</details>
### Step 2. View and test the signals

Provision a Grafana datasource and dashboard. Use fixed counters in promtool to test a healthy, failing, and recovering canary independently of kind.

<details>
<summary>Hint</summary>

Expect no stable alert at any checkpoint.

</details>

<details>
<summary>Type-along files</summary>

Create `chart/files/observability/grafana.yaml`.

<!-- file: chart/files/observability/grafana.yaml -->
~~~yaml
apiVersion: 1
datasources:
- name: Lab Prometheus
  uid: lab
  type: prometheus
  access: proxy
  url: http://prometheus:9090
  isDefault: true
~~~

Create `chart/files/observability/provider.yaml`.

<!-- file: chart/files/observability/provider.yaml -->
~~~yaml
apiVersion: 1
providers:
- name: switchyard
  type: file
  options:
    path: /etc/lab
~~~

Create `chart/files/observability/dashboard.json`.

<!-- file: chart/files/observability/dashboard.json -->
~~~json
{
  "title": "Switchyard delivery",
  "uid": "switchyard-delivery",
  "schemaVersion": 39,
  "panels": [
    {
      "id": 1, "title": "Failed request share by track", "type": "timeseries",
      "datasource": {"uid": "lab"},
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 0},
      "targets": [{
        "refId": "A",
        "expr": "sum by (track) (rate(delivery_attempts_total{result=\"bad\"}[20s])) / clamp_min(sum by (track) (rate(delivery_attempts_total[20s])), 1e-9)"
      }]
    }
  ]
}
~~~

Create `ops/burn-test.yaml`.

<!-- file: ops/burn-test.yaml -->
~~~yaml
rule_files: [../chart/files/observability/burn.yaml]
evaluation_interval: 2s
tests:
- interval: 2s
  input_series:
  - series: 'delivery_attempts_total{track="stable",result="good"}'
    values: '0+1x45'
  - series: 'delivery_attempts_total{track="stable",result="bad"}'
    values: '0+0x45'
  - series: 'delivery_attempts_total{track="canary",result="bad"}'
    values: '0+0x8 0+1x9 9+0x28'
  - series: 'delivery_attempts_total{track="canary",result="good"}'
    values: '0+1x8 8+0x9 8+1x28'
  alert_rule_test:
  - eval_time: 12s
    alertname: DeliveryBudgetBurn
    exp_alerts: []
  - eval_time: 30s
    alertname: DeliveryBudgetBurn
    exp_alerts:
    - exp_labels: {track: canary, severity: lab}
      exp_annotations: {summary: "Request budget burning on canary"}
  - eval_time: 85s
    alertname: DeliveryBudgetBurn
    exp_alerts: []
~~~

Create `ops/check-alerts.sh`.

<!-- file: ops/check-alerts.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
if command -v promtool >/dev/null; then
  promtool test rules ops/burn-test.yaml
else
  docker run --rm --network none --user "$(id -u):$(id -g)" --entrypoint /bin/promtool \
    -v "$PWD/ops/burn-test.yaml:/lab/ops/burn-test.yaml:ro" \
    -v "$PWD/chart/files/observability/burn.yaml:/lab/chart/files/observability/burn.yaml:ro" \
    -w /lab prom/prometheus:v3.15.0 test rules ops/burn-test.yaml
fi
~~~

</details>

## Check it

~~~bash
helm lint chart --set observability.enabled=true && if command -v promtool >/dev/null || [[ "${SWITCHYARD_DELIVERY_PROMTOOL:-0}" == 1 ]]; then bash ops/check-alerts.sh; fi
~~~

<!-- run: helm lint chart --set observability.enabled=true && if command -v promtool >/dev/null || [[ "${SWITCHYARD_DELIVERY_PROMTOOL:-0}" == 1 ]]; then bash ops/check-alerts.sh; fi -->

The Prometheus rule test passed. [Rule capture](../evidence/rules.txt)

## Run locally

During the failed release, repeatedly request `/health` and `/candidate/health` through the entry port-forward. Check `/api/v1/alerts` through a Prometheus port-forward and open the provisioned Switchyard Delivery Grafana dashboard. Restore a healthy candidate and continue the same probe stream until the alert clears.
