# Phase 5: what I learned

Fill this in as you go, with evidence: commands and their output, test names, trace IDs, dashboard screenshots, alert timelines. Keep your filled-in copy in your own repository.

## Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | What does a PID namespace change, and what does it not? | | |
| 1 | What happens, mechanically, when a container goes over its memory limit, and how do you recognise it? | | |
| 1 | Why did `sleep` take 10 seconds to stop, and the API half a second? | | |
| 1 | Why did `127.0.0.1` work on your laptop and fail in a container? | | |
| 2 | What does `condition: service_healthy` wait for that `depends_on` alone doesn't? | | |
| 2 | Why does Kafka need two advertised listeners in Compose? | | |
| 3 | Which controllers acted when you deleted a Pod, and what did each do? | | |
| 3 | Liveness vs readiness: what goes wrong if a liveness probe checks a database? | | |
| 3 | Why did a broken memory limit not take the service down? | | |
| 3 | Why did the Pods on a stopped node stay `Running` for five minutes? | | |
| 4 | Where does a Service's virtual IP live, and how does a packet reach a Pod? | | |
| 4 | Why did every gRPC call go to one Pod, and what fixed it? | | |
| 4 | What does a layer-7 balancer see that kube-proxy can't, and what does it cost? | | |
| 4 | Why does the better of *two* random backends work almost as well as the best of all? | | |
| 5 | What does a StatefulSet give `postgres-0` that a Deployment wouldn't? | | |
| 5 | Why run migrations as a Job, and why were the API Pods ready with no schema? | | |
| 6 | Why does `OrderedReady` deadlock a Raft cluster, and what does `publishNotReadyAddresses` change? | | |
| 6 | What did the disruption budget prevent, and why did the evicted member stay `Pending`? | | |
| 7 | Explain the shutdown race step by step, and why a sleep fixes it | | |
| 7 | Why did kload see no errors with or without the sleep? | | |
| 7 | What protected users from the broken upgrade, and what did `helm rollback` do? | | |
| 7 | Why can't this kind of canary take 1% of traffic? | | |
| 8 | Tags, digests and image IDs: what is each, and which do you deploy? | | |
| 8 | Why build once and pass the file between jobs? | | |
| 9 | How does a trace get from the API to the worker, through the outbox? | | |
| 9 | Why must the relay continue the stored trace rather than its own? | | |
| 9 | What did `--reuse-values` do wrong? | | |
| 10 | SLI, SLO, error budget, burn rate: define each with Runway's numbers | | |
| 10 | Why two windows per alert, and why was the page still firing after recovery? | | |
| 10 | Why must recording rules and their alerts share a group? | | |
| 10 | Name the U, the S and the E for Runway's workers | | |
| 11 | What makes the controller level-triggered, and why is that safe to restart? | | |
| 11 | Why does scale-down wait, and why to the window's *largest* recommendation? | | |
| 11 | What can the autoscaler's service account do, and what can't it? | | |
| 12 | Trigger and amplifier: name both for the step 11 cascade | | |
| 12 | Why did a full events queue dead-letter jobs that never ran, and why does waiting fix it? | | |
| 12 | Why can readiness never help when it checks a dependency every Pod shares? | | |
| 12 | What stopped a cut-off `metad` follower from disrupting the leader? | | |
| 13 | What does `terraform plan` compare, and with what? | | |
| 13 | Execution role vs task role: what does each allow? | | |
| 13 | Which step does each AWS resource replace, and what did you have to rebuild? | | |

## Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A container over its memory limit exits 137 | | |
| A PID 1 that ignores `SIGTERM` takes 10 s to stop; the API takes under 1 s | | |
| A deleted Pod is replaced before the old one has stopped | | |
| A stopped node's Pods are replaced only after about 5 minutes | | |
| kube-proxy's iptables rules for the API Service, read and explained | | |
| gRPC through a Service: one Pod; through a headless Service: all of them | | |
| Two choices vs random with one slow Pod: slow requests counted | | |
| PostgreSQL's data survives deleting its Pod | | |
| `OrderedReady` leaves `metad-0` unready and no `metad-1` | | |
| A drain refused by the disruption budget | | |
| Rolling restart with a new connection per request: failures without and with `preStop` | | |
| A broken upgrade rolled back; users unaffected | | |
| The canary's share of traffic | | |
| The same digest under two tags; a tag moved | | |
| One job's trace across API, outbox, RabbitMQ and worker; the outbox wait | | |
| Every promtool test passing; one that failed first, and why | | |
| The page firing during a database outage, with timings | | |
| A burst: the autoscaler's decisions and the queue over time | | |
| The event-consumer experiment before and after the fix | | |
| Readiness during a very slow database, before and after the fix | | |
| A partial partition: terms unchanged; a new leader when isolated | | |
| An offline Terraform plan | | |
| A job through SQS (ElasticMQ) | | |

## Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the guide, and why:
- What is still unclear:
