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

---

# Phase 5 exercise 2: Runway in two regions

Build this **on your own**, after beacon. Everything Runway does so far happens in one place: one cluster, one database, one region. If that place goes, so does Runway. This exercise runs Runway in two simulated regions, and rehearses losing one. It's the multi-region and disaster-recovery work that design interviews ask about ([the multi-region prompt](../../system-design/cloud-infra/README.md#1-a-multi-region-web-service)), done for real at small scale.

There's no solution in this repository. This page shows exactly what the finished system does.

## What you're building

Two "regions", each a kind cluster (or a Compose project) on your machine, with the network between them slowed down to look like a real distance. Region A is the **primary**: it takes writes. Region B holds a **standby**: a PostgreSQL replica receiving A's changes by streaming replication, and Runway's services running but not taking writes. A failover promotes B, fences A, and points traffic at B.

You decide two numbers before building anything, and measure them at the end:

- **RPO** (recovery point objective): how much acknowledged data you may lose when A is lost. Target: **under 5 seconds** of writes.
- **RTO** (recovery time objective): how long until Runway accepts jobs again. Target: **under 5 minutes**, with a person following the runbook.

## Requirements

**Two regions.**
1. Two clusters (or Compose projects), each running Runway from your Phase 5 chart, with region-specific values.
2. 40 ms of delay each way between them (`tc netem` on the link, or on the containers that cross it), so replication lag is real.

**Data.**
3. PostgreSQL streaming replication from A to B ([the PostgreSQL manual, *High Availability, Load Balancing, and Replication*](https://www.postgresql.org/docs/current/high-availability.html)). Asynchronous to start.
4. A metric and a dashboard panel for **replication lag**, in bytes and in seconds, with an alert when it exceeds your RPO.
5. Decide what happens to the queue (RabbitMQ) and to Kafka in a failover, and write it down: what's lost, what's replayed, what's duplicated. Your idempotency keys and inbox from Phases 2–3 should make duplicates harmless; show that they do.

**Failover.**
6. A **runbook** a teammate could follow at 3 a.m.:
   - how to decide to fail over;
   - how to **fence** region A, so it can't keep accepting writes if it comes back (it must not become a second primary);
   - how to promote B;
   - how to move traffic;
   - how to check the result.
7. A **failback** procedure: rebuild A as a replica of B, then switch back when you choose.
8. One command that runs the whole drill and prints the measured RPO and RTO.

**Evidence.**
9. A **drill report**:
   - the hypothesis written before the drill;
   - the timeline;
   - the measured data loss (count the jobs acknowledged by A that B never had) and recovery time;
   - what surprised you.

## What finished looks like

With a load generator submitting jobs to region A, kill region A outright (`docker stop` every node of its cluster). Then follow the runbook. The drill command prints something like this. Your numbers are your result; these are only the shape:

~~~text
drill: region A stopped at 14:02:11.320
  last job acknowledged by A:   14:02:11.290  (id 18342)
  last job present in B:        14:02:10.870  (id 18331)
  acknowledged but lost:        11 jobs, 0.42 s of writes   RPO target 5 s: met
  B promoted:                   14:03:02
  first job accepted by B:      14:03:40.115                RTO target 300 s: met (88.8 s)
  duplicates after replay:      0
~~~

Then start region A again. It must **not** accept writes: its database refuses them, or its API is fenced off, and your runbook's check shows which. Run the failback, and show jobs flowing through A again with B replicating from it.

Repeat the drill with **synchronous** replication to B, and report the trade:
- the RPO should drop to zero;
- write latency at A should rise by about one round trip (80 ms here);
- if B is unreachable, A blocks writes. Show that too.

## How it will be checked

A reviewer (or you, honestly) runs the drill from your README on a fresh machine, reads the runbook and the drill report, and checks:
- the measured RPO and RTO came from the drill, not from the targets;
- fencing was tested by bringing A back, not assumed;
- the synchronous run shows its cost.

## Stretch goals

- Run the drill on AWS: two regions with Terraform, a cross-region read replica, and DNS failover with health checks. Apply it for an afternoon, then `terraform destroy`; report what it cost.
- Make failover automatic, with a human approval step, and show the case automation must refuse: a partition where both regions are alive but can't see each other.
- Serve reads from B while A is primary, and handle "read your own writes" for a user who just submitted a job.
