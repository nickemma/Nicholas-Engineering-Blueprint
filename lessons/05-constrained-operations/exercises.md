# Phase 5 exercise: beacon, synthetic monitoring

Build this **on your own**, in a new repository, after the [checkpoint](TEACHING.md#checkpoint). It is a different service from Runway, so you can't copy the guide's code. But to build it and run it well you need every Phase 5 idea:
- a small, locked-down image and a Helm chart;
- a controller that reconciles desired state from the Kubernetes API;
- traces and metrics, an SLO and tested burn-rate alerts;
- a pipeline that builds once, smoke-tests on kind and publishes by digest;
- a game day, a runbook and a postmortem;
- a Terraform plan for AWS.

There's no solution in this repository. This page shows exactly what the finished system does.

## What you're building

**Synthetic monitoring** checks a service from the outside, the way a user would, on a schedule: request a URL every few seconds, and record whether it answered, how fast, and with what. Real products (Pingdom, Checkly, Prometheus's blackbox exporter) do this. `beacon` does it on Kubernetes, and is itself operated to an SLO.

**Probes are declared as ConfigMaps.** Anyone with access to a namespace adds a probe by creating a ConfigMap labelled `beacon.dev/probe: "true"`:

~~~yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: runway-health
  namespace: runway
  labels: { beacon.dev/probe: "true" }
data:
  url: http://api.runway:8080/health
  interval: 5s
  timeout: 2s
  expectStatus: "200"
~~~

`beacon` has two parts:
- **`beacon-controller`**: watches probe ConfigMaps in every namespace, and keeps a `Probe` record per ConfigMap in PostgreSQL in step with them: created, changed or deleted within 10 seconds of the ConfigMap. Level-triggered: if it is down while ConfigMaps change, it catches up on start.
- **`beacon-runner`**: runs every probe on its interval, records each result (`probe`, `at`, `ok`, `status`, `duration_ms`, `error`) in PostgreSQL, and exports Prometheus metrics. Several runners share the work: each probe is run by exactly one runner at a time (use leases, as in Phase 4, or PostgreSQL advisory locks, as in Phase 3).

And an HTTP API on the runner:
- `GET /probes` lists probes with their last result and their availability over the last hour;
- `GET /probes/{namespace}/{name}/results?since=...` returns raw results.

## Requirements

**Packaging and deployment.**
1. One image, distroless and non-root by number, with both commands. Under 40 MB of content.
2. A Helm chart that installs the controller (1 replica), the runners (2 by default), their Services, a ServiceAccount and the narrowest RBAC that works (the controller may `get`, `list` and `watch` ConfigMaps cluster-wide, and nothing else), and a migration hook.
3. A `preStop` sleep and graceful shutdown, with the chart refusing values where they can't fit, as in step 7.
4. PostgreSQL as a plain StatefulSet manifest outside the chart.

**Observability.**
5. Metrics: `beacon_probe_success{namespace,name}` (0 or 1, the last result), `beacon_probe_duration_seconds` (a histogram), `beacon_probes` (how many probes the runners know), and the runners' own request metrics.
6. A trace per probe run: a span for the run, a child span for the HTTP request with the `traceparent` header sent to the probed service. Probing Runway's API should produce traces that join Runway's own.
7. Two SLOs, with multi-window burn-rate alerts, and promtool tests for each alert:
   - **beacon's own:** 99.5% of scheduled probe runs start within one second of their schedule;
   - **per probe:** a probe's target answers successfully 99% of the time; alert per `namespace/name`.
8. A Grafana dashboard: beacon's SLO, the probes' availability, and USE for the runners.

**Delivery.**
9. A CI workflow: tests with the race detector; `helm lint`; promtool; build once; a kind smoke test that installs PostgreSQL, the chart and one probe ConfigMap, and checks that results appear within 30 seconds; publish to GHCR by digest on `main`.
10. A Terraform configuration, plannable offline, that runs beacon on ECS with RDS. (Probes there come from a table you fill by hand instead of ConfigMaps: say in a comment what that loses.)

**Operations.**
11. A runbook for each page.
12. A game-day report with at least four experiments, each with a written hypothesis, and a postmortem for the most interesting finding.

## What finished looks like

Install it and declare a probe for Runway:

~~~bash
helm install beacon deploy/helm/beacon -n beacon --create-namespace --wait
kubectl apply -f examples/runway-health.yaml
sleep 15
kubectl -n beacon port-forward svc/beacon-runner 8090:8090 &
curl -s localhost:8090/probes
~~~

~~~json
[{"namespace":"runway","name":"runway-health","url":"http://api.runway:8080/health","interval":"5s","last":{"at":"...","ok":true,"status":200,"duration_ms":3},"availability_1h":1}]
~~~

Delete the ConfigMap, and within 10 seconds the probe is gone from `/probes` and from `beacon_probes`. Stop the controller, create two probes and delete one, start it again: the records match the ConfigMaps within 10 seconds of start.

Scale the runners to 3 while they work, and to 1, and back to 2: the results table never shows two runs of the same probe less than one interval apart, and never a gap of more than two intervals.

Break the target (scale Runway's API to 0): `beacon_probe_success{name="runway-health"}` drops to 0 within one interval, and the per-probe page fires within the time your promtool test predicts. Bring it back, and the alert resolves.

The game day must include:
- a slow target (netem on its Pod): what happens to the runners when every probe waits for its timeout?
- the database slow or gone: do probes keep running, and what is recorded afterwards?
- a runner killed mid-probe: is the probe re-run, skipped, or run twice?
- beacon's own SLO: make it miss its schedule (starve the runners of CPU with a low limit) and show the page.

## How it will be checked

Your repository's CI runs the tests, the promtool tests and the smoke test. Then a reviewer (or you, honestly) runs the scenarios above on a fresh kind cluster from your README, and reads the runbooks, the game-day report and the postmortem. The postmortem should name a trigger and an amplifier, and the fix for the amplifier should be in the code.

## Stretch goals

- A `Probe` **CustomResourceDefinition** instead of ConfigMaps, with a status field the controller fills in (`lastResult`, `availability`).
- Probes from two "regions": runners labelled with a region, each probe run from both, and an alert only when both regions fail (the target is down) rather than one (the network between).
- Scan the image for known vulnerabilities and produce an SBOM in CI, and fail the build on a critical finding.
- Apply the Terraform for an afternoon, run the game day on AWS, and `terraform destroy`; report what it cost.
