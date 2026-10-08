# Phase 5 teaching: operate it

At the end of Phase 4, Runway is a real distributed system: an API, workers behind RabbitMQ, PostgreSQL with an outbox, Kafka, a Redis cache ring, and a Raft cluster of its own. It runs on your laptop, started by hand, one terminal per process. Nobody else can use it, nothing restarts it when it crashes, and when it is slow you find out because you are watching.

This phase makes it something you can **operate**: package it, run it on a cluster that keeps it running, spread traffic across copies of it, change it without dropping requests, see inside it while it runs, be told when users are hurting, break it on purpose to learn how it fails, and run the whole thing on a real cloud.

**The goal:** Runway on Kubernetes (on your machine, with kind), installed and upgraded by a Helm chart, built and tested by a CI pipeline, traced end to end with OpenTelemetry, measured by Prometheus against service level objectives, scaled by a controller you write, tested in a game day with a postmortem, and described for AWS in Terraform. Every claim in this guide was measured on a real cluster, and most of the measurements surprised me at least once. Those surprises are the lessons.

**Time:** about 9 weeks. **Before you start:** finish Phase 4. Install:
- Docker (or Docker Desktop), and give it at least 4 CPUs and 6 GB of memory;
- [kind](https://kind.sigs.k8s.io/) 0.33 or newer (it runs Kubernetes 1.37), `kubectl`, and [Helm](https://helm.sh/) 4;
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.10 or newer (step 13);
- `uv`, for kload from the Python Bridge.

An AWS account is needed only if you choose to *apply* step 13's Terraform, which costs money while it runs. Everything else is free and local.

## How this guide works

The same as before: type everything, file by file, and run the checks at the end of each step. This phase adds a new kind of check. Much of what you build is configuration (Dockerfiles, Kubernetes manifests, a Helm chart, alert rules, Terraform), and much of what you learn comes from running it on a cluster and watching what happens. The guide shows the commands and the output they produced on my machine. Your names and numbers will differ (Pod names are random, timings vary), but the shape should match. When it doesn't, that is worth understanding before you move on.

| Step | What you add |
|---|---|
| 1 | Containers are processes: namespaces, cgroups, an image, PID 1 and signals |
| 2 | The whole of Runway in Docker Compose: config in the environment, health checks |
| 3 | Kubernetes on kind: Pods, Deployments, control loops, probes, requests and limits |
| 4 | Services, DNS and load balancing: kube-proxy, headless Services, and a layer-7 balancer of your own |
| 5 | All of Runway on Kubernetes: StatefulSets, ConfigMaps and Secrets, a migration Job |
| 6 | `metad` as a StatefulSet: ordinals as IDs, the readiness deadlock, disruption budgets |
| 7 | Helm and safe rollouts: hooks, graceful shutdown measured, rollback, a canary |
| 8 | CI/CD: build once, smoke-test on a throwaway cluster, publish by digest |
| 9 | Tracing with OpenTelemetry: one trace across HTTP, the outbox, RabbitMQ and the worker |
| 10 | Prometheus and Grafana: SLOs, multi-window burn-rate alerts, tested rules, the USE method |
| 11 | A controller of your own: an autoscaler driven by the queue |
| 12 | A game day: network impairment, partitions, a runbook and a postmortem |
| 13 | Runway on AWS with Terraform, and an SQS adapter |

## Setup

Start from your finished Phase 4 code. From the repository root:

~~~bash
cd lessons/05-constrained-operations
cp -r ../04-replicated-state/practice practice
rm -rf practice/audit/target
cd practice
go test ./...
~~~

<!-- continue: ../04-replicated-state/TEACHING.md -->

Keep the Phase 4 variables (`RUNWAY_DATABASE_URL` and the rest) exported, and the Compose services running: the tests still use them.

**A note on your machine.** A Kubernetes cluster with all of Runway on it, plus Prometheus, Grafana and Jaeger, is a lot for a laptop. On mine (16 cores, 7 GB of memory given to WSL), the cluster and the Compose services together pushed the load average past 100, and timing-sensitive tests from Phases 3 and 4 started failing for no reason but starvation. If that happens to you, stop the cluster while you run the tests (`docker stop runway-control-plane runway-worker runway-worker2`, then `docker start` them again), and don't mistake a starved machine for a bug.

---

## Step 1: Containers are processes

**The problem.** To run Runway anywhere but your laptop, you need to ship it with everything it expects: the right binary for the machine, no dependency on a Go toolchain, and a predictable filesystem, user and network. And once it runs on a shared machine, it must not be able to see or starve its neighbours.

A container image solves the first half; the Linux kernel solves the second. The thing to understand before anything else in this phase: **a container is not a small virtual machine. It is an ordinary process**, started with two kernel features switched on.

**New ideas.**

- **Namespaces** give a process its own *view* of something global: process IDs (`pid`), hostname (`uts`), mounts (`mnt`), network interfaces (`net`), users (`user`), and a few more. Inside a new PID namespace, your process is PID 1 and sees no others. Nothing is copied or emulated; the kernel just answers differently.
- **cgroups** (control groups) *limit and account for* resources: memory, CPU, I/O, process count. A memory limit is a number in a file; when the group goes over it, the kernel's out-of-memory killer ends a process in that group, with `SIGKILL`. The exit status is 128 + 9 = **137**: remember the number.
- **An image** is a stack of read-only filesystem layers plus some settings (the command to run, the user, environment variables). Each Dockerfile instruction makes a layer; a layer is rebuilt only when its inputs change, so the order of instructions decides how fast rebuilds are.
- **PID 1 is special.** The kernel gives the first process in a namespace no default signal handlers: a `SIGTERM` that it doesn't handle explicitly is *ignored*, where any other process would die. `docker stop` sends `SIGTERM`, waits 10 seconds, then sends `SIGKILL`.

### Look before you build

You don't need Docker to make a namespace. `unshare` starts a program in new ones. With a user namespace (`--user --map-root-user`), an ordinary user may create the others, so this needs no `sudo`:

~~~bash
unshare --user --map-root-user --pid --fork --mount-proc --uts sh -c "hostname box; hostname; id; ps -ef"
hostname; id -u
~~~

~~~text
box
uid=0(root) gid=0(root) groups=0(root),65534(nogroup)
UID          PID    PPID  C STIME TTY          TIME CMD
root           1       0  0 06:21 ?        00:00:00 sh -c hostname box; hostname; id; ps -ef
root           5       1  0 06:21 ?        00:00:00 ps -ef
Techieemma
1000
~~~

Inside, the shell renamed "its" machine to `box`, believes it is `root`, and sees two processes, itself as PID 1. Outside, nothing changed: the hostname is still yours and you are still user 1000. "Root" inside a user namespace is root only over that namespace's own resources.

Every namespace is a file under `/proc`. Compare yours with a container's:

~~~bash
readlink /proc/self/ns/pid /proc/self/ns/uts
docker run --rm busybox:1.37 sh -c "readlink /proc/self/ns/pid; readlink /proc/self/ns/uts"
~~~

~~~text
pid:[4026532212]
uts:[4026532211]
pid:[4026532642]
uts:[4026532640]
~~~

Different numbers: different namespaces. And the limits are just files in the container's cgroup:

~~~bash
docker run --rm --memory 64m --cpus 0.5 busybox:1.37 cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max
~~~

~~~text
67108864
50000 100000
~~~

64 MiB of memory, and 50,000 microseconds of CPU in every 100,000: half a core.

**Break it: go over the limit.** Give a container 32 MiB and make it hold 200 MB:

~~~bash
docker run --name hog --memory 32m --memory-swap 32m busybox:1.37 sh -c "head -c 200m /dev/zero | tail"
echo "exit status: $?"
docker inspect hog --format "{{.State.OOMKilled}} {{.State.ExitCode}}"
docker rm hog
~~~

~~~text
Killed
exit status: 137
true 137
~~~

(`tail` has to keep the last lines, and `/dev/zero` has no newlines, so it holds everything.) When you see 137 in this phase, think "out of memory" first.

**Break it: a PID 1 that ignores SIGTERM.** `sleep` installs no signal handlers:

~~~bash
docker run -d --name napper busybox:1.37 sleep 600
time docker stop napper
docker inspect napper --format "{{.State.ExitCode}}"; docker rm napper
~~~

~~~text
napper
10.48 seconds
137
~~~

Ten seconds of waiting, then `SIGKILL`. Run it again with `docker run -d --init ...`: Docker puts a tiny init process at PID 1, which forwards the signal, and `sleep`, no longer PID 1, dies of it at once (0.35 seconds, exit 143, which is 128 + 15, `SIGTERM`). Runway's commands don't need `--init`: since Phase 1 they handle `SIGTERM` themselves and shut down gracefully.

### An image for Runway

One image holds all of Runway's commands (`api`, `worker`, `metad` and the rest); each container chooses which to run. Create `Dockerfile` at the top of your practice directory:

<!-- file: Dockerfile -->
~~~dockerfile
# syntax=docker/dockerfile:1

# Stage 1: build every command with the full Go toolchain (about 1 GB).
FROM golang:1.26 AS build
WORKDIR /src

# Download modules first, in their own layer. This layer is rebuilt only
# when go.mod or go.sum change, not on every edit to the code.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .
# CGO_ENABLED=0 makes static binaries that need no C library at run time.
# -trimpath drops local paths; -s -w drop debug symbols, for a smaller file.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/ ./cmd/...

# Stage 2: only the binaries, on an image with no shell and no package
# manager, running as an unprivileged user (UID 65532, "nonroot").
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/ /usr/local/bin/
USER nonroot:nonroot
# Listen on every interface: inside a container, 127.0.0.1 is the
# container's own loopback, which nothing outside can reach.
ENV LISTEN_ADDR=0.0.0.0:8080 GRPC_ADDR=0.0.0.0:9090
EXPOSE 8080 9090
ENTRYPOINT ["/usr/local/bin/api"]
~~~

Two **stages**. The first has the whole Go toolchain, over a gigabyte, and builds static binaries. The second starts again from **distroless**: an image with CA certificates, time zone data and a non-root user, and nothing else. No shell, no package manager, no `curl`: fewer things to patch, and nothing for an attacker who gets in to use. Only the binaries are copied across.

The `--mount=type=cache` lines keep Go's module and build caches between builds, outside the image. And `COPY go.mod go.sum` comes before `COPY . .` so that the slow `go mod download` layer is rebuilt only when your dependencies change, not on every edit.

Docker sends the whole directory to the builder (the *build context*) unless told not to. Create `.dockerignore`:

<!-- file: .dockerignore -->
~~~text
# Everything here stays out of the build context: Docker never sends it to
# the builder, so it can't bloat the image or bust the layer cache.
.git
audit
tla
deploy
*.log
Dockerfile
.dockerignore
~~~

Build it, and compare the sizes:

~~~bash
docker build -t runway:dev .
docker image ls runway:dev
docker image ls golang:1.26
~~~

~~~text
IMAGE        ID             DISK USAGE   CONTENT SIZE   EXTRA
runway:dev   78ae85143fd9        119MB         31.2MB
IMAGE         ID             DISK USAGE   CONTENT SIZE   EXTRA
golang:1.26   2dbae7442048       1.29GB          323MB
~~~

Thirty-one megabytes to download, against 323 for the builder. Change a Go file and build again: every step up to `COPY . .` says `CACHED`, and the rebuild takes seconds.

### Run it

~~~bash
docker run -d --name api -p 8080:8080 runway:dev
curl -s localhost:8080/health
curl -s localhost:8080/jobs -H "Content-Type: application/json" -d '{"description":"hello from a container","duration_ms":200}'
sleep 1; curl -s localhost:8080/jobs/1
~~~

~~~text
{"status":"ok"}
{"id":1,"state":"queued","description":"hello from a container","duration_ms":200,"created_at":"2026-10-06T13:22:52.35112362Z","updated_at":"2026-10-06T13:22:52.35112362Z"}
{"id":1,"state":"completed","description":"hello from a container","duration_ms":200,"created_at":"2026-10-06T13:22:52.35112362Z","updated_at":"2026-10-06T13:22:52.552664787Z"}
~~~

With no `DATABASE_URL` or `AMQP_URL`, the API uses its in-memory store and in-process workers, exactly as in Phase 1. Now look at it from the host, where it is just a process:

~~~bash
ps -o pid,user,rss,cmd -p "$(docker inspect -f {{.State.Pid}} api)"
time docker stop api
docker logs api | tail -2
docker rm api
~~~

~~~text
    PID USER       RSS CMD
1529878 65532    19472 /usr/local/bin/api
api
0.58 seconds
{"time":"2026-10-06T13:22:39.289457666Z","level":"INFO","msg":"shutting down","grace":"10s"}
{"time":"2026-10-06T13:22:39.290146356Z","level":"INFO","msg":"stopped"}
~~~

An ordinary process in your host's process table, owned by user 65532, using 19 MB. `docker stop` took half a second, because the API handles `SIGTERM`.

**Break it: listen on 127.0.0.1.** Delete the `ENV LISTEN_ADDR=...` line from the Dockerfile, rebuild, and run it the same way:

~~~text
$ curl -sS localhost:8080/health
curl: (56) Recv failure: Connection reset by peer
$ docker logs api
{"time":"2026-10-06T13:22:13.416244635Z","level":"INFO","msg":"listening","addr":"127.0.0.1:8080","bus":"in-memory","in_process_workers":4,"database":false,"kafka":false,"cache":false}
~~~

The API is running and listening, on `127.0.0.1:8080`. But that is the loopback interface *of the container's network namespace*. Docker's port forwarding arrives on the container's other interface, `eth0`, where nothing listens. Runway's default of `127.0.0.1` was right on your laptop (don't expose a service by accident); inside a container, the right answer is `0.0.0.0`, set in the image. Put the line back.

**Explain it:** what does a PID namespace change, and what does it not? What happens, mechanically, when a container goes over its memory limit, and how do you recognise it afterwards? Why did `sleep` take 10 seconds to stop? Why does the order of `COPY` lines matter? Why did `127.0.0.1` work on your laptop and fail in a container?

**Read.** OSTEP, chapters 4–6 (processes, the process API, limited direct execution), if they aren't fresh. Then the `namespaces(7)` and `cgroups(7)` man pages, the overview sections. Then *Kubernetes in Action* (2nd edition), chapter 2, on containers. Carry this question in: if containers share the host's kernel, what can one container do to another that two virtual machines can't do to each other?

---

## Step 2: The whole of Runway in Docker Compose

**The problem.** One container is easy. Runway is nine: an API, workers, a projector, PostgreSQL, RabbitMQ, Kafka, and three Redis servers. They must start in an order that works, find each other by name, get their settings from somewhere, and be restarted when they fail. Your `compose.yaml` already runs the data services for the tests. This step runs Runway itself there too, and on the way meets three ideas Kubernetes is built on.

**New ideas.**

- **Twelve-factor config.** The [twelve-factor app](https://12factor.net/config) keeps configuration in the environment, not in the code or the image: the same image runs on your laptop, in CI and in production, given different variables. Runway has done this since Phase 1 (`envconfig`); now it pays off.
- **Service discovery by DNS.** Compose puts the services on one network with a DNS server (at 127.0.0.11 inside each container) that answers each service's name with its containers' addresses. `postgres` means "the PostgreSQL container, wherever it is".
- **Health checks.** "The container is running" doesn't mean "it can do its job". A health check is a command run inside the container that says whether it can. Other services can wait for it: `depends_on` with `condition: service_healthy`.
- **Advertised addresses.** Some clients connect twice: first to any address you give them, then to the addresses the server *tells* them to use. Kafka does this. A broker that advertises `localhost:9092` works for programs on your machine and fails for programs in containers, where `localhost` is the container itself.

### A health check that can run in an empty image

The image has no shell and no `curl`, so a health check needs a program of its own. Create `cmd/probe/main.go`:

<!-- file: cmd/probe/main.go -->
~~~go
// Command probe checks that a URL answers 200, for container health checks.
//
// Runway's image has no shell and no curl, on purpose: less to attack and
// less to patch. So it carries this instead:
//
//	probe http://127.0.0.1:8080/ready
//
// It exits 0 when the URL answers 200 within two seconds, and 1 otherwise.
package main

import (
	"fmt"
	"net/http"
	"os"
	"time"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: probe URL")
		os.Exit(2)
	}
	if err := check(os.Args[1], 2*time.Second); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func check(url string, timeout time.Duration) error {
	client := &http.Client{Timeout: timeout}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s answered %s", url, resp.Status)
	}
	return nil
}
~~~

And `cmd/probe/main_test.go`:

<!-- file: cmd/probe/main_test.go -->
~~~go
package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestCheck(t *testing.T) {
	status := http.StatusOK
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
	}))
	defer server.Close()

	if err := check(server.URL, time.Second); err != nil {
		t.Fatalf("a 200 should pass, got %v", err)
	}
	status = http.StatusServiceUnavailable
	if err := check(server.URL, time.Second); err == nil {
		t.Fatal("a 503 should fail")
	}
	server.Close()
	if err := check(server.URL, time.Second); err == nil {
		t.Fatal("a closed server should fail")
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./cmd/probe/... && go test -race -count=1 ./cmd/probe/... -->

The Dockerfile builds every command under `cmd/`, so `probe` lands in `/usr/local/bin` with the rest.

### Runway's services in Compose

Make these changes to `compose.yaml`. The anchor at the top (`&runway-env`) names a block of settings that each Runway service copies in with `<<: *runway-env`:

Change:

<!-- edit: compose.yaml -->
~~~yaml
services:
~~~

to:

~~~yaml
# Settings every Runway service shares. "&runway-env" names this block, and
# "<<: *runway-env" copies it into a service below.
x-runway-env: &runway-env
  AMQP_URL: amqp://guest:guest@rabbitmq:5672/
  DATABASE_URL: postgres://runway:runway@postgres:5432/runway
  REDIS_URL: redis://redis:6379/0,redis://redis-2:6379/0,redis://redis-3:6379/0
  KAFKA_BROKERS: kafka:19092

services:
~~~

Change:

<!-- edit: compose.yaml -->
~~~yaml
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
~~~

to:

~~~yaml
      # "ping" passes as soon as the Erlang node runs, before the AMQP port
      # accepts connections. Check the thing clients actually need.
      test: ["CMD", "rabbitmq-diagnostics", "-q", "check_port_connectivity"]
~~~

Change:

<!-- edit: compose.yaml -->
~~~yaml
    image: apache/kafka:4.1.0 # one broker, in KRaft mode: no ZooKeeper
    ports:
~~~

to:

~~~yaml
    image: apache/kafka:4.1.0 # one broker, in KRaft mode: no ZooKeeper
    # A client asks any broker for the cluster's layout, then connects to
    # the addresses the brokers *advertise*. Programs on your machine must be
    # told localhost:9092; containers must be told kafka:19092. So there are
    # two listeners, one for each. (Setting any KAFKA_ variable replaces the
    # image's whole default configuration, hence the rest of this list.)
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: HOST://:9092,DOCKER://:19092,CONTROLLER://:9093
      KAFKA_ADVERTISED_LISTENERS: HOST://localhost:9092,DOCKER://kafka:19092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: HOST:PLAINTEXT,DOCKER:PLAINTEXT,CONTROLLER:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: DOCKER
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@localhost:9093
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
    ports:
~~~

Change:

<!-- edit: compose.yaml -->
~~~yaml

volumes:
~~~

to:

~~~yaml

  # Runway itself. These start only with --profile app, so a plain
  # "docker compose up -d" still starts just what the tests need:
  #   docker compose --profile app up -d --build
  api:
    profiles: [app]
    restart: unless-stopped # a dependency can also fail later
    build: .
    image: runway:dev
    environment:
      <<: *runway-env
    ports:
      - "8080:8080" # HTTP
      - "9090:9090" # gRPC
    healthcheck:
      test: ["CMD", "/usr/local/bin/probe", "http://127.0.0.1:8080/ready"]
      interval: 2s
      timeout: 3s
      retries: 20
    depends_on:
      postgres: { condition: service_healthy }
      rabbitmq: { condition: service_healthy }
      kafka: { condition: service_healthy }
      redis: { condition: service_healthy }
      redis-2: { condition: service_healthy }
      redis-3: { condition: service_healthy }

  worker:
    profiles: [app]
    restart: unless-stopped
    image: runway:dev
    entrypoint: ["/usr/local/bin/worker"]
    environment:
      <<: *runway-env
    deploy:
      replicas: 2
    depends_on:
      api: { condition: service_healthy } # the API declares the queues

  projector:
    profiles: [app]
    restart: unless-stopped
    image: runway:dev
    entrypoint: ["/usr/local/bin/projector"]
    environment:
      <<: *runway-env
      PROJECTOR_GROUP: projector
    depends_on:
      api: { condition: service_healthy } # the API creates the topic

volumes:
~~~


What changed, and why:
- **RabbitMQ's health check** used `ping`, which passes before the AMQP port accepts connections (see below). Check the thing clients need: `check_port_connectivity`.
- **Kafka now has two listeners**, one advertised as `localhost:9092` for the tests on your machine, one as `kafka:19092` for containers. (Setting any `KAFKA_` variable replaces the image's whole default configuration, which is why the list is long.)
- **The Runway services** have `profiles: [app]`, so `docker compose up -d` still starts only what the tests need, and `--profile app` adds Runway. The API waits for every data service to be healthy; the worker and projector wait for the API, which declares the queues and creates the topic. `restart: unless-stopped` restarts any of them that dies later. The worker runs two copies (`replicas: 2`).

### Run it

~~~bash
docker compose --profile app up -d --build --wait
docker compose --profile app ps --format "table {{.Service}}\t{{.Status}}"
~~~

~~~text
SERVICE     STATUS
api         Up 3 seconds (healthy)
kafka       Up 18 seconds (healthy)
postgres    Up 18 seconds (healthy)
projector   Up 1 second
rabbitmq    Up 18 seconds (healthy)
redis       Up 18 seconds (healthy)
redis-2     Up 18 seconds (healthy)
redis-3     Up 18 seconds (healthy)
worker      Up 1 second
worker      Up Less than a second
~~~

The order is visible in the uptimes: the data services first, then the API once they were healthy, then the workers and projector once the API was. Send it some work:

~~~bash
for i in 1 2 3 4; do curl -s localhost:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"compose job $i\",\"duration_ms\":300}" > /dev/null; done
sleep 1; curl -s localhost:8080/jobs/4
docker compose exec postgres psql -U runway -c "SELECT * FROM job_state_counts ORDER BY state"
~~~

~~~text
{"id":4,"state":"completed","description":"compose job 4","duration_ms":300,"created_at":"2026-10-06T13:35:00.978472Z","updated_at":"2026-10-06T13:35:01.710101Z"}
 consumer  |   state   | count
-----------+-----------+-------
 projector | completed |     4
 projector | queued    |     4
 projector | running   |     4
(3 rows)
~~~

The whole Phase 3 path ran in containers: the API wrote each job and its command through the outbox, a worker ran it, the events came back, and the projector read every change from Kafka into its read model.

How did the API find `postgres`? Ask Compose's DNS server, from a container on the same network (Compose names it after the directory, here `practice_default`):

~~~bash
docker run --rm --network practice_default busybox:1.37 nslookup worker
~~~

~~~text
Server:		127.0.0.11
Address:	127.0.0.11:53

Name:	worker
Address: 172.24.0.11
Name:	worker
Address: 172.24.0.9
~~~

One name, two addresses: the two worker containers. Kubernetes will do the same thing with more machinery.

**Why not `ping`?** It answers as soon as RabbitMQ's Erlang runtime is up, which is seconds before the AMQP listener opens. An API that waits for "healthy" by `ping` can connect in that gap, fail, exit, and be restarted by `restart: unless-stopped`: it recovers, but only thanks to the restart policy, and the race is there on every start. A health check should test what the clients of the service need.

When you're done, `docker compose --profile app stop api worker projector`, so that the next steps' clusters don't fight them for ports.

**Explain it:** what does `condition: service_healthy` wait for that `depends_on` alone doesn't? Why does Kafka need two advertised listeners here? Why is configuration in the environment, rather than in a file baked into the image?

**Read.** The twelve-factor app, sections III (Config), VI (Processes) and IX (Disposability). The Compose specification's pages on [`depends_on`](https://docs.docker.com/reference/compose-file/services/#depends_on) and [healthchecks](https://docs.docker.com/reference/compose-file/services/#healthcheck).

---

## Step 3: Kubernetes on kind

**The problem.** Compose runs containers on one machine, and does what you say once. It doesn't move work off a machine that dies, doesn't keep five copies running when one crashes at 3 a.m., and doesn't replace copies one by one when you ship a new version. For that you need a system that *keeps* things the way you asked: Kubernetes.

**New ideas.**

- **Desired state and control loops.** You don't tell Kubernetes what to do; you tell it what should be true ("three copies of this Pod"), and it stores that in its API server. **Controllers** are loops that each watch one kind of object, compare what is with what should be, and act to close the gap, again and again. This one idea explains almost everything Kubernetes does. You'll write a controller of your own in step 11.
- **Pods** are the unit Kubernetes runs: one or more containers sharing a network namespace (one IP) and volumes. A **Deployment** asks for some number of identical Pods. Its controller keeps a **ReplicaSet** per version of the Pod template; the ReplicaSet's controller keeps that many Pods in existence; the **scheduler** picks a node for each new Pod; and the **kubelet** on that node starts its containers. Four loops, each doing one thing.
- **Probes.** A *liveness* probe asks "is this process stuck?"; failing it restarts the container. A *readiness* probe asks "should this Pod get traffic right now?"; failing it only takes the Pod out of rotation. Confusing the two is a classic way to turn a slow dependency into a restart storm.
- **Requests and limits.** A *request* is what the scheduler reserves on a node for the Pod; a *limit* is what the kernel enforces, through the cgroups of step 1. Memory over the limit is an OOM kill; CPU over it is throttling (the process is paused until the next period).
- **kind** ("Kubernetes in Docker") runs each Kubernetes node as a Docker container on your machine. The nodes are real: a real API server, scheduler, kubelets and container runtime. Only the machines are pretend.

### A cluster

Create `deploy/kind.yaml`, a control-plane node and two workers. The image is pinned by digest, so everyone gets the same Kubernetes. The port mappings are for step 4.

<!-- file: deploy/kind.yaml -->
~~~yaml
# A local Kubernetes cluster: one control-plane node and two workers, each a
# Docker container. Create it with:
#   kind create cluster --config deploy/kind.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: runway
nodes:
  - role: control-plane
    image: kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
    # Step 4: ports on your machine that reach NodePort Services: 8080 the
    # API's, 8000 the gateway's.
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080
      - containerPort: 30081
        hostPort: 8000
  - role: worker
    image: kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
  - role: worker
    image: kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
~~~

~~~bash
kind create cluster --config deploy/kind.yaml
kubectl get nodes
kind load docker-image runway:dev --name runway
~~~

~~~text
Creating cluster "runway" ...
 ✓ Ensuring node image (kindest/node:v1.37.0) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-runway"
NAME                   STATUS     ROLES           AGE   VERSION
runway-control-plane   NotReady   control-plane   18s   v1.37.0
runway-worker          NotReady   <none>          5s    v1.37.0
runway-worker2         NotReady   <none>          5s    v1.37.0
Image: "runway:dev" with ID "sha256:5f98576aaf57..." not yet present on node "runway-worker", loading...
~~~

The nodes become `Ready` within a minute, once their network plugin starts. `kind load` copies your local image into every node, so nothing needs a registry yet.

### The API, as a Deployment

Kubernetes asks every Pod "are you ready?", even an API with no database to check. Make `/ready` always exist. In `internal/httpapi/handler.go`, change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	if cfg.ready != nil {
		mux.HandleFunc("GET /ready", h.readiness(cfg.ready))
	}
~~~

to:

~~~go
	// Every instance answers /ready, so an orchestrator can always ask. With
	// nothing to check, being up is being ready.
	ready := cfg.ready
	if ready == nil {
		ready = func(context.Context) error { return nil }
	}
	mux.HandleFunc("GET /ready", h.readiness(ready))
~~~

And add a test at the end of `internal/httpapi/handler_test.go`:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
func TestReadyWithNothingToCheck(t *testing.T) {
	if got := do(t, newTestHandler(), http.MethodGet, "/ready", ""); got.Code != http.StatusOK {
		t.Fatalf("ready = %d, want 200", got.Code)
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/httpapi/... && go test -race -count=1 ./internal/httpapi/... -->

Now the manifest. Create `deploy/k8s/api.yaml`:

<!-- file: deploy/k8s/api.yaml -->
~~~yaml
apiVersion: v1
kind: Namespace
metadata:
  name: runway
---
# A Deployment asks for a number of identical Pods. It doesn't run them
# itself: it keeps a ReplicaSet, whose controller keeps that many Pods in
# existence, and the scheduler places each Pod on a node.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: runway
spec:
  replicas: 3
  selector:
    matchLabels: { app: api } # which Pods this Deployment owns
  template:
    metadata:
      labels: { app: api }
    spec:
      securityContext:
        runAsNonRoot: true # refuse to start if the image would run as root
      containers:
        - name: api
          image: runway:dev
          imagePullPolicy: IfNotPresent # loaded into kind, not pulled
          ports:
            - { name: http, containerPort: 8080 }
            - { name: grpc, containerPort: 9090 }
          env:
            # Tell the Go runtime its memory limit, so it collects garbage
            # harder before the kernel would kill it.
            - name: GOMEMLIMIT
              valueFrom:
                resourceFieldRef: { resource: limits.memory }
          # requests: what the scheduler reserves on a node for this Pod.
          # limits: what the kernel enforces, through cgroups (step 1).
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { cpu: 500m, memory: 128Mi }
          # Liveness: is the process stuck? Failing it restarts the container.
          livenessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 10
            failureThreshold: 3
          # Readiness: should it get traffic now? Failing it only takes the
          # Pod out of rotation; nothing is restarted.
          readinessProbe:
            httpGet: { path: /ready, port: http }
            periodSeconds: 2
            failureThreshold: 2
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
~~~

Read it top to bottom; every field is commented. Three things deserve a word more:
- `runAsNonRoot`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem` and dropping every capability lock the container down to what Runway needs, which is nothing special. Phase 6 builds on this.
- `GOMEMLIMIT` comes from the container's own memory limit, through the *downward API* (`resourceFieldRef`). Go's garbage collector then works harder as memory nears the limit, instead of being OOM-killed at it.
- The probes call `/health` (liveness: the process answers) and `/ready` (readiness: it can take traffic). They will differ more as the API gains dependencies.

~~~bash
kubectl apply -f deploy/k8s/api.yaml
kubectl config set-context --current --namespace runway
kubectl get pods
~~~

~~~text
namespace/runway created
deployment.apps/api created
Context "kind-runway" modified.
NAME                   READY   STATUS                       RESTARTS   AGE
api-547d94c65b-99z78   0/1     CreateContainerConfigError   0          5m18s
api-547d94c65b-kqlmh   0/1     CreateContainerConfigError   0          5m18s
api-547d94c65b-zvfxn   0/1     CreateContainerConfigError   0          5m18s
~~~

It didn't start. When a Pod is stuck, the events say why:

~~~bash
kubectl get events --field-selector type=Warning | tail -1
~~~

~~~text
20s         Warning   Failed   pod/api-547d94c65b-zvfxn   Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root (pod: "api-547d94c65b-zvfxn_runway(453e6d60-...)", container: api)
~~~

The Dockerfile says `USER nonroot:nonroot`. Kubernetes can't know that the name `nonroot` means 65532 without reading the image's `/etc/passwd`, so it refuses to guess. Give the user by number. In `Dockerfile`, change:

Change:

<!-- edit: Dockerfile -->
~~~dockerfile
# manager, running as an unprivileged user (UID 65532, "nonroot").
~~~

to:

~~~dockerfile
# manager, running as an unprivileged user.
~~~

Change:

<!-- edit: Dockerfile -->
~~~dockerfile
USER nonroot:nonroot
~~~

to:

~~~dockerfile
# The user by number (distroless calls 65532 "nonroot"). Kubernetes can
# check a number is not 0; it can't check a name without the image's files.
USER 65532:65532
~~~


Rebuild, load, and roll out the new image. `rollout restart` changes an annotation on the Pod template, which makes the Deployment start a new ReplicaSet:

~~~bash
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
kubectl rollout restart deployment/api && kubectl rollout status deployment/api
kubectl get deployment,replicaset,pods -o wide
~~~

~~~text
deployment "api" successfully rolled out
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE     CONTAINERS   IMAGES       SELECTOR
deployment.apps/api   3/3     3            3           8m54s   api          runway:dev   app=api

NAME                             DESIRED   CURRENT   READY   AGE     CONTAINERS   IMAGES       SELECTOR
replicaset.apps/api-547d94c65b   0         0         0       8m54s   api          runway:dev   app=api,pod-template-hash=547d94c65b
replicaset.apps/api-55b48d6644   3         3         3       3s      api          runway:dev   app=api,pod-template-hash=55b48d6644

NAME                       READY   STATUS    RESTARTS   AGE   IP           NODE             NOMINATED NODE   READINESS GATES
pod/api-55b48d6644-ljbkp   1/1     Running   0          1s    10.244.3.5   runway-worker2   <none>           <none>
pod/api-55b48d6644-tz77t   1/1     Running   0          3s    10.244.3.4   runway-worker2   <none>           <none>
pod/api-55b48d6644-x9vv9   1/1     Running   0          2s    10.244.1.4   runway-worker    <none>           <none>
~~~

Two ReplicaSets: the old one scaled to 0, the new one to 3. The Deployment did that one Pod at a time, never leaving you with none. Each Pod has its own IP, on whichever node the scheduler chose.

### Run it: the loops at work

Delete a Pod, and look straight away:

~~~bash
kubectl delete pod api-55b48d6644-ljbkp --wait=false
kubectl get pods
~~~

~~~text
pod "api-55b48d6644-ljbkp" deleted from runway namespace
NAME                   READY   STATUS              RESTARTS   AGE
api-55b48d6644-ljbkp   1/1     Terminating         0          26s
api-55b48d6644-tz77t   1/1     Running             0          28s
api-55b48d6644-w6vb7   0/1     ContainerCreating   0          1s
api-55b48d6644-x9vv9   1/1     Running             0          27s
~~~

The ReplicaSet controller saw two Pods where there should be three and made a new one before the old one had even finished stopping. Nobody told it to; it noticed. Scale up the same way, by changing the desired state:

~~~bash
kubectl scale deployment/api --replicas 5 && kubectl rollout status deployment/api
kubectl get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP
~~~

~~~text
deployment "api" successfully rolled out
NAME                   NODE             IP
api-55b48d6644-bprkr   runway-worker2   10.244.3.6
api-55b48d6644-fjvlv   runway-worker2   10.244.3.7
api-55b48d6644-tz77t   runway-worker2   10.244.3.4
api-55b48d6644-w6vb7   runway-worker    10.244.1.5
api-55b48d6644-x9vv9   runway-worker    10.244.1.4
~~~

Scale back to 3 before going on.

**Break it: a limit too small.** Set the memory limit below what the process needs:

~~~bash
kubectl set resources deployment/api --requests=memory=4Mi --limits=memory=4Mi
kubectl get pods
kubectl describe pod <the new pod> | grep -A4 'Last State'
~~~

~~~text
NAME                   READY   STATUS             RESTARTS      AGE
api-85bdf55c7c-cgt8r   1/1     Running            0             64s
api-85bdf55c7c-gswj2   1/1     Running            0             62s
api-85bdf55c7c-xd92f   1/1     Running            0             65s
api-8649c97cbb-4gltq   0/1     CrashLoopBackOff   2 (10s ago)   39s
    Last State:     Terminated
      Reason:       StartError
      Message:      failed to create containerd task: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: container init was OOM-killed (memory limit too low?)
      Exit Code:    128
~~~

So small a limit that the container's init process was killed before Runway even started. The more interesting part: the three old Pods are **still running and serving**. The Deployment replaces Pods one at a time and waits for each new one to be ready, so a broken version stalls the rollout instead of taking the service down. `kubectl rollout undo deployment/api` puts the previous template back.

**Break it: lose a node.** Stop one of kind's node containers, which is as close to pulling a machine's plug as kind gets, and watch the node and the Pods every five seconds:

~~~bash
start=$(date +%s); docker stop runway-worker2
for i in $(seq 80); do
  node=$(kubectl get node runway-worker2 --no-headers | awk '{print $2}')
  pods=$(kubectl get pods -o wide --no-headers | awk '{printf "%s:%s:%s ", substr($1, length($1)-4), $3, $7}')
  echo "t=$(( $(date +%s) - start ))s node=$node pods: $pods"
  sleep 5
done
~~~

Some lines from the output:

~~~text
t=1s node=Ready pods: cgt8r:Running:runway-worker gswj2:Running:runway-worker2 xd92f:Running:runway-worker2
t=49s node=Ready pods: cgt8r:Running:runway-worker gswj2:Running:runway-worker2 xd92f:Running:runway-worker2
t=55s node=NotReady pods: cgt8r:Running:runway-worker gswj2:Running:runway-worker2 xd92f:Running:runway-worker2
t=340s node=NotReady pods: cgt8r:Running:runway-worker gswj2:Running:runway-worker2 xd92f:Running:runway-worker2
t=345s node=NotReady pods: cgt8r:Running:runway-worker gswj2:Terminating:runway-worker2 jf9c6:Running:runway-worker xd92f:Terminating:runway-worker2 zh6f4:Running:runway-worker
~~~

Read the timeline carefully, because it surprises most people:
- For **55 seconds** the node still showed `Ready`. The control plane only marks a node `NotReady` after its kubelet has been silent for the node-monitor grace period (about 40 seconds), and it can't tell a dead node from a slow one any sooner. (Phase 4, step 1: a failure detector can only suspect.)
- For **another five minutes**, the two Pods on the dead node still showed `Running`. Every Pod tolerates a `NotReady` node for 300 seconds by default, in case the node comes back.
- Only at **345 seconds** were they evicted and replaced on the other node.

Two thirds of the API's capacity was gone for almost six minutes, and Kubernetes did exactly what it was configured to do. Lowering `tolerationSeconds` makes failover faster and turns every network blip into Pods rescheduling. `docker start runway-worker2` to bring it back.

**Explain it:** which controllers acted when you deleted a Pod, and what did each one do? What is the difference between a liveness and a readiness probe, and what goes wrong if a liveness probe checks a database? Why did Kubernetes reject `USER nonroot`? Why did the broken limit not take the service down? Why did the Pods on the stopped node stay `Running` for five minutes?

**Read.** *Kubernetes in Action* (2nd edition), chapters on Pods, Deployments and ReplicaSets, and the one on how Kubernetes works internally (controllers, the scheduler, the kubelet). Then *Borg, Omega, and Kubernetes* (Burns et al., ACM Queue 2016), which explains where these ideas came from. Carry this question in: why is every controller written as a loop that reads the whole state, rather than as a handler for events?

---

## Step 4: Services, DNS and load balancing

**The problem.** Three API Pods, each with its own IP, and the IPs change every time a Pod is replaced. Clients need one stable name, and something must spread their requests across whichever Pods are ready right now. How that spreading works, and where it happens, decides how evenly load lands, what a slow Pod costs you, and how many requests fail when Pods come and go.

**New ideas.**

- **A Service** gives a set of Pods (chosen by label) one stable **virtual IP** and a DNS name. The IP belongs to no machine. On every node, **kube-proxy** writes firewall rules (iptables here) that rewrite packets sent to it into packets for one of the ready Pods, chosen at random, **once per TCP connection**.
- **EndpointSlices** list the ready Pods behind each Service. Readiness probes decide who is on the list.
- **Cluster DNS** (CoreDNS) answers `api` with the Service's IP. A **headless** Service (`clusterIP: None`) has no virtual IP: its name answers with **every ready Pod's IP**, and the client chooses.
- **Layer 4 vs layer 7.** kube-proxy balances *connections* (layer 4: TCP) and never looks inside them. A layer-7 balancer reads each HTTP *request* and chooses per request, so it can see status codes and timings, retry, and route by path. The price: one more process and one more hop.
- **Long-lived connections defeat layer 4.** gRPC sends every call over one HTTP/2 connection, so kube-proxy's per-connection choice sends *all* of a client's calls to one Pod.
- **The power of two choices.** Picking a random backend ignores load. Picking the least loaded of *all* backends needs global knowledge and makes every balancer stampede to the same one. Picking **two at random and taking the less busy** gets most of the benefit for almost no cost (Mitzenmacher, 2001).
- **Outlier ejection.** Stop sending to a backend that keeps failing, for a while.

### Which Pod answered?

To see balancing, each response must say who sent it. Add an option to `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	idempotency    idempotency.Keys
	ready          func(context.Context) error
~~~

to:

~~~go
	idempotency    idempotency.Keys
	servedBy       string
	ready          func(context.Context) error
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	return func(c *config) { c.ready = check }
}
~~~

to:

~~~go
	return func(c *config) { c.ready = check }
}

// WithServedBy adds an X-Served-By header, naming the instance that
// answered, to every response. It shows where a load balancer sent each
// request. Leave it off where instance names should stay private.
func WithServedBy(name string) Option {
	return func(c *config) { c.servedBy = name }
}
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	handler = withRecover(cfg.logger, handler)
	return handler
~~~

to:

~~~go
	handler = withRecover(cfg.logger, handler)
	if cfg.servedBy != "" {
		handler = withServedBy(cfg.servedBy, handler)
	}
	return handler
~~~


And the middleware it uses, in `internal/httpapi/middleware.go`:

Change:

<!-- edit: internal/httpapi/middleware.go -->
~~~go

// routeOf returns the pattern the router matched, such as "GET /jobs/{id}".
~~~

to:

~~~go

// withServedBy names this instance in every response, before the handler
// writes anything.
func withServedBy(name string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Served-By", name)
		next.ServeHTTP(w, r)
	})
}

// routeOf returns the pattern the router matched, such as "GET /jobs/{id}".
~~~


Test it, in `internal/httpapi/handler_test.go`:

Add this at the end of the file:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
func TestServedBy(t *testing.T) {
	got := do(t, newTestHandler(WithServedBy("api-7")), http.MethodGet, "/health", "")
	if name := got.Header().Get("X-Served-By"); name != "api-7" {
		t.Fatalf("X-Served-By = %q, want api-7", name)
	}
	got = do(t, newTestHandler(), http.MethodGet, "/health", "")
	if _, ok := got.Header()["X-Served-By"]; ok {
		t.Fatal("X-Served-By sent without WithServedBy")
	}
}
~~~


gRPC has middleware too, called *interceptors*. Create `internal/grpcapi/servedby.go`:

<!-- file: internal/grpcapi/servedby.go -->
~~~go
package grpcapi

import (
	"context"

	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

// ServedBy returns an interceptor that names this instance in the header of
// every response, as x-served-by: the gRPC twin of httpapi.WithServedBy.
// An interceptor is gRPC's middleware: it wraps every call to a method.
func ServedBy(name string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		_ = grpc.SetHeader(ctx, metadata.Pairs("x-served-by", name))
		return handler(ctx, req)
	}
}
~~~

Test it, in `internal/grpcapi/server_test.go`:

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
~~~

to:

~~~go
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
~~~

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go
func client(t *testing.T) jobsv1.JobsClient {
~~~

to:

~~~go
func client(t *testing.T, opts ...grpc.ServerOption) jobsv1.JobsClient {
~~~

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go
	server := grpc.NewServer()
~~~

to:

~~~go
	server := grpc.NewServer(opts...)
~~~

Add this at the end of the file:

<!-- append: internal/grpcapi/server_test.go -->
~~~go
func TestServedBy(t *testing.T) {
	c := client(t, grpc.UnaryInterceptor(ServedBy("api-7")))
	var header metadata.MD
	if _, err := c.CreateJob(context.Background(), &jobsv1.CreateJobRequest{Description: "x"}, grpc.Header(&header)); err != nil {
		t.Fatal(err)
	}
	if got := header.Get("x-served-by"); len(got) != 1 || got[0] != "api-7" {
		t.Fatalf("x-served-by = %v, want [api-7]", got)
	}
}
~~~


The API takes the name from `SERVED_BY`. In `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	BreakerCooldown  time.Duration
}
~~~

to:

~~~go
	BreakerCooldown  time.Duration
	ServedBy         string
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), DatabaseURL: getenv("DATABASE_URL"), RedisURL: getenv("REDIS_URL")}
~~~

to:

~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), DatabaseURL: getenv("DATABASE_URL"), RedisURL: getenv("REDIS_URL"), ServedBy: getenv("SERVED_BY")}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	}
	handler := httpapi.NewHandler(service, options...)
~~~

to:

~~~go
	}
	var grpcOptions []grpc.ServerOption
	if cfg.ServedBy != "" {
		options = append(options, httpapi.WithServedBy(cfg.ServedBy))
		grpcOptions = append(grpcOptions, grpc.UnaryInterceptor(grpcapi.ServedBy(cfg.ServedBy)))
	}
	handler := httpapi.NewHandler(service, options...)
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	grpcServer := grpc.NewServer()
~~~

to:

~~~go
	grpcServer := grpc.NewServer(grpcOptions...)
~~~


And give `jobsctl` a way to count where calls land, with a gRPC client that balances across every address a name resolves to (`round_robin`). In `cmd/jobsctl/main.go`:

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
//	jobsctl get ID
package main
~~~

to:

~~~go
//	jobsctl get ID
//	jobsctl spread N    make N calls and count which instance answered each
package main
~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
	"fmt"
	"os"
	"strconv"
~~~

to:

~~~go
	"fmt"
	"maps"
	"os"
	"slices"
	"strconv"
~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
~~~

to:

~~~go
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
~~~

to:

~~~go
	conn, err := grpc.NewClient(addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		// Spread calls over every address the name resolves to, in turn.
		// A Kubernetes Service name resolves to one virtual IP, so this
		// changes nothing there; a headless Service resolves to every Pod.
		grpc.WithDefaultServiceConfig(`{"loadBalancingConfig": [{"round_robin": {}}]}`),
	)
~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
	client := jobsv1.NewJobsClient(conn)

~~~

to:

~~~go
	client := jobsv1.NewJobsClient(conn)
	if len(args) == 2 && args[0] == "spread" {
		n, err := strconv.Atoi(args[1])
		if err != nil || n < 1 {
			return errors.New("N must be a whole number, 1 or more")
		}
		return spread(client, n)
	}

~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
		return errors.New("usage: jobsctl create DESCRIPTION [DURATION_MS] | jobsctl get ID")
~~~

to:

~~~go
		return errors.New("usage: jobsctl create DESCRIPTION [DURATION_MS] | jobsctl get ID | jobsctl spread N")
~~~

Add this at the end of the file:

<!-- append: cmd/jobsctl/main.go -->
~~~go
// spread makes n calls over one client connection and counts which instance
// answered each, from the x-served-by header.
func spread(client jobsv1.JobsClient, n int) error {
	counts := map[string]int{}
	for range n {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		var header metadata.MD
		_, err := client.CreateJob(ctx, &jobsv1.CreateJobRequest{Description: "spread"}, grpc.Header(&header))
		cancel()
		if err != nil {
			s := status.Convert(err)
			return fmt.Errorf("%s: %s", s.Code(), s.Message())
		}
		name := "(not named)"
		if v := header.Get("x-served-by"); len(v) > 0 {
			name = v[0]
		}
		counts[name]++
	}
	for _, name := range slices.Sorted(maps.Keys(counts)) {
		fmt.Printf("%-24s %d\n", name, counts[name])
	}
	return nil
}
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/httpapi/... ./internal/grpcapi/... ./cmd/api/... ./cmd/jobsctl/... -->

### A layer-7 balancer

Now a balancer of your own, in a new package. Create `internal/lb/lb.go`:

<!-- file: internal/lb/lb.go -->
~~~go
// Package lb is a layer-7 load balancer: it chooses a backend for every
// HTTP request, where a layer-4 balancer such as kube-proxy chooses once per
// TCP connection and never looks inside it.
package lb

import (
	"errors"
	"math/rand/v2"
	"slices"
	"sync"
	"time"
)

// Policy is how a backend is chosen.
type Policy int

const (
	// Random picks any healthy backend, ignoring load. kube-proxy does
	// this for each new connection.
	Random Policy = iota
	// LeastLoaded samples two healthy backends at random and picks the
	// one with fewer requests in flight: "the power of two choices".
	LeastLoaded
)

// ErrNoBackends means there is nowhere to send the request.
var ErrNoBackends = errors.New("no backends")

type backend struct {
	addr         string
	inFlight     int
	failures     int // consecutive
	ejectedUntil time.Time
}

// Options configure a Balancer.
type Options struct {
	Policy     Policy
	EjectAfter int           // consecutive failures before a backend is ejected
	EjectFor   time.Duration // how long an ejected backend sits out
	Now        func() time.Time
	Rand       *rand.Rand
}

// Balancer chooses backends. It is safe for concurrent use.
type Balancer struct {
	mu       sync.Mutex
	opts     Options
	backends []*backend
}

func New(opts Options) *Balancer {
	if opts.Now == nil {
		opts.Now = time.Now
	}
	if opts.Rand == nil {
		opts.Rand = rand.New(rand.NewPCG(rand.Uint64(), rand.Uint64()))
	}
	return &Balancer{opts: opts}
}

// SetBackends replaces the set of backends. A backend that stays keeps its
// load and failure record; one that leaves is forgotten.
func (b *Balancer) SetBackends(addrs []string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	var next []*backend
	for _, addr := range addrs {
		i := slices.IndexFunc(b.backends, func(be *backend) bool { return be.addr == addr })
		if i >= 0 {
			next = append(next, b.backends[i])
		} else {
			next = append(next, &backend{addr: addr})
		}
	}
	b.backends = next
}

// Backends returns the current addresses.
func (b *Balancer) Backends() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	addrs := make([]string, len(b.backends))
	for i, be := range b.backends {
		addrs[i] = be.addr
	}
	return addrs
}

// Pick chooses a backend for one request. The caller must call done exactly
// once, when the request finishes, saying whether it succeeded.
func (b *Balancer) Pick() (addr string, done func(ok bool), err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.opts.Now()
	var healthy []*backend
	for _, be := range b.backends {
		if !now.Before(be.ejectedUntil) {
			healthy = append(healthy, be)
		}
	}
	if len(healthy) == 0 {
		// Every backend is ejected. Trying one is better than failing
		// every request: the ejections may be wrong.
		healthy = b.backends
	}
	if len(healthy) == 0 {
		return "", nil, ErrNoBackends
	}

	chosen := healthy[b.opts.Rand.IntN(len(healthy))]
	if b.opts.Policy == LeastLoaded && len(healthy) > 1 {
		// A second, different backend at random; keep the less busy.
		other := healthy[(slices.Index(healthy, chosen)+1+b.opts.Rand.IntN(len(healthy)-1))%len(healthy)]
		if other.inFlight < chosen.inFlight {
			chosen = other
		}
	}
	chosen.inFlight++
	return chosen.addr, func(ok bool) { b.finish(chosen, ok) }, nil
}

func (b *Balancer) finish(be *backend, ok bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	be.inFlight--
	if ok {
		be.failures = 0
		return
	}
	be.failures++
	if b.opts.EjectAfter > 0 && be.failures >= b.opts.EjectAfter {
		be.ejectedUntil = b.opts.Now().Add(b.opts.EjectFor)
		be.failures = 0
	}
}
~~~

`Pick` returns a `done` callback, so the balancer counts requests in flight and sees each result. Five failures in a row eject a backend for ten seconds; if *every* backend is ejected, it tries them anyway, because the ejections might be wrong and failing every request certainly is.

Backends come from DNS. Create `internal/lb/discover.go`:

<!-- file: internal/lb/discover.go -->
~~~go
package lb

import (
	"context"
	"log/slog"
	"net"
	"slices"
	"time"
)

// Lookup resolves a name to IP addresses, like net.DefaultResolver.LookupHost.
type Lookup func(ctx context.Context, host string) ([]string, error)

// Discover keeps the balancer's backends up to date with DNS: every
// interval, it resolves host and sets the backends to every address found,
// on port. It returns when ctx is cancelled.
//
// For a headless Kubernetes Service, the name resolves to the IP of every
// ready Pod. A failed lookup keeps the last good set: stale backends are
// better than none.
func Discover(ctx context.Context, b *Balancer, lookup Lookup, host, port string, interval time.Duration, logger *slog.Logger) {
	var last []string
	for {
		ips, err := lookup(ctx, host)
		if err != nil {
			logger.Warn("lookup failed; keeping the last backends", "host", host, "error", err)
		} else {
			addrs := make([]string, len(ips))
			for i, ip := range ips {
				addrs[i] = net.JoinHostPort(ip, port)
			}
			slices.Sort(addrs)
			if !slices.Equal(addrs, last) {
				b.SetBackends(addrs)
				logger.Info("backends changed", "backends", addrs)
				last = addrs
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(interval):
		}
	}
}
~~~

And the HTTP side, `internal/lb/proxy.go`, built on the standard library's `httputil.ReverseProxy`:

<!-- file: internal/lb/proxy.go -->
~~~go
package lb

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"

	"github.com/prometheus/client_golang/prometheus"
)

type upstreamKey struct{}

// Proxy is an http.Handler that forwards each request to the backend its
// Balancer picks. A 5xx answer, or no answer at all, counts as a failure.
type Proxy struct {
	balancer *Balancer
	proxy    *httputil.ReverseProxy
	requests *prometheus.CounterVec
}

func NewProxy(balancer *Balancer, logger *slog.Logger) *Proxy {
	p := &Proxy{
		balancer: balancer,
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "gateway_upstream_requests_total",
			Help: "Requests forwarded, by backend address and status code.",
		}, []string{"upstream", "code"}),
	}
	p.proxy = &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			addr := r.In.Context().Value(upstreamKey{}).(string)
			r.SetURL(&url.URL{Scheme: "http", Host: addr})
			r.SetXForwarded()
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			logger.Warn("upstream failed", "upstream", r.Context().Value(upstreamKey{}), "error", err)
			w.WriteHeader(http.StatusBadGateway)
		},
	}
	return p
}

// Collectors returns the proxy's metrics, to register with a registry.
func (p *Proxy) Collectors() []prometheus.Collector {
	return []prometheus.Collector{p.requests}
}

func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	addr, done, err := p.balancer.Pick()
	if err != nil {
		http.Error(w, "no backends", http.StatusServiceUnavailable)
		return
	}
	recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
	p.proxy.ServeHTTP(recorder, r.WithContext(context.WithValue(r.Context(), upstreamKey{}, addr)))
	done(recorder.status < 500)
	p.requests.WithLabelValues(addr, strconv.Itoa(recorder.status)).Inc()
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(status int) {
	s.status = status
	s.ResponseWriter.WriteHeader(status)
}
~~~

Test it, `internal/lb/lb_test.go`. The last two tests run the real proxy against real HTTP servers, one fast and one slow:

<!-- file: internal/lb/lb_test.go -->
~~~go
package lb

import (
	"context"
	"io"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func newBalancer(policy Policy, addrs ...string) *Balancer {
	b := New(Options{Policy: policy, Rand: rand.New(rand.NewPCG(1, 2))})
	b.SetBackends(addrs)
	return b
}

// count picks n times, finishing each request at once, and counts the picks.
func count(t *testing.T, b *Balancer, n int) map[string]int {
	t.Helper()
	counts := map[string]int{}
	for range n {
		addr, done, err := b.Pick()
		if err != nil {
			t.Fatal(err)
		}
		counts[addr]++
		done(true)
	}
	return counts
}

func TestLeastLoadedAvoidsTheBusyBackend(t *testing.T) {
	b := newBalancer(LeastLoaded, "busy")
	for range 5 {
		b.Pick() // held open: never finished
	}
	b.SetBackends([]string{"busy", "b", "c"})
	if got := count(t, b, 1000)["busy"]; got != 0 {
		t.Fatalf("the busy backend got %d of 1000 requests, want 0", got)
	}
}

func TestRandomIgnoresLoad(t *testing.T) {
	b := newBalancer(Random, "a", "b", "c")
	busy, _, _ := b.Pick() // held open, and never finished
	if got := count(t, b, 3000)[busy]; got < 900 || got > 1100 {
		t.Fatalf("the busy backend got %d of 3000 requests, want about 1000", got)
	}
}

func TestFailingBackendIsEjectedThenReturns(t *testing.T) {
	now := time.Unix(0, 0)
	b := New(Options{Policy: Random, EjectAfter: 3, EjectFor: 10 * time.Second,
		Now: func() time.Time { return now }, Rand: rand.New(rand.NewPCG(1, 2))})
	b.SetBackends([]string{"good", "bad"})

	failures := 0
	for failures < 3 {
		addr, done, _ := b.Pick()
		ok := addr != "bad"
		if !ok {
			failures++
		}
		done(ok)
	}
	if got := count(t, b, 100)["bad"]; got != 0 {
		t.Fatalf("an ejected backend got %d requests", got)
	}
	now = now.Add(10 * time.Second)
	if got := count(t, b, 100)["bad"]; got == 0 {
		t.Fatal("the backend never came back after its ejection")
	}
}

func TestEveryBackendEjectedStillServes(t *testing.T) {
	b := New(Options{EjectAfter: 1, EjectFor: time.Hour, Rand: rand.New(rand.NewPCG(1, 2))})
	b.SetBackends([]string{"only"})
	_, done, _ := b.Pick()
	done(false)
	if addr, _, err := b.Pick(); err != nil || addr != "only" {
		t.Fatalf("Pick = %q, %v; want the ejected backend rather than nothing", addr, err)
	}
}

func TestNoBackends(t *testing.T) {
	if _, _, err := newBalancer(Random).Pick(); err != ErrNoBackends {
		t.Fatalf("err = %v, want ErrNoBackends", err)
	}
}

func TestSetBackendsKeepsState(t *testing.T) {
	b := newBalancer(LeastLoaded, "a", "b")
	busy, _, _ := b.Pick() // stays in flight
	b.SetBackends([]string{"a", "b", "c"})
	if got := count(t, b, 300)[busy]; got != 0 {
		t.Fatalf("%s lost its in-flight count: it got %d requests", busy, got)
	}
}

func TestDiscoverFollowsDNS(t *testing.T) {
	b := newBalancer(Random)
	answers := make(chan []string, 1)
	answers <- []string{"10.0.0.2", "10.0.0.1"}
	lookup := func(ctx context.Context, host string) ([]string, error) {
		select {
		case ips := <-answers:
			return ips, nil
		default:
			return nil, lookupError{} // later lookups fail: keep the last set
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go Discover(ctx, b, lookup, "api-pods", "8080", time.Millisecond, slog.New(slog.DiscardHandler))
	deadline := time.Now().Add(2 * time.Second)
	for len(b.Backends()) == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	time.Sleep(20 * time.Millisecond) // several failed lookups
	if got := strings.Join(b.Backends(), ","); got != "10.0.0.1:8080,10.0.0.2:8080" {
		t.Fatalf("backends = %s", got)
	}
}

type lookupError struct{}

func (lookupError) Error() string { return "no such host" }

// TestProxySendsLessToASlowBackend runs the proxy for real, in front of one
// fast and one slow backend, with 16 requests always in flight.
func TestProxySendsLessToASlowBackend(t *testing.T) {
	for _, tc := range []struct {
		policy   Policy
		min, max float64 // the fast backend's share of requests
	}{
		{Random, 0.35, 0.65}, // about half: random ignores speed
		{LeastLoaded, 0.70, 1},
	} {
		var fast, slow atomic.Int64
		fastServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fast.Add(1) }))
		defer fastServer.Close()
		slowServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			slow.Add(1)
			time.Sleep(50 * time.Millisecond) // slow enough to stand out even on a busy machine
		}))
		defer slowServer.Close()

		b := New(Options{Policy: tc.policy})
		b.SetBackends([]string{strings.TrimPrefix(fastServer.URL, "http://"), strings.TrimPrefix(slowServer.URL, "http://")})
		gateway := httptest.NewServer(NewProxy(b, slog.New(slog.DiscardHandler)))
		defer gateway.Close()

		var wg sync.WaitGroup
		for range 16 {
			wg.Go(func() {
				for range 25 {
					resp, err := http.Get(gateway.URL)
					if err != nil {
						t.Error(err)
						return
					}
					io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
				}
			})
		}
		wg.Wait()
		share := float64(fast.Load()) / float64(fast.Load()+slow.Load())
		t.Logf("policy %d: fast %d, slow %d (%.0f%% fast)", tc.policy, fast.Load(), slow.Load(), share*100)
		if share < tc.min || share > tc.max {
			t.Errorf("policy %d sent %.0f%% to the fast backend, want %.0f%% to %.0f%%", tc.policy, share*100, tc.min*100, tc.max*100)
		}
	}
}

func TestProxyEjectsABrokenBackend(t *testing.T) {
	var broken atomic.Int64
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer good.Close()
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		broken.Add(1)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer bad.Close()

	b := New(Options{Policy: Random, EjectAfter: 3, EjectFor: time.Minute})
	b.SetBackends([]string{strings.TrimPrefix(good.URL, "http://"), strings.TrimPrefix(bad.URL, "http://")})
	gateway := httptest.NewServer(NewProxy(b, slog.New(slog.DiscardHandler)))
	defer gateway.Close()

	failed := 0
	for range 100 {
		resp, err := http.Get(gateway.URL)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			failed++
		}
	}
	if failed != 3 || broken.Load() != 3 {
		t.Fatalf("%d requests failed and the broken backend saw %d; want 3 and 3, then ejection", failed, broken.Load())
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/lb/... && go test -race -count=1 ./internal/lb/... -->

~~~bash
go test -v -run TestProxySendsLessToASlowBackend ./internal/lb/
~~~

~~~text
    lb_test.go:175: policy 0: fast 208, slow 192 (52% fast)
    lb_test.go:175: policy 1: fast 373, slow 27 (93% fast)
--- PASS: TestProxySendsLessToASlowBackend (1.52s)
ok  	runway/internal/lb	1.532s
~~~

Random sent about half the requests to the slow backend. Two choices sent it 7%: whenever it was busy with a slow request, it lost the comparison.

Wrap it in a command. Create `cmd/gateway/main.go`:

<!-- file: cmd/gateway/main.go -->
~~~go
// Command gateway is a layer-7 load balancer in front of the API's Pods.
//
//	GATEWAY_UPSTREAM  the name to resolve, host:port; a headless Service
//	                  name resolves to every ready Pod
//	GATEWAY_POLICY    random or least-loaded (the default)
//	LISTEN_ADDR       where to take traffic (default 127.0.0.1:8000)
//	ADMIN_ADDR        /health and /metrics (default 127.0.0.1:8001)
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"runway/internal/envconfig"
	"runway/internal/lb"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer) error {
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
	host, port, err := net.SplitHostPort(getenv("GATEWAY_UPSTREAM"))
	if err != nil {
		return errors.New("GATEWAY_UPSTREAM must look like host:port, such as api-pods:8080")
	}
	policy, policyName := lb.LeastLoaded, getenv("GATEWAY_POLICY")
	switch policyName {
	case "":
		policyName = "least-loaded"
	case "least-loaded":
	case "random":
		policy = lb.Random
	default:
		return errors.New("GATEWAY_POLICY must be random or least-loaded")
	}
	listenAddr, err := envconfig.HostPort(getenv, "LISTEN_ADDR", "127.0.0.1:8000")
	if err != nil {
		return err
	}
	adminAddr, err := envconfig.HostPort(getenv, "ADMIN_ADDR", "127.0.0.1:8001")
	if err != nil {
		return err
	}

	balancer := lb.New(lb.Options{Policy: policy, EjectAfter: 5, EjectFor: 10 * time.Second})
	go lb.Discover(ctx, balancer, net.DefaultResolver.LookupHost, host, port, 5*time.Second, logger)
	proxy := lb.NewProxy(balancer, logger)

	registry := prometheus.NewRegistry()
	registry.MustRegister(proxy.Collectors()...)
	admin := http.NewServeMux()
	admin.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok\n") })
	admin.Handle("GET /metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))

	servers := []*http.Server{
		{Addr: listenAddr, Handler: proxy, ReadHeaderTimeout: 5 * time.Second},
		{Addr: adminAddr, Handler: admin, ReadHeaderTimeout: 5 * time.Second},
	}
	failed := make(chan error, len(servers))
	for _, s := range servers {
		go func() { failed <- s.ListenAndServe() }()
	}
	logger.Info("gateway listening", "addr", listenAddr, "admin", adminAddr, "upstream", host+":"+port, "policy", policyName)

	select {
	case err := <-failed:
		return err
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, s := range servers {
		_ = s.Shutdown(shutdown)
	}
	return nil
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./cmd/gateway/... -->

### On the cluster

In `deploy/k8s/api.yaml`, add `SERVED_BY`, which the downward API fills with the Pod's own name. Change:

<!-- edit: deploy/k8s/api.yaml -->
~~~yaml
          env:
~~~

to:

~~~yaml
          env:
            # Name each response after the Pod that sent it (step 4).
            - name: SERVED_BY
              valueFrom:
                fieldRef: { fieldPath: metadata.name }
~~~

And add two Services after the Deployment. Change the Deployment's last line:

<!-- edit: deploy/k8s/api.yaml -->
~~~yaml
            capabilities: { drop: [ALL] }
~~~

to:

~~~yaml
            capabilities: { drop: [ALL] }
---
# A Service gives the Pods labelled app=api one stable virtual IP and DNS
# name, "api". kube-proxy on every node load-balances connections to it
# across the ready Pods. NodePort also opens port 30080 on every node.
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: runway
spec:
  type: NodePort
  selector: { app: api }
  ports:
    - { name: http, port: 8080, targetPort: http, nodePort: 30080 }
    - { name: grpc, port: 9090, targetPort: grpc }
---
# A headless Service (clusterIP: None) has no virtual IP and no kube-proxy
# rules. Its DNS name resolves straight to the IP of every ready Pod, so a
# client can balance requests itself.
apiVersion: v1
kind: Service
metadata:
  name: api-pods
  namespace: runway
spec:
  clusterIP: None
  selector: { app: api }
  ports:
    - { name: http, port: 8080, targetPort: http }
    - { name: grpc, port: 9090, targetPort: grpc }
~~~

The `api` Service is a `NodePort`: as well as its virtual IP, it opens port 30080 on every node, which `deploy/kind.yaml` maps to port 8080 on your machine. Create `deploy/k8s/gateway.yaml`:

<!-- file: deploy/k8s/gateway.yaml -->
~~~yaml
# The layer-7 gateway from step 4, in front of the API's Pods.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
  namespace: runway
spec:
  replicas: 1
  selector:
    matchLabels: { app: gateway }
  template:
    metadata:
      labels: { app: gateway }
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: gateway
          image: runway:dev
          imagePullPolicy: IfNotPresent
          command: ["/usr/local/bin/gateway"]
          env:
            - { name: GATEWAY_UPSTREAM, value: "api-pods:8080" }
            - { name: GATEWAY_POLICY, value: least-loaded }
            - { name: LISTEN_ADDR, value: "0.0.0.0:8000" }
            - { name: ADMIN_ADDR, value: "0.0.0.0:8001" }
          ports:
            - { name: http, containerPort: 8000 }
            - { name: admin, containerPort: 8001 }
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits: { cpu: 500m, memory: 64Mi }
          readinessProbe:
            httpGet: { path: /health, port: admin }
            periodSeconds: 2
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
---
apiVersion: v1
kind: Service
metadata:
  name: gateway
  namespace: runway
spec:
  type: NodePort
  selector: { app: gateway }
  ports:
    - { name: http, port: 8000, targetPort: http, nodePort: 30081 }
    - { name: admin, port: 8001, targetPort: admin }
~~~

~~~bash
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
kubectl apply -f deploy/k8s/api.yaml -f deploy/k8s/gateway.yaml
kubectl rollout status deployment/api
kubectl get services
kubectl get endpointslices -l kubernetes.io/service-name=api
~~~

~~~text
NAME       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)                         AGE
api        NodePort    10.96.187.186   <none>        8080:30080/TCP,9090:31475/TCP   50s
api-pods   ClusterIP   None            <none>        8080/TCP,9090/TCP               49s
gateway    NodePort    10.96.229.216   <none>        8000:30081/TCP,8001:32586/TCP   49s
NAME        ADDRESSTYPE   PORTS       ENDPOINTS                          AGE
api-t77mp   IPv4          8080,9090   10.244.1.2,10.244.2.2,10.244.1.3   49s
~~~

Each `curl` is a new connection, so kube-proxy chooses again each time:

~~~bash
for i in 1 2 3 4 5 6; do curl -si localhost:8080/health | grep X-Served-By; done
~~~

~~~text
X-Served-By: api-548498c484-xpcmm
X-Served-By: api-548498c484-mm9jt
X-Served-By: api-548498c484-xpcmm
X-Served-By: api-548498c484-mm9jt
X-Served-By: api-548498c484-xpcmm
X-Served-By: api-548498c484-mm9jt
~~~

Now create a job and read it back a few times:

~~~bash
curl -s localhost:8080/jobs -H "Content-Type: application/json" -d '{"description":"where am I?","duration_ms":100}'
for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w "%{http_code} " localhost:8080/jobs/1; done; echo
~~~

~~~text
{"id":1,"state":"queued","description":"where am I?","duration_ms":100,...}
200 404 404 404 200 404
~~~

Found on one request in three. These Pods still use the in-memory store from Phase 1, so job 1 exists only in the Pod that created it. Copies of a service behind a load balancer must keep their state somewhere they all share: step 5 gives them PostgreSQL.

### Under the virtual IP

How does a packet for 10.96.187.186, an address no machine has, reach a Pod? Look at the rules kube-proxy wrote on a node:

~~~bash
docker exec runway-worker iptables-save -t nat | grep -- "-A KUBE-SVC-.*runway/api:http"
~~~

~~~text
-A KUBE-SVC-L765FLS3S2BEVO7Y ! -s 10.244.0.0/16 -d 10.96.187.186/32 -p tcp -m comment --comment "runway/api:http cluster IP" -m tcp --dport 8080 -j KUBE-MARK-MASQ
-A KUBE-SVC-L765FLS3S2BEVO7Y -m comment --comment "runway/api:http -> 10.244.1.2:8080" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-VKI3ZIB46YMWHP3G
-A KUBE-SVC-L765FLS3S2BEVO7Y -m comment --comment "runway/api:http -> 10.244.1.3:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-RTTGCX3M6Z2JDHX7
-A KUBE-SVC-L765FLS3S2BEVO7Y -m comment --comment "runway/api:http -> 10.244.2.2:8080" -j KUBE-SEP-4MTYVB4ZXWOIJI4J
~~~

The load balancer is three firewall rules. The first Pod is chosen with probability 1/3; if not, the second with 1/2 (of the remaining 2/3); otherwise the third: one third each. The chosen rule rewrites the destination address (DNAT), and the connection tracker remembers the choice for the rest of the connection. And the names, from inside a Pod:

~~~bash
kubectl run dns --rm -i --restart=Never --image=busybox:1.37 -- sh -c "cat /etc/resolv.conf; nslookup api; nslookup api-pods"
~~~

~~~text
search runway.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
Name:	api.runway.svc.cluster.local
Address: 10.96.187.186
Name:	api-pods.runway.svc.cluster.local
Address: 10.244.2.2
Name:	api-pods.runway.svc.cluster.local
Address: 10.244.1.2
Name:	api-pods.runway.svc.cluster.local
Address: 10.244.1.3
~~~

(I've left out the `NXDOMAIN` lines. `ndots:5` makes the resolver try `api.cluster.local` and friends before the search path finds `api.runway.svc.cluster.local`: several wasted lookups for every short name. That's why some teams write names in full.)

### gRPC and the one-connection problem

Run `jobsctl spread` from inside the cluster, first through the Service's virtual IP, then through the headless Service with the `dns:///` scheme, which makes gRPC resolve every address itself:

~~~bash
kubectl run spread --rm -i --restart=Never --image=runway:dev --image-pull-policy=IfNotPresent --env GRPC_ADDR=api:9090 --command -- /usr/local/bin/jobsctl spread 300
kubectl run spread --rm -i --restart=Never --image=runway:dev --image-pull-policy=IfNotPresent --env GRPC_ADDR=dns:///api-pods:9090 --command -- /usr/local/bin/jobsctl spread 300
~~~

~~~text
api-548498c484-m7dpz     300
api-548498c484-m7dpz     101
api-548498c484-mm9jt     100
api-548498c484-xpcmm     99
~~~

Through the Service, **all 300 calls went to one Pod**: one connection, one choice. Through the headless Service, `round_robin` spread them evenly. Any client that holds connections open (gRPC, HTTP/2, database pools, a keep-alive HTTP client) gets this behaviour from layer-4 balancing.

### The gateway: what a layer-7 hop costs, and what it buys

The gateway answers on port 8000. First, its cost. Send the same 200 requests a second to the API through kube-proxy (8080) and through the gateway (8000), with kload from the Python Bridge (run it from kload's own project directory, as in the Bridge):

~~~bash
uv run kload load --url http://localhost:8080 --target health --rate 200 --duration 10 --out results/proxy.csv
uv run kload load --url http://localhost:8000 --target health --rate 200 --duration 10 --out results/gateway.csv
~~~

~~~text
proxy    slower than 20 ms:  0.9%   p50   3.2 ms   p90   3.8 ms   p99  17.6 ms
gateway  slower than 20 ms:  8.3%   p50   4.1 ms   p90   8.5 ms   p99  56.5 ms
~~~

(Those two summary lines are a few lines of pandas over the two result files: the share of requests over 20 ms, and the percentiles. Write them; it's the Bridge's analysis again.) One more process to pass through: about a millisecond at the median, and a much worse tail. Now what it buys. Slow one API Pod down, by adding 200 ms of delay to its network interface (step 12 explains this command; for now, it's a slow Pod):

~~~bash
docker exec runway-worker ip route get 10.244.1.3       # which interface reaches that Pod?
docker exec runway-worker tc qdisc replace dev vetha06fd68b root netem delay 200ms
~~~

Then measure with the gateway's two policies, using `deploy/measure.sh`, which sends 400 requests 16 at a time and counts the slow ones. Create it:

<!-- file: deploy/measure.sh -->
~~~bash
#!/usr/bin/env bash
# Send 400 requests to the gateway, 16 at a time, each on a new connection,
# and summarise how long they took. Step 4 slows one API Pod by 200 ms, so
# "slower than 150 ms" counts the requests that went to it.
set -euo pipefail
url=${1:-http://localhost:8000/health}
seq 400 | xargs -P 16 -I{} curl -s -o /dev/null -w "%{time_total}\n" "$url" | sort -n |
  awk '{ t[NR] = $1 * 1000; if ($1 > 0.15) slow++ }
       END { printf "slower than 150 ms: %d of %d   p50 %.0f ms   p90 %.0f ms   p99 %.0f ms\n",
                    slow, NR, t[int(NR * .5)], t[int(NR * .9)], t[int(NR * .99)] }'
~~~

~~~bash
kubectl set env deployment/gateway GATEWAY_POLICY=random && kubectl rollout status deployment/gateway
bash deploy/measure.sh
kubectl set env deployment/gateway GATEWAY_POLICY=least-loaded && kubectl rollout status deployment/gateway
bash deploy/measure.sh
docker exec runway-worker tc qdisc del dev vetha06fd68b root
~~~

~~~text
slower than 150 ms: 131 of 400   p50 3 ms   p90 224 ms   p99 386 ms
slower than 150 ms: 15 of 400   p50 4 ms   p90 35 ms   p99 399 ms
~~~

Random sent a third of the requests to the slow Pod, and the 90th percentile was its 224 ms. Two choices sent it 15 of 400, and the 90th percentile fell to 35 ms. Layer 4 can't do this at all: kube-proxy doesn't know how long anything takes.

**Break it: Pods leave faster than DNS says.** Scale the API from 3 Pods to 1 while 2000 requests go through the gateway:

~~~bash
(seq 2000 | xargs -P 8 -I{} curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/health | sort | uniq -c) &
sleep 2; kubectl scale deployment/api --replicas 1; wait
kubectl logs deploy/gateway | grep "upstream failed" | head -2
~~~

~~~text
   1990 200
     10 502
{"time":"...","level":"WARN","msg":"upstream failed","upstream":"10.244.1.3:8080","error":"dial tcp 10.244.1.3:8080: connect: connection refused"}
{"time":"...","level":"WARN","msg":"upstream failed","upstream":"10.244.1.2:8080","error":"dial tcp 10.244.1.2:8080: connect: connection refused"}
~~~

Ten requests failed. The two Pods stopped at once, but the gateway asks DNS only every five seconds, so for a moment it still sent requests to Pods that were gone. Ejection limited the damage to ten. Any balancer that learns about backends after they change has this window; step 7 closes it for good with a pause before each Pod stops. Scale back to 3.

**Explain it:** where does the Service's virtual IP live? Why did every gRPC call go to one Pod through the Service, and why did the headless Service fix it? What does a layer-7 balancer see that kube-proxy can't, and what does it cost? Why does picking the better of *two* random backends work almost as well as knowing all of them? Why did scaling down fail ten requests?

**Read.** *Kubernetes in Action* (2nd edition), the chapters on Services and on how networking works. Then Mitzenmacher, *The Power of Two Choices in Randomized Load Balancing* (IEEE TPDS 2001), sections 1–2. Then the Envoy documentation's [load balancing overview](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/load_balancing/overview), and on outlier detection. Kurose & Ross, chapter 2.4 (DNS), if the resolver lines above were a mystery.

---

## Step 5: All of Runway on Kubernetes

**The problem.** The API Pods are stateless copies, which is exactly what a Deployment is for. PostgreSQL, RabbitMQ and Redis are not: each holds data that must survive restarts and stay attached to *that* server. They need stable names, their own disks, and an order to start in. The API also needs its settings and passwords from somewhere other than the image, and the database schema must be migrated once, not by every API Pod at once.

**New ideas.**

- **StatefulSets** run Pods that are *not* interchangeable. Each gets a stable name with an ordinal (`postgres-0`), a stable DNS name through a Service, and its own **PersistentVolumeClaim**, made from a template, which follows it when it is rescheduled and is kept even when the Pod (or the whole StatefulSet) is deleted.
- **PersistentVolumes** are disks Kubernetes manages; a **claim** asks for one, and a **StorageClass** says how to make it. kind's `standard` class makes a directory on a node: real persistence, but tied to that node. (Step 6 shows what that costs.)
- **ConfigMaps and Secrets** hold settings outside the image, and `envFrom` turns every key into an environment variable. A Secret's values are only base64-encoded, not encrypted: anyone who may read Secrets in the namespace may read them. Phase 6 does better.
- **Jobs** run Pods until one succeeds, then stop: right for work that must happen once, such as a migration. Running migrations as a separate step means the API needs no permission to change the schema, and a slow migration can't hold every API Pod back from becoming ready.

### Migrations as their own command

`pgstore.Migrate` already takes a PostgreSQL advisory lock, so two migrations at once are safe. What's missing is a way to run one without starting the API. Teach `envconfig` to read a yes/no. In `internal/envconfig/envconfig.go`:

Change:

<!-- edit: internal/envconfig/envconfig.go -->
~~~go

// Fraction reads a number between 0 and 1 inclusive.
~~~

to:

~~~go

// Bool reads true or false (also 1 and 0, as strconv.ParseBool accepts).
func Bool(getenv Getenv, name string, fallback bool) (bool, error) {
	v := getenv(name)
	if v == "" {
		return fallback, nil
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false, got %q", name, v)
	}
	return b, nil
}

// Fraction reads a number between 0 and 1 inclusive.
~~~


Test it, in `internal/envconfig/envconfig_test.go`:

Change:

<!-- edit: internal/envconfig/envconfig_test.go -->
~~~go
	vars := env(map[string]string{"D": "250ms", "N": "8", "A": "0.0.0.0:9000"})
~~~

to:

~~~go
	vars := env(map[string]string{"D": "250ms", "N": "8", "A": "0.0.0.0:9000", "B": "false"})
~~~

Change:

<!-- edit: internal/envconfig/envconfig_test.go -->
~~~go
		t.Errorf("HostPort = %v, %v", a, err)
	}
}

~~~

to:

~~~go
		t.Errorf("HostPort = %v, %v", a, err)
	}
	if b, err := Bool(vars, "B", true); err != nil || b {
		t.Errorf("Bool = %v, %v", b, err)
	}
	if b, err := Bool(vars, "MISSING", true); err != nil || !b {
		t.Errorf("Bool default = %v, %v", b, err)
	}
}

~~~

Change:

<!-- edit: internal/envconfig/envconfig_test.go -->
~~~go
	vars := env(map[string]string{"D": "soon", "N": "0", "A": "8080"})
~~~

to:

~~~go
	vars := env(map[string]string{"D": "soon", "N": "0", "A": "8080", "B": "yes"})
~~~

Change:

<!-- edit: internal/envconfig/envconfig_test.go -->
~~~go
	for name, err := range map[string]error{"D": errD, "N": errN, "A": errA} {
~~~

to:

~~~go
	_, errB := Bool(vars, "B", true)
	for name, err := range map[string]error{"D": errD, "N": errN, "A": errA, "B": errB} {
~~~


Create `cmd/migrate/main.go`:

<!-- file: cmd/migrate/main.go -->
~~~go
// Command migrate brings Runway's PostgreSQL schema up to date, then exits.
// On Kubernetes it runs as a Job, once per release, before the API starts:
// the API then needs no rights to change the schema, and a slow migration
// can't hold every API Pod back from becoming ready.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"runway/internal/envconfig"
	"runway/internal/pgstore"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer) error {
	url := getenv("DATABASE_URL")
	if url == "" {
		return errors.New("DATABASE_URL is required, for example postgres://runway:runway@localhost:5432/runway")
	}
	// Two connections: one holds the migration lock, one runs the migrations.
	pool, err := pgstore.Open(ctx, url, pgstore.PoolOptions{MaxConns: 2})
	if err != nil {
		return err
	}
	defer pool.Close()
	// Safe to run twice, or two at once: Migrate holds a PostgreSQL advisory
	// lock and skips the migrations already applied.
	if err := pgstore.Migrate(ctx, pool); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "schema up to date")
	return nil
}
~~~

Two connections, not one: goose's session locker holds the lock on one connection and runs the migrations on another, so a pool of one would wait for itself for ever. Test that racing runs both succeed, in `cmd/migrate/main_test.go`:

<!-- file: cmd/migrate/main_test.go -->
~~~go
package main

import (
	"context"
	"io"
	"strings"
	"testing"

	"runway/internal/pgstore/pgtest"
)

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestDatabaseURLIsRequired(t *testing.T) {
	err := run(context.Background(), env(nil), io.Discard)
	if err == nil || !strings.Contains(err.Error(), "DATABASE_URL is required") {
		t.Fatalf("error = %v", err)
	}
}

// Two Jobs racing (a retried Pod, an overlapping release) must both succeed
// and leave one schema, not fail on "relation already exists".
func TestConcurrentRunsBothSucceed(t *testing.T) {
	vars := env(map[string]string{"DATABASE_URL": pgtest.URL(t)})
	errs := make(chan error, 2)
	for range 2 {
		go func() { errs <- run(context.Background(), vars, io.Discard) }()
	}
	for range 2 {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	var out strings.Builder
	if err := run(context.Background(), vars, &out); err != nil || out.String() != "schema up to date\n" {
		t.Fatalf("third run: %q, %v", out.String(), err)
	}
}
~~~

And let the API skip migrating, with migrating still the default so that `go run` and Compose need no extra step. In `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	DatabaseURL      string
	KafkaBrokers     []string
~~~

to:

~~~go
	DatabaseURL      string
	MigrateOnStart   bool
	KafkaBrokers     []string
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	if cfg.GRPCAddr, err = envconfig.HostPort(getenv, "GRPC_ADDR", "127.0.0.1:9090"); err != nil {
		return config{}, err
~~~

to:

~~~go
	if cfg.GRPCAddr, err = envconfig.HostPort(getenv, "GRPC_ADDR", "127.0.0.1:9090"); err != nil {
		return config{}, err
	}
	// On by default, so "go run" and Compose need no separate step. On
	// Kubernetes, a Job migrates once, before the API starts (Phase 5).
	if cfg.MigrateOnStart, err = envconfig.Bool(getenv, "MIGRATE_ON_START", true); err != nil {
		return config{}, err
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
// connectDatabase opens the PostgreSQL pool and brings the schema up to
// date. It returns a nil pool when DATABASE_URL is unset.
~~~

to:

~~~go
// connectDatabase opens the PostgreSQL pool and, unless MIGRATE_ON_START is
// false, brings the schema up to date. It returns a nil pool when
// DATABASE_URL is unset.
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	if err := pgstore.Migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, err
~~~

to:

~~~go
	if cfg.MigrateOnStart {
		if err := pgstore.Migrate(ctx, pool); err != nil {
			pool.Close()
			return nil, err
		}
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/envconfig/... ./cmd/migrate/... ./cmd/api/... -->

### The data services

One file for the namespace and the settings. Create `deploy/k8s/config.yaml`:

<!-- file: deploy/k8s/config.yaml -->
~~~yaml
# Everything Runway runs lives in this namespace.
apiVersion: v1
kind: Namespace
metadata:
  name: runway
---
# Settings, kept out of the image (twelve-factor: config in the
# environment). A ConfigMap holds what is safe to read; a Secret holds what
# isn't. Both reach the containers as environment variables.
apiVersion: v1
kind: ConfigMap
metadata:
  name: runway
  namespace: runway
data:
  REDIS_URL: redis://redis-0.redis:6379/0,redis://redis-1.redis:6379/0,redis://redis-2.redis:6379/0
  WORKERS: "4"
---
# A Secret's values are only base64-encoded, not encrypted: anyone who can
# read Secrets in this namespace can read these. Phase 6 does better.
apiVersion: v1
kind: Secret
metadata:
  name: runway
  namespace: runway
stringData:
  POSTGRES_PASSWORD: runway
  DATABASE_URL: postgres://runway:runway@postgres:5432/runway
  AMQP_URL: amqp://runway:runway@rabbitmq:5672/
  RABBITMQ_DEFAULT_USER: runway
  RABBITMQ_DEFAULT_PASS: runway
~~~

The namespace moves here from `api.yaml`, because this is now the first file you apply. In `deploy/k8s/api.yaml`, take the namespace out, read the settings, and turn off migrating:

Change:

<!-- edit: deploy/k8s/api.yaml -->
~~~yaml
apiVersion: v1
kind: Namespace
metadata:
  name: runway
---
# A Deployment asks for a number of identical Pods. It doesn't run them
~~~

to:

~~~yaml
# A Deployment asks for a number of identical Pods. It doesn't run them
~~~

Change:

<!-- edit: deploy/k8s/api.yaml -->
~~~yaml
            - { name: grpc, containerPort: 9090 }
          env:
~~~

to:

~~~yaml
            - { name: grpc, containerPort: 9090 }
          # Every key in the ConfigMap and the Secret becomes a variable.
          envFrom:
            - configMapRef: { name: runway }
            - secretRef: { name: runway }
          env:
~~~

Change:

<!-- edit: deploy/k8s/api.yaml -->
~~~yaml
                fieldRef: { fieldPath: metadata.name }
            # Tell the Go runtime
~~~

to:

~~~yaml
                fieldRef: { fieldPath: metadata.name }
            # The migrate Job has already brought the schema up to date.
            - { name: MIGRATE_ON_START, value: "false" }
            # Tell the Go runtime
~~~

PostgreSQL, as a StatefulSet of one. Create `deploy/k8s/postgres.yaml`:

<!-- file: deploy/k8s/postgres.yaml -->
~~~yaml
# A StatefulSet is for Pods that are not interchangeable: each gets a stable
# name (postgres-0) and its own disk (a PersistentVolumeClaim), which follow
# it when it is rescheduled.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: runway
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels: { app: postgres }
  template:
    metadata:
      labels: { app: postgres }
    spec:
      containers:
        - name: postgres
          image: postgres:17
          args: ["-c", "max_prepared_transactions=10"] # Phase 4's two-phase commit
          env:
            - { name: POSTGRES_USER, value: runway }
            - { name: POSTGRES_DB, value: runway }
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: { name: runway, key: POSTGRES_PASSWORD }
            # The volume's root holds lost+found on some disks; keep the
            # data one directory down.
            - { name: PGDATA, value: /var/lib/postgresql/data/pgdata }
          ports:
            - { name: postgres, containerPort: 5432 }
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "runway"] }
            periodSeconds: 2
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { memory: 512Mi }
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
  # One claim per Pod, created from this template, and kept when the Pod
  # (or even the StatefulSet) is deleted.
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests: { storage: 1Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: runway
spec:
  selector: { app: postgres }
  ports:
    - { name: postgres, port: 5432, targetPort: postgres }
~~~

RabbitMQ the same way, `deploy/k8s/rabbitmq.yaml`. The `fsGroup` line matters: the volume is created owned by root, and RabbitMQ runs as user 999.

<!-- file: deploy/k8s/rabbitmq.yaml -->
~~~yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: rabbitmq
  namespace: runway
spec:
  serviceName: rabbitmq
  replicas: 1
  selector:
    matchLabels: { app: rabbitmq }
  template:
    metadata:
      labels: { app: rabbitmq }
    spec:
      # Run as the image's rabbitmq user (999), as in compose.yaml. fsGroup
      # makes the volume belong to group 999, so the broker can write its
      # .erlang.cookie there; without it, the first start fails with eacces.
      securityContext:
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      containers:
        - name: rabbitmq
          image: rabbitmq:4-management
          envFrom:
            - secretRef: { name: runway } # RABBITMQ_DEFAULT_USER and _PASS
          ports:
            - { name: amqp, containerPort: 5672 }
            - { name: management, containerPort: 15672 }
          readinessProbe:
            exec: { command: ["rabbitmq-diagnostics", "-q", "check_port_connectivity"] }
            periodSeconds: 5
            timeoutSeconds: 10
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { memory: 512Mi }
          volumeMounts:
            - { name: data, mountPath: /var/lib/rabbitmq }
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests: { storage: 1Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq
  namespace: runway
spec:
  selector: { app: rabbitmq }
  ports:
    - { name: amqp, port: 5672, targetPort: amqp }
    - { name: management, port: 15672, targetPort: management }
~~~

Three Redis servers for the cache ring of Phase 4, `deploy/k8s/redis.yaml`. The ring must reach *particular* servers, so a headless Service gives each its own name, `redis-0.redis` to `redis-2.redis`. Order doesn't matter for caches, so they start in parallel:

<!-- file: deploy/k8s/redis.yaml -->
~~~yaml
# Three Redis servers for Phase 4's cache ring. The headless Service gives
# each one its own DNS name, redis-0.redis to redis-2.redis, which the ring
# needs: it must reach a particular server, not any of them.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
  namespace: runway
spec:
  serviceName: redis
  replicas: 3
  podManagementPolicy: Parallel # start all three at once; order doesn't matter
  selector:
    matchLabels: { app: redis }
  template:
    metadata:
      labels: { app: redis }
    spec:
      containers:
        - name: redis
          image: redis:8
          ports:
            - { name: redis, containerPort: 6379 }
          readinessProbe:
            exec: { command: ["redis-cli", "ping"] }
            periodSeconds: 2
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits: { memory: 128Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: runway
spec:
  clusterIP: None
  selector: { app: redis }
  ports:
    - { name: redis, port: 6379, targetPort: redis }
~~~

The workers, `deploy/k8s/worker.yaml`:

<!-- file: deploy/k8s/worker.yaml -->
~~~yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  namespace: runway
spec:
  replicas: 2
  selector:
    matchLabels: { app: worker }
  template:
    metadata:
      labels: { app: worker }
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: worker
          image: runway:dev
          imagePullPolicy: IfNotPresent
          command: ["/usr/local/bin/worker"]
          envFrom:
            - configMapRef: { name: runway }
            - secretRef: { name: runway }
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits: { cpu: 500m, memory: 128Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
~~~

And the migration Job, `deploy/k8s/migrate.yaml`:

<!-- file: deploy/k8s/migrate.yaml -->
~~~yaml
# A Job runs Pods until one succeeds, then stops: right for work that must
# happen once, such as a schema migration. Apply it after PostgreSQL is ready
# and before the API, and wait for it to complete in between.
#
# A Job's Pod template can't be changed once created. To run it again (a new
# release, a new migration), delete it first:
#   kubectl -n runway delete job migrate
apiVersion: batch/v1
kind: Job
metadata:
  name: migrate
  namespace: runway
spec:
  backoffLimit: 6 # retry failed Pods, with growing delays, up to six times
  activeDeadlineSeconds: 300 # and give up after five minutes in all
  template:
    spec:
      restartPolicy: Never # a failed run makes a new Pod, so its logs survive
      securityContext:
        runAsNonRoot: true
      containers:
        - name: migrate
          image: runway:dev
          imagePullPolicy: IfNotPresent
          command: ["/usr/local/bin/migrate"]
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef: { name: runway, key: DATABASE_URL }
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits: { cpu: 500m, memory: 64Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
~~~

Kafka and the projector stay in Compose for now. The API runs happily without `KAFKA_BROKERS`: job changes still go through the outbox, just not to a stream. Adding them is one of this phase's exercises.

### Run it, in order

Order matters. The data services first, then the migration, then the services that need the schema:

~~~bash
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
kubectl delete -f deploy/k8s/api.yaml -f deploy/k8s/gateway.yaml   # start clean
kubectl apply -f deploy/k8s/config.yaml -f deploy/k8s/postgres.yaml -f deploy/k8s/rabbitmq.yaml -f deploy/k8s/redis.yaml
kubectl -n runway wait --for=condition=Ready pod -l 'app in (postgres,rabbitmq,redis)' --timeout=180s
~~~

~~~text
configmap/runway created
secret/runway created
statefulset.apps/postgres created
service/postgres created
statefulset.apps/rabbitmq created
service/rabbitmq created
statefulset.apps/redis created
service/redis created
pod/postgres-0 condition met
pod/rabbitmq-0 condition met
pod/redis-0 condition met
pod/redis-1 condition met
pod/redis-2 condition met
~~~

(If `wait` says "no matching resources found", the StatefulSets haven't made their Pods yet; run it again. `kubectl rollout status statefulset/postgres` waits for one StatefulSet without that problem.)

~~~bash
kubectl apply -f deploy/k8s/migrate.yaml
kubectl -n runway wait --for=condition=Complete job/migrate --timeout=120s
kubectl -n runway logs job/migrate
kubectl apply -f deploy/k8s/api.yaml -f deploy/k8s/worker.yaml -f deploy/k8s/gateway.yaml
kubectl -n runway rollout status deployment/api
kubectl -n runway get pods -o wide
~~~

~~~text
job.batch/migrate created
job.batch/migrate condition met
schema up to date
deployment "api" successfully rolled out
NAME                       READY   STATUS      RESTARTS   AGE     IP            NODE
api-8c8844c45-f8x2g        1/1     Running     0          4s      10.244.2.13   runway-worker2
api-8c8844c45-jwc5c        1/1     Running     0          4s      10.244.1.13   runway-worker
api-8c8844c45-nlpv2        1/1     Running     0          4s      10.244.2.12   runway-worker2
gateway-7db9b69c79-9mqdd   1/1     Running     0          3s      10.244.1.15   runway-worker
migrate-zjk68              0/1     Completed   0          42s     10.244.1.12   runway-worker
postgres-0                 1/1     Running     0          3m44s   10.244.1.11   runway-worker
rabbitmq-0                 1/1     Running     0          3m44s   10.244.2.11   runway-worker2
redis-0                    1/1     Running     0          3m44s   10.244.1.9    runway-worker
redis-1                    1/1     Running     0          3m44s   10.244.1.10   runway-worker
redis-2                    1/1     Running     0          3m44s   10.244.2.10   runway-worker2
worker-6b569bd5bc-4chcr    1/1     Running     0          3s      10.244.2.14   runway-worker2
worker-6b569bd5bc-z4j9h    1/1     Running     0          3s      10.244.1.14   runway-worker
~~~

Zero restarts: nothing started before what it needed. Send a job through:

~~~bash
curl -s -X POST localhost:8080/jobs -H 'Content-Type: application/json' -d '{"description":"hello, kubernetes","duration_ms":200}'
sleep 2; curl -s localhost:8080/jobs/1
~~~

~~~text
{"id":1,"state":"queued","description":"hello, kubernetes","duration_ms":200,...}
{"id":1,"state":"completed","description":"hello, kubernetes","duration_ms":200,...}
~~~

Every API Pod now finds job 1: they share PostgreSQL. The whole Phase 3 path ran across Pods on two nodes.

**Break it: lose the database's Pod.** Delete `postgres-0`. The StatefulSet makes a new one, with the same name, and the same claim:

~~~bash
kubectl -n runway delete pod postgres-0
kubectl -n runway wait --for=condition=Ready pod/postgres-0 --timeout=120s
kubectl -n runway get pvc
curl -s localhost:8080/jobs/1
~~~

~~~text
pod "postgres-0" deleted from runway namespace
pod/postgres-0 condition met
NAME              STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
data-postgres-0   Bound    pvc-2b16b444-cbef-4953-942d-eb0f54bf8062   1Gi        RWO            standard
data-rabbitmq-0   Bound    pvc-401699c9-0903-4bff-93e2-7d8adf37364f   1Gi        RWO            standard
{"id":1,"state":"completed","description":"hello, kubernetes","duration_ms":200,...}
~~~

The Pod was new; the data wasn't. That is the whole difference between a StatefulSet and a Deployment.

**Break it: start the API before the schema.** Throw the schema away and restart the API, as if the Job had never run:

~~~bash
kubectl -n runway exec postgres-0 -- psql -U runway -qc 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
kubectl -n runway rollout restart deployment/api
sleep 20; kubectl -n runway get pods -l app=api
kubectl -n runway logs deployment/api --tail=2
curl -s -X POST localhost:8080/jobs -H 'Content-Type: application/json' -d '{"description":"no schema","duration_ms":10}'
~~~

~~~text
NAME                   READY   STATUS    RESTARTS   AGE
api-5f598f7949-p5j27   1/1     Running   0          19s
api-5f598f7949-s7dm2   1/1     Running   0          18s
api-5f598f7949-wwzkg   1/1     Running   0          20s
{"level":"WARN","msg":"outbox relay failed; will retry","error":"ERROR: relation \"outbox\" does not exist (SQLSTATE 42P01)"}
{"level":"WARN","msg":"outbox relay failed; will retry","error":"ERROR: relation \"outbox\" does not exist (SQLSTATE 42P01)"}
{"error":"internal error"}
~~~

Every Pod is `Ready`, so every Pod gets traffic, and every write fails. Readiness pings PostgreSQL, and PostgreSQL answers; nothing checks that the tables exist. That's why the order is enforced from outside, by applying the Job first and waiting for it, and in step 7 by Helm. (Whether readiness should check the database at all is a question step 12 answers, with data.) Put the schema back by running the Job again; a Job's Pod template can't be changed, so delete it first:

~~~bash
kubectl -n runway delete job migrate
kubectl apply -f deploy/k8s/migrate.yaml
kubectl -n runway wait --for=condition=Complete job/migrate --timeout=120s
~~~

**Explain it:** what does a StatefulSet give `postgres-0` that a Deployment wouldn't? Where does the data live, and what happens to it when the Pod is deleted? Why run migrations as a Job instead of in the API? Why were the API Pods ready with no schema, and what would have to change for readiness to notice?

**Read.** *Kubernetes in Action* (2nd edition), the chapters on volumes and persistent storage, ConfigMaps and Secrets, StatefulSets, and Jobs. Carry this question in: PostgreSQL here is one Pod with one disk. What would it take to run it highly available on Kubernetes, and why do many teams use a managed database instead (step 13)?

---

## Step 6: `metad` as a StatefulSet

**The problem.** `metad`, the Raft cluster from Phase 4, is the hardest kind of thing to run on Kubernetes. Each member has an identity (its Raft ID) that must never change, a disk holding its log, and the addresses of all the others. Members must reach each other *before* any of them is useful. And taking two of three down at once, for a node upgrade say, loses the majority and stops the cluster.

**New ideas.**

- **Ordinals as identity.** A StatefulSet names its Pods `metad-0`, `metad-1`, `metad-2`, and labels each with its index. Raft IDs start at 1, so member ID = ordinal + 1. Same name, same claim, same ID, every time the Pod comes back.
- **Pod management policy.** By default (`OrderedReady`), a StatefulSet starts `metad-1` only once `metad-0` is ready, and so on. Good for a primary and its replicas; fatal for a cluster that is only ready once a majority is up.
- **Publishing addresses before readiness.** A headless Service normally lists only *ready* Pods in DNS. Raft members must find each other to elect a leader, which is what makes them ready: `publishNotReadyAddresses: true` breaks the circle.
- **PodDisruptionBudgets** limit *voluntary* disruptions (draining a node, an upgrade), not crashes: Kubernetes evicts a Pod only if the budget allows it.
- **Anti-affinity** asks the scheduler to spread Pods, so one node failing takes down one member, not a majority.

### Readiness for a Raft member

A member is ready once it knows a leader: then it can serve a request, or point the client to the member that can. In `internal/metad/metad.go`:

Change:

<!-- edit: internal/metad/metad.go -->
~~~go
	mux.HandleFunc("GET /status", s.status)
	mux.HandleFunc("GET /kv/{key}", s.op("get"))
~~~

to:

~~~go
	mux.HandleFunc("GET /status", s.status)
	mux.HandleFunc("GET /ready", s.ready)
	mux.HandleFunc("GET /kv/{key}", s.op("get"))
~~~

Change:

<!-- edit: internal/metad/metad.go -->
~~~go
	writeJSON(w, http.StatusOK, statusResponse{ID: st.ID, Role: st.Role.String(), Term: st.Term, Leader: st.Leader, Commit: st.Commit})
}
~~~

to:

~~~go
	writeJSON(w, http.StatusOK, statusResponse{ID: st.ID, Role: st.Role.String(), Term: st.Term, Leader: st.Leader, Commit: st.Commit})
}

// ready answers 200 once this member knows a leader: then it can serve a
// request, or point the client to the member that can. Until then, 503. A
// lone member can never be ready: it takes a majority to elect a leader.
func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	if st := s.node.Status(); st.Leader == raft.None {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "no leader known"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}
~~~


Test it: a member alone must never be ready. In `internal/metad/metad_test.go`:

Change:

<!-- edit: internal/metad/metad_test.go -->
~~~go

func TestAFollowerPointsToTheLeader(t *testing.T) {
~~~

to:

~~~go

// A member alone can't elect a leader, so it never becomes ready. This is
// why the StatefulSet must start every member at once (Phase 5, step 6).
func TestAMemberIsReadyOnlyOnceALeaderIsKnown(t *testing.T) {
	c := newCluster(t, 3)
	c.stop(2)
	c.stop(3)
	time.Sleep(300 * time.Millisecond) // several election timeouts
	if code, _ := do(t, http.MethodGet, c.urls[1]+"/ready", ""); code != http.StatusServiceUnavailable {
		t.Fatalf("alone: /ready = %d, want 503", code)
	}

	c.restart(2)
	deadline := time.Now().Add(5 * time.Second)
	for {
		code, _ := do(t, http.MethodGet, c.urls[1]+"/ready", "")
		if code == http.StatusOK {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("with a majority: /ready = %d, want 200", code)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestAFollowerPointsToTheLeader(t *testing.T) {
~~~


### Identity and address from the environment

Two changes to `cmd/metad/main.go`. The ID may come from the ordinal, and the listening address may differ from the address peers use: a Pod's DNS name may not resolve to its own IP yet when it starts, so it listens on every interface:

Change:

<!-- edit: cmd/metad/main.go -->
~~~go
//	METAD_ID     this member's ID, 1 to n
//	METAD_PEERS  every member, as 1=http://127.0.0.1:7001,2=...,3=...
//	METAD_DATA   the directory for this member's log and snapshot
//
// It listens on the address in its own METAD_PEERS entry.
~~~

to:

~~~go
//	METAD_ID       this member's ID, 1 to n
//	METAD_ORDINAL  or its position counting from 0, as a Kubernetes
//	               StatefulSet numbers its Pods; the ID is one more
//	METAD_PEERS    every member, as 1=http://127.0.0.1:7001,2=...,3=...
//	METAD_DATA     the directory for this member's log and snapshot
//	METAD_LISTEN   the address to listen on; by default, the one in its
//	               own METAD_PEERS entry
~~~

Change:

<!-- edit: cmd/metad/main.go -->
~~~go

func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer) error {
~~~

to:

~~~go

// memberID reads METAD_ID or, failing that, METAD_ORDINAL. A StatefulSet's
// Pods are metad-0, metad-1, ...; Raft IDs start at 1, because 0 means none.
func memberID(getenv envconfig.Getenv) (int, error) {
	if v := getenv("METAD_ID"); v != "" {
		id, err := strconv.Atoi(v)
		if err != nil || id < 1 {
			return 0, fmt.Errorf("METAD_ID must be a member ID, 1 or more, got %q", v)
		}
		return id, nil
	}
	if v := getenv("METAD_ORDINAL"); v != "" {
		ordinal, err := strconv.Atoi(v)
		if err != nil || ordinal < 0 {
			return 0, fmt.Errorf("METAD_ORDINAL must be 0 or more, got %q", v)
		}
		return ordinal + 1, nil
	}
	return 0, errors.New("set METAD_ID (1 or more) or METAD_ORDINAL (0 or more)")
}

func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer) error {
~~~

Change:

<!-- edit: cmd/metad/main.go -->
~~~go
	id, err := strconv.Atoi(getenv("METAD_ID"))
	if err != nil || id < 1 {
		return errors.New("METAD_ID must be a member ID, 1 or more")
~~~

to:

~~~go
	id, err := memberID(getenv)
	if err != nil {
		return err
~~~

Change:

<!-- edit: cmd/metad/main.go -->
~~~go

	u, _ := url.Parse(self)
	listener, err := net.Listen("tcp", u.Host)
~~~

to:

~~~go

	// On Kubernetes, the peer URL names the Pod's DNS record, which may not
	// resolve to its own IP yet; listen on every interface instead.
	u, _ := url.Parse(self)
	addr, err := envconfig.HostPort(getenv, "METAD_LISTEN", u.Host)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", addr)
~~~

Change:

<!-- edit: cmd/metad/main.go -->
~~~go
	logger.Info("metad started", "id", id, "addr", u.Host, "members", len(ids), "data", dir)
~~~

to:

~~~go
	logger.Info("metad started", "id", id, "addr", addr, "members", len(ids), "data", dir)
~~~


Test the ID rules. Create `cmd/metad/main_test.go`:

<!-- file: cmd/metad/main_test.go -->
~~~go
package main

import (
	"strings"
	"testing"
)

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestMemberID(t *testing.T) {
	for _, tc := range []struct {
		vars map[string]string
		want int
	}{
		{map[string]string{"METAD_ID": "2"}, 2},
		{map[string]string{"METAD_ORDINAL": "0"}, 1}, // metad-0 is member 1
		{map[string]string{"METAD_ORDINAL": "2"}, 3},
		{map[string]string{"METAD_ID": "1", "METAD_ORDINAL": "2"}, 1}, // METAD_ID wins
	} {
		if got, err := memberID(env(tc.vars)); err != nil || got != tc.want {
			t.Errorf("%v: got %d, %v; want %d", tc.vars, got, err, tc.want)
		}
	}
}

func TestBadMemberIDsNameTheVariable(t *testing.T) {
	for _, tc := range []struct {
		vars map[string]string
		want string
	}{
		{nil, "set METAD_ID"},
		{map[string]string{"METAD_ID": "0"}, "METAD_ID must"},
		{map[string]string{"METAD_ORDINAL": "-1"}, "METAD_ORDINAL must"},
		{map[string]string{"METAD_ORDINAL": "metad-0"}, "METAD_ORDINAL must"},
	} {
		if _, err := memberID(env(tc.vars)); err == nil || !strings.HasPrefix(err.Error(), tc.want) {
			t.Errorf("%v: error = %v, want one starting %q", tc.vars, err, tc.want)
		}
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/metad/... ./cmd/metad/... -->

### The manifest

Create `deploy/k8s/metad.yaml`:

<!-- file: deploy/k8s/metad.yaml -->
~~~yaml
# metad, Phase 4's Raft cluster, as three Pods: metad-0, metad-1, metad-2.
# A StatefulSet keeps each name, and the disk that goes with it, across
# restarts, so a member comes back as the same Raft member with its log.
#
# The headless Service gives each member a DNS name, metad-0.metad and so
# on. publishNotReadyAddresses publishes those names before the Pods are
# ready: members must reach each other to elect a leader, and they are not
# ready until there is one.
apiVersion: v1
kind: Service
metadata:
  name: metad
  namespace: runway
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector: { app: metad }
  ports:
    - { name: http, port: 7001, targetPort: http }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: metad
  namespace: runway
spec:
  serviceName: metad
  replicas: 3
  # The default, OrderedReady, starts metad-1 only once metad-0 is ready.
  # metad-0 alone can't elect a leader, so it would never be ready, and
  # metad-1 would never start. Parallel starts all three at once.
  podManagementPolicy: Parallel
  selector:
    matchLabels: { app: metad }
  template:
    metadata:
      labels: { app: metad }
    spec:
      securityContext:
        runAsNonRoot: true
        fsGroup: 65532 # the volume belongs to the image's user, so it can write
      # Prefer a different node for each member, so one node failing takes
      # down one member, not a majority. "Preferred": kind has only two
      # worker nodes for three members.
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels: { app: metad }
      containers:
        - name: metad
          image: runway:dev
          imagePullPolicy: IfNotPresent
          command: ["/usr/local/bin/metad"]
          env:
            # The StatefulSet labels each Pod with its ordinal: 0, 1 or 2.
            - name: METAD_ORDINAL
              valueFrom:
                fieldRef: { fieldPath: "metadata.labels['apps.kubernetes.io/pod-index']" }
            - name: METAD_PEERS
              value: 1=http://metad-0.metad:7001,2=http://metad-1.metad:7001,3=http://metad-2.metad:7001
            - { name: METAD_LISTEN, value: "0.0.0.0:7001" }
            - { name: METAD_DATA, value: /data }
          ports:
            - { name: http, containerPort: 7001 }
          # Ready once a leader is known. Not a liveness check: a member cut
          # off from the others is working as designed, and restarting it
          # wouldn't help.
          readinessProbe:
            httpGet: { path: /ready, port: http }
            periodSeconds: 2
          livenessProbe:
            httpGet: { path: /status, port: http }
            periodSeconds: 10
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits: { cpu: 500m, memory: 128Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: data, mountPath: /data }
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests: { storage: 256Mi }
---
# A PodDisruptionBudget limits voluntary disruptions, such as draining a
# node for an upgrade: Kubernetes evicts a metad Pod only if two others stay
# available, so a majority (and the leader election) survives.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: metad
  namespace: runway
spec:
  minAvailable: 2
  selector:
    matchLabels: { app: metad }
~~~

The ordinal comes from the label the StatefulSet puts on each Pod, `apps.kubernetes.io/pod-index`, through the downward API. Every member gets the same `METAD_PEERS`, built from the stable names.

### Run it

~~~bash
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
kubectl apply -f deploy/k8s/metad.yaml
kubectl -n runway wait --for=condition=Ready pod -l app=metad --timeout=120s
kubectl -n runway get pods -l app=metad -o wide
~~~

~~~text
service/metad created
statefulset.apps/metad created
poddisruptionbudget.policy/metad created
pod/metad-0 condition met
pod/metad-1 condition met
pod/metad-2 condition met
NAME      READY   STATUS    RESTARTS   AGE   IP            NODE             NOMINATED NODE   READINESS GATES
metad-0   1/1     Running   0          8s    10.244.1.21   runway-worker    <none>           <none>
metad-1   1/1     Running   0          8s    10.244.2.18   runway-worker2   <none>           <none>
metad-2   1/1     Running   0          8s    10.244.2.19   runway-worker2   <none>           <none>
~~~

Ready in eight seconds. (Three members, two worker nodes: anti-affinity is only *preferred*, so two share a node. On a real cluster, use three nodes and make it required.) Each member's view is at `/status`. The image has no `curl`, so ask through the API server, which can proxy to a Pod:

~~~bash
for i in 0 1 2; do echo "metad-$i: $(kubectl get --raw /api/v1/namespaces/runway/pods/metad-$i:7001/proxy/status)"; done
~~~

~~~text
metad-0: {"id":1,"role":"leader","term":1,"leader":1,"commit":1}
metad-1: {"id":2,"role":"follower","term":1,"leader":1,"commit":1}
metad-2: {"id":3,"role":"follower","term":1,"leader":1,"commit":1}
~~~

**Break it: kill the leader.** Write a key through the leader, delete its Pod, and look again:

~~~bash
kubectl -n runway port-forward pod/metad-0 7001:7001 &
curl -s -X PUT localhost:7001/kv/greeting -d 'hello from the old leader'; kill %1
kubectl -n runway delete pod metad-0
sleep 3; for i in 0 1 2; do echo "metad-$i: $(kubectl get --raw /api/v1/namespaces/runway/pods/metad-$i:7001/proxy/status)"; done
~~~

~~~text
pod "metad-0" deleted from runway namespace
metad-0: {"id":1,"role":"follower","term":2,"leader":3,"commit":3}
metad-1: {"id":2,"role":"follower","term":2,"leader":3,"commit":3}
metad-2: {"id":3,"role":"leader","term":2,"leader":3,"commit":3}
~~~

`metad-2` won the election in term 2. And `metad-0` is already back: a new Pod with the old name, so the old ID (1), and the old claim, so its log; it rejoined as a follower and caught up. Read the key through the new leader (port-forward to `metad-2`, `curl localhost:7001/kv/greeting`) and it's there.

**Break it: the default pod management policy.** Delete the StatefulSet and its claims, and apply it without `podManagementPolicy: Parallel`:

~~~bash
kubectl -n runway delete statefulset metad
kubectl -n runway delete pvc -l app=metad
grep -v 'podManagementPolicy: Parallel' deploy/k8s/metad.yaml | kubectl apply -f -
sleep 45; kubectl -n runway get pods -l app=metad
kubectl -n runway get events --field-selector involvedObject.name=metad-0 | tail -1
~~~

~~~text
NAME      READY   STATUS    RESTARTS   AGE
metad-0   0/1     Running   0          45s
1s          Warning   Unhealthy           pod/metad-0                     Readiness probe failed: HTTP probe failed with statuscode: 503
~~~

A deadlock, and Kubernetes is doing exactly what it was told: `metad-1` waits for `metad-0` to be ready; `metad-0` can't be ready until there is a leader; there can't be a leader without a second member. `metad-0`'s log says it is a `pre-candidate`, asking for votes from members that don't exist. Delete the StatefulSet again and apply the real file.

**Break it: drain a node.** `kubectl drain` evicts every Pod from a node, as you would before upgrading it. Drain the node that holds two members:

~~~bash
kubectl drain runway-worker2 --pod-selector=app=metad --timeout=20s
kubectl -n runway get pods -l app=metad -o wide
kubectl uncordon runway-worker2
~~~

~~~text
node/runway-worker2 cordoned
evicting pod runway/metad-2
evicting pod runway/metad-1
error when evicting pods/"metad-1" -n "runway" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/metad-2 evicted
...
error: unable to drain node "runway-worker2" due to error: error when evicting pods/"metad-1" -n "runway": global timeout reached: 20s, continuing command...
NAME      READY   STATUS    RESTARTS   AGE   IP            NODE             NOMINATED NODE   READINESS GATES
metad-0   1/1     Running   0          27s   10.244.1.26   runway-worker    <none>           <none>
metad-1   1/1     Running   0          27s   10.244.2.24   runway-worker2   <none>           <none>
metad-2   0/1     Pending   0          19s   <none>        <none>           <none>           <none>
~~~

The budget did its job: one member evicted, the second refused, so two of three kept running and the cluster kept its majority. But look at `metad-2`: `Pending`. Its claim is a directory on `runway-worker2`, which is cordoned, so it can't be scheduled anywhere else. **Local storage pins a Pod to a node.** A drain that should have moved it just stopped it, until `uncordon` let it back. Network storage (the cloud's block volumes, step 13) can follow a Pod to another node; a node's own disk can't.

**Explain it:** how does each member learn its Raft ID, and why does it survive the Pod being replaced? Why does `OrderedReady` deadlock a Raft cluster? What does `publishNotReadyAddresses` change? What did the disruption budget prevent, and why did the evicted member stay `Pending`?

**Read.** *Kubernetes in Action* (2nd edition), the StatefulSets chapter again, now that you've run one. Then the Kubernetes documentation on [disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/). Then look at how etcd's own operator (or the etcd Helm chart) bootstraps a cluster: what does it do about membership that this step's fixed `METAD_PEERS` doesn't?

---

## Step 7: Helm and safe rollouts

**The problem.** Runway is now nine YAML files applied in the right order, with values (image tags, replica counts, settings) copied between them by hand. To ship a new version you edit the files, apply them in order, and hope. If it goes wrong there is no "undo", and nothing records what was running yesterday. And even a *correct* rollout drops requests, as you'll measure.

**New ideas.**

- **Helm** turns manifests into **templates** filled from **values**. A set of templates is a **chart**; each install of a chart is a **release**, with numbered **revisions**: `helm upgrade` makes a new one, `helm rollback` goes back to an old one, `helm history` lists them.
- **Hooks** are resources Helm runs at a point in a release's life, such as `pre-upgrade`: the migration Job's natural home. Helm waits for the hook and stops the release if it fails.
- **Graceful shutdown in a cluster** has a race. When a Pod is deleted, two things start *at the same time*: the kubelet sends `SIGTERM` to the container, and the endpoints controller removes the Pod from the Service, after which every node's kube-proxy must update its rules. If the process stops accepting connections before the last node has updated, new connections are sent to a Pod that refuses them. The standard fix is boring and effective: **sleep before stopping** (a `preStop` hook), so the rules change first.
- **Rolling updates** replace Pods a few at a time. `maxUnavailable: 0, maxSurge: 1` never runs fewer than the desired count: a new Pod must be ready before an old one goes.
- **Canaries** run a few Pods of a new version beside the old ones, behind the same Service, so a small share of real traffic tests it before everyone gets it.

### The chart

A chart is a directory. It holds Runway's own services, not the databases: you upgrade an application many times a week, and a database almost never, and `helm uninstall` should never be able to delete your data. The data services stay as the plain manifests of step 5 (and on AWS, in step 13, become managed services).

Create `deploy/helm/runway/Chart.yaml`:

<!-- file: deploy/helm/runway/Chart.yaml -->
~~~yaml
apiVersion: v2
name: runway
description: Runway's services (API, workers, gateway, metad) on Kubernetes
type: application
# The chart's own version: bump it when the templates change.
version: 0.1.0
# The version of the software it deploys, shown by "helm list".
appVersion: "dev"
~~~

The values, with every default the templates read, `deploy/helm/runway/values.yaml`:

<!-- file: deploy/helm/runway/values.yaml -->
~~~yaml
# Defaults for every setting the templates read. Override one with
#   helm upgrade runway deploy/helm/runway --set api.replicas=5
# or a whole file of them with -f my-values.yaml.

image:
  repository: runway
  tag: dev
  pullPolicy: IfNotPresent # loaded into kind, not pulled

# A Secret this chart doesn't create, holding DATABASE_URL and AMQP_URL
# (deploy/k8s/config.yaml). Keeping passwords out of values keeps them out
# of "helm get values" and out of version control.
existingSecret: runway

# Settings shared by the API and the workers. Each becomes an environment
# variable; changing one restarts the Pods that read them.
config:
  REDIS_URL: redis://redis-0.redis:6379/0,redis://redis-1.redis:6379/0,redis://redis-2.redis:6379/0
  WORKERS: "4"

api:
  replicas: 3
  # Shutting down without dropping requests (step 7). On SIGTERM the Pod
  # is removed from the Service's endpoints, but every node's kube-proxy
  # learns that a moment later. Sleep first, so traffic stops arriving
  # before the server stops accepting it.
  preStopSeconds: 5
  # Then up to this long to finish the requests and jobs in flight.
  shutdownGraceSeconds: 20
  # Kubernetes kills the container this long after it starts stopping.
  # It must be longer than the two above together; the chart checks.
  terminationGracePeriodSeconds: 30
  # Extra environment variables, for experiments.
  env: {}
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits: { cpu: 500m, memory: 128Mi }

# A canary: a few Pods of a new version alongside the stable ones, behind
# the same Service. Traffic splits by Pod count: 1 canary beside 3 stable
# Pods gets about a quarter of it.
canary:
  enabled: false
  tag: ""
  replicas: 1

worker:
  replicas: 2
  resources:
    requests: { cpu: 50m, memory: 32Mi }
    limits: { cpu: 500m, memory: 128Mi }

gateway:
  enabled: true
  policy: least-loaded

metad:
  enabled: true
  # Phase 4's Raft has a fixed membership. Changing this on a running
  # cluster is not a safe membership change: reinstall instead.
  replicas: 3
  storage: 256Mi
~~~

Shared pieces go in `templates/_helpers.tpl`. A `define` names a block; `include` fills it in; `nindent` indents it to fit. This is the densest file in the chart, so read it slowly:

<!-- file: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
{{/*
Labels on every object, so "kubectl get all -l app.kubernetes.io/part-of=runway"
finds them, and so it is clear Helm manages them.
*/}}
{{- define "runway.labels" -}}
app.kubernetes.io/part-of: runway
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* The image, at a tag: runway.image (list $ "v2"). */}}
{{- define "runway.image" -}}
{{- $root := index . 0 -}}
{{ $root.Values.image.repository }}:{{ index . 1 }}
{{- end }}

{{/*
The settings the API and the workers share. The checksum annotation changes
whenever the ConfigMap does, which changes the Pod template, which makes the
Deployment roll out new Pods: environment variables are read only at start.
*/}}
{{- define "runway.configChecksum" -}}
checksum/config: {{ include (print .Template.BasePath "/config.yaml") . | sha256sum }}
{{- end }}

{{- define "runway.envFrom" -}}
envFrom:
  - configMapRef: { name: {{ .Release.Name }}-config }
  - secretRef: { name: {{ .Values.existingSecret }} }
{{- end }}

{{/* Locked down as in step 1: no root, no new privileges, no writes. */}}
{{- define "runway.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: [ALL] }
{{- end }}

{{/*
An API Pod template. The stable Deployment and the canary differ only in
their track label and image tag: runway.apiPod (dict "root" $ "track"
"stable" "tag" "dev").
*/}}
{{- define "runway.apiPod" -}}
{{- $root := .root -}}
{{- $api := $root.Values.api -}}
metadata:
  labels: { app: api, track: {{ .track }} }
  annotations:
    {{- include "runway.configChecksum" $root | nindent 4 }}
spec:
  securityContext:
    runAsNonRoot: true
  terminationGracePeriodSeconds: {{ $api.terminationGracePeriodSeconds }}
  containers:
    - name: api
      image: {{ include "runway.image" (list $root .tag) }}
      imagePullPolicy: {{ $root.Values.image.pullPolicy }}
      ports:
        - { name: http, containerPort: 8080 }
        - { name: grpc, containerPort: 9090 }
      {{- include "runway.envFrom" $root | nindent 6 }}
      env:
        - name: SERVED_BY
          valueFrom:
            fieldRef: { fieldPath: metadata.name }
        - { name: MIGRATE_ON_START, value: "false" } # the migrate hook did it
        - { name: SHUTDOWN_GRACE, value: "{{ $api.shutdownGraceSeconds }}s" }
        - name: GOMEMLIMIT
          valueFrom:
            resourceFieldRef: { resource: limits.memory }
        {{- range $name, $value := $api.env }}
        - { name: {{ $name }}, value: {{ $value | quote }} }
        {{- end }}
      {{- if $api.preStopSeconds }}
      lifecycle:
        preStop:
          sleep: { seconds: {{ $api.preStopSeconds }} }
      {{- end }}
      resources:
        {{- toYaml $api.resources | nindent 8 }}
      livenessProbe:
        httpGet: { path: /health, port: http }
        periodSeconds: 10
        failureThreshold: 3
      readinessProbe:
        httpGet: { path: /ready, port: http }
        periodSeconds: 2
        failureThreshold: 2
      {{- include "runway.containerSecurity" $root | nindent 6 }}
{{- end }}
~~~

The checksum annotation solves a real problem: environment variables are read only when a container starts, so changing a ConfigMap does nothing to running Pods. Putting the ConfigMap's hash into the Pod template means a changed ConfigMap is a changed template, and the Deployment rolls out new Pods.

The settings, `templates/config.yaml`:

<!-- file: deploy/helm/runway/templates/config.yaml -->
~~~yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
  labels:
    {{- include "runway.labels" . | nindent 4 }}
data:
  {{- range $name, $value := .Values.config }}
  {{ $name }}: {{ $value | quote }}
  {{- end }}
~~~

The migration as a hook, `templates/migrate.yaml`:

<!-- file: deploy/helm/runway/templates/migrate.yaml -->
~~~yaml
# The migration, as a hook: Helm runs this Job before installing or
# upgrading anything else, waits for it to succeed, and stops the release
# if it fails. So new code never runs against an old schema.
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Release.Name }}-migrate
  labels:
    {{- include "runway.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    # Delete the last run's Job before making a new one (a Job's template
    # can't change), and delete this one once it succeeds. A failed one
    # stays, with its logs, until the next attempt.
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 300
  template:
    metadata:
      labels: { app: migrate }
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
      containers:
        - name: migrate
          image: {{ include "runway.image" (list $ .Values.image.tag) }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: ["/usr/local/bin/migrate"]
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef: { name: {{ .Values.existingSecret }}, key: DATABASE_URL }
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits: { cpu: 500m, memory: 64Mi }
          {{- include "runway.containerSecurity" . | nindent 10 }}
~~~

The API, its optional canary, and its Services, `templates/api.yaml`. The `fail` at the top refuses to render a chart whose shutdown can't work: if the grace period is shorter than the sleep plus the drain, Kubernetes kills the API mid-shutdown.

<!-- file: deploy/helm/runway/templates/api.yaml -->
~~~yaml
{{- $api := .Values.api -}}
{{- if le (int $api.terminationGracePeriodSeconds) (add $api.preStopSeconds $api.shutdownGraceSeconds | int) }}
{{- fail "api.terminationGracePeriodSeconds must be longer than api.preStopSeconds + api.shutdownGraceSeconds, or Kubernetes kills the API mid-shutdown" }}
{{- end }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  replicas: {{ $api.replicas }}
  # Replace Pods one at a time, and never go below the replica count: a new
  # Pod must be ready before an old one stops. A new version that never
  # becomes ready leaves the old ones serving.
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  # A new Pod counts as available only after staying ready this long.
  minReadySeconds: 3
  selector:
    matchLabels: { app: api, track: stable }
  template:
    {{- include "runway.apiPod" (dict "root" . "track" "stable" "tag" .Values.image.tag) | nindent 4 }}
{{- if .Values.canary.enabled }}
{{- if not .Values.canary.tag }}
{{- fail "canary.enabled needs canary.tag, the image tag to try" }}
{{- end }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-canary
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.canary.replicas }}
  selector:
    matchLabels: { app: api, track: canary }
  template:
    {{- include "runway.apiPod" (dict "root" . "track" "canary" "tag" .Values.canary.tag) | nindent 4 }}
{{- end }}
---
# Selects app=api, not the track: stable and canary Pods share the traffic.
apiVersion: v1
kind: Service
metadata:
  name: api
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  type: NodePort
  selector: { app: api }
  ports:
    - { name: http, port: 8080, targetPort: http, nodePort: 30080 }
    - { name: grpc, port: 9090, targetPort: grpc }
---
# Headless: every ready API Pod's IP, for the gateway to balance itself.
apiVersion: v1
kind: Service
metadata:
  name: api-pods
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  clusterIP: None
  selector: { app: api }
  ports:
    - { name: http, port: 8080, targetPort: http }
    - { name: grpc, port: 9090, targetPort: grpc }
~~~

The workers, `templates/worker.yaml`:

<!-- file: deploy/helm/runway/templates/worker.yaml -->
~~~yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.worker.replicas }}
  selector:
    matchLabels: { app: worker }
  template:
    metadata:
      labels: { app: worker }
      annotations:
        {{- include "runway.configChecksum" . | nindent 8 }}
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: worker
          image: {{ include "runway.image" (list $ .Values.image.tag) }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: ["/usr/local/bin/worker"]
          {{- include "runway.envFrom" . | nindent 10 }}
          resources:
            {{- toYaml .Values.worker.resources | nindent 12 }}
          {{- include "runway.containerSecurity" . | nindent 10 }}
~~~

The gateway, `templates/gateway.yaml`:

<!-- file: deploy/helm/runway/templates/gateway.yaml -->
~~~yaml
{{- if .Values.gateway.enabled }}
# The layer-7 gateway from step 4, in front of the API's Pods.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  replicas: 1
  selector:
    matchLabels: { app: gateway }
  template:
    metadata:
      labels: { app: gateway }
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: gateway
          image: {{ include "runway.image" (list $ .Values.image.tag) }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: ["/usr/local/bin/gateway"]
          env:
            - { name: GATEWAY_UPSTREAM, value: "api-pods:8080" }
            - { name: GATEWAY_POLICY, value: {{ .Values.gateway.policy }} }
            - { name: LISTEN_ADDR, value: "0.0.0.0:8000" }
            - { name: ADMIN_ADDR, value: "0.0.0.0:8001" }
          ports:
            - { name: http, containerPort: 8000 }
            - { name: admin, containerPort: 8001 }
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits: { cpu: 500m, memory: 64Mi }
          readinessProbe:
            httpGet: { path: /health, port: admin }
            periodSeconds: 2
          {{- include "runway.containerSecurity" . | nindent 10 }}
---
apiVersion: v1
kind: Service
metadata:
  name: gateway
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  type: NodePort
  selector: { app: gateway }
  ports:
    - { name: http, port: 8000, targetPort: http, nodePort: 30081 }
    - { name: admin, port: 8001, targetPort: admin }
{{- end }}
~~~

And `metad`, `templates/metad.yaml`. The peer list and the disruption budget's majority are computed from the replica count:

<!-- file: deploy/helm/runway/templates/metad.yaml -->
~~~yaml
{{- if .Values.metad.enabled }}
{{- $n := int .Values.metad.replicas }}
{{- $peers := list }}
{{- range $i := until $n }}
{{- $peers = append $peers (printf "%d=http://metad-%d.metad:7001" (add1 $i) $i) }}
{{- end }}
# metad from step 6. Every value here is explained in deploy/k8s/metad.yaml.
apiVersion: v1
kind: Service
metadata:
  name: metad
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector: { app: metad }
  ports:
    - { name: http, port: 7001, targetPort: http }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: metad
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  serviceName: metad
  replicas: {{ $n }}
  podManagementPolicy: Parallel
  selector:
    matchLabels: { app: metad }
  template:
    metadata:
      labels: { app: metad }
    spec:
      securityContext:
        runAsNonRoot: true
        fsGroup: 65532
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels: { app: metad }
      containers:
        - name: metad
          image: {{ include "runway.image" (list $ .Values.image.tag) }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: ["/usr/local/bin/metad"]
          env:
            - name: METAD_ORDINAL
              valueFrom:
                fieldRef: { fieldPath: "metadata.labels['apps.kubernetes.io/pod-index']" }
            - { name: METAD_PEERS, value: {{ join "," $peers | quote }} }
            - { name: METAD_LISTEN, value: "0.0.0.0:7001" }
            - { name: METAD_DATA, value: /data }
          ports:
            - { name: http, containerPort: 7001 }
          readinessProbe:
            httpGet: { path: /ready, port: http }
            periodSeconds: 2
          livenessProbe:
            httpGet: { path: /status, port: http }
            periodSeconds: 10
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits: { cpu: 500m, memory: 128Mi }
          {{- include "runway.containerSecurity" . | nindent 10 }}
          volumeMounts:
            - { name: data, mountPath: /data }
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests: { storage: {{ .Values.metad.storage }} }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: metad
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  minAvailable: {{ add1 (div $n 2) }} # a majority
  selector:
    matchLabels: { app: metad }
{{- end }}
~~~

Finally, `templates/NOTES.txt`, which Helm prints after every install and upgrade:

<!-- file: deploy/helm/runway/templates/NOTES.txt -->
~~~text
Runway {{ .Values.image.tag }} is release {{ .Release.Name }}, revision {{ .Release.Revision }}, in namespace {{ .Release.Namespace }}.

  API:      curl localhost:8080/health
  Gateway:  curl localhost:8000/health
{{- if .Values.canary.enabled }}
  Canary:   {{ .Values.canary.replicas }} Pod(s) of {{ .Values.canary.tag }} beside {{ .Values.api.replicas }} of {{ .Values.image.tag }}
{{- end }}

  History:  helm -n {{ .Release.Namespace }} history {{ .Release.Name }}
  Undo:     helm -n {{ .Release.Namespace }} rollback {{ .Release.Name }}
~~~

Check it renders, and that the guards work:

<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway > /dev/null && ! helm template runway deploy/helm/runway --set api.preStopSeconds=15 > /dev/null 2>&1 && ! helm template runway deploy/helm/runway --set canary.enabled=true > /dev/null 2>&1 -->

~~~bash
helm lint deploy/helm/runway
helm template runway deploy/helm/runway --set api.preStopSeconds=15 > /dev/null
helm template runway deploy/helm/runway --set canary.enabled=true > /dev/null
~~~

~~~text
==> Linting deploy/helm/runway
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
Error: execution error at (runway/templates/api.yaml:3:4): api.terminationGracePeriodSeconds must be longer than api.preStopSeconds + api.shutdownGraceSeconds, or Kubernetes kills the API mid-shutdown
Error: execution error at (runway/templates/api.yaml:27:4): canary.enabled needs canary.tag, the image tag to try
~~~

`helm template` renders without installing; read its output once, top to bottom, to see what the templates make.

### Hand over to Helm

Helm won't take over objects it didn't create. Delete the step 5 and 6 application objects (the claims stay, so `metad` keeps its data), then install:

~~~bash
kubectl delete -f deploy/k8s/api.yaml -f deploy/k8s/worker.yaml -f deploy/k8s/gateway.yaml -f deploy/k8s/metad.yaml -f deploy/k8s/migrate.yaml
helm install runway deploy/helm/runway -n runway --wait --timeout 3m
kubectl -n runway get pods
~~~

~~~text
NAME: runway
LAST DEPLOYED: Tue Oct  6 10:27:03 2026
NAMESPACE: runway
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
NOTES:
Runway dev is release runway, revision 1, in namespace runway.

  API:      curl localhost:8080/health
  Gateway:  curl localhost:8000/health

  History:  helm -n runway history runway
  Undo:     helm -n runway rollback runway
NAME                       READY   STATUS    RESTARTS   AGE
api-5d4c75bbcc-2s6r8       1/1     Running   0          6s
api-5d4c75bbcc-gtc5b       1/1     Running   0          6s
api-5d4c75bbcc-xtjbt       1/1     Running   0          6s
gateway-7db9b69c79-8rwzl   1/1     Running   0          6s
metad-0                    1/1     Running   0          6s
metad-1                    1/1     Running   0          6s
metad-2                    1/1     Running   0          6s
postgres-0                 1/1     Running   0          16m
rabbitmq-0                 1/1     Running   0          20m
redis-0                    1/1     Running   0          20m
...
~~~

The migration hook ran first (its Job deleted itself on success), then everything else.

### Measure a rollout

Does a rolling restart drop requests? The answer depends on how you ask. First with kload, 50 job submissions a second, restarting the API in the middle, once with no `preStop` sleep and once with five seconds:

~~~bash
helm upgrade runway deploy/helm/runway -n runway --reuse-values --set api.preStopSeconds=0 --wait
uv run kload load --url http://localhost:8080 --target create --rate 50 --duration 45 --out results/no-prestop.csv &
sleep 5; kubectl -n runway rollout restart deployment/api; kubectl -n runway rollout status deployment/api; wait
uv run kload analyze results/no-prestop.csv
~~~

~~~text
{
  "requests": 2250,
  "error_rate": 0.0,
  "throughput_rps": 50.0,
  "p50_ms": 9.49,
  "p95_ms": 13.07,
  "p99_ms": 17.32,
  "max_ms": 250.99
}
~~~

No errors, without the sleep. And no errors with it. So the sleep is pointless? No: **the measurement was blind**. kload's client keeps a small pool of connections open and reuses them. A pooled connection is already established to a Pod; when that Pod shuts down gracefully, Go's server finishes the requests in flight and closes idle connections, and the client opens new ones, which by then go to Pods that are in the rules. The race needs a *new* connection to arrive at a Pod in the moment between "stopped listening" and "removed from the rules". 50 requests a second over a few pooled connections rarely gets one there.

So test what's exposed: a new connection per request, from many clients at once. Create `deploy/rollout-check.sh`:

<!-- file: deploy/rollout-check.sh -->
~~~bash
#!/usr/bin/env bash
# Restart the API's Pods under load and count the requests that failed.
# Each request is a new connection (curl), the client most exposed to a Pod
# that has stopped listening: a pooled client such as kload's reuses
# connections and rarely sees it. HTTP code 000 means no response at all
# (connection refused or reset).
set -euo pipefail
url=${1:-http://localhost:8080/health}
codes=$(mktemp)
(
  end=$((SECONDS + 40))
  while [ $SECONDS -lt $end ]; do
    seq 64 | xargs -P 32 -I{} curl -s -o /dev/null -m 3 -w '%{http_code}\n' "$url"
  done
) >"$codes" &
load=$!
sleep 3
kubectl -n runway rollout restart deployment/api >/dev/null
kubectl -n runway rollout status deployment/api --timeout=120s >/dev/null
wait $load
echo "responses by HTTP code:"
sort "$codes" | uniq -c
rm -f "$codes"
~~~

~~~bash
chmod +x deploy/rollout-check.sh
helm upgrade runway deploy/helm/runway -n runway --reuse-values --set api.preStopSeconds=0 --wait
deploy/rollout-check.sh
helm upgrade runway deploy/helm/runway -n runway --reuse-values --set api.preStopSeconds=5 --wait
deploy/rollout-check.sh
~~~

~~~text
responses by HTTP code:
     17 000
  19503 200
responses by HTTP code:
  18944 200
~~~

Without the sleep, 17 requests got no response at all (`000`: connection refused or reset) out of about 19,500. With it, none. A second run of each gave 8 and 0. Small numbers, on a cluster where kube-proxy updates in milliseconds; on a big cluster under load, rules take longer to update everywhere, and the window grows. The fix costs five seconds per Pod per rollout.

### When an upgrade goes wrong

Ship a broken setting, and tell Helm to wait for the result:

~~~bash
helm upgrade runway deploy/helm/runway -n runway --reuse-values --set api.env.REQUEST_TIMEOUT=soon --wait --timeout 45s
kubectl -n runway get pods -l app=api
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/health
~~~

~~~text
Error: UPGRADE FAILED: resource Deployment/runway/api not ready. status: InProgress, message: Updated: 1/3
context deadline exceeded
NAME                   READY   STATUS             RESTARTS     AGE
api-559465fcc7-2k4dz   1/1     Running            0            117s
api-559465fcc7-nr5vn   1/1     Running            0            112s
api-559465fcc7-sc2hp   1/1     Running            0            108s
api-864f6595f4-vrtlm   0/1     CrashLoopBackOff   3 (9s ago)   45s
200
~~~

One new Pod crashing (its log says `REQUEST_TIMEOUT must be a positive duration such as 2s, got "soon"`), three old ones serving, and users unaffected, thanks to `maxUnavailable: 0`. Helm marked the revision `failed`. Go back:

~~~bash
helm -n runway rollback runway --wait
helm -n runway history runway | tail -2
~~~

~~~text
Rollback was a success! Happy Helming!
8       	Tue Oct  6 10:34:39 2026	failed    	runway-0.1.0	dev        	Upgrade "runway" failed: resource Deployment/runway/api not ready. ...
9       	Tue Oct  6 10:35:29 2026	deployed  	runway-0.1.0	dev        	Rollback to 7
~~~

A rollback is a new revision with an old revision's contents. Helm can also do it for you: `--rollback-on-failure` (called `--atomic` before Helm 4) rolls back as soon as the upgrade fails.

~~~text
Error: UPGRADE FAILED: release runway failed, and has been rolled back due to rollback-on-failure being set: resource Deployment/runway/api not ready. status: InProgress, message: Updated: 1/3
~~~

### A canary

Tag the same image as `v2` (pretend it's a new version), load it, and turn the canary on:

~~~bash
docker tag runway:dev runway:v2 && kind load docker-image runway:v2 --name runway
helm upgrade runway deploy/helm/runway -n runway --reuse-values --set canary.enabled=true,canary.tag=v2 --wait
kubectl -n runway get pods -l app=api -L track
seq 400 | xargs -P 16 -I{} curl -s -D - -o /dev/null localhost:8080/health | grep -i '^x-served-by' | sed 's/.*: \(api-[a-z]*\).*/\1/; s/api-[0-9a-f]*$/api/' | sort | uniq -c
~~~

~~~text
NAME                          READY   STATUS    RESTARTS   AGE     TRACK
api-559465fcc7-2k4dz          1/1     Running   0          3m14s   stable
api-559465fcc7-nr5vn          1/1     Running   0          3m9s    stable
api-559465fcc7-sc2hp          1/1     Running   0          3m5s    stable
api-canary-7bdb688c99-p8bjc   1/1     Running   0          1s      canary
    307 api
     93 api-canary
~~~

93 of 400, 23%, went to the one canary Pod beside three stable ones: traffic splits by Pod count, because kube-proxy picks Pods at random. That's also the limit of this kind of canary: you can only have 1/4 or 1/5, not 1%. Finer splits need a layer-7 router that weighs versions (step 4's gateway could). If the canary looks healthy, promote it, which is just making it the stable tag:

~~~bash
helm upgrade runway deploy/helm/runway -n runway --reuse-values --set image.tag=v2,canary.enabled=false --wait
~~~

Then set `image.tag=dev` again before going on.

**Explain it:** why does the chart leave out the databases? What does the checksum annotation do, and what would happen without it? Explain the shutdown race step by step, and why a sleep fixes it. Why did kload see no errors either way? What protected users from the broken upgrade, and what did `helm rollback` actually do? Why can't this canary take 1% of traffic?

**Read.** The Helm documentation's [chart template guide](https://helm.sh/docs/chart_template_guide/), the first eight pages. Then the Kubernetes documentation on [Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination). Then *Site Reliability Engineering* (Beyer et al.), chapter 8, *Release Engineering*, and the Google SRE workbook's chapter 16, *Canarying Releases*.

---

## Step 8: CI/CD: build once, test it, publish it by digest

**The problem.** Every image so far was built on your laptop, tagged `dev`, and copied into the cluster by hand. Nobody can tell which commit a running Pod came from, the image that ran in your test may not be the one that ships, and "it worked on my machine" is the whole of the evidence. A pipeline should build the image once, from a known commit, prove it works on a real cluster, and publish it under a name that can never point at anything else.

**New ideas.**

- **CI and CD.** *Continuous integration* tests every change; *continuous delivery* turns every change that passes into something you could deploy. The Blueprint's own CI has replayed these guides since Phase 0; this step gives Runway a pipeline of its own.
- **Build once, promote the artifact.** Rebuilding for each stage risks shipping something you never tested (a base image moved, a dependency changed). Build one image, save it, and pass *that file* from job to job.
- **Tags move; digests don't.** A tag (`runway:latest`, `runway:v2`) is a name someone can re-point at different bytes tomorrow. A **digest** (`runway@sha256:b380...`) is the hash of the image's manifest: it names the content itself. Deploying by digest means the cluster runs exactly what was tested.
- **Least privilege for pipelines.** A workflow's token can do whatever its permissions allow. Give every job read-only access, and only the job that publishes the right to write packages.

### A smoke test

The pipeline needs a test that installs Runway on an empty cluster and pushes one job through it. Create `deploy/smoke.sh`:

<!-- file: deploy/smoke.sh -->
~~~bash
#!/usr/bin/env bash
# Deploy Runway to the current kubectl cluster and check that one job runs
# from start to finish. CI runs this on a throwaway kind cluster against the
# image it just built; you can run it against yours.
#   deploy/smoke.sh [IMAGE_TAG]
set -euo pipefail
tag=${1:-dev}
url=${RUNWAY_URL:-http://localhost:8080}

kubectl apply -f deploy/k8s/config.yaml -f deploy/k8s/postgres.yaml \
  -f deploy/k8s/rabbitmq.yaml -f deploy/k8s/redis.yaml
# "rollout status", not "wait": wait fails at once if the Pods don't exist yet.
for store in postgres rabbitmq redis; do
  kubectl -n runway rollout status "statefulset/$store" --timeout=300s
done

# install the first time, upgrade after that
helm upgrade --install runway deploy/helm/runway -n runway \
  --set image.tag="$tag" --wait --timeout 5m

created=$(curl -sf -X POST "$url/jobs" -H 'Content-Type: application/json' \
  -d '{"description":"smoke test","duration_ms":50}')
id=$(echo "$created" | sed 's/{"id":\([0-9]*\).*/\1/')
for _ in $(seq 30); do
  job=$(curl -sf "$url/jobs/$id")
  case "$job" in
    *'"state":"completed"'*) echo "smoke test passed: job $id completed"; exit 0 ;;
    *'"state":"failed"'*) break ;;
  esac
  sleep 1
done
echo "smoke test failed: $job" >&2
kubectl -n runway get pods >&2
exit 1
~~~

`helm upgrade --install` installs the first time and upgrades after, so the script works on a fresh cluster and on yours. `rollout status` waits for each StatefulSet; `kubectl wait -l ...` would fail at once if the Pods didn't exist yet.

Try it on an empty namespace, which is what CI will have. Deleting the namespace deletes everything in it, the database's volume included, so you start with no jobs:

~~~bash
chmod +x deploy/smoke.sh
helm -n runway uninstall runway --wait; kubectl delete namespace runway --wait=true
time deploy/smoke.sh dev
~~~

~~~text
namespace/runway created
configmap/runway created
secret/runway created
statefulset.apps/postgres created
...
NOTES:
Runway dev is release runway, revision 1, in namespace runway.
...
smoke test passed: job 1 completed
real	0m34.88s
~~~

Thirty-five seconds from nothing to a completed job.

### Deploying by digest

Let the chart take a digest instead of a tag. In `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
{{/* The image, at a tag: runway.image (list $ "v2"). */}}
~~~

to:

~~~yaml
{{/*
The image, at a tag: runway.image (list $ "v2"). With image.digest set, the
stable Pods use the digest instead: the exact bytes CI tested, which no one
can move the way they can move a tag.
*/}}
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
{{ $root.Values.image.repository }}:{{ index . 1 }}
~~~

to:

~~~yaml
{{- $tag := index . 1 -}}
{{- if and $root.Values.image.digest (eq $tag $root.Values.image.tag) -}}
{{ $root.Values.image.repository }}@{{ $root.Values.image.digest }}
{{- else -}}
{{ $root.Values.image.repository }}:{{ $tag }}
{{- end }}
~~~


And in `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
  tag: dev
  pullPolicy: IfNotPresent # loaded into kind, not pulled
~~~

to:

~~~yaml
  tag: dev
  # sha256:..., from CI (step 8). When set, it wins over the tag.
  digest: ""
  pullPolicy: IfNotPresent # loaded into kind, not pulled
~~~


The canary keeps its tag: the digest belongs to the version being promoted, not the one being tried.

<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway --set image.repository=ghcr.io/me/runway --set image.digest=sha256:b380f55fbf57245b3998a53d0c2db47af51bdb536caa977c50857ac3426a974d --set canary.enabled=true,canary.tag=v3 | grep -c 'image: ghcr.io/me/runway@sha256:b380' | grep -qx 5 -->

~~~bash
helm template runway deploy/helm/runway --set image.repository=ghcr.io/me/runway \
  --set image.digest=sha256:b380f55fbf57245b3998a53d0c2db47af51bdb536caa977c50857ac3426a974d \
  --set canary.enabled=true,canary.tag=v3 | grep 'image:' | sort | uniq -c
~~~

~~~text
      1           image: ghcr.io/me/runway:v3
      5           image: ghcr.io/me/runway@sha256:b380f55fbf57245b3998a53d0c2db47af51bdb536caa977c50857ac3426a974d
~~~

What tags and digests mean is easiest to see with a registry of your own. Run one, push the same image under two tags, then move one of them:

~~~bash
docker run -d --name registry -p 5001:5000 registry:3
docker tag runway:ci localhost:5001/runway:sha-abc1234 && docker push -q localhost:5001/runway:sha-abc1234
docker tag runway:ci localhost:5001/runway:latest && docker push -q localhost:5001/runway:latest
docker buildx imagetools inspect localhost:5001/runway:sha-abc1234 --format '{{.Manifest.Digest}}'
docker buildx imagetools inspect localhost:5001/runway:latest --format '{{.Manifest.Digest}}'
docker tag runway:v2 localhost:5001/runway:latest && docker push -q localhost:5001/runway:latest
docker buildx imagetools inspect localhost:5001/runway:latest --format '{{.Manifest.Digest}}'
~~~

~~~text
sha256:b380f55fbf57245b3998a53d0c2db47af51bdb536caa977c50857ac3426a974d
sha256:b380f55fbf57245b3998a53d0c2db47af51bdb536caa977c50857ac3426a974d
sha256:3385b2e7c6d1bc98788b1cbdc97c5df366e56c0558d6630797898f41a76e6e4c
~~~

Same bytes, same digest, whatever the tag. Then `latest` moved to different bytes, and anyone deploying `latest` got something new without changing a line. (Build `runway:ci` first if you haven't: `docker build -t runway:ci .`. `docker rm -f registry` when you're done.)

**A trap I fell into.** The obvious way to get a digest after pushing is `docker inspect --format '{{index .RepoDigests 0}}'`. On my machine it printed `runway@sha256:...`: a digest recorded for the *local* name `runway`, not for the registry I'd just pushed to, because an image can have several. Ask the registry instead (`buildx imagetools inspect`), which is what the workflow below does. The local image ID that `docker build` prints is a third, different hash (of the image's configuration, not its manifest).

### The workflow

GitHub Actions runs workflows from `.github/workflows/` at the top of a repository. If your practice directory is its own repository (a good idea if you want to show this work), put it there; otherwise read it and adapt the paths. Create `.github/workflows/ci.yml`:

<!-- file: .github/workflows/ci.yml -->
~~~yaml
# Every push and pull request: test the code, build the image once, and run
# that image on a throwaway Kubernetes cluster. Pushes to main also publish
# it to GitHub's container registry (GHCR), named by its digest.
name: ci

on:
  push:
    branches: [main]
  pull_request:

# Read-only by default. Only the publish job asks for more.
permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    env:
      RUNWAY_AMQP_URL: amqp://guest:guest@localhost:5672/
      RUNWAY_DATABASE_URL: postgres://runway:runway@localhost:5432/runway
      RUNWAY_REDIS_URL: redis://localhost:6379/0
      RUNWAY_REDIS_URLS: redis://localhost:6379/0,redis://localhost:6380/0,redis://localhost:6381/0
      RUNWAY_KAFKA_BROKERS: localhost:9092
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-go@v7
        with:
          go-version-file: go.mod
      # The same compose.yaml you use on your machine: CI tests against the
      # same PostgreSQL settings, broker versions and ports.
      - name: Start the data services
        run: docker compose up -d --wait
      - run: go vet ./...
      - run: go test -race ./...
      - uses: azure/setup-helm@v5
      - run: helm lint deploy/helm/runway

  # Build once. The smoke test and the publish job both use this exact
  # image, saved as a file, so what is published is what was tested.
  image:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: docker/setup-buildx-action@v4
      - uses: docker/build-push-action@v7
        with:
          context: .
          tags: runway:ci
          outputs: type=docker,dest=${{ runner.temp }}/runway.tar
          # Reuse layers from earlier runs (the go mod download layer).
          cache-from: type=gha
          cache-to: type=gha,mode=max
      - uses: actions/upload-artifact@v7
        with:
          name: image
          path: ${{ runner.temp }}/runway.tar
          retention-days: 1

  smoke:
    needs: image
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/download-artifact@v8
        with:
          name: image
          path: ${{ runner.temp }}
      - uses: azure/setup-helm@v5
      # The same kind.yaml as on your machine: same Kubernetes version,
      # same ports.
      - uses: helm/kind-action@v1
        with:
          cluster_name: runway
          config: deploy/kind.yaml
      - name: Load the image into the cluster
        run: |
          docker load --input ${{ runner.temp }}/runway.tar
          kind load docker-image runway:ci --name runway
      - run: deploy/smoke.sh ci
      - name: Show what was running, if it failed
        if: failure()
        run: |
          kubectl -n runway get pods -o wide
          kubectl -n runway get events --sort-by=.lastTimestamp | tail -30

  publish:
    needs: smoke
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write # push to ghcr.io/OWNER/REPO
    steps:
      - uses: actions/download-artifact@v8
        with:
          name: image
          path: ${{ runner.temp }}
      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Push, and report the digest
        run: |
          docker load --input "$RUNNER_TEMP/runway.tar"
          # Registry names must be lowercase; GitHub user names needn't be.
          repo="ghcr.io/${GITHUB_REPOSITORY,,}"
          docker tag runway:ci "$repo:sha-${GITHUB_SHA::7}"
          docker push "$repo:sha-${GITHUB_SHA::7}"
          # The digest names the content. Tags can be moved; digests can't.
          # Ask the registry: the local image's ID is a different hash.
          digest=$(docker buildx imagetools inspect "$repo:sha-${GITHUB_SHA::7}" --format '{{.Manifest.Digest}}')
          {
            echo "Published \`$repo@$digest\`"
            echo
            echo "Deploy it with \`helm upgrade runway deploy/helm/runway --set image.repository=$repo --set image.digest=$digest\`"
          } >> "$GITHUB_STEP_SUMMARY"
~~~

Four jobs, each needing the one before:
1. **test** starts the same `compose.yaml` services you use (so CI and your laptop agree on versions and ports), and runs vet, the tests with the race detector, and `helm lint`.
2. **image** builds the image once, and saves it as a file (`type=docker,dest=...`), uploaded as an artifact. The GitHub Actions cache keeps the module-download layer between runs.
3. **smoke** downloads that file, makes a kind cluster from the same `deploy/kind.yaml`, loads the image, and runs `deploy/smoke.sh`. On failure, it prints the Pods and events, because a failed CI run you can't diagnose is half a failure.
4. **publish** runs only for pushes to `main`. It loads the same file, pushes it to GitHub's container registry (`ghcr.io`), asks the registry for the digest, and writes it, with the command to deploy it, to the run's summary page. It is the only job with `packages: write`.

Registry names must be lowercase and GitHub user names needn't be, hence `${GITHUB_REPOSITORY,,}` (bash for "lowercase"). The actions are pinned to major versions; to pin harder, use full commit SHAs, which can't be moved, for the same reason as digests.

**Check it before you push it.** [actionlint](https://github.com/rhysd/actionlint) checks workflow files, including the shell in `run:` steps:

~~~bash
go install github.com/rhysd/actionlint/cmd/actionlint@latest
actionlint .github/workflows/ci.yml
~~~

No output means no problems. Then push to a branch, open a pull request, and watch the first three jobs run; merge, and watch the fourth publish.

**A second cluster on WSL.** If you want to run the smoke test on a throwaway cluster next to your main one, as CI does, on WSL you may hit `too many open files` while the second cluster starts: each node's container runtime watches files with inotify, and WSL's default of 128 watchers per user runs out. Raise it (this one needs `sudo`): `sudo sysctl fs.inotify.max_user_instances=512`.

**Explain it:** why build the image once and pass the file between jobs, rather than build it in each? What is the difference between a tag, a digest and an image ID? Why does only the publish job get `packages: write`? What does the smoke test prove that the unit tests don't?

**Read.** *Continuous Delivery* (Humble and Farley), chapter 5, *Anatomy of the Deployment Pipeline*. The GitHub documentation on [workflow permissions](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/controlling-permissions-for-github_token). Then the OCI image specification's short section on [digests](https://github.com/opencontainers/image-spec/blob/main/descriptor.md#digests).

---

## Step 9: Tracing with OpenTelemetry

**The problem.** A job's life now crosses three processes and two brokers: an HTTP request to an API Pod, a transaction, a row in the outbox, a relay that publishes it later (maybe from a different API Pod), RabbitMQ, a worker, two events back through RabbitMQ, and an API Pod that applies them. When one job is slow, which of those was slow? Logs from each process tell their own part, with nothing joining them. Metrics tell you averages.

**New ideas.**

- **A trace** is the tree of work done for one request. Each node is a **span**: a named, timed piece of work with attributes, in one process. Spans share a **trace ID**; each knows its parent's span ID.
- **Context propagation.** Inside a process, the current span rides in Go's `context.Context`. Between processes it must be *written down* in whatever crosses the boundary: over HTTP, the W3C `traceparent` header (`00-<trace id>-<span id>-01`); in a message, a field of the message itself. Lose it at any boundary, and the trace breaks in two.
- **Asynchronous gaps.** The outbox is the interesting boundary. The request that wrote a command finishes long before the relay sends it. So the trace context must be stored *in the outbox row*, and the relay must continue the stored trace, not its own (it has none).
- **OpenTelemetry** is the standard API and SDK for traces (and metrics and logs). Services send spans with **OTLP** to a **collector**, which batches, samples and forwards them to a backend; here, **Jaeger**. Services know only the collector's address.
- **Gateway or sidecar.** This step runs one shared collector (a *gateway*). The other common layout puts a collector in every Pod, as a second container beside the application: a **sidecar**. Containers in a Pod share its network, so the app sends to `localhost`; each Pod's spans get enriched and buffered locally; and every Pod pays the sidecar's memory and CPU. Phase 6 comes back to sidecars, for mTLS between services.

### Dependencies

<!-- run: go get github.com/exaring/otelpgx@v0.12.1 go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp@v0.72.0 go.opentelemetry.io/otel@v1.47.0 go.opentelemetry.io/otel/sdk@v1.47.0 go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp@v1.47.0 -->

~~~bash
go get github.com/exaring/otelpgx@v0.12.1 \
  go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp@v0.72.0 \
  go.opentelemetry.io/otel@v1.47.0 go.opentelemetry.io/otel/sdk@v1.47.0 \
  go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp@v1.47.0
~~~

### A message carries its trace

In `internal/messages/messages.go`, add a field to the envelope. `omitempty` keeps old messages, and senders that don't trace, readable:

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
	Payload    json.RawMessage `json:"payload"`
}
~~~

to:

~~~go
	Payload    json.RawMessage `json:"payload"`
	// Trace is the W3C traceparent of the span that sent this message, so
	// the receiver's work joins the same trace (Phase 5). Optional: older
	// messages, and senders that don't trace, leave it out.
	Trace string `json:"trace,omitempty"`
}
~~~


### The telemetry package

Create `internal/telemetry/telemetry.go`:

<!-- file: internal/telemetry/telemetry.go -->
~~~go
// Package telemetry traces a job across Runway's processes with
// OpenTelemetry. A trace is a tree of spans, one per piece of work, that
// share a trace ID. Within a process, the current span rides in the
// context. Between processes it must be written down: over HTTP in the
// traceparent header, and in a message's Envelope.Trace field, which
// survives the outbox table and the broker.
package telemetry

import (
	"context"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"

	"runway/internal/envconfig"
)

// Setup installs the process-wide tracer provider and propagator.
//
// With OTEL_EXPORTER_OTLP_ENDPOINT unset, spans are not recorded, but
// trace context still passes through: a process without an exporter
// doesn't break the trace for the processes after it.
//
// Call the returned function before exiting, to send the spans still
// buffered.
func Setup(ctx context.Context, service string, getenv envconfig.Getenv) (func(context.Context) error, error) {
	otel.SetTextMapPropagator(propagation.TraceContext{})
	endpoint := getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		return func(context.Context) error { return nil }, nil
	}
	exporter, err := otlptracehttp.New(ctx, otlptracehttp.WithEndpointURL(endpoint+"/v1/traces"))
	if err != nil {
		return nil, err
	}
	// Who sent these spans. OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES,
	// if set, add to or override this.
	res, err := resource.Merge(resource.Default(), resource.NewSchemaless(semconv.ServiceName(service)))
	if err != nil {
		return nil, err
	}
	res, err = resource.Merge(res, resource.Environment())
	if err != nil {
		return nil, err
	}
	provider := sdktrace.NewTracerProvider(
		// Send spans in batches, off the request path. The sampler comes
		// from OTEL_TRACES_SAMPLER; by default, every trace is kept.
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(provider)
	return provider.Shutdown, nil
}

// Traceparent returns the W3C traceparent of the span in ctx, such as
// 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01, or "" if there is
// none.
func Traceparent(ctx context.Context) string {
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)
	return carrier.Get("traceparent")
}

// WithTraceparent returns ctx with traceparent as the remote parent span,
// so spans started from it join that trace.
func WithTraceparent(ctx context.Context, traceparent string) context.Context {
	if traceparent == "" {
		return ctx
	}
	return otel.GetTextMapPropagator().Extract(ctx, propagation.MapCarrier{"traceparent": traceparent})
}
~~~

With no endpoint set, `Setup` installs only the propagator. Spans aren't recorded, but a `traceparent` that comes in still goes out: one process without tracing doesn't break the trace for the processes after it.

The bus side is a pair of decorators, so neither RabbitMQ's adapter nor the in-memory bus has to know about tracing. Create `internal/telemetry/bus.go`:

<!-- file: internal/telemetry/bus.go -->
~~~go
package telemetry

import (
	"context"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"

	"runway/internal/bus"
	"runway/internal/messages"
)

// tracer is looked up on each use, not once: the provider can be replaced
// after this package is loaded (by Setup, or by a test).
func tracer() trace.Tracer { return otel.Tracer("runway/internal/telemetry") }

// Publisher wraps a bus.Publisher so each message gets a producer span,
// and carries that span in Envelope.Trace to whoever consumes it.
//
// A message that already has a Trace (written into the outbox during the
// request) continues that trace, not the caller's: the outbox relay
// publishes on behalf of a request that may have finished long ago.
func Publisher(next bus.Publisher) bus.Publisher {
	return publisher{next}
}

type publisher struct{ next bus.Publisher }

func (p publisher) Publish(ctx context.Context, queue string, msg messages.Envelope) error {
	if msg.Trace != "" {
		ctx = WithTraceparent(ctx, msg.Trace)
	}
	ctx, span := tracer().Start(ctx, "publish "+queue,
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(messageAttributes(queue, msg)...))
	defer span.End()
	if span.SpanContext().IsValid() {
		msg.Trace = Traceparent(ctx)
	}
	err := p.next.Publish(ctx, queue, msg)
	if err != nil {
		span.SetStatus(codes.Error, err.Error())
	}
	return err
}

// Handler wraps a bus.Handler so each delivery runs in a consumer span,
// a child of the span that published the message.
func Handler(queue string, next bus.Handler) bus.Handler {
	return func(ctx context.Context, msg messages.Envelope) error {
		ctx = WithTraceparent(ctx, msg.Trace)
		ctx, span := tracer().Start(ctx, "process "+queue,
			trace.WithSpanKind(trace.SpanKindConsumer),
			trace.WithAttributes(messageAttributes(queue, msg)...))
		defer span.End()
		err := next(ctx, msg)
		if err != nil {
			span.SetStatus(codes.Error, err.Error())
		}
		return err
	}
}

// Attribute names from OpenTelemetry's messaging conventions, so tracing
// tools know how to show them.
func messageAttributes(queue string, msg messages.Envelope) []attribute.KeyValue {
	return []attribute.KeyValue{
		attribute.String("messaging.system", "runway"),
		attribute.String("messaging.destination.name", queue),
		attribute.String("messaging.message.id", msg.ID),
		attribute.String("runway.message.type", msg.Type),
	}
}
~~~

Note `tracer()` is a function, looked up on every use, not a package variable. That isn't style. OpenTelemetry's global provider forwards to the real one only for the *first* `SetTracerProvider`; a tracer saved in a variable at start-up kept pointing at the first provider when my tests installed a second, and they silently recorded nothing.

Test it, `internal/telemetry/telemetry_test.go`. The second and third tests are the two promises that matter: a trace crosses the bus, and a stored trace beats the caller's:

<!-- file: internal/telemetry/telemetry_test.go -->
~~~go
package telemetry

import (
	"context"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"

	"runway/internal/bus"
	"runway/internal/messages"
)

// record makes every span in this test go to an in-memory recorder.
func record(t *testing.T) *tracetest.SpanRecorder {
	t.Helper()
	recorder := tracetest.NewSpanRecorder()
	provider := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder))
	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	t.Cleanup(func() { _ = provider.Shutdown(context.Background()) })
	return recorder
}

func span(t *testing.T, recorder *tracetest.SpanRecorder, name string) sdktrace.ReadOnlySpan {
	t.Helper()
	for _, s := range recorder.Ended() {
		if s.Name() == name {
			return s
		}
	}
	t.Fatalf("no span named %q", name)
	return nil
}

func TestTraceparentRoundTrip(t *testing.T) {
	record(t)
	ctx, parent := otel.Tracer("test").Start(context.Background(), "request")
	defer parent.End()

	tp := Traceparent(ctx)
	if !strings.HasPrefix(tp, "00-"+parent.SpanContext().TraceID().String()+"-") {
		t.Fatalf("traceparent = %q", tp)
	}
	// Another process, given only the string, continues the same trace.
	remote := trace.SpanContextFromContext(WithTraceparent(context.Background(), tp))
	if remote.TraceID() != parent.SpanContext().TraceID() || remote.SpanID() != parent.SpanContext().SpanID() {
		t.Fatalf("extracted %v, want the parent's IDs", remote)
	}
	if Traceparent(context.Background()) != "" {
		t.Fatal("a context with no span should give no traceparent")
	}
}

// A request publishes a message; the consumer's span must be in the same
// trace, under the producer's span.
func TestATraceCrossesTheBus(t *testing.T) {
	recorder := record(t)
	memory := bus.NewMemory(10, 3)
	ctx, request := otel.Tracer("test").Start(context.Background(), "request")
	msg, _ := messages.New(messages.TypeJobStarted, messages.JobStarted{JobID: 1}, time.Now())
	if err := Publisher(memory).Publish(ctx, "q", msg); err != nil {
		t.Fatal(err)
	}
	request.End()

	consumed := make(chan trace.SpanContext, 1)
	stop, cancel := context.WithCancel(context.Background())
	go func() {
		_ = memory.Subscribe(stop, "q", Handler("q", func(ctx context.Context, _ messages.Envelope) error {
			consumed <- trace.SpanContextFromContext(ctx)
			cancel()
			return nil
		}))
	}()
	got := <-consumed
	<-stop.Done()
	time.Sleep(10 * time.Millisecond) // let the consumer span end

	if got.TraceID() != request.SpanContext().TraceID() {
		t.Fatalf("consumer trace %s, want %s", got.TraceID(), request.SpanContext().TraceID())
	}
	producer := span(t, recorder, "publish q")
	consumer := span(t, recorder, "process q")
	if producer.Parent().SpanID() != request.SpanContext().SpanID() {
		t.Error("the producer span should be the request's child")
	}
	if consumer.Parent().SpanID() != producer.SpanContext().SpanID() {
		t.Error("the consumer span should be the producer's child")
	}
}

// The outbox relay publishes with no trace of its own. The message's stored
// trace, from the request that wrote it, must win.
func TestAStoredTraceOutlivesTheRequest(t *testing.T) {
	recorder := record(t)
	ctx, request := otel.Tracer("test").Start(context.Background(), "request")
	msg, _ := messages.New(messages.TypeRunJob, messages.RunJob{JobID: 1}, time.Now())
	msg.Trace = Traceparent(ctx) // as outbox.Write does
	request.End()

	memory := bus.NewMemory(10, 3)
	if err := Publisher(memory).Publish(context.Background(), "q", msg); err != nil {
		t.Fatal(err)
	}
	producer := span(t, recorder, "publish q")
	if producer.SpanContext().TraceID() != request.SpanContext().TraceID() {
		t.Fatal("the relay's publish started a new trace instead of continuing the request's")
	}
}

func TestSetupWithoutAnEndpointStillPropagates(t *testing.T) {
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator()) // none
	shutdown, err := Setup(context.Background(), "test", func(string) string { return "" })
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = shutdown(context.Background()) }()
	const tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	if got := Traceparent(WithTraceparent(context.Background(), tp)); got != tp {
		t.Fatalf("passed through %q, want %q", got, tp)
	}
}
~~~

### Every boundary

The outbox stamps each message with the request's trace as it writes it. In `internal/outbox/outbox.go`:

Change:

<!-- edit: internal/outbox/outbox.go -->
~~~go
	"runway/internal/messages"
)
~~~

to:

~~~go
	"runway/internal/messages"
	"runway/internal/telemetry"
)
~~~

Change:

<!-- edit: internal/outbox/outbox.go -->
~~~go
// Write saves msgs inside tx. They are sent only if tx commits.
func Write(ctx context.Context, tx pgx.Tx, msgs ...Message) error {
	for _, msg := range msgs {
		envelope, err := json.Marshal(msg.Envelope)
~~~

to:

~~~go
// Write saves msgs inside tx. They are sent only if tx commits.
//
// Each message records the trace of the request that caused it, so the
// relay, which sends it later from another goroutine or another process,
// can continue that trace.
func Write(ctx context.Context, tx pgx.Tx, msgs ...Message) error {
	for _, msg := range msgs {
		if msg.Envelope.Trace == "" {
			msg.Envelope.Trace = telemetry.Traceparent(ctx)
		}
		envelope, err := json.Marshal(msg.Envelope)
~~~


The worker wraps the whole run of a job in one span, and records each failed attempt as an event on it. In `internal/worker/worker.go`:

Change:

<!-- edit: internal/worker/worker.go -->
~~~go

	"runway/internal/bus"
~~~

to:

~~~go

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"

	"runway/internal/bus"
~~~

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
	"runway/internal/retry"
)

// ErrTransient is the failure Flaky injects.
~~~

to:

~~~go
	"runway/internal/retry"
)

// tracer is looked up on each use: the provider is installed after this
// package is loaded.
func tracer() trace.Tracer { return otel.Tracer("runway/internal/worker") }

// ErrTransient is the failure Flaky injects.
~~~

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
	}
	if err := w.emit(ctx, messages.TypeJobStarted, messages.JobStarted{JobID: cmd.JobID}); err != nil {
~~~

to:

~~~go
	}
	// One span for the whole run. The events it publishes, and each
	// attempt, appear inside it.
	ctx, span := tracer().Start(ctx, "run job", trace.WithAttributes(
		attribute.Int64("runway.job.id", cmd.JobID),
		attribute.Int("runway.job.max_attempts", cmd.MaxAttempts)))
	defer span.End()

	if err := w.emit(ctx, messages.TypeJobStarted, messages.JobStarted{JobID: cmd.JobID}); err != nil {
~~~

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
	policy.Attempts = cmd.MaxAttempts
	err = policy.Do(jobCtx, func(ctx context.Context) error {
		err := w.work(ctx, job)
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
~~~

to:

~~~go
	policy.Attempts = cmd.MaxAttempts
	attempt := 0
	err = policy.Do(jobCtx, func(ctx context.Context) error {
		attempt++
		err := w.work(ctx, job)
		if err != nil {
			span.AddEvent("attempt failed", trace.WithAttributes(
				attribute.Int("runway.attempt", attempt), attribute.String("error", err.Error())))
		}
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
~~~

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
	if err != nil {
		failed := messages.JobFailed{JobID: cmd.JobID, Reason: jobs.FailureReason(err)}
~~~

to:

~~~go
	if err != nil {
		span.SetStatus(codes.Error, jobs.FailureReason(err))
		failed := messages.JobFailed{JobID: cmd.JobID, Reason: jobs.FailureReason(err)}
~~~


The worker command sets up tracing, publishes events through the decorator, handles each command inside a span continued from its sender, and logs the trace ID with each command, so a log line leads you to its trace. In `cmd/worker/main.go`:

Change:

<!-- edit: cmd/worker/main.go -->
~~~go

	"runway/internal/bus"
~~~

to:

~~~go

	"go.opentelemetry.io/otel/trace"

	"runway/internal/bus"
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	"runway/internal/rabbit"
	"runway/internal/worker"
~~~

to:

~~~go
	"runway/internal/rabbit"
	"runway/internal/telemetry"
	"runway/internal/worker"
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go

	client, err := rabbit.Dial(cfg.AMQPURL, rabbit.Options{
~~~

to:

~~~go

	shutdownTracing, err := telemetry.Setup(ctx, "worker", getenv)
	if err != nil {
		return err
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = shutdownTracing(ctx) // send the spans still buffered
	}()

	client, err := rabbit.Dial(cfg.AMQPURL, rabbit.Options{
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	handle := logged(logger, worker.New(client, work, cfg.JobTimeout).Handle)
~~~

to:

~~~go
	// Events go out through a tracing publisher; each command is handled,
	// and logged, inside a span continued from the one that sent it.
	events := telemetry.Publisher(client)
	handle := telemetry.Handler(messages.CommandsQueue,
		logged(logger, worker.New(events, work, cfg.JobTimeout).Handle))
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
			"message_id", msg.ID,
			"type", msg.Type,
~~~

to:

~~~go
			"message_id", msg.ID,
			// The same ID as in the tracing UI: search for it there.
			"trace_id", traceID(ctx),
			"type", msg.Type,
~~~

Add this at the end of the file:

<!-- append: cmd/worker/main.go -->
~~~go
// traceID returns the ID of the trace in ctx, or "" if there is none.
func traceID(ctx context.Context) string {
	if sc := trace.SpanContextFromContext(ctx); sc.HasTraceID() {
		return sc.TraceID().String()
	}
	return ""
}
~~~


The database: `otelpgx` makes a span for each query and each wait for a pooled connection, but only for queries made on behalf of a traced request. The outbox relay polls ten times a second; without that rule it would bury every real trace in noise. In `internal/pgstore/pool.go`:

Change:

<!-- edit: internal/pgstore/pool.go -->
~~~go

	"github.com/jackc/pgx/v5/pgxpool"
~~~

to:

~~~go

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5/pgxpool"
~~~

Change:

<!-- edit: internal/pgstore/pool.go -->
~~~go
	}
	if opts.MaxConns > 0 {
~~~

to:

~~~go
	}
	// A span for each query, and for each wait for a free connection, made
	// on behalf of a traced request (Phase 5). Queries with no trace to
	// join, such as the outbox relay's polling, make none.
	config.ConnConfig.Tracer = otelpgx.NewTracer(otelpgx.WithTrimSQLInSpanName(), otelpgx.WithQuerySpanNamePrefix())
	if opts.MaxConns > 0 {
~~~


HTTP. `otelhttp` starts a span for each request (continuing the caller's trace if it sent a `traceparent`), but it runs *before* the router, so all it knows to call the span is the method: `POST`. The request-logging middleware runs after the router has matched a route, so it renames the span to the route, `POST /jobs`, and puts the trace ID in the log line. In `internal/httpapi/middleware.go`:

Change:

<!-- edit: internal/httpapi/middleware.go -->
~~~go
	"time"
)
~~~

to:

~~~go
	"time"

	"go.opentelemetry.io/otel/trace"
)
~~~

Change:

<!-- edit: internal/httpapi/middleware.go -->
~~~go
		logger.Info("request",
~~~

to:

~~~go
		route := routeOf(r)
		attrs := []any{
~~~

Change:

<!-- edit: internal/httpapi/middleware.go -->
~~~go
			"route", routeOf(r),
~~~

to:

~~~go
			"route", route,
~~~

Change:

<!-- edit: internal/httpapi/middleware.go -->
~~~go
		)
~~~

to:

~~~go
		}
		// The tracing middleware started this request's span before the
		// router had matched a route, so it could only name it "POST". Now
		// the route is known: "POST /jobs", the same for every job.
		if span := trace.SpanFromContext(r.Context()); span.SpanContext().IsValid() {
			span.SetName(route)
			attrs = append(attrs, "trace_id", span.SpanContext().TraceID().String())
		}
		logger.Info("request", attrs...)
~~~


And the API command wires it all. Probes and scrapes are filtered out: at one probe every two seconds per Pod, they would be most of the traces and tell you nothing. In `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"github.com/prometheus/client_golang/prometheus"
	"google.golang.org/grpc"
~~~

to:

~~~go
	"github.com/prometheus/client_golang/prometheus"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"google.golang.org/grpc"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/stream"
	"runway/internal/worker"
~~~

to:

~~~go
	"runway/internal/stream"
	"runway/internal/telemetry"
	"runway/internal/worker"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go

	metrics := httpapi.NewMetrics()
~~~

to:

~~~go

	shutdownTracing, err := telemetry.Setup(ctx, "api", getenv)
	if err != nil {
		return err
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = shutdownTracing(ctx) // send the spans still buffered
	}()

	metrics := httpapi.NewMetrics()
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	defer closeBus()
	dispatchBreaker := breaker.New(cfg.BreakerThreshold, cfg.BreakerCooldown, time.Now)
~~~

to:

~~~go
	defer closeBus()
	// Every message sent carries its trace (Phase 5).
	publisher = telemetry.Publisher(publisher)
	dispatchBreaker := breaker.New(cfg.BreakerThreshold, cfg.BreakerCooldown, time.Now)
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		Handler:           handler,
~~~

to:

~~~go
		// A span for each request, continuing the caller's trace if its
		// request has a traceparent header. Probes and scrapes are left out:
		// they would be most of the traces and tell you nothing.
		Handler: otelhttp.NewHandler(handler, "http",
			otelhttp.WithFilter(func(r *http.Request) bool {
				return r.URL.Path != "/health" && r.URL.Path != "/ready" && r.URL.Path != "/metrics"
			})),
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
			if err := subscriber.Subscribe(stopConsuming, queue, handle); err != nil {
~~~

to:

~~~go
			if err := subscriber.Subscribe(stopConsuming, queue, telemetry.Handler(queue, handle)); err != nil {
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/telemetry/... ./internal/worker/... ./internal/outbox/... ./internal/messages/... ./internal/httpapi/... ./cmd/... -->

**Break it: forget to read the stored trace.** In `bus.go`, comment out both `ctx = WithTraceparent(ctx, msg.Trace)` lines and run the tests:

~~~text
--- FAIL: TestATraceCrossesTheBus (0.01s)
    telemetry_test.go:86: consumer trace d0123b5033b680b82ab5c3f5ce73dd9c, want a62f3c10293ecd5a5b7e52cab37921ff
--- FAIL: TestAStoredTraceOutlivesTheRequest (0.00s)
    telemetry_test.go:113: the relay's publish started a new trace instead of continuing the request's
~~~

Each side quietly started a trace of its own. Nothing crashes when propagation breaks; the traces just stop joining up, which is why it needs tests. Put the lines back.

### A collector and Jaeger

Tracing infrastructure lives in its own namespace. Create `deploy/k8s/tracing.yaml`. (The collector's exporter is called `otlp_grpc`; older examples on the web say `otlp`, which this version no longer has. When a collector won't start, `docker run --rm otel/opentelemetry-collector:0.162.0 components` lists what it does have.)

<!-- file: deploy/k8s/tracing.yaml -->
~~~yaml
# Tracing, in its own namespace: an OpenTelemetry Collector that every
# service sends spans to, and Jaeger, which stores them and shows them.
#
# Services know only the collector's address. What happens next (sampling,
# batching, which backend, or several) is the collector's configuration,
# changed without touching the services.
apiVersion: v1
kind: Namespace
metadata:
  name: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    processors:
      # Refuse data before running out of memory, rather than be OOM-killed
      # and lose everything buffered.
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      batch: {}
    exporters:
      otlp_grpc/jaeger:
        endpoint: jaeger.observability:4317
        tls: { insecure: true }
    extensions:
      health_check: { endpoint: 0.0.0.0:13133 }
    service:
      extensions: [health_check]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp_grpc/jaeger]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels: { app: otel-collector }
  template:
    metadata:
      labels: { app: otel-collector }
      annotations:
        # Change this to restart the collector after editing its config.
        config-version: "1"
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector:0.162.0
          args: ["--config=/etc/otelcol/config.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: health, containerPort: 13133 }
          readinessProbe:
            httpGet: { path: /, port: health }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { memory: 256Mi }
          volumeMounts:
            - { name: config, mountPath: /etc/otelcol }
      volumes:
        - name: config
          configMap: { name: otel-collector }
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
spec:
  selector: { app: otel-collector }
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: otlp-grpc }
    - { name: otlp-http, port: 4318, targetPort: otlp-http }
---
# Jaeger with no configuration runs everything in one process and keeps
# traces in memory: right for learning, gone when the Pod restarts.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels: { app: jaeger }
  template:
    metadata:
      labels: { app: jaeger }
    spec:
      containers:
        - name: jaeger
          image: jaegertracing/jaeger:2.22.0
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: ui, containerPort: 16686 }
          readinessProbe:
            httpGet: { path: /, port: ui }
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { memory: 512Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: observability
spec:
  selector: { app: jaeger }
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: otlp-grpc }
    - { name: ui, port: 16686, targetPort: ui }
~~~

Point the chart's services at the collector. In `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
  WORKERS: "4"

~~~

to:

~~~yaml
  WORKERS: "4"

# Where to send spans (step 9): the collector's OTLP/HTTP address. Empty
# turns tracing off; trace context still passes through.
tracing:
  endpoint: http://otel-collector.observability:4318

~~~


The settings are OpenTelemetry's standard variables, shared by the API and the workers through a helper. Each span is labelled with the Pod that made it. In `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
  - secretRef: { name: {{ .Values.existingSecret }} }
{{- end }}
~~~

to:

~~~yaml
  - secretRef: { name: {{ .Values.existingSecret }} }
{{- end }}

{{/*
Tracing settings, standard OpenTelemetry variables: runway.tracingEnv
(dict "root" $ "service" "api"). Each span carries the Pod's name, so a slow
span leads you to the Pod that made it.
*/}}
{{- define "runway.tracingEnv" -}}
{{- if .root.Values.tracing.endpoint }}
- { name: OTEL_EXPORTER_OTLP_ENDPOINT, value: {{ .root.Values.tracing.endpoint | quote }} }
- { name: OTEL_SERVICE_NAME, value: {{ .service }} }
- name: POD_NAME
  valueFrom:
    fieldRef: { fieldPath: metadata.name }
- { name: OTEL_RESOURCE_ATTRIBUTES, value: "k8s.pod.name=$(POD_NAME)" }
{{- end }}
{{- end }}
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
            resourceFieldRef: { resource: limits.memory }
        {{- range $name, $value := $api.env }}
~~~

to:

~~~yaml
            resourceFieldRef: { resource: limits.memory }
        {{- with include "runway.tracingEnv" (dict "root" $root "service" "api") | trim }}
        {{- . | nindent 8 }}
        {{- end }}
        {{- range $name, $value := $api.env }}
~~~


`| trim` inside `with` avoids a blank, whitespace-only line where the helper renders nothing. In `deploy/helm/runway/templates/worker.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/worker.yaml -->
~~~yaml
          {{- include "runway.envFrom" . | nindent 10 }}
          resources:
~~~

to:

~~~yaml
          {{- include "runway.envFrom" . | nindent 10 }}
          {{- with include "runway.tracingEnv" (dict "root" $ "service" "worker") | trim }}
          env:
            {{- . | nindent 12 }}
          {{- end }}
          resources:
~~~


<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway | grep -c OTEL_EXPORTER_OTLP_ENDPOINT | grep -qx 2 && helm template runway deploy/helm/runway --set tracing.endpoint= | grep -c OTEL_ | grep -qx 0 -->

Deploy:

~~~bash
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
kubectl apply -f deploy/k8s/tracing.yaml
kubectl -n observability rollout status deployment/otel-collector deployment/jaeger
helm upgrade runway deploy/helm/runway -n runway --reuse-values --wait
~~~

~~~text
Error: UPGRADE FAILED: runway/templates/worker.yaml:25:19
  executing "runway/templates/worker.yaml" at <include "runway.tracingEnv" (dict "root" $ "service" "worker")>:
    error calling include: ...
~~~

**A Helm trap.** `--reuse-values` reuses the last release's values *instead of* the chart's defaults, so the new `tracing` section in `values.yaml` doesn't exist as far as this upgrade is concerned, and the template trips over it. You want the new defaults with your earlier `--set`s on top: that's `--reset-then-reuse-values`.

~~~bash
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait
~~~

### Run it: one job, end to end

Send a job, and give the collector a few seconds to batch and forward:

~~~bash
curl -s -X POST localhost:8080/jobs -H 'Content-Type: application/json' -d '{"description":"traced, settled","duration_ms":300}'
kubectl -n runway logs -l app=api --tail=100 | grep '"POST /jobs"' | tail -1
~~~

~~~text
{"time":"2026-10-06T18:09:09.601521155Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs","status":201,"duration_ms":15,"trace_id":"eb513555b54e293d6b6b4759207d57f2"}
~~~

Open Jaeger (`kubectl -n observability port-forward svc/jaeger 16686:16686`, then http://localhost:16686), choose the service `api`, and find that trace ID. Jaeger draws it as a waterfall. To print the same thing in a terminal, query Jaeger's API (version 2.22 serves only `/api/v3`; the older `/api/traces` you'll see in tutorials returns 404) and turn the answer into a tree. Create `deploy/trace-tree.py`:

<!-- file: deploy/trace-tree.py -->
~~~python
#!/usr/bin/env python3
"""Print traces from Jaeger's API (OTLP JSON on stdin) as indented trees.

  curl -s "localhost:16686/api/v3/traces?query.service_name=api&..." |
    python3 deploy/trace-tree.py "run job"

Only traces that contain a span with the given name are shown (all, if no
name is given). Each line: service, span name, start offset, duration.
"""
import json
import sys
from collections import defaultdict

want = sys.argv[1] if len(sys.argv) > 1 else None
spans = []
for rs in json.load(sys.stdin)["result"]["resourceSpans"]:
    attrs = {a["key"]: a["value"].get("stringValue") for a in rs["resource"]["attributes"]}
    for ss in rs["scopeSpans"]:
        for s in ss["spans"]:
            s["service"] = attrs.get("service.name", "?")
            spans.append(s)

traces = defaultdict(list)
for s in spans:
    traces[s["traceId"]].append(s)

for trace_id, members in traces.items():
    if want and not any(s["name"] == want for s in members):
        continue
    ids = {s["spanId"] for s in members}
    children = defaultdict(list)
    for s in members:
        parent = s.get("parentSpanId", "")
        children[parent if parent in ids else None].append(s)
    start = min(int(s["startTimeUnixNano"]) for s in members)

    def show(s, depth):
        offset = (int(s["startTimeUnixNano"]) - start) / 1e6
        took = (int(s["endTimeUnixNano"]) - int(s["startTimeUnixNano"])) / 1e6
        print(f"{'  ' * depth}{s['service']:<7} {s['name']:<{40 - 2 * depth}} +{offset:7.1f} ms {took:7.1f} ms")
        for c in sorted(children[s["spanId"]], key=lambda c: int(c["startTimeUnixNano"])):
            show(c, depth + 1)

    print(f"trace {trace_id}: {len(members)} spans")
    for root in sorted(children[None], key=lambda c: int(c["startTimeUnixNano"])):
        show(root, 0)
    print()
~~~

~~~bash
MIN=$(date -u -d '-3 min' +%Y-%m-%dT%H:%M:%SZ); MAX=$(date -u -d '+1 min' +%Y-%m-%dT%H:%M:%SZ)
curl -s "localhost:16686/api/v3/traces?query.service_name=api&query.start_time_min=$MIN&query.start_time_max=$MAX&query.search_depth=20" | python3 deploy/trace-tree.py "run job"
~~~

~~~text
trace 9fd78fa983b17825ca042c695fcbd5dd: 36 spans
api     POST /jobs                               +    0.0 ms    11.4 ms
  api     pool.acquire                           +    0.3 ms     0.0 ms
  api     query BEGIN                            +    0.3 ms     0.6 ms
  api     query INSERT                           +    0.9 ms     2.6 ms
    api     prepare INSERT                       +    1.0 ms     1.1 ms
  api     query INSERT                           +    3.7 ms     2.5 ms
    api     prepare INSERT                       +    3.8 ms     0.6 ms
  api     query INSERT                           +    6.5 ms     1.4 ms
    api     prepare INSERT                       +    6.6 ms     0.6 ms
  api     query COMMIT                           +    8.1 ms     2.9 ms
  api     publish jobs.commands                  +   12.4 ms    15.3 ms
    worker  process jobs.commands                +   28.3 ms   322.4 ms
      worker  run job                            +   28.4 ms   322.2 ms
        worker  publish jobs.events              +   28.4 ms     8.4 ms
          api     process jobs.events            +   36.7 ms    20.9 ms
            api     pool.acquire                 +   38.6 ms     0.0 ms
            api     query SELECT                 +   38.8 ms     1.7 ms
              api     prepare SELECT             +   38.9 ms     0.8 ms
            api     query BEGIN                  +   41.7 ms     0.5 ms
            api     query UPDATE                 +   42.3 ms     1.6 ms
            ...
        worker  publish jobs.events              +  337.6 ms    13.0 ms
          api     process jobs.events            +  351.1 ms    11.9 ms
            ...
~~~

Everything from Phases 2 and 3 in one picture. The request: three `INSERT`s (the job, its event in the `job_events` history, and its outbox row) in one transaction. Then the relay publishing the command, a child of the request although it ran after the request ended. The worker's 300 ms run, its `JobStarted` event and the API applying it, then `JobCompleted` and the API applying that. (The `prepare` spans are pgx preparing each statement the first time a connection sees it.)

Look at the gap between `COMMIT` ending (about 11 ms) and `publish jobs.commands` starting (12.4 ms here). In another run, the command waited 67 ms: the relay polls every 100 ms, so a command waits between 0 and 100 ms in the outbox, and only the trace shows it. That is the outbox pattern's latency cost, measured.

**One more thing the traces showed me.** In a run straight after a rollout, the spans for the event handlers had no `query`/`prepare` prefix: they came from *old* code. The old API Pods, still shutting down after the rollout (the five-second sleep, then the drain), were still consuming from RabbitMQ. During every rollout, two versions of your code handle messages at once. That's why Phase 2 versioned the messages.

**Explain it:** how does the trace get from the API to the worker? Why must the outbox row carry the trace, and why must the relay's publish continue that trace rather than its own? Why does the HTTP span need renaming after routing? Why are probe requests and the relay's polling queries left out of the traces? What did `--reuse-values` do wrong?

**Read.** Sigelman et al., *Dapper, a Large-Scale Distributed Systems Tracing Infrastructure* (Google, 2010), sections 1–4. Then the W3C [Trace Context](https://www.w3.org/TR/trace-context/) specification, sections 1–3. Then the OpenTelemetry documentation's [concepts](https://opentelemetry.io/docs/concepts/) pages on traces, context propagation and the collector. Carry this question in: Dapper sampled 1 trace in 1024. What would sampling do to this step's "find the slow job" use, and how would you sample differently?

---

## Step 10: Prometheus, SLOs and burn-rate alerts

**The problem.** Traces explain one request. To know whether Runway is *healthy*, you need numbers over time, and to know when to wake someone, you need a definition of "healthy" that matches what users feel. "CPU over 80%" pages people for things users never notice, and stays silent through outages that happen at 20% CPU.

**New ideas.**

- **An SLI** (service level indicator) measures what users experience: the share of requests that succeed, the share answered within 250 ms. **An SLO** is a target for it over a window: 99.9% of requests succeed, over 30 days.
- **The error budget** is what the SLO allows to fail: 0.1% of requests, about 43 minutes of total outage a month. It turns reliability into a quantity you can spend (on releases, experiments) and run out of.
- **Burn rate** is how fast the budget is going: a burn rate of 1 spends exactly the month's budget in 30 days; 14.4 spends 2% of it in an hour, all of it in about two days.
- **Multi-window, multi-burn-rate alerts** (the Google SRE Workbook, chapter 5). Page when *both* a long window (1 hour: is this real, and big?) *and* a short one (5 minutes: is it still happening?) burn fast. Open a ticket for slow burns. The alert fires quickly for big problems, ignores blips, and stops soon after the problem does.
- **Recording rules** compute an expression on a schedule and store the result as a new series, so that alerts and dashboards read cheap, named results.
- **The USE method** (Brendan Gregg): for every resource, check its **U**tilization (how busy), **S**aturation (how much work is waiting) and **E**rrors. The SLO says *whether* users hurt; USE helps find *why*.
- **Service discovery.** Prometheus *pulls* metrics, so it must know what to scrape. On Kubernetes it asks the API server, and **relabelling** rules turn what it finds into targets and labels.

### Worker metrics

The API has exposed metrics since Phase 1; the workers never had a port. Give them one, with what USE needs: how many consumers are busy (utilization) and how many commands failed (errors). Saturation, the commands waiting, comes from RabbitMQ itself. Create `cmd/worker/metrics.go`:

<!-- file: cmd/worker/metrics.go -->
~~~go
package main

import (
	"context"
	"net"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"runway/internal/bus"
	"runway/internal/messages"
)

// metrics are the worker's numbers for the USE method (Phase 5):
// utilization is busy / consumers, saturation is the queue's depth (from
// RabbitMQ), and errors are commands handled with an error.
type metrics struct {
	registry *prometheus.Registry
	busy     prometheus.Gauge
	handled  *prometheus.CounterVec
	duration prometheus.Histogram
}

func newMetrics(consumers int) *metrics {
	m := &metrics{
		registry: prometheus.NewRegistry(),
		busy: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "worker_busy_consumers",
			Help: "Consumers handling a command right now.",
		}),
		handled: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "worker_commands_total",
			Help: "Commands handled, by outcome: ok, or error (to be redelivered or dead-lettered).",
		}, []string{"outcome"}),
		duration: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "worker_command_duration_seconds",
			Help:    "Time to handle one command, retries included.",
			Buckets: prometheus.ExponentialBuckets(0.01, 2, 12), // 10 ms to 20 s
		}),
	}
	consumersGauge := prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "worker_consumers",
		Help: "Consumers this process runs: the most commands it can handle at once.",
	})
	consumersGauge.Set(float64(consumers))
	m.registry.MustRegister(m.busy, m.handled, m.duration, consumersGauge,
		collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	return m
}

// observe wraps a handler to count and time each command.
func (m *metrics) observe(next bus.Handler) bus.Handler {
	return func(ctx context.Context, msg messages.Envelope) error {
		m.busy.Inc()
		defer m.busy.Dec()
		start := time.Now()
		err := next(ctx, msg)
		m.duration.Observe(time.Since(start).Seconds())
		outcome := "ok"
		if err != nil {
			outcome = "error"
		}
		m.handled.WithLabelValues(outcome).Inc()
		return err
	}
}

// serve exposes /metrics on addr until the returned function is called.
func (m *metrics) serve(addr string) (func(), error) {
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{}))
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = server.Serve(listener) }()
	return func() { _ = server.Close() }, nil
}
~~~

Wire it in, behind an optional `METRICS_ADDR`. In `cmd/worker/main.go`:

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	FailRate      float64
}
~~~

to:

~~~go
	FailRate      float64
	MetricsAddr   string // empty: no metrics endpoint
}
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	if cfg.FailRate, err = envconfig.Fraction(getenv, "FAIL_RATE", 0); err != nil {
		return config{}, err
~~~

to:

~~~go
	if cfg.FailRate, err = envconfig.Fraction(getenv, "FAIL_RATE", 0); err != nil {
		return config{}, err
	}
	if cfg.MetricsAddr, err = envconfig.HostPort(getenv, "METRICS_ADDR", ""); err != nil {
		return config{}, err
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	events := telemetry.Publisher(client)
	handle := telemetry.Handler(messages.CommandsQueue,
		logged(logger, worker.New(events, work, cfg.JobTimeout).Handle))
~~~

to:

~~~go
	events := telemetry.Publisher(client)
	metrics := newMetrics(cfg.Workers)
	handle := telemetry.Handler(messages.CommandsQueue,
		metrics.observe(logged(logger, worker.New(events, work, cfg.JobTimeout).Handle)))
	if cfg.MetricsAddr != "" {
		stopMetrics, err := metrics.serve(cfg.MetricsAddr)
		if err != nil {
			return err
		}
		defer stopMetrics()
	}
~~~


And test it, in `cmd/worker/main_test.go`:

Change:

<!-- edit: cmd/worker/main_test.go -->
~~~go
	"context"
	"io"
~~~

to:

~~~go
	"context"
	"errors"
	"io"
~~~

Change:

<!-- edit: cmd/worker/main_test.go -->
~~~go
	"testing"
)
~~~

to:

~~~go
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"

	"runway/internal/messages"
)
~~~

Add this at the end of the file:

<!-- append: cmd/worker/main_test.go -->
~~~go
func TestMetricsCountOutcomes(t *testing.T) {
	m := newMetrics(4)
	ok := m.observe(func(context.Context, messages.Envelope) error { return nil })
	failing := m.observe(func(context.Context, messages.Envelope) error { return errors.New("boom") })
	_ = ok(context.Background(), messages.Envelope{})
	_ = ok(context.Background(), messages.Envelope{})
	_ = failing(context.Background(), messages.Envelope{})

	stop, err := m.serve("127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	stop()
	if got := testutil.ToFloat64(m.handled.WithLabelValues("ok")); got != 2 {
		t.Errorf("ok = %v, want 2", got)
	}
	if got := testutil.ToFloat64(m.handled.WithLabelValues("error")); got != 1 {
		t.Errorf("error = %v, want 1", got)
	}
	if got := testutil.ToFloat64(m.busy); got != 0 {
		t.Errorf("busy = %v after every handler returned, want 0", got)
	}
}
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./cmd/worker/... && go test -race -count=1 ./cmd/worker/... -->

### What to scrape

The configuration lives in files under `deploy/prometheus/`, so it can be tested before it runs. Create `deploy/prometheus/prometheus.yml`:

<!-- file: deploy/prometheus/prometheus.yml -->
~~~yaml
# Prometheus finds what to scrape by asking the Kubernetes API, not from a
# list of addresses: Pods come and go, and their IPs change. Each scrape
# job below says what kind of object to discover (role), then relabels:
# rules that keep, drop and rename the discovered targets and their labels.
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules.yml

scrape_configs:
  # Every Pod annotated prometheus.io/scrape: "true", on the port (and
  # path) its other annotations name. A team adds monitoring for a new
  # service by annotating it; nothing here changes.
  - job_name: pods
    kubernetes_sd_configs:
      - role: pod
        namespaces: { names: [runway] }
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        regex: "true"
        action: keep
      # A Pod that is shutting down or not yet running has nothing to say.
      - source_labels: [__meta_kubernetes_pod_phase]
        regex: Running
        action: keep
      - source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
        regex: (.+);(.+)
        replacement: $1:$2
        target_label: __address__
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        regex: (.+)
        target_label: __metrics_path__
      # job="api", "worker", ... from the Pod's app label, so queries read
      # like the service names.
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: job
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace

  # RabbitMQ's per-queue numbers (messages ready, unacknowledged) are on a
  # separate path, with a query parameter an annotation can't express.
  - job_name: rabbitmq
    metrics_path: /metrics/detailed
    params:
      family: [queue_coarse_metrics]
    static_configs:
      - targets: [rabbitmq.runway:15692]

  # Containers' CPU, memory and throttling, as each node's kubelet measures
  # them (cAdvisor). The kubelet wants a client that may read node metrics:
  # this Pod's service account token, allowed by the ClusterRole.
  - job_name: cadvisor
    scheme: https
    metrics_path: /metrics/cadvisor
    kubernetes_sd_configs:
      - role: node
    authorization:
      credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    tls_config:
      # kind's kubelets use self-signed certificates. A real cluster would
      # use its CA: ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      insecure_skip_verify: true
    metric_relabel_configs:
      # cAdvisor reports every container on the node; keep Runway's, and
      # only the series the USE dashboard reads.
      - source_labels: [namespace]
        regex: runway
        action: keep
      - source_labels: [__name__]
        regex: container_(cpu_usage_seconds_total|cpu_cfs_(throttled_)?periods_total|memory_working_set_bytes|spec_cpu_(quota|period)|spec_memory_limit_bytes)
        action: keep
~~~

Three jobs. **pods** keeps only Pods annotated `prometheus.io/scrape: "true"`, and builds each target's address from the Pod's IP and its `prometheus.io/port` annotation; a team adds monitoring for a new service by annotating it, without touching this file. **rabbitmq** reads RabbitMQ's per-queue numbers, which live on a path with a query parameter that an annotation can't express. **cadvisor** reads containers' CPU, memory and throttling from each node's kubelet, keeping only Runway's and only the series the rules use: cAdvisor reports thousands.

Annotate the chart's Pods. In `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
    {{- include "runway.configChecksum" $root | nindent 4 }}
spec:
~~~

to:

~~~yaml
    {{- include "runway.configChecksum" $root | nindent 4 }}
    # Prometheus scrapes Pods that ask to be (step 10).
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: /metrics
spec:
~~~


In `deploy/helm/runway/templates/worker.yaml`, the annotations, the port, and `METRICS_ADDR`:

Change:

<!-- edit: deploy/helm/runway/templates/worker.yaml -->
~~~yaml
        {{- include "runway.configChecksum" . | nindent 8 }}
    spec:
~~~

to:

~~~yaml
        {{- include "runway.configChecksum" . | nindent 8 }}
        prometheus.io/scrape: "true"
        prometheus.io/port: "9100"
    spec:
~~~

Change:

<!-- edit: deploy/helm/runway/templates/worker.yaml -->
~~~yaml
          {{- with include "runway.tracingEnv" (dict "root" $ "service" "worker") | trim }}
          env:
            {{- . | nindent 12 }}
          {{- end }}
~~~

to:

~~~yaml
          env:
            - { name: METRICS_ADDR, value: "0.0.0.0:9100" }
            {{- with include "runway.tracingEnv" (dict "root" $ "service" "worker") | trim }}
            {{- . | nindent 12 }}
            {{- end }}
          ports:
            - { name: metrics, containerPort: 9100 }
~~~


In `deploy/helm/runway/templates/gateway.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/gateway.yaml -->
~~~yaml
      labels: { app: gateway }
    spec:
~~~

to:

~~~yaml
      labels: { app: gateway }
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8001"
    spec:
~~~


And open RabbitMQ's Prometheus port (its plugin is enabled in the image), in `deploy/k8s/rabbitmq.yaml`:

Change:

<!-- edit: deploy/k8s/rabbitmq.yaml -->
~~~yaml
            - { name: management, containerPort: 15672 }
~~~

to:

~~~yaml
            - { name: management, containerPort: 15672 }
            - { name: prometheus, containerPort: 15692 } # step 10
~~~

Change:

<!-- edit: deploy/k8s/rabbitmq.yaml -->
~~~yaml
    - { name: management, port: 15672, targetPort: management }
~~~

to:

~~~yaml
    - { name: management, port: 15672, targetPort: management }
    - { name: prometheus, port: 15692, targetPort: prometheus }
~~~

<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway | grep -c 'prometheus.io/scrape: "true"' | grep -qx 3 -->

### The rules

Create `deploy/prometheus/rules.yml`. Read the comment at the top first, then each group:

<!-- file: deploy/prometheus/rules.yml -->
~~~yaml
# Runway's service level objectives, and the alerts that defend them.
#
# Availability SLO: 99.9% of API requests succeed (are not 5xx), over 30
# days. The error budget is the other 0.1%: about 43 minutes of total
# outage a month, or 0.1% of requests failing all month.
#
# An alert should fire when the budget is being spent fast enough to
# matter, and not otherwise. The burn rate is how fast: 1 spends exactly
# the budget in 30 days; 14.4 spends 2% of it in an hour, all of it in about
# two days. Each alert checks a long window (is this real, and big?) and a
# short one (is it still happening?), so it fires fast and stops soon after
# the problem does. The factors follow Google's SRE Workbook, chapter 5.
groups:
  - name: api-availability
    rules:
      # The fraction of requests that failed, over each window the alerts
      # need. Probes and scrapes aren't users, so they don't count. With no
      # failures at all there are no 5xx series, and the division would
      # give nothing instead of 0: "or vector(0)" supplies the 0.
      - record: api:request_errors:ratio_rate5m
        expr: |
          (sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)", code=~"5.."}[5m])) or vector(0))
          /
          sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)"}[5m]))
      - record: api:request_errors:ratio_rate30m
        expr: |
          (sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)", code=~"5.."}[30m])) or vector(0))
          /
          sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)"}[30m]))
      - record: api:request_errors:ratio_rate1h
        expr: |
          (sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)", code=~"5.."}[1h])) or vector(0))
          /
          sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)"}[1h]))
      - record: api:request_errors:ratio_rate2h
        expr: |
          (sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)", code=~"5.."}[2h])) or vector(0))
          /
          sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)"}[2h]))
      - record: api:request_errors:ratio_rate6h
        expr: |
          (sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)", code=~"5.."}[6h])) or vector(0))
          /
          sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)"}[6h]))
      - record: api:request_errors:ratio_rate1d
        expr: |
          (sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)", code=~"5.."}[1d])) or vector(0))
          /
          sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)"}[1d]))
      - record: api:request_errors:ratio_rate3d
        expr: |
          (sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)", code=~"5.."}[3d])) or vector(0))
          /
          sum(rate(http_requests_total{job="api", route!~"GET /(health|ready|metrics)"}[3d]))

      # Alerts sit in the same group as the rules they read. Rules in a
      # group run in order, one after another; separate groups run
      # independently, so an alert elsewhere could read the previous
      # evaluation's ratio.
      # Page: a person should look now. 2% of the month's budget gone in an
      # hour, or 5% in six hours.
      - alert: ApiErrorBudgetBurn
        expr: |
          (api:request_errors:ratio_rate1h > (14.4 * 0.001) and api:request_errors:ratio_rate5m > (14.4 * 0.001))
          or
          (api:request_errors:ratio_rate6h > (6 * 0.001) and api:request_errors:ratio_rate30m > (6 * 0.001))
        for: 2m
        labels:
          severity: page
          slo: api-availability
        annotations:
          summary: The API is spending its error budget fast
          description: "{{ $value | humanizePercentage }} of API requests are failing (the SLO allows 0.1%)."
          runbook_url: https://github.com/YOU/runway/blob/main/docs/runbooks/api-errors.md
      # Ticket: worth fixing this week, not worth waking anyone. 10% of the
      # budget in a day, or 10% in three days.
      - alert: ApiErrorBudgetBurnSlow
        expr: |
          (api:request_errors:ratio_rate1d > (3 * 0.001) and api:request_errors:ratio_rate2h > (3 * 0.001))
          or
          (api:request_errors:ratio_rate3d > (1 * 0.001) and api:request_errors:ratio_rate6h > (1 * 0.001))
        for: 1h
        labels:
          severity: ticket
          slo: api-availability
        annotations:
          summary: The API is slowly spending its error budget
          description: "{{ $value | humanizePercentage }} of API requests are failing (the SLO allows 0.1%)."

  # Latency SLO: 99% of job submissions (POST /jobs) answer within 250 ms.
  # The histogram's 0.25 bucket counts the requests at or under 250 ms.
  - name: api-latency
    rules:
      - record: api:create_slow:ratio_rate5m
        expr: |
          1 - (
            sum(rate(http_request_duration_seconds_bucket{job="api", route="POST /jobs", le="0.25"}[5m]))
            /
            sum(rate(http_request_duration_seconds_count{job="api", route="POST /jobs"}[5m]))
          )
      - record: api:create_slow:ratio_rate30m
        expr: |
          1 - (
            sum(rate(http_request_duration_seconds_bucket{job="api", route="POST /jobs", le="0.25"}[30m]))
            /
            sum(rate(http_request_duration_seconds_count{job="api", route="POST /jobs"}[30m]))
          )
      - record: api:create_slow:ratio_rate1h
        expr: |
          1 - (
            sum(rate(http_request_duration_seconds_bucket{job="api", route="POST /jobs", le="0.25"}[1h]))
            /
            sum(rate(http_request_duration_seconds_count{job="api", route="POST /jobs"}[1h]))
          )
      - record: api:create_slow:ratio_rate6h
        expr: |
          1 - (
            sum(rate(http_request_duration_seconds_bucket{job="api", route="POST /jobs", le="0.25"}[6h]))
            /
            sum(rate(http_request_duration_seconds_count{job="api", route="POST /jobs"}[6h]))
          )
      - alert: ApiLatencyBudgetBurn
        expr: |
          (api:create_slow:ratio_rate1h > (14.4 * 0.01) and api:create_slow:ratio_rate5m > (14.4 * 0.01))
          or
          (api:create_slow:ratio_rate6h > (6 * 0.01) and api:create_slow:ratio_rate30m > (6 * 0.01))
        for: 2m
        labels:
          severity: page
          slo: api-latency
        annotations:
          summary: Job submissions are too slow
          description: "{{ $value | humanizePercentage }} of POST /jobs took over 250 ms (the SLO allows 1%)."

  # The USE method: for every resource, its Utilization (how busy), its
  # Saturation (how much work is waiting), and its Errors. Recorded here so
  # the dashboard, and you, can read them by name.
  - name: use
    rules:
      # CPU: the share of the limit in use, and how often the kernel paused
      # the container for reaching it (throttling is CPU saturation).
      - record: pod:cpu_utilization:ratio
        expr: |
          sum by (pod) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
          /
          sum by (pod) (container_spec_cpu_quota{container!=""} / container_spec_cpu_period{container!=""})
      - record: pod:cpu_throttled:ratio
        expr: |
          sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{container!=""}[5m]))
          /
          sum by (pod) (rate(container_cpu_cfs_periods_total{container!=""}[5m]))
      - record: pod:memory_utilization:ratio
        expr: |
          sum by (pod) (container_memory_working_set_bytes{container!=""})
          /
          sum by (pod) (container_spec_memory_limit_bytes{container!=""} > 0)
      # Workers: utilization is busy consumers over all of them; saturation
      # is the commands waiting in the queue; errors are failed commands.
      - record: worker:utilization:ratio
        expr: sum(worker_busy_consumers) / sum(worker_consumers)
      - record: queue:messages_ready
        expr: sum by (queue) (rabbitmq_detailed_queue_messages_ready)
      - record: worker:command_errors:rate5m
        expr: sum(rate(worker_commands_total{outcome="error"}[5m]))
      # The database pool: saturation is requests waiting for a connection.
      - record: api:db_pool_waits:rate5m
        expr: sum(rate(db_pool_waits_total{job="api"}[5m]))

      # Commands piling up faster than workers take them. Step 11's
      # controller adds workers before this fires.
      - alert: JobQueueBacklog
        expr: queue:messages_ready{queue="jobs.commands"} > 50
        for: 5m
        labels:
          severity: ticket
        annotations:
          summary: Jobs are waiting for workers
          description: "{{ $value }} commands have waited in jobs.commands for 5 minutes."
~~~

Three details that each came from a failing test, below:
- Each SLI and its alerts are in **one group**. Rules within a group run in order; separate groups run independently, so an alert in another group may read the *previous* evaluation's ratio. My first version split them, and the same test gave a different alert value on different runs.
- The error ratio's numerator has **`or vector(0)`**. With no failures at all there are no 5xx series, `sum(...)` returns *nothing* rather than 0, and nothing divided by something is nothing: the dashboard showed "No data" for a perfectly healthy service.
- Probes and scrapes are excluded from the SLI: a failing readiness probe is not a failing user.

### Test the rules

Alert rules are code that runs only during incidents, which is the worst time to find a bug in them. `promtool`, which ships in the Prometheus image, can feed made-up series to rules and check which alerts fire, and when. Create `deploy/prometheus/rules_test.yml`:

<!-- file: deploy/prometheus/rules_test.yml -->
~~~yaml
# Tests for rules.yml. Each test feeds Prometheus made-up series, one
# sample a minute, then checks which alerts fire, and when. Run them with:
#   promtool test rules deploy/prometheus/rules_test.yml
# "0+600x120" means: start at 0, add 600 each minute, 120 times. "_" is a
# missing sample.
rule_files:
  - rules.yml

evaluation_interval: 1m

tests:
  # An outage: every request fails from minute 60. The fast-burn alert
  # pages within minutes, not an hour.
  - name: an outage pages quickly
    interval: 1m
    input_series:
      - series: 'http_requests_total{job="api", route="POST /jobs", code="201"}'
        values: '0+600x60 36000x60'
      - series: 'http_requests_total{job="api", route="POST /jobs", code="500"}'
        values: '0x60 0+600x60'
    alert_rule_test:
      - eval_time: 61m
        alertname: ApiErrorBudgetBurn
        exp_alerts: [] # pending: it must hold for 2 minutes first
      - eval_time: 65m
        alertname: ApiErrorBudgetBurn
        exp_alerts:
          - exp_labels: { severity: page, slo: api-availability }
            exp_annotations:
              summary: The API is spending its error budget fast
              description: "6.789% of API requests are failing (the SLO allows 0.1%)."
              runbook_url: https://github.com/YOU/runway/blob/main/docs/runbooks/api-errors.md

  # Six healthy hours, then one minute with half the requests failing. That
  # spends under 1% of the month's budget: neither pair of windows crosses
  # its threshold, so nobody is woken. (A whole minute of total failure
  # would page: that is 2.3% of the budget, in a minute.)
  - name: a small blip does not page
    interval: 1m
    input_series:
      - series: 'http_requests_total{job="api", route="POST /jobs", code="201"}'
        values: '0+600x360 216300+600x30'
      - series: 'http_requests_total{job="api", route="POST /jobs", code="500"}'
        values: '0x360 300x30'
    alert_rule_test:
      - eval_time: 363m
        alertname: ApiErrorBudgetBurn
        exp_alerts: []
      - eval_time: 366m
        alertname: ApiErrorBudgetBurn
        exp_alerts: []
      - eval_time: 380m
        alertname: ApiErrorBudgetBurn
        exp_alerts: []

  # 0.5% failing, steadily: five times the budget. Not an emergency, but
  # left alone it spends the month's budget in six days.
  - name: a slow burn opens a ticket, and does not page
    interval: 1m
    input_series:
      - series: 'http_requests_total{job="api", route="POST /jobs", code="201"}'
        values: '0+597x300'
      - series: 'http_requests_total{job="api", route="POST /jobs", code="500"}'
        values: '0+3x300'
    alert_rule_test:
      - eval_time: 4h
        alertname: ApiErrorBudgetBurn
        exp_alerts: []
      - eval_time: 4h
        alertname: ApiErrorBudgetBurnSlow
        exp_alerts:
          - exp_labels: { severity: ticket, slo: api-availability }
            exp_annotations:
              summary: The API is slowly spending its error budget
              description: "0.5% of API requests are failing (the SLO allows 0.1%)."

  # Probes don't count: a failing readiness probe is not a failing user.
  - name: probes are not users
    interval: 1m
    input_series:
      - series: 'http_requests_total{job="api", route="POST /jobs", code="201"}'
        values: '0+600x60'
      - series: 'http_requests_total{job="api", route="GET /ready", code="503"}'
        values: '0+600x60'
    promql_expr_test:
      - expr: api:request_errors:ratio_rate5m
        eval_time: 30m
        exp_samples:
          - labels: 'api:request_errors:ratio_rate5m'
            value: 0

  - name: a backed-up queue raises a ticket
    interval: 1m
    input_series:
      - series: 'rabbitmq_detailed_queue_messages_ready{queue="jobs.commands"}'
        values: '0 80x10'
    alert_rule_test:
      - eval_time: 4m
        alertname: JobQueueBacklog
        exp_alerts: []
      - eval_time: 8m
        alertname: JobQueueBacklog
        exp_alerts:
          - exp_labels: { severity: ticket, queue: jobs.commands }
            exp_annotations:
              summary: Jobs are waiting for workers
              description: "80 commands have waited in jobs.commands for 5 minutes."
~~~

<!-- run: docker run --rm -v "$PWD/deploy/prometheus:/etc/prometheus" -w /etc/prometheus --entrypoint promtool prom/prometheus:v3.15.0 check config --syntax-only prometheus.yml && docker run --rm -v "$PWD/deploy/prometheus:/etc/prometheus" -w /etc/prometheus --entrypoint promtool prom/prometheus:v3.15.0 test rules rules_test.yml -->

~~~bash
promtool() { docker run --rm -v "$PWD/deploy/prometheus:/etc/prometheus" -w /etc/prometheus --entrypoint promtool prom/prometheus:v3.15.0 "$@"; }
promtool check config --syntax-only prometheus.yml
promtool test rules rules_test.yml
~~~

~~~text
Checking prometheus.yml
 SUCCESS: prometheus.yml is valid prometheus config file syntax

  SUCCESS
~~~

(`--syntax-only` because the full check opens the service-account token file, which exists only inside a Pod.) Two things the tests taught me, beyond the bugs above:
- An outage that starts at minute 60 pages at minute 65: the 1-hour ratio crosses 1.44% within a minute, and `for: 2m` waits two evaluations more. At that point 6.8% of the last hour's requests had failed.
- My first "a blip doesn't page" test, two minutes of total failure, *did* page, through the 6h/30m pair. Two minutes of total failure is about 4.6% of a month's budget, and the workbook's table says that deserves a page. The test was wrong, not the rule. The test now uses half the requests failing for one minute, which spends under 1%.

Run the tests in CI too. In `.github/workflows/ci.yml`:

Change:

<!-- edit: .github/workflows/ci.yml -->
~~~yaml
      - run: helm lint deploy/helm/runway

~~~

to:

~~~yaml
      - run: helm lint deploy/helm/runway
      # promtool ships in the Prometheus image. A broken rule fails here,
      # not silently at 3 a.m. when the alert should have fired.
      - name: Check the Prometheus config, and test the alert rules
        run: |
          promtool() { docker run --rm -v "$PWD/deploy/prometheus:/etc/prometheus" -w /etc/prometheus --entrypoint promtool prom/prometheus:v3.15.0 "$@"; }
          promtool check config --syntax-only prometheus.yml
          promtool test rules rules_test.yml

~~~


### Prometheus and Grafana on the cluster

Create `deploy/k8s/monitoring.yaml`. Prometheus needs permission to list Pods and nodes, and to read node metrics: a ServiceAccount, a ClusterRole and a binding, the same mechanism step 11 uses for your own controller.

<!-- file: deploy/k8s/monitoring.yaml -->
~~~yaml
# Prometheus and Grafana, in the observability namespace (from step 9).
#
# Their configuration lives in files under deploy/prometheus and
# deploy/grafana, so promtool can test it. Load those into ConfigMaps first:
#   kubectl -n observability create configmap prometheus --from-file=deploy/prometheus/ --dry-run=client -o yaml | kubectl apply -f -
#   kubectl -n observability create configmap grafana-dashboards --from-file=deploy/grafana/ --dry-run=client -o yaml | kubectl apply -f -

# Prometheus asks the Kubernetes API what to scrape, and reads containers'
# numbers from each node's kubelet. Both need permission: a ServiceAccount
# for the Pod, a ClusterRole saying what it may read, cluster-wide, and a
# binding between the two.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
  - apiGroups: [""]
    resources: [pods, nodes]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [nodes/metrics] # the kubelet's /metrics/cadvisor
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: observability
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels: { app: prometheus }
  template:
    metadata:
      labels: { app: prometheus }
    spec:
      serviceAccountName: prometheus
      containers:
        - name: prometheus
          image: prom/prometheus:v3.15.0
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.retention.time=3d # the longest SLO window
            # POST /-/reload re-reads the config and rules without a restart.
            - --web.enable-lifecycle
          ports:
            - { name: http, containerPort: 9090 }
          readinessProbe:
            httpGet: { path: /-/ready, port: http }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { memory: 1Gi }
          volumeMounts:
            - { name: config, mountPath: /etc/prometheus }
            - { name: data, mountPath: /prometheus }
      volumes:
        - name: config
          configMap: { name: prometheus }
        # Lost when the Pod is replaced. Real setups keep it on a volume.
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: observability
spec:
  selector: { app: prometheus }
  ports:
    - { name: http, port: 9090, targetPort: http }
---
# Grafana reads its data source and dashboards from files at start-up
# ("provisioning"), so a fresh Grafana comes up already set up.
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-provisioning
  namespace: observability
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        uid: prometheus
        type: prometheus
        url: http://prometheus.observability:9090
        isDefault: true
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: runway
        options:
          path: /var/lib/grafana/dashboards
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels: { app: grafana }
  template:
    metadata:
      labels: { app: grafana }
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:13.2.3
          env:
            # No login, for a local cluster only: anyone who can reach the
            # port can change anything.
            - { name: GF_AUTH_ANONYMOUS_ENABLED, value: "true" }
            - { name: GF_AUTH_ANONYMOUS_ORG_ROLE, value: Admin }
            - { name: GF_AUTH_DISABLE_LOGIN_FORM, value: "true" }
          ports:
            - { name: http, containerPort: 3000 }
          readinessProbe:
            httpGet: { path: /api/health, port: http }
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { memory: 512Mi }
          volumeMounts:
            - { name: datasources, mountPath: /etc/grafana/provisioning/datasources }
            - { name: providers, mountPath: /etc/grafana/provisioning/dashboards }
            - { name: dashboards, mountPath: /var/lib/grafana/dashboards }
      volumes:
        - name: datasources
          configMap:
            name: grafana-provisioning
            items: [{ key: datasources.yaml, path: datasources.yaml }]
        - name: providers
          configMap:
            name: grafana-provisioning
            items: [{ key: dashboards.yaml, path: dashboards.yaml }]
        - name: dashboards
          configMap: { name: grafana-dashboards }
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: observability
spec:
  selector: { app: grafana }
  ports:
    - { name: http, port: 3000, targetPort: http }
~~~

Grafana reads its data source and dashboards from files at start-up. Create the dashboard, `deploy/grafana/runway.json`. You would normally build a dashboard in Grafana's editor and export it; this is the exported file, so the guide is complete. It has three rows: the SLO (availability and burn rates, with the alert thresholds as lines), RED for job submissions (rate, errors, duration), and USE (CPU, throttling, memory, busy workers, waiting commands, errors and database pool waits).

<!-- file: deploy/grafana/runway.json -->
~~~json
{
  "uid": "runway",
  "title": "Runway",
  "schemaVersion": 41,
  "time": {
    "from": "now-30m",
    "to": "now"
  },
  "refresh": "10s",
  "panels": [
    {
      "type": "row",
      "title": "SLO: 99.9% of API requests succeed",
      "gridPos": {
        "x": 0,
        "y": 0,
        "w": 24,
        "h": 1
      },
      "collapsed": false,
      "panels": []
    },
    {
      "type": "stat",
      "title": "Availability, last hour",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 1,
        "w": 6,
        "h": 5
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "1 - api:request_errors:ratio_rate1h",
          "legendFormat": ""
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 0.999
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {},
      "description": "Requests that did not fail, over the last hour. The SLO is 99.9% over 30 days."
    },
    {
      "type": "stat",
      "title": "Burn rate, last hour",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 6,
        "y": 1,
        "w": 6,
        "h": 5
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "api:request_errors:ratio_rate1h / 0.001",
          "legendFormat": ""
        }
      ],
      "fieldConfig": {
        "defaults": {
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "yellow",
                "value": 1
              },
              {
                "color": "red",
                "value": 14.4
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {},
      "description": "1 spends exactly the month's error budget in 30 days. 14.4 spends 2% of it in an hour: a page."
    },
    {
      "type": "timeseries",
      "title": "Burn rate by window",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 1,
        "w": 12,
        "h": 5
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "api:request_errors:ratio_rate5m / 0.001",
          "legendFormat": "5m"
        },
        {
          "refId": "B",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "api:request_errors:ratio_rate1h / 0.001",
          "legendFormat": "1h"
        },
        {
          "refId": "C",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "api:request_errors:ratio_rate6h / 0.001",
          "legendFormat": "6h"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "transparent",
                "value": null
              },
              {
                "color": "orange",
                "value": 6
              },
              {
                "color": "red",
                "value": 14.4
              }
            ]
          },
          "custom": {
            "thresholdsStyle": {
              "mode": "line"
            }
          }
        },
        "overrides": []
      },
      "options": {},
      "description": "The page fires when a long window and its short window both cross a line: 1h and 5m above 14.4, or 6h and 30m above 6."
    },
    {
      "type": "row",
      "title": "Requests (RED: rate, errors, duration)",
      "gridPos": {
        "x": 0,
        "y": 6,
        "w": 24,
        "h": 1
      },
      "collapsed": false,
      "panels": []
    },
    {
      "type": "timeseries",
      "title": "Requests per second",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 7,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "sum by (route, code) (rate(http_requests_total{job=\"api\", route!~\"GET /(health|ready|metrics)\"}[1m]))",
          "legendFormat": "{{route}} {{code}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "reqps"
        },
        "overrides": []
      },
      "options": {}
    },
    {
      "type": "timeseries",
      "title": "POST /jobs latency",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 7,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "histogram_quantile(0.5, sum by (le) (rate(http_request_duration_seconds_bucket{job=\"api\", route=\"POST /jobs\"}[5m])))",
          "legendFormat": "p50"
        },
        {
          "refId": "B",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{job=\"api\", route=\"POST /jobs\"}[5m])))",
          "legendFormat": "p99"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "transparent",
                "value": null
              },
              {
                "color": "red",
                "value": 0.25
              }
            ]
          },
          "custom": {
            "thresholdsStyle": {
              "mode": "line"
            }
          }
        },
        "overrides": []
      },
      "options": {},
      "description": "The latency SLO: 99% under 250 ms."
    },
    {
      "type": "row",
      "title": "Resources (USE: utilization, saturation, errors)",
      "gridPos": {
        "x": 0,
        "y": 15,
        "w": 24,
        "h": 1
      },
      "collapsed": false,
      "panels": []
    },
    {
      "type": "timeseries",
      "title": "CPU utilization (of limit)",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 16,
        "w": 8,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "pod:cpu_utilization:ratio",
          "legendFormat": "{{pod}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit"
        },
        "overrides": []
      },
      "options": {}
    },
    {
      "type": "timeseries",
      "title": "CPU throttled (saturation)",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 8,
        "y": 16,
        "w": 8,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "pod:cpu_throttled:ratio",
          "legendFormat": "{{pod}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit"
        },
        "overrides": []
      },
      "options": {},
      "description": "Share of scheduling periods in which the kernel paused the container for reaching its CPU limit."
    },
    {
      "type": "timeseries",
      "title": "Memory utilization (of limit)",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 16,
        "y": 16,
        "w": 8,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "pod:memory_utilization:ratio",
          "legendFormat": "{{pod}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit"
        },
        "overrides": []
      },
      "options": {},
      "description": "At 100% the kernel kills the container (exit 137, step 1)."
    },
    {
      "type": "timeseries",
      "title": "Workers busy (utilization)",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 24,
        "w": 8,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "worker:utilization:ratio",
          "legendFormat": "busy / consumers"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit",
          "max": 1,
          "min": 0
        },
        "overrides": []
      },
      "options": {}
    },
    {
      "type": "timeseries",
      "title": "Commands waiting (saturation)",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 8,
        "y": 24,
        "w": 8,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "queue:messages_ready{queue=\"jobs.commands\"}",
          "legendFormat": "jobs.commands"
        }
      ],
      "fieldConfig": {
        "defaults": {},
        "overrides": []
      },
      "options": {}
    },
    {
      "type": "timeseries",
      "title": "Errors and waits",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 16,
        "y": 24,
        "w": 8,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "worker:command_errors:rate5m",
          "legendFormat": "failed commands/s"
        },
        {
          "refId": "B",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "api:db_pool_waits:rate5m",
          "legendFormat": "waits for a DB connection/s"
        }
      ],
      "fieldConfig": {
        "defaults": {},
        "overrides": []
      },
      "options": {}
    }
  ],
  "tags": [
    "runway"
  ]
}
~~~

Load the files into ConfigMaps, and apply:

~~~bash
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
kubectl apply -f deploy/k8s/rabbitmq.yaml
kubectl -n observability create configmap prometheus --from-file=deploy/prometheus/ --dry-run=client -o yaml | kubectl apply -f -
kubectl -n observability create configmap grafana-dashboards --from-file=deploy/grafana/ --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f deploy/k8s/monitoring.yaml
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait
~~~

**A trap with `kind load`.** Pull `prom/prometheus` and `grafana/grafana` into Docker first, and load them one command each. I loaded three images in one `kind load` while one was still downloading; the whole command failed quietly (I'd sent its output to `/dev/null`), so the nodes kept the *old* `runway:dev`, and with `imagePullPolicy: IfNotPresent` and an unchanged tag, Kubernetes happily kept running it. The workers' new metrics port refused connections, and it took a while to see why. That is the mutable-tag problem of step 8 again, on your own machine.

Check the targets, through a port-forward (`kubectl -n observability port-forward svc/prometheus 9090:9090`), at http://localhost:9090/targets, or:

~~~bash
curl -s localhost:9090/api/v1/targets | python3 -c '
import json, sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    l = t["labels"]; print(l.get("job"), l.get("pod", l.get("instance")), t["health"])' | sort
~~~

~~~text
api api-6d599bf5f8-l4fmt up
api api-6d599bf5f8-psk5h up
api api-6d599bf5f8-wj25q up
cadvisor runway-control-plane up
cadvisor runway-worker up
cadvisor runway-worker2 up
gateway gateway-65d4f84f86-9fcgq up
rabbitmq rabbitmq.runway:15692 up
worker worker-6756d89479-hln8t up
worker worker-6756d89479-tmv7g up
~~~

Ten targets, all found by discovery. Open Grafana (`kubectl -n observability port-forward svc/grafana 3000:3000`, then http://localhost:3000/d/runway) to see the dashboard.

### Run it: an outage, and the page

Send steady load, take PostgreSQL away for five minutes, and watch the SLI and the alerts every 30 seconds (kload from its own directory; the watching is two `curl`s to Prometheus's `/api/v1/query` and `/api/v1/alerts`):

~~~bash
uv run kload load --url http://localhost:8080 --target create --rate 20 --duration 780 --out results/outage.csv &
sleep 120; kubectl -n runway scale statefulset postgres --replicas=0
sleep 300; kubectl -n runway scale statefulset postgres --replicas=1
~~~

~~~text
14:04:05 healthy        errors5m=0.0%    errors1h=0.0%    alerts=none
14:04:35 >>> kubectl -n runway scale statefulset postgres --replicas=0
14:05:07 postgres down  errors5m=0.0%    errors1h=0.0%    alerts=none
14:05:37 postgres down  errors5m=28.73%  errors1h=28.73%  alerts=ApiErrorBudgetBurn=pending,ApiErrorBudgetBurnSlow=pending
14:06:38 postgres down  errors5m=44.32%  errors1h=44.32%  alerts=ApiErrorBudgetBurn=pending,ApiErrorBudgetBurnSlow=pending
14:07:12 postgres down  errors5m=50.3%   errors1h=50.3%   alerts=ApiErrorBudgetBurn=firing,ApiErrorBudgetBurnSlow=pending
14:09:17 postgres down  errors5m=86.91%  errors1h=60.96%  alerts=ApiErrorBudgetBurn=firing,ApiErrorBudgetBurnSlow=pending
14:09:47 >>> kubectl -n runway scale statefulset postgres --replicas=1
14:12:53 recovering     errors5m=37.31%  errors1h=46.31%  alerts=ApiErrorBudgetBurn=firing,ApiErrorBudgetBurnSlow=pending
14:15:26 recovering     errors5m=0.49%   errors1h=35.97%  alerts=ApiErrorBudgetBurn=firing,ApiErrorBudgetBurnSlow=pending
~~~

The page went **pending a minute** after the database went, and **fired two and a half minutes** after: the time for the 1-hour ratio to cross the line, plus `for: 2m`. After recovery it kept firing until the 5-minute window had moved past the failures, then resolved. Two more things to notice:
- The 5-minute and 1-hour ratios are *equal* at first. This Prometheus had only been running a few minutes, so its "1 hour" held a few minutes of data. A fresh Prometheus inflates every long window, and the slow-burn alert went pending for the same reason. Real alerting needs history.
- kload's per-second results show requests alternating between 10-second timeouts and fast failures during the outage: the database circuit breaker of Phase 2 cycling, failing fast while open and letting a trial request through every ten seconds. PostgreSQL was ready six seconds after being scaled back up, and errors stopped about four seconds after that.

**Explain it:** what is the difference between an SLI, an SLO and an error budget? Why does the page need two windows, and why those two? Why was the alert still firing after PostgreSQL came back? Why did recording rules and alerts need to share a group? Name the U, the S and the E for Runway's workers.

**Read.** *Site Reliability Engineering*, chapter 4 (*Service Level Objectives*) and chapter 6 (*Monitoring Distributed Systems*). The *Site Reliability Workbook*, chapter 2 (*Implementing SLOs*) and chapter 5 (*Alerting on SLOs*), the source of this step's alerts: read its table of burn rates and windows. Brendan Gregg, [*The USE Method*](https://www.brendangregg.com/usemethod.html). Then *Systems Performance* (Gregg, 2nd edition), chapter 2, on methodologies.

---

## Step 11: A controller of your own

**The problem.** Two workers are wasteful at night and too few during a burst. The number should follow the work waiting. Kubernetes' Horizontal Pod Autoscaler scales on CPU and memory out of the box; Runway's workers spend their time *waiting* on jobs, not using CPU, and the honest signal is the queue. You could install KEDA, which does exactly this. You'll write it instead, because it's the clearest way to understand what every controller in Kubernetes does, and it is less code than you'd think.

**New ideas.**

- **A controller is a loop: observe, compare, act.** Read the current state, compute the desired state, change the world to close the gap, repeat. It is **level-triggered**: each pass looks at the whole situation, not at what changed since the last pass. So a missed pass, a repeated one, or a restart after a crash all still converge.
- **The scale subresource.** A Deployment's replica count can be read and changed through `deployments/scale` alone, so a controller that only scales needs no permission to rewrite the whole Deployment.
- **Stabilization.** Scaling down too soon means scaling up again a second later (flapping). Like the HPA, scale up at once, and scale down only to the *largest* recommendation of the last minute.
- **RBAC.** A Pod's ServiceAccount, a Role listing what it may do, and a RoleBinding between them. Grant the least that works, down to the names of the objects.
- **One owner per field.** If a Helm chart sets `replicas` and the controller sets `replicas`, they overwrite each other on every upgrade.

<!-- run: go get k8s.io/client-go@v0.37.1 k8s.io/api@v0.37.1 k8s.io/apimachinery@v0.37.1 -->

~~~bash
go get k8s.io/client-go@v0.37.1 k8s.io/api@v0.37.1 k8s.io/apimachinery@v0.37.1
~~~

### The control loop

The policy and the loop have no Kubernetes or RabbitMQ in them: just a `Source` of backlog and a `Target` to scale. Create `internal/autoscale/autoscale.go`:

<!-- file: internal/autoscale/autoscale.go -->
~~~go
// Package autoscale is a controller: a loop that observes the world,
// compares it with what it should be, and acts to close the gap. Here, it
// sizes the worker Deployment to the commands waiting for it.
//
// A controller is level-triggered: each pass looks at the whole current
// state, not at what changed since the last pass. A pass that is missed,
// repeated or run after a crash still converges, so the loop needs no
// memory of its own beyond its stabilization window.
package autoscale

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

// Source reports the backlog: commands waiting plus commands in progress.
type Source interface {
	Backlog(ctx context.Context) (int, error)
}

// Target is the thing being scaled.
type Target interface {
	Replicas(ctx context.Context) (int32, error)
	Scale(ctx context.Context, replicas int32) error
}

// Policy decides how many workers a backlog needs.
type Policy struct {
	PerReplica int   // backlog each replica should carry: its consumers, plus some waiting
	Min, Max   int32 // never fewer, never more
	// ScaleDownAfter is how long the backlog must stay low before removing
	// workers. Scaling up is immediate; scaling down waits, so a moment's
	// lull between bursts doesn't drain workers that are needed again a
	// second later (flapping).
	ScaleDownAfter time.Duration
}

// Desired returns the replicas for backlog: enough that each carries at
// most PerReplica, within [Min, Max].
func (p Policy) Desired(backlog int) int32 {
	n := int32((backlog + p.PerReplica - 1) / p.PerReplica) // rounded up
	return min(max(n, p.Min), p.Max)
}

// Controller runs the policy against a source and a target.
type Controller struct {
	policy Policy
	source Source
	target Target
	logger *slog.Logger
	now    func() time.Time

	// recent holds each pass's recommendation within ScaleDownAfter. The
	// controller scales down only to the largest of them: the fewest
	// workers that would have been enough for the whole window.
	recent []recommendation
}

type recommendation struct {
	at       time.Time
	replicas int32
}

func New(policy Policy, source Source, target Target, logger *slog.Logger) *Controller {
	return &Controller{policy: policy, source: source, target: target, logger: logger, now: time.Now}
}

// Decision is what one pass saw and did.
type Decision struct {
	Backlog          int
	Current, Desired int32
	Scaled           bool
}

// Reconcile makes one pass: observe, compare, act.
func (c *Controller) Reconcile(ctx context.Context) (Decision, error) {
	backlog, err := c.source.Backlog(ctx)
	if err != nil {
		return Decision{}, fmt.Errorf("read backlog: %w", err)
	}
	current, err := c.target.Replicas(ctx)
	if err != nil {
		return Decision{}, fmt.Errorf("read replicas: %w", err)
	}
	now := c.now()
	// More replicas than anything in the window: the controller just
	// started, or someone scaled up by hand. Treat that count as a
	// recommendation too, so it too must wait out the window before
	// coming down.
	if current > c.highestRecent() {
		c.remember(now, current)
	}
	wanted := c.policy.Desired(backlog)
	c.remember(now, wanted)

	d := Decision{Backlog: backlog, Current: current, Desired: current}
	switch {
	case wanted > current:
		d.Desired = wanted // more work than workers: act now
	case wanted < current:
		// Less work: go down, but only as far as every recommendation in
		// the window allows.
		d.Desired = c.highestRecent()
	}
	if d.Desired == current {
		return d, nil
	}
	if err := c.target.Scale(ctx, d.Desired); err != nil {
		return d, fmt.Errorf("scale to %d: %w", d.Desired, err)
	}
	d.Scaled = true
	c.logger.Info("scaled workers", "backlog", backlog, "from", current, "to", d.Desired)
	return d, nil
}

func (c *Controller) remember(now time.Time, replicas int32) {
	cutoff := now.Add(-c.policy.ScaleDownAfter)
	kept := c.recent[:0]
	for _, r := range c.recent {
		if r.at.After(cutoff) {
			kept = append(kept, r)
		}
	}
	c.recent = append(kept, recommendation{at: now, replicas: replicas})
}

func (c *Controller) highestRecent() int32 {
	highest := c.policy.Min
	for _, r := range c.recent {
		highest = max(highest, r.replicas)
	}
	return highest
}

// Run reconciles every interval until ctx is done. A failed pass is logged
// and the next one tries again: the loop itself is the retry.
func (c *Controller) Run(ctx context.Context, every time.Duration) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		if _, err := c.Reconcile(ctx); err != nil {
			c.logger.Warn("reconcile failed; will retry", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
~~~

The first version had a bug the tests below caught. With an empty window on its first pass, a freshly started controller would scale 9 workers down to 5 immediately, during what might be a lull between bursts. Now a replica count above everything in the window counts as a recommendation too, so a restart (or someone running `kubectl scale` by hand) waits out the window like everything else.

The real source and target. The backlog is ready messages *plus* messages a consumer holds unacknowledged; AMQP itself can count only the first, so a queue whose every message is being worked on would look empty. RabbitMQ's management API reports both. Create `internal/autoscale/sources.go`:

<!-- file: internal/autoscale/sources.go -->
~~~go
package autoscale

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"

	autoscalingv1 "k8s.io/api/autoscaling/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// RabbitQueue reads a queue's backlog from RabbitMQ's management API.
// AMQP itself can count the messages waiting, but not the ones a consumer
// holds unacknowledged: a busy worker's job would look like no work at all.
type RabbitQueue struct {
	BaseURL  string // http://rabbitmq:15672
	User     string
	Password string
	VHost    string // "/" by default
	Queue    string
	Client   *http.Client
}

func (q RabbitQueue) Backlog(ctx context.Context) (int, error) {
	vhost := q.VHost
	if vhost == "" {
		vhost = "/"
	}
	u := fmt.Sprintf("%s/api/queues/%s/%s", q.BaseURL, url.PathEscape(vhost), url.PathEscape(q.Queue))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return 0, err
	}
	req.SetBasicAuth(q.User, q.Password)
	client := q.Client
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("GET %s: %s", u, resp.Status)
	}
	var body struct {
		Ready   int `json:"messages_ready"`
		Unacked int `json:"messages_unacknowledged"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return 0, err
	}
	return body.Ready + body.Unacked, nil
}

// Deployment scales a Deployment through its scale subresource. That needs
// permission only to read and change the replica count, not to rewrite the
// whole Deployment: see the Role in the chart.
type Deployment struct {
	Client    kubernetes.Interface
	Namespace string
	Name      string
}

func (d Deployment) Replicas(ctx context.Context) (int32, error) {
	scale, err := d.Client.AppsV1().Deployments(d.Namespace).GetScale(ctx, d.Name, metav1.GetOptions{})
	if err != nil {
		return 0, err
	}
	return scale.Spec.Replicas, nil
}

func (d Deployment) Scale(ctx context.Context, replicas int32) error {
	scale := &autoscalingv1.Scale{
		ObjectMeta: metav1.ObjectMeta{Name: d.Name, Namespace: d.Namespace},
		Spec:       autoscalingv1.ScaleSpec{Replicas: replicas},
	}
	_, err := d.Client.AppsV1().Deployments(d.Namespace).UpdateScale(ctx, d.Name, scale, metav1.UpdateOptions{FieldManager: "runway-autoscaler"})
	return err
}
~~~

### Testing against a fake API server

client-go has a **fake clientset**: an in-memory API server that answers the same calls, so the controller's real code runs in a test. Almost the same calls: it doesn't implement the scale subresource, and returns the Deployment where a Scale is expected (the test panicked until I found out). Two *reactors* teach it, reading and writing the replica count as the real API server does. Create `internal/autoscale/autoscale_test.go`:

<!-- file: internal/autoscale/autoscale_test.go -->
~~~go
package autoscale

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	autoscalingv1 "k8s.io/api/autoscaling/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
)

func TestDesired(t *testing.T) {
	p := Policy{PerReplica: 8, Min: 2, Max: 10}
	for backlog, want := range map[int]int32{
		0:    2, // never below Min
		16:   2, // 16 / 8 = 2
		17:   3, // rounded up: 17 needs a third replica
		40:   5,
		1000: 10, // never above Max
	} {
		if got := p.Desired(backlog); got != want {
			t.Errorf("Desired(%d) = %d, want %d", backlog, got, want)
		}
	}
}

type backlog int

func (b *backlog) Backlog(context.Context) (int, error) { return int(*b), nil }

// newWorkers is a worker Deployment in a fake API server: client-go's fake
// clientset keeps objects in memory and answers the same calls a real
// cluster would, so the controller's real code runs against it.
//
// Almost the same calls: the fake doesn't implement the scale subresource,
// so two reactors teach it, reading and writing the Deployment's replicas
// as the real API server does.
func newWorkers(t *testing.T, replicas int32) Deployment {
	t.Helper()
	client := fake.NewClientset(&appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: "worker", Namespace: "runway"},
		Spec:       appsv1.DeploymentSpec{Replicas: &replicas},
	})
	deployments := appsv1.SchemeGroupVersion.WithResource("deployments")
	client.PrependReactor("get", "deployments", func(action k8stesting.Action) (bool, runtime.Object, error) {
		get := action.(k8stesting.GetAction)
		if get.GetSubresource() != "scale" {
			return false, nil, nil // not ours: let the default handle it
		}
		obj, err := client.Tracker().Get(deployments, get.GetNamespace(), get.GetName())
		if err != nil {
			return true, nil, err
		}
		d := obj.(*appsv1.Deployment)
		return true, &autoscalingv1.Scale{
			ObjectMeta: metav1.ObjectMeta{Name: d.Name, Namespace: d.Namespace},
			Spec:       autoscalingv1.ScaleSpec{Replicas: *d.Spec.Replicas},
		}, nil
	})
	client.PrependReactor("update", "deployments", func(action k8stesting.Action) (bool, runtime.Object, error) {
		update := action.(k8stesting.UpdateAction)
		if update.GetSubresource() != "scale" {
			return false, nil, nil
		}
		scale := update.GetObject().(*autoscalingv1.Scale)
		obj, err := client.Tracker().Get(deployments, update.GetNamespace(), scale.Name)
		if err != nil {
			return true, nil, err
		}
		d := obj.(*appsv1.Deployment).DeepCopy()
		d.Spec.Replicas = &scale.Spec.Replicas
		return true, scale, client.Tracker().Update(deployments, d, d.Namespace)
	})
	return Deployment{Client: client, Namespace: "runway", Name: "worker"}
}

func replicasOf(t *testing.T, d Deployment) int32 {
	t.Helper()
	n, err := d.Replicas(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return n
}

type clock struct{ t time.Time }

func (c *clock) now() time.Time          { return c.t }
func (c *clock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newController(src Source, target Target) (*Controller, *clock) {
	c := New(Policy{PerReplica: 8, Min: 2, Max: 10, ScaleDownAfter: time.Minute}, src, target,
		slog.New(slog.NewTextHandler(io.Discard, nil)))
	clk := &clock{t: time.Unix(0, 0)}
	c.now = clk.now
	return c, clk
}

func TestScalesUpAtOnce(t *testing.T) {
	work := backlog(40)
	workers := newWorkers(t, 2)
	c, _ := newController(&work, workers)
	d, err := c.Reconcile(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !d.Scaled || replicasOf(t, workers) != 5 {
		t.Fatalf("decision %+v, replicas %d; want 5 at once", d, replicasOf(t, workers))
	}
}

// After a burst, the backlog drops. The controller must wait out the
// window before removing workers, and then remove them.
func TestScalesDownOnlyAfterTheWindow(t *testing.T) {
	work := backlog(80)
	workers := newWorkers(t, 2)
	c, clk := newController(&work, workers)
	ctx := context.Background()
	_, _ = c.Reconcile(ctx) // up to 10

	work = 0
	for range 5 { // 50 seconds of an empty queue
		clk.advance(10 * time.Second)
		if _, err := c.Reconcile(ctx); err != nil {
			t.Fatal(err)
		}
		if got := replicasOf(t, workers); got != 10 {
			t.Fatalf("after %v: %d replicas; want 10 until the window passes", clk.t.Sub(time.Unix(0, 0)), got)
		}
	}
	clk.advance(15 * time.Second) // the burst's recommendation is now over a minute old
	if _, err := c.Reconcile(ctx); err != nil {
		t.Fatal(err)
	}
	if got := replicasOf(t, workers); got != 2 {
		t.Fatalf("after the window: %d replicas, want 2", got)
	}
}

// A pass that changes nothing writes nothing: no needless API calls, and
// no fighting over a value that is already right.
func TestAQuietPassWritesNothing(t *testing.T) {
	work := backlog(10)
	workers := newWorkers(t, 2)
	c, _ := newController(&work, workers)
	d, err := c.Reconcile(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	actions := workers.Client.(*fake.Clientset).Actions()
	for _, a := range actions {
		if a.GetVerb() == "update" {
			t.Fatalf("decision %+v, but the controller wrote: %v", d, a)
		}
	}
}

// Someone scales up by hand, or the controller restarts with more replicas
// than it would choose. Either way it waits out the window before scaling
// down, then puts the count back where the policy says: the controller
// owns the replica count.
func TestExtraReplicasAlsoWaitForTheWindow(t *testing.T) {
	work := backlog(40)
	workers := newWorkers(t, 9) // kubectl scale --replicas=9
	c, clk := newController(&work, workers)
	ctx := context.Background()
	_, _ = c.Reconcile(ctx)
	if got := replicasOf(t, workers); got != 9 {
		t.Fatalf("got %d at once; a scale-down must wait for the window", got)
	}
	clk.advance(61 * time.Second)
	_, _ = c.Reconcile(ctx)
	if got := replicasOf(t, workers); got != 5 {
		t.Fatalf("after the window: %d, want the policy's 5", got)
	}
}

func TestRabbitQueueCountsReadyAndUnacked(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, _ := r.BasicAuth()
		if r.URL.EscapedPath() != "/api/queues/%2F/jobs.commands" || user != "runway" || pass != "secret" {
			http.Error(w, "unexpected request "+r.URL.EscapedPath(), http.StatusNotFound)
			return
		}
		_, _ = io.WriteString(w, `{"messages_ready": 30, "messages_unacknowledged": 8, "consumers": 8}`)
	}))
	defer server.Close()
	q := RabbitQueue{BaseURL: server.URL, User: "runway", Password: "secret", Queue: "jobs.commands"}
	got, err := q.Backlog(context.Background())
	if err != nil || got != 38 {
		t.Fatalf("Backlog = %d, %v; want 38 (30 waiting + 8 in progress)", got, err)
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/autoscale/... && go test -race -count=1 ./internal/autoscale/... -->

~~~bash
go test -v ./internal/autoscale/
~~~

~~~text
--- PASS: TestDesired (0.00s)
--- PASS: TestScalesUpAtOnce (0.13s)
--- PASS: TestScalesDownOnlyAfterTheWindow (0.01s)
--- PASS: TestAQuietPassWritesNothing (0.00s)
--- PASS: TestExtraReplicasAlsoWaitForTheWindow (0.00s)
--- PASS: TestRabbitQueueCountsReadyAndUnacked (0.01s)
ok  	runway/internal/autoscale	0.185s
~~~

A fake clock makes "a minute later" instant and exact.

### The command

Create `cmd/autoscaler/main.go`. Inside a cluster it uses its Pod's service account; outside, your kubeconfig, as `kubectl` does, so you can run it from your laptop while developing.

<!-- file: cmd/autoscaler/main.go -->
~~~go
// Command autoscaler sizes the worker Deployment to the jobs waiting for it
// (see package autoscale). It runs inside the cluster with a service
// account allowed to scale that one Deployment, or outside it with your
// kubeconfig.
//
//	AUTOSCALE_DEPLOYMENT   the Deployment to scale (worker)
//	POD_NAMESPACE          its namespace (runway)
//	RABBITMQ_API_URL       RabbitMQ's management API (http://rabbitmq:15672)
//	RABBITMQ_DEFAULT_USER, RABBITMQ_DEFAULT_PASS  its credentials
//	AUTOSCALE_QUEUE        the queue to watch (jobs.commands)
//	PER_REPLICA            backlog each worker Pod should carry (8)
//	MIN_REPLICAS, MAX_REPLICAS  bounds (2, 8)
//	SCALE_DOWN_AFTER       how long the backlog must stay low first (60s)
//	INTERVAL               time between passes (5s)
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"

	"runway/internal/autoscale"
	"runway/internal/envconfig"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type config struct {
	Deployment, Namespace string
	Queue                 autoscale.RabbitQueue
	Policy                autoscale.Policy
	Interval              time.Duration
}

func orDefault(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

func loadConfig(getenv envconfig.Getenv) (config, error) {
	cfg := config{
		Deployment: orDefault(getenv("AUTOSCALE_DEPLOYMENT"), "worker"),
		Namespace:  orDefault(getenv("POD_NAMESPACE"), "runway"),
		Queue: autoscale.RabbitQueue{
			BaseURL:  orDefault(getenv("RABBITMQ_API_URL"), "http://rabbitmq:15672"),
			User:     getenv("RABBITMQ_DEFAULT_USER"),
			Password: getenv("RABBITMQ_DEFAULT_PASS"),
			Queue:    orDefault(getenv("AUTOSCALE_QUEUE"), "jobs.commands"),
		},
	}
	if cfg.Queue.User == "" || cfg.Queue.Password == "" {
		return config{}, errors.New("RABBITMQ_DEFAULT_USER and RABBITMQ_DEFAULT_PASS are required")
	}
	var err error
	if cfg.Policy.PerReplica, err = envconfig.PositiveInt(getenv, "PER_REPLICA", 8); err != nil {
		return config{}, err
	}
	minReplicas, err := envconfig.PositiveInt(getenv, "MIN_REPLICAS", 2)
	if err != nil {
		return config{}, err
	}
	maxReplicas, err := envconfig.PositiveInt(getenv, "MAX_REPLICAS", 8)
	if err != nil {
		return config{}, err
	}
	if minReplicas > maxReplicas {
		return config{}, fmt.Errorf("MIN_REPLICAS (%d) is more than MAX_REPLICAS (%d)", minReplicas, maxReplicas)
	}
	cfg.Policy.Min, cfg.Policy.Max = int32(minReplicas), int32(maxReplicas)
	if cfg.Policy.ScaleDownAfter, err = envconfig.Duration(getenv, "SCALE_DOWN_AFTER", time.Minute); err != nil {
		return config{}, err
	}
	if cfg.Interval, err = envconfig.Duration(getenv, "INTERVAL", 5*time.Second); err != nil {
		return config{}, err
	}
	return cfg, nil
}

// kubeClient connects with the Pod's service account inside a cluster, or
// with your kubeconfig (as kubectl does) outside one.
func kubeClient() (kubernetes.Interface, error) {
	restConfig, err := rest.InClusterConfig()
	if errors.Is(err, rest.ErrNotInCluster) {
		rules := clientcmd.NewDefaultClientConfigLoadingRules()
		restConfig, err = clientcmd.NewNonInteractiveDeferredLoadingClientConfig(rules, nil).ClientConfig()
	}
	if err != nil {
		return nil, err
	}
	return kubernetes.NewForConfig(restConfig)
}

func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
	client, err := kubeClient()
	if err != nil {
		return err
	}
	target := autoscale.Deployment{Client: client, Namespace: cfg.Namespace, Name: cfg.Deployment}
	controller := autoscale.New(cfg.Policy, cfg.Queue, target, logger)
	logger.Info("autoscaler started", "deployment", cfg.Namespace+"/"+cfg.Deployment, "queue", cfg.Queue.Queue,
		"per_replica", cfg.Policy.PerReplica, "min", cfg.Policy.Min, "max", cfg.Policy.Max,
		"scale_down_after", cfg.Policy.ScaleDownAfter.String())
	controller.Run(ctx, cfg.Interval)
	return nil
}
~~~

And `cmd/autoscaler/main_test.go`:

<!-- file: cmd/autoscaler/main_test.go -->
~~~go
package main

import (
	"strings"
	"testing"
	"time"
)

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestDefaults(t *testing.T) {
	cfg, err := loadConfig(env(map[string]string{"RABBITMQ_DEFAULT_USER": "u", "RABBITMQ_DEFAULT_PASS": "p"}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Deployment != "worker" || cfg.Namespace != "runway" || cfg.Queue.Queue != "jobs.commands" ||
		cfg.Policy.Min != 2 || cfg.Policy.Max != 8 || cfg.Policy.ScaleDownAfter != time.Minute {
		t.Fatalf("defaults = %+v", cfg)
	}
}

func TestBadBounds(t *testing.T) {
	_, err := loadConfig(env(map[string]string{
		"RABBITMQ_DEFAULT_USER": "u", "RABBITMQ_DEFAULT_PASS": "p", "MIN_REPLICAS": "5", "MAX_REPLICAS": "3",
	}))
	if err == nil || !strings.Contains(err.Error(), "MIN_REPLICAS (5) is more than MAX_REPLICAS (3)") {
		t.Fatalf("error = %v", err)
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./cmd/autoscaler/... && go test -race -count=1 ./cmd/autoscaler/... -->

### In the chart

Create `deploy/helm/runway/templates/autoscaler.yaml`. The Role is the interesting part: in this namespace only, `get` and `update` on `deployments/scale`, for the Deployment named `worker`, and nothing else.

<!-- file: deploy/helm/runway/templates/autoscaler.yaml -->
~~~yaml
{{- if .Values.autoscaler.enabled }}
# The autoscaler from step 11, and exactly the permission it needs: in this
# namespace only, read and change the worker Deployment's scale, and
# nothing else. If it were compromised, the worst it could do is change how
# many workers run.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: autoscaler
  labels:
    {{- include "runway.labels" . | nindent 4 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: autoscaler
  labels:
    {{- include "runway.labels" . | nindent 4 }}
rules:
  - apiGroups: [apps]
    resources: [deployments/scale]
    resourceNames: [worker]
    verbs: [get, update]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: autoscaler
  labels:
    {{- include "runway.labels" . | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: autoscaler
subjects:
  - kind: ServiceAccount
    name: autoscaler
    namespace: {{ .Release.Namespace }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autoscaler
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  # One: two controllers scaling the same Deployment would fight. Running
  # more for availability needs leader election (a Lease), so only one acts.
  replicas: 1
  selector:
    matchLabels: { app: autoscaler }
  template:
    metadata:
      labels: { app: autoscaler }
    spec:
      serviceAccountName: autoscaler
      securityContext:
        runAsNonRoot: true
      containers:
        - name: autoscaler
          image: {{ include "runway.image" (list $ .Values.image.tag) }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: ["/usr/local/bin/autoscaler"]
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef: { fieldPath: metadata.namespace }
            - name: RABBITMQ_DEFAULT_USER
              valueFrom:
                secretKeyRef: { name: {{ .Values.existingSecret }}, key: RABBITMQ_DEFAULT_USER }
            - name: RABBITMQ_DEFAULT_PASS
              valueFrom:
                secretKeyRef: { name: {{ .Values.existingSecret }}, key: RABBITMQ_DEFAULT_PASS }
            - { name: PER_REPLICA, value: {{ .Values.autoscaler.perReplica | quote }} }
            - { name: MIN_REPLICAS, value: {{ .Values.autoscaler.minReplicas | quote }} }
            - { name: MAX_REPLICAS, value: {{ .Values.autoscaler.maxReplicas | quote }} }
            - { name: SCALE_DOWN_AFTER, value: {{ .Values.autoscaler.scaleDownAfter | quote }} }
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits: { cpu: 200m, memory: 64Mi }
          {{- include "runway.containerSecurity" . | nindent 10 }}
{{- end }}
~~~

Give the autoscaler its settings, in `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
worker:
  replicas: 2
~~~

to:

~~~yaml
worker:
  # Ignored while the autoscaler is on: it owns the count.
  replicas: 2
~~~

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
    requests: { cpu: 50m, memory: 32Mi }
    limits: { cpu: 500m, memory: 128Mi }

gateway:
~~~

to:

~~~yaml
    requests: { cpu: 50m, memory: 32Mi }
    limits: { cpu: 500m, memory: 128Mi }

# The queue-depth autoscaler (step 11).
autoscaler:
  enabled: true
  perReplica: 8 # each worker Pod: 4 consumers busy, 4 commands waiting
  minReplicas: 2
  maxReplicas: 8
  scaleDownAfter: 60s

gateway:
~~~


And let it own the replica count. In `deploy/helm/runway/templates/worker.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/worker.yaml -->
~~~yaml
spec:
  replicas: {{ .Values.worker.replicas }}
  selector:
~~~

to:

~~~yaml
spec:
  # Two writers of one field fight: every "helm upgrade" would reset the
  # count the autoscaler chose. With the autoscaler on, the chart leaves
  # replicas out and the autoscaler alone sets it.
  {{- if not .Values.autoscaler.enabled }}
  replicas: {{ .Values.worker.replicas }}
  {{- end }}
  selector:
~~~


<!-- run: helm lint deploy/helm/runway && ! helm template runway deploy/helm/runway | grep -A12 'name: worker$' | grep -q 'replicas:' && helm template runway deploy/helm/runway --set autoscaler.enabled=false | grep -A12 'name: worker$' | grep -q 'replicas: 2' -->

~~~bash
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
kubectl -n runway get deployment worker -o jsonpath='{.spec.replicas}{"\n"}'
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait
kubectl -n runway logs deployment/autoscaler
~~~

~~~text
2
{"time":"2026-10-08T14:21:47.971207375Z","level":"INFO","msg":"autoscaler started","deployment":"runway/worker","queue":"jobs.commands","per_replica":8,"min":2,"max":8,"scale_down_after":"1m0s"}
{"time":"2026-10-08T14:21:48.602758398Z","level":"INFO","msg":"scaled workers","backlog":0,"from":1,"to":2}
~~~

Look at the second line: "from 1 to 2". There were 2 workers before the upgrade. The chart used to set `replicas: 2`, and now leaves it out, so Helm *removed the field it had owned*, and the Deployment fell back to its default, 1, stopping a worker. The autoscaler put it back half a second later. The Kubernetes documentation warns about exactly this when handing a Deployment to an HPA; it's a one-time cost of changing owners, worth knowing before you do it in production.

Check the permissions, by asking the API server what the service account may do:

~~~bash
kubectl auth can-i get deployments/worker --subresource=scale -n runway --as=system:serviceaccount:runway:autoscaler
kubectl auth can-i update deployments/api --subresource=scale -n runway --as=system:serviceaccount:runway:autoscaler
kubectl auth can-i update deployments/worker -n runway --as=system:serviceaccount:runway:autoscaler
kubectl auth can-i delete pods -n runway --as=system:serviceaccount:runway:autoscaler
~~~

~~~text
yes
no
no
no
~~~

It may read and change the worker's scale; it may not scale the API, edit the worker's Deployment itself, or delete anything.

### Run it: a burst

Submit 300 jobs of three seconds each, and watch the queue every second through RabbitMQ's management API (`kubectl -n runway port-forward svc/rabbitmq 15672:15672`, then `curl -s -u runway:runway localhost:15672/api/queues/%2F/jobs.commands`), and the autoscaler's log. A selection of the queue readings, then the log:

~~~bash
seq 300 | xargs -P 20 -I{} curl -s -o /dev/null -X POST localhost:8080/jobs -H 'Content-Type: application/json' -d '{"description":"burst","duration_ms":3000}'
kubectl -n runway logs deployment/autoscaler --since=5m | grep scaled
~~~

~~~text
14:28:21 ready   0  unacked  0  consumers  8
14:28:28 ready 102  unacked  8  consumers  8
14:28:44 ready  85  unacked 32  consumers  8
14:28:45 ready  85  unacked 32  consumers 32
14:29:04 ready  11  unacked 32  consumers 32
14:29:09 ready   0  unacked  0  consumers 32
14:30:15 ready   0  unacked  0  consumers 24
14:30:21 ready   0  unacked  0  consumers  8
{"time":"2026-10-08T14:28:33.230875753Z","level":"INFO","msg":"scaled workers","backlog":110,"from":2,"to":8}
{"time":"2026-10-08T14:30:08.357971998Z","level":"INFO","msg":"scaled workers","backlog":0,"from":8,"to":6}
{"time":"2026-10-08T14:30:13.110027597Z","level":"INFO","msg":"scaled workers","backlog":0,"from":6,"to":2}
~~~

The queue hit its limit of 100 within seven seconds (the rest of the 300 waited in the outbox), and the autoscaler went to the maximum, 8, at once. Six new Pods took twelve seconds to start, then 32 consumers drained everything in under half a minute. A minute after the queue emptied, it scaled down, in two moves as the burst's recommendations aged out of the window. All 300 jobs completed.

**That was the second burst.** The first one, a few minutes earlier, went differently: all three API Pods crashed and restarted five times over five minutes, while the workers hammered RabbitMQ so hard that it failed its own readiness probe. Every job still completed in the end, which says something good about Phases 2 and 3. But a system that falls over on its second-ever burst has something to teach. Step 12 finds out what.

**Explain it:** what does "level-triggered" mean, and why does it make the controller safe to restart? Why is the backlog ready *plus* unacknowledged messages? Why does scaling down wait, and why to the *largest* recommendation in the window? What can the autoscaler's service account do, and what can't it? Why did the upgrade briefly stop a worker?

**Read.** The Kubernetes documentation on [controllers](https://kubernetes.io/docs/concepts/architecture/controller/) and on the [HPA algorithm](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#algorithm-details), especially stabilization. Then *Programming Kubernetes* (Hausenblas and Schimanski), chapters 1 and 6, on writing controllers with client-go, informers and work queues: what would this controller gain from an informer instead of polling? Then skim [KEDA's RabbitMQ scaler](https://keda.sh/docs/latest/scalers/rabbitmq-queue/), which does in production what you just built.

---

## Step 12: A game day

**The problem.** Every failure so far was one you thought of. The ones that hurt in production are the ones nobody thought of: two harmless behaviours that combine, a safety mechanism that makes things worse, a slow dependency that nobody tested slow. And step 11 left a mystery: a burst of jobs crashed every API Pod once, and not the second time.

**New ideas.**

- **A game day** breaks the system on purpose, in a planned way, while people watch. Each experiment starts with a **hypothesis written down before running it**: a prediction you can be wrong about. Being wrong is the useful outcome; it means you learned something before an outage taught it to you.
- **Fault injection at the network.** Every Pod's network is one end of a veth pair whose other end is on the node. **netem**, a queueing discipline in the Linux kernel, can delay, drop, duplicate or reorder what passes through an interface. **iptables** rules on the nodes can drop traffic between two particular Pods: a **partial partition**, where A can't reach B but both reach C.
- **Triggers and amplifiers.** An outage usually has a trigger (something that will always happen sometimes: a slow disk, a dropped connection) and amplifiers (behaviours of *your* system that turn it into an outage). You can't remove triggers. You can remove amplifiers, and a deterministic way to reproduce one is worth more than a hundred reruns of the original.
- **Backpressure vs failure.** A full queue means "slow down", not "this failed". Systems that confuse the two retry harder exactly when they should wait.
- **Blameless postmortems** describe what the system did and why, not who should have done what. The goal is to change the system, and people are honest only where honesty is safe.

### The tools

Create `deploy/chaos/netem.sh`:

<!-- file: deploy/chaos/netem.sh -->
~~~bash
#!/usr/bin/env bash
# Impair the network into one Pod: delay, jitter, loss.
#
#   deploy/chaos/netem.sh postgres-0 delay 200ms 50ms   # 200 ms, give or take 50
#   deploy/chaos/netem.sh rabbitmq-0 loss 20%
#   deploy/chaos/netem.sh postgres-0 clear
#
# Every Pod's network is one end of a veth pair; the other end sits on its
# node, where the node routes the Pod's traffic. A kind node is a Docker
# container, so "docker exec" reaches it. netem, a queueing discipline in
# the kernel, then shapes what the node sends down that veth: everything
# the Pod receives. (Its replies are untouched: delay one direction only.)
set -euo pipefail
pod=$1
shift
ns=${NAMESPACE:-runway}
node=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}')
ip=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.podIP}')
# "ip route get" asks the node how it reaches the Pod: "... dev vethXXXX ..."
veth=$(docker exec "$node" ip route get "$ip" | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }')

if [ "${1:-}" = clear ]; then
  docker exec "$node" tc qdisc del dev "$veth" root 2>/dev/null || true
  echo "$pod: network restored ($node $veth)"
else
  docker exec "$node" tc qdisc replace dev "$veth" root netem "$@"
  echo "$pod: netem $* ($node $veth)"
fi
~~~

And `deploy/chaos/partition.sh`. Its rules go in a chain of their own, so `heal` removes them without touching the rules Kubernetes depends on:

<!-- file: deploy/chaos/partition.sh -->
~~~bash
#!/usr/bin/env bash
# Cut the network between two Pods, in both directions, leaving everything
# else connected: a partial partition.
#
#   deploy/chaos/partition.sh metad-0 metad-2
#   deploy/chaos/partition.sh heal
#
# Each node forwards its Pods' traffic, so a firewall rule there can drop
# what passes between two of them. The rules live in a chain of their own,
# RUNWAY-CHAOS, so "heal" removes them all without touching the rules
# Kubernetes itself depends on.
set -euo pipefail
ns=${NAMESPACE:-runway}
nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

chain() { # make sure the chain exists and FORWARD jumps to it
  docker exec "$1" sh -c 'iptables -N RUNWAY-CHAOS 2>/dev/null; iptables -C FORWARD -j RUNWAY-CHAOS 2>/dev/null || iptables -I FORWARD 1 -j RUNWAY-CHAOS'
}

if [ "$1" = heal ]; then
  for node in $nodes; do
    docker exec "$node" sh -c 'iptables -F RUNWAY-CHAOS 2>/dev/null || true'
  done
  echo "partitions healed"
  exit 0
fi

a=$(kubectl -n "$ns" get pod "$1" -o jsonpath='{.status.podIP}')
b=$(kubectl -n "$ns" get pod "$2" -o jsonpath='{.status.podIP}')
# Drop on every node: the packets cross the sender's node, and the
# receiver's if it is a different one.
for node in $nodes; do
  chain "$node"
  docker exec "$node" iptables -A RUNWAY-CHAOS -s "$a" -d "$b" -j DROP
  docker exec "$node" iptables -A RUNWAY-CHAOS -s "$b" -d "$a" -j DROP
done
echo "partitioned $1 ($a) from $2 ($b)"
~~~

~~~bash
chmod +x deploy/chaos/*.sh
deploy/chaos/netem.sh metad-2 delay 300ms
time kubectl get --raw /api/v1/namespaces/runway/pods/metad-2:7001/proxy/status > /dev/null
deploy/chaos/netem.sh metad-2 clear
time kubectl get --raw /api/v1/namespaces/runway/pods/metad-2:7001/proxy/status > /dev/null
~~~

~~~text
metad-2: netem delay 300ms (runway-worker2 vethf4e2071d)
real	0m1.440s
metad-2: network restored (runway-worker2 vethf4e2071d)
real	0m0.798s
~~~

About two delayed round trips more: the TCP handshake and the request.

### Experiment 1: the event consumer stops

The step 11 crash left no logs (five restarts had overwritten them) and didn't happen again. So reason about what it *could* have been, and make the suspicious part happen on purpose. When the API Pods were down, nothing was reading `jobs.events`. What do workers do then?

**Hypothesis:** commands wait in their queue; when the API comes back, everything completes.

~~~bash
seq 200 | xargs -P 20 -I{} curl -s -o /dev/null -X POST localhost:8080/jobs -H 'Content-Type: application/json' -d '{"description":"amp","duration_ms":5000}'
sleep 3; kubectl -n runway scale deployment api --replicas=0
# watch both queues every 5 seconds (management API, as in step 11) for 70 seconds, then:
kubectl -n runway scale deployment api --replicas=3
~~~

~~~text
14:31:43 >>> kubectl -n runway scale deployment api --replicas=0
14:31:56 jobs.commands ready= 87 unacked=  8 consumers=  8 | jobs.events ready=  0
14:32:01 jobs.commands ready= 55 unacked= 32 consumers= 32 | jobs.events ready= 16
14:32:07 jobs.commands ready= 24 unacked= 32 consumers= 32 | jobs.events ready= 55
14:32:13 jobs.commands ready=  0 unacked=  0 consumers= 32 | jobs.events ready=101
14:32:47 jobs.commands ready=  0 unacked=  0 consumers= 32 | jobs.events ready=101
~~~

**Wrong.** The commands queue *emptied*, in six seconds, with five-second jobs. Nothing ran them. The worker logs, all 80 lines from that window, say why:

~~~text
{"msg":"command handled","type":"jobs.run_job","duration_ms":97,"error":"broker rejected the message: jobs.events"}
~~~

And the database, a few minutes after the API came back:

~~~bash
kubectl -n runway exec postgres-0 -- psql -U runway -tAc "SELECT state, count(*) FROM jobs WHERE description='amp' GROUP BY 1 ORDER BY 1"
~~~

~~~text
completed|136
failed|29
queued|35
~~~

64 of 200 jobs never ran. Here's the chain:
1. `jobs.events` filled to its limit of 100, and RabbitMQ, declared with `reject-publish`, refused new events.
2. A worker's first act is to publish `JobStarted`. Refused, so the command fails.
3. The bus retries a failed command by republishing it *at once*, and the worker fails it the same way, in milliseconds, five times. Then it is dead-lettered.
4. 29 jobs had been marked `running`; Phase 3's sweep later failed them as abandoned. 35 never got that far, and stay `queued` for ever: nothing will ever move them.

In the step 11 crash, this loop ran across 32 consumers until RabbitMQ was so busy it failed its own readiness probe, Kubernetes took it out of its Service, and the restarting API Pods couldn't connect. The trigger was the API dropping its connection; the amplifier was this loop. **A full queue was treated as a failed job.**

**The fix: wait while the queue is full.** The bus already has a name for it, `bus.ErrFull`. RabbitMQ's adapter should say so when the broker refuses. In `internal/rabbit/rabbit.go`:

Change:

<!-- edit: internal/rabbit/rabbit.go -->
~~~go
		return fmt.Errorf("%w: %s", ErrRejected, queue)
~~~

to:

~~~go
		// Each queue is declared with x-overflow: reject-publish, so a
		// refusal means it is full. Saying so lets callers treat it as
		// backpressure (wait and retry) rather than failure.
		return fmt.Errorf("%w: %s: %w", ErrRejected, queue, bus.ErrFull)
~~~


And the worker, on `ErrFull`, waits with backoff and tries again, for as long as it takes, holding its command. While it holds it, this consumer takes no new ones, so the pressure travels back up the pipeline: commands wait in their queue, and beyond that in the outbox, where nothing is lost. In `internal/worker/worker.go`:

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
	"errors"
	"time"
~~~

to:

~~~go
	"errors"
	"math"
	"time"
~~~

Change:

<!-- edit: internal/worker/worker.go -->
~~~go

func (w *Worker) emit(ctx context.Context, msgType string, payload any) error {
~~~

to:

~~~go

// emit publishes an event. A full events queue is backpressure, not
// failure: whoever reads events is behind. Returning an error would retry
// the command, which would fail the same way at once, spending all the
// job's attempts in milliseconds and dead-lettering it unrun (found in the
// Phase 5 game day). So emit waits and tries again, as long as it takes,
// holding this command; and while it holds it, this consumer takes no new
// ones. The pressure travels back up: commands wait in their queue, and
// beyond that in the outbox, where nothing is lost.
func (w *Worker) emit(ctx context.Context, msgType string, payload any) error {
~~~

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
	return w.events.Publish(ctx, messages.EventsQueue, msg)
~~~

to:

~~~go
	waiting := w.retry
	waiting.Attempts = math.MaxInt // until it is accepted, or ctx ends
	return waiting.Do(ctx, func(ctx context.Context) error {
		err := w.events.Publish(ctx, messages.EventsQueue, msg)
		if errors.Is(err, bus.ErrFull) {
			trace.SpanFromContext(ctx).AddEvent("events queue full; waiting")
			return err
		}
		if err != nil {
			return retry.Stop(err) // any other failure: retry the command instead
		}
		return nil
	})
~~~


Test both promises: a full queue is waited out, and shutting down still ends the wait. In `internal/worker/worker_test.go`:

Add this at the end of the file:

<!-- append: internal/worker/worker_test.go -->
~~~go
// fullFor is a publisher whose queue is full for its first n publishes.
type fullFor struct {
	recorder
	n int
}

func (f *fullFor) Publish(ctx context.Context, queue string, msg messages.Envelope) error {
	f.mu.Lock()
	if f.n > 0 {
		f.n--
		f.mu.Unlock()
		return bus.ErrFull
	}
	f.mu.Unlock()
	return f.recorder.Publish(ctx, queue, msg)
}

// A full events queue is backpressure: the worker waits, however many
// tries it takes, instead of failing the command (and spending the job's
// attempts) at once.
func TestAFullEventsQueueIsWaitedOut(t *testing.T) {
	events := &fullFor{n: 20} // more than the job's attempts
	waits := 0
	w := New(events, jobs.Simulate, time.Second, WithRetry(retry.Policy{
		Sleep: func(context.Context, time.Duration) error { waits++; return nil },
	}))
	if err := w.Handle(context.Background(), runJob(t, 0)); err != nil {
		t.Fatalf("Handle: %v; a full queue should be waited out", err)
	}
	if got := events.types(); len(got) != 2 || got[1] != messages.TypeJobCompleted {
		t.Fatalf("events = %v", got)
	}
	if waits != 20 {
		t.Fatalf("waited %d times, want 20", waits)
	}
}

// Waiting ends when the worker shuts down; the command is then redelivered.
func TestWaitingForAFullQueueStopsOnShutdown(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	w := New(&fullFor{n: 1 << 30}, jobs.Simulate, time.Second)
	err := w.Handle(ctx, runJob(t, 0))
	if !errors.Is(err, bus.ErrFull) || bus.IsPermanent(err) {
		t.Fatalf("error = %v, want a retryable ErrFull", err)
	}
}
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/worker/... ./internal/rabbit/... ./internal/bus/... -->

Build, load, restart the workers, and run the same experiment:

~~~text
14:48:12 jobs.commands ready= 61 unacked= 32 consumers= 32 | jobs.events ready=101
14:48:17 jobs.commands ready= 50 unacked= 32 consumers= 32 | jobs.events ready=101
14:48:48 jobs.commands ready= 50 unacked= 32 consumers= 32 | jobs.events ready=101
14:48:58 >>> kubectl -n runway scale deployment api --replicas=3
14:49:09 jobs.commands ready= 78 unacked= 32 consumers= 32 | jobs.events ready=  0
14:49:24 jobs.commands ready=  0 unacked= 14 consumers= 32 | jobs.events ready=  0
~~~

~~~text
amp-fixed|completed|200
~~~

While the API was gone, 32 workers each held one command and 50 waited; nothing was rejected, nothing dead-lettered. When the API came back, it all drained. 200 of 200.

The 35 jobs stuck in `queued` show a second gap: **dead-lettered work is invisible**. Add an alert for any dead letter at all. In `deploy/prometheus/rules.yml`:

Change:

<!-- edit: deploy/prometheus/rules.yml -->
~~~yaml

      # Commands piling up faster than workers take them. Step 11's
~~~

to:

~~~yaml

      # A dead-lettered message is work that will never happen unless a
      # person looks: a RunJob command there leaves its job "queued" for
      # ever (found in the Phase 5 game day). Any at all deserves a ticket.
      - alert: MessagesDeadLettered
        expr: sum by (queue) (rabbitmq_detailed_queue_messages_ready{queue=~".+[.]dead"}) > 0
        for: 1m
        labels:
          severity: ticket
        annotations:
          summary: Messages were dead-lettered
          description: "{{ $value }} messages wait in {{ $labels.queue }}. Read them, fix the cause, then replay or discard them."
      # Commands piling up faster than workers take them. Step 11's
~~~


And its test, in `deploy/prometheus/rules_test.yml`:

Add this at the end of the file:

<!-- append: deploy/prometheus/rules_test.yml -->
~~~yaml
  - name: any dead letter raises a ticket
    interval: 1m
    input_series:
      - series: 'rabbitmq_detailed_queue_messages_ready{queue="jobs.commands.dead"}'
        values: '0 0 3x5'
      - series: 'rabbitmq_detailed_queue_messages_ready{queue="jobs.commands"}'
        values: '40x7'
    alert_rule_test:
      - eval_time: 2m
        alertname: MessagesDeadLettered
        exp_alerts: []
      - eval_time: 4m
        alertname: MessagesDeadLettered
        exp_alerts:
          - exp_labels: { severity: ticket, queue: jobs.commands.dead }
            exp_annotations:
              summary: Messages were dead-lettered
              description: "3 messages wait in jobs.commands.dead. Read them, fix the cause, then replay or discard them."
~~~


<!-- run: docker run --rm -v "$PWD/deploy/prometheus:/etc/prometheus" -w /etc/prometheus --entrypoint promtool prom/prometheus:v3.15.0 test rules rules_test.yml -->

### Experiment 2: the database is slow

**Hypothesis:** a job submission makes about five round trips to PostgreSQL. With 150 ms added to each, it takes about 750 ms: over the 250 ms latency objective, so that alert pages, but nothing fails.

Run kload at 10 requests a second, and watch readiness, the SLI and the alerts every 15 seconds:

~~~bash
deploy/chaos/netem.sh postgres-0 delay 150ms
~~~

~~~text
14:52:29 >>> deploy/chaos/netem.sh postgres-0 delay 150ms
14:52:46 pg+150ms api-ready=[True True False] slow5m=0.0%  p99=632ms  alerts=...
14:53:01 pg+150ms api-ready=[True True True]  slow5m=1.0%  p99=2287ms alerts=...
14:53:17 pg+150ms api-ready=[True True True]  slow5m=35.4% p99=2321ms alerts=ApiErrorBudgetBurn=pending,...
14:54:03 pg+150ms api-ready=[True True True]  slow5m=56.1% p99=998ms  alerts=ApiLatencyBudgetBurn=pending,...
14:55:20 pg+150ms api-ready=[True True True]  slow5m=71.8% p99=996ms  alerts=ApiLatencyBudgetBurn=pending,...
~~~

**Mostly right.** The median went to 760 ms, and the latency alert went pending after 90 seconds (it fired at about three and a half minutes). But two things I didn't predict. For the first minute, p99 sat at 2.3 seconds, *past* the 2-second request timeout, so some requests failed and the *error* alert went pending too. And one API Pod briefly went not-ready. The likely explanation is Little's law: each request held a pooled connection five times longer, the event handlers and the outbox relay did too, and ten connections per Pod weren't enough, so requests queued for a connection. The dashboard's database-wait panel would confirm it; check yours.

### Experiment 3: the database is very slow

**Hypothesis:** with 1500 ms added, nothing fits in two seconds, so every request fails. And readiness, which pings the database with a one-second deadline, fails on *every* API Pod at once, taking them all out of the Service.

~~~bash
deploy/chaos/netem.sh postgres-0 delay 1500ms
~~~

~~~text
14:55:36 pg+1500ms api-ready=[True True True]
14:55:51 pg+1500ms api-ready=[False False False]
14:56:52 >>> deploy/chaos/netem.sh postgres-0 clear
14:57:09 recovered api-ready=[True True True]
~~~

**Right, and it showed the problem.** All three Pods were out within 15 seconds. kload's view of those seconds: every request failed, mostly by a 10-second client timeout, because there was nobody to answer. Readiness checking a dependency *that every Pod shares* can never help: when it fails, it fails for all of them at once, and turns "slow" into "nothing". The circuit breaker from Phase 2 already does the useful thing (answer 503 at once when the database is failing), but only if the Pod gets the request.

**The fix: readiness says only that this process can take requests.** In `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	if pool != nil {
		options = append(options, httpapi.WithReadiness(func(ctx context.Context) error { return pool.Ping(ctx) }))
	}
~~~

to:

~~~go
	// Readiness does not ping PostgreSQL (changed in Phase 5). Every API
	// Pod shares one database, so when it is slow, every Pod's check fails
	// at once and Kubernetes takes them all out of the Service: a slow
	// database became no API at all, with clients timing out instead of
	// getting an answer (the game day, step 12). /ready now says only that
	// this process started and can take requests; when the database fails,
	// the circuit breaker answers 503 at once, which tells clients more.
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./cmd/api/... && go test -race -count=1 ./cmd/api/... ./internal/httpapi/... -->

This reverses something Phases 1 to 3 did, on purpose: that was the right default for one process; with many copies behind one Service, the game day shows it's wrong. (It also explains step 5's surprise, where every Pod was ready with no schema: readiness was never going to catch that.) The same experiment again:

~~~text
15:08:58 baseline  api-ready=[True True True]
15:08:59 >>> deploy/chaos/netem.sh postgres-0 delay 1500ms
15:09:15 pg+1500ms api-ready=[True True True]
15:10:16 pg+1500ms api-ready=[True True True]
15:10:16 >>> deploy/chaos/netem.sh postgres-0 clear
failures by kind: [(('503', ''), 873)]
~~~

The Pods stayed in. Requests still failed while the database took 1.5 seconds a round trip (nothing could fit in the timeout), but every failure was a 503 in under ten milliseconds, and the API recovered the moment the delay went.

### Experiments 4 and 5: partial partitions

**Hypothesis:** cut `metad`'s leader off from one follower. With PreVote (Phase 4, step 6) the follower can't disrupt the leader: same term, writes still succeed. Then cut the leader off from the other follower too. With CheckQuorum it steps down; the followers elect a new leader in a higher term; the old one can't win, doesn't inflate the term, and rejoins cleanly when healed.

~~~bash
deploy/chaos/partition.sh metad-2 metad-1   # the leader was metad-2
deploy/chaos/partition.sh metad-2 metad-0
deploy/chaos/partition.sh heal
~~~

Each member's view, read through the API server (which isn't affected by the partition), and writes through a port-forward (nor is that):

~~~text
15:02:31 before    metad-0=follower/term5/leader3/commit8   metad-1=follower/term5/leader3/commit8       metad-2=leader/term5/leader3/commit8
15:02:33 >>> partition.sh metad-2 metad-1   (one follower cut off)
15:02:37 1-cut     metad-0=follower/term5/leader3/commit9   metad-1=pre-candidate/term5/leader0/commit9  metad-2=leader/term5/leader3/commit9
15:02:52 PUT /kv/during-one-cut via metad-2: 200
15:02:52 1-cut     metad-0=follower/term5/leader3/commit10  metad-1=pre-candidate/term5/leader0/commit9  metad-2=leader/term5/leader3/commit10
15:02:52 >>> partition.sh metad-2 metad-0   (leader now cut off from both)
15:02:56 isolated  metad-0=leader/term6/leader1/commit11    metad-1=follower/term6/leader1/commit11      metad-2=pre-candidate/term5/leader0/commit10
15:03:16 PUT /kv/during-isolation via metad-0: 200
15:03:18 PUT /kv/to-old-leader via metad-2: 421
15:03:18 >>> partition.sh heal
15:03:21 healed    metad-0=leader/term6/leader1/commit12    metad-1=follower/term6/leader1/commit12      metad-2=follower/term6/leader1/commit12
~~~

**Right, both times.** Cut off from the leader, `metad-1` sat in `pre-candidate` at term 5: PreVote asked whether it could win, `metad-0` (still hearing the leader) said no, and the term never moved. Writes kept committing. Then the leader, isolated, stepped down within four seconds; `metad-0` won term 6; the old leader refused writes with 421 and stayed at term 5; healed, it rejoined as a follower and caught up. Phase 4's protocol work, confirmed on a real network.

### Write it down

A game day is only useful if what you learned outlives the day. Three documents.

A **runbook** for the page from step 10, linked from the alert's `runbook_url`. Its job is to make 3 a.m. decisions easy: look here, then mitigate this way. Create `docs/runbooks/api-errors.md`:

<!-- file: docs/runbooks/api-errors.md -->
~~~markdown
# Runbook: the API is failing requests (ApiErrorBudgetBurn)

**The alert means:** more than 1.44% of API requests have failed over the last hour *and* the last 5 minutes (or 0.6% over 6 hours and 30 minutes). At that rate the month's error budget is gone in about two days. Users are seeing errors now.

**Your first goal is to stop the errors, not to understand them.** Mitigate first, then find the cause.

## 1. Look (2 minutes)

Open the Runway dashboard in Grafana (`kubectl -n observability port-forward svc/grafana 3000:3000`, then http://localhost:3000/d/runway).

- **Requests per second**, split by route and code. Is it one route or all of them? 500, 503 or 504?
- **POST /jobs latency.** If p99 sits near 2 s, requests are timing out (the API's request timeout is 2 s), and the cause is probably something slow under the API, not something broken.
- **Errors and waits.** Rising *waits for a DB connection* means the pool is exhausted: the database is slow, or something is holding connections.

Then check what changed:

```sh
helm -n runway history runway | tail -3       # a release in the last hour?
kubectl -n runway get pods                    # restarts, CrashLoopBackOff, Pending?
kubectl -n runway get events --sort-by=.lastTimestamp | tail -20
```

## 2. Mitigate (pick the first that fits)

| You see | Do |
|---|---|
| A release in the last hour | `helm -n runway rollback runway` and watch the error rate. Roll back first; debug after. |
| API Pods restarting with `connect to RabbitMQ` | The broker is overloaded or unready: `kubectl -n runway get pods rabbitmq-0`, and its logs. See *Broker overloaded* below. |
| p99 near 2 s, pool waits rising | The database is slow. See *Database slow* below. |
| `jobs.commands` backing up, workers busy | Not an API error by itself; the autoscaler should be adding workers (`kubectl -n runway logs deploy/autoscaler`). |

### Database slow

The API holds a connection for every query of a request. If each query takes longer, each request holds its connection longer, and the 10 connections per Pod run out: requests then wait for a connection and time out, even though the database is up. *A small slowdown becomes a large outage.*

```sh
kubectl -n runway exec postgres-0 -- psql -U runway -c "SELECT state, wait_event_type, count(*) FROM pg_stat_activity GROUP BY 1, 2"
kubectl -n runway exec postgres-0 -- psql -U runway -c "SELECT pid, now() - query_start AS running, left(query, 60) FROM pg_stat_activity WHERE state = 'active' ORDER BY 2 DESC LIMIT 5"
```

Mitigate by removing the load or the cause: a long-running query (`SELECT pg_cancel_backend(pid)`), a noisy neighbour, a network problem between the nodes.

### Broker overloaded

```sh
kubectl -n runway port-forward svc/rabbitmq 15672:15672   # then http://localhost:15672 (runway / runway)
```

Look at the queues. A queue at its limit (100) refuses new messages. Is anything consuming `jobs.events`? Does `jobs.commands.dead` hold messages? If so, read them before replaying them.

## 3. After

- Once the error rate is back under 0.1%, the alert resolves on its own within about 5 minutes (the short window).
- Write down the timeline while you remember it, and open a postmortem if users were affected for more than a few minutes. See [docs/postmortems](../postmortems/).
~~~

A **postmortem** for the step 11 cascade. Create `docs/postmortems/2026-10-08-burst-cascade.md`, and write your own from what *your* system did; mine is here as a model of the form:

<!-- file: docs/postmortems/2026-10-08-burst-cascade.md -->
~~~markdown
# Postmortem: a burst of jobs crashed the API and dead-lettered work

**Date:** 2026-10-08 · **Duration:** about 5 minutes (14:23 to 14:28 UTC) · **Status:** resolved, actions done · **Author:** you

Blameless: this describes what the system did and why, not who should have done what. Every decision in it was reasonable with what was known at the time.

## Summary

A burst of 300 jobs, submitted while the autoscaler was adding workers (step 11), crashed all three API Pods. They restarted five times over five minutes. Every job eventually completed. A controlled repeat of the trigger (the API not reading events for 70 seconds) dead-lettered 64 of 200 jobs, which then never ran: 29 were marked failed by the abandoned-jobs sweep, and 35 stayed `queued` with nothing left to move them.

## Impact

- Job submissions failed or timed out for about five minutes while the API restarted.
- In the controlled repeat, 32% of jobs (64 of 200) were dead-lettered without running. No alert fired for them.

## Timeline (UTC)

| Time | Event |
|---|---|
| 14:22:29 | 300 jobs submitted, 3 seconds each. The outbox fills `jobs.commands` to its limit of 100 and holds the rest. |
| 14:22:38 | The autoscaler scales workers from 2 to 8 (backlog 110). Six new Pods start, on a machine already short of CPU. |
| 14:23:47 | An API Pod's connection to RabbitMQ drops; its event subscription ends; the API exits ("lost the message bus"). The other two follow. |
| 14:24 | Nothing reads `jobs.events`. It fills to its limit of 100, and RabbitMQ rejects new events. |
| 14:24 to 14:25 | Every worker's `JobStarted` publish is rejected. Each command fails in 1 to 21 ms, is retried at once, and fails again: a hot loop across 32 consumers. |
| 14:25 | RabbitMQ, busy with the loop, misses its readiness probe (10 s timeout). Kubernetes removes it from the Service, so restarting API Pods get "connection refused" and crash again (CrashLoopBackOff). |
| 14:26:25 | The commands queue empties; the loop stops; RabbitMQ recovers; the API reconnects. |
| 14:27:23 | The autoscaler scales back to 2 workers. All 300 jobs show `completed`. |

## Root causes

There was a trigger, and there were amplifiers. The trigger was the API's broker connection dropping. Why it dropped is not certain: the logs of the first crash were overwritten by the restarts, and a second identical burst did not repeat it. The most likely cause is CPU starvation on an overloaded machine delaying heartbeats. Triggers like that will always exist. The amplifiers turned it into an outage, and they were deterministic:

1. **Backpressure treated as failure.** A full events queue means "slow down", not "this job failed". The worker turned it into a command failure, retried with no delay, and spent all of a job's attempts in milliseconds. The jobs were dead-lettered without ever running.
2. **No backoff on redelivery.** A command that failed went straight back to a consumer, so the failure became a hot loop, and the loop overloaded the broker.
3. **A dependency in a readiness check.** RabbitMQ's slow probe took it out of the Service. That stopped exactly the clients (restarting API Pods) that would have drained the events.

A related finding from the same game day: the API's readiness check pinged PostgreSQL. With 1.5 s added to the database's network, all three API Pods went NotReady within 15 seconds and the API answered nothing; clients waited 10 s for timeouts.

## What went well

- No job was lost silently in the original incident: the outbox held what the queues couldn't, and the idempotent handlers made every redelivery harmless.
- The autoscaler did its part: up to 8 under load, back to 2 a minute after the backlog cleared.
- Traces and logs shared a `trace_id`, so a job could be followed from the API through the worker.

## What went badly

- Dead-lettered work raised no alert. 35 jobs would have stayed `queued` for ever.
- The first cascade's cause had to be found by reproducing it: the logs of the first API crash were gone after five restarts (only `--previous` is kept).

## Actions

| Action | Type | Status |
|---|---|---|
| Worker waits, with backoff, while the events queue is full, holding its command, instead of failing it (`bus.ErrFull`, `worker.emit`). Repeat of the test: 200 of 200 completed, 0 dead-lettered. | Fix | Done |
| Alert on any dead-lettered message (`MessagesDeadLettered`), with a promtool test. | Detect | Done |
| API readiness no longer pings PostgreSQL; the circuit breaker answers 503 at once instead. Repeat of the test: Pods stayed Ready, failures were 503s in under 10 ms, recovery was immediate. | Fix | Done |
| Ship logs somewhere that outlives a Pod's restarts (Loki or similar). | Detect | Open |
| Sweep jobs left `queued` whose command was dead-lettered, or replay them from the dead-letter queue. | Fix | Open |
| Delay requeued commands (a retry queue with a TTL) instead of redelivering them at once. | Fix | Open |
~~~

And the **game day report**, every hypothesis and what happened, `docs/gamedays/2026-10-08.md`:

<!-- file: docs/gamedays/2026-10-08.md -->
~~~markdown
# Game day, 2026-10-08

A game day breaks the system on purpose, in a planned way, to learn how it fails before an outage teaches you. Each experiment starts with a hypothesis written down *before* running it: a prediction you can be wrong about. Being wrong is the useful outcome.

**Rules:** one experiment at a time; a way to stop it (`deploy/chaos/netem.sh POD clear`, `deploy/chaos/partition.sh heal`) ready before starting; load running throughout (kload, 10 to 20 requests a second); the Grafana dashboard open.

## 1. The event consumer stops

**Injected:** 200 jobs of 5 s queued, then `kubectl -n runway scale deployment api --replicas=0` for 70 s.
**Hypothesis:** commands wait; when the API returns, everything completes.
**Result: wrong.** Once `jobs.events` filled (100 messages), every remaining command failed in milliseconds and was dead-lettered: 64 of 200 jobs never ran. See the [postmortem](../postmortems/2026-10-08-burst-cascade.md).
**After the fix:** 32 commands were held by waiting workers and 50 waited in the queue; 200 of 200 completed once the API returned.

## 2. The database is slow: 150 ms

**Injected:** `deploy/chaos/netem.sh postgres-0 delay 150ms` for 3 minutes.
**Hypothesis:** POST /jobs makes about 5 round trips, so it slows to about 750 ms; the latency SLO pages; no errors.
**Result: mostly right.** p50 rose to about 760 ms. But p99 first jumped to 2.3 s, past the 2 s request timeout, and some requests failed. The likely cause is the connection pools filling, since each request held its connection about five times longer (Little's law); the dashboard's database-wait panel would confirm it, and I didn't look. The latency alert went pending after 1.5 minutes and fired after 3.5.

## 3. The database is very slow: 1500 ms

**Injected:** `deploy/chaos/netem.sh postgres-0 delay 1500ms` for 75 s.
**Hypothesis:** every request fails (nothing fits in 2 s), and readiness, which pinged the database with a 1 s deadline, takes every API Pod out of service.
**Result: right, and worse than it needed to be.** All three Pods were NotReady within 15 s; clients got 10 s timeouts. The API recovered about 20 s after the delay was removed.
**After the fix** (readiness no longer pings the database): Pods stayed Ready, every failure was a 503 in under 10 ms, and the API recovered at once.

## 4. metad: one follower cut off

**Injected:** `deploy/chaos/partition.sh <leader> <follower>`.
**Hypothesis:** with PreVote, the cut-off follower can't disrupt the leader: same term, writes succeed.
**Result: right.** The follower sat in `pre-candidate` at the same term (no term inflation); the leader kept term 5; writes committed on the leader and the other follower.

## 5. metad: the leader cut off from both followers

**Injected:** a second `partition.sh`, from the leader to the other follower.
**Hypothesis:** with CheckQuorum, the old leader steps down; the followers elect a new one in a higher term; the old leader can't win and doesn't inflate the term; it rejoins cleanly after healing.
**Result: right.** A new leader in term 6 within about 4 s; the old leader answered 421 and stayed at term 5 as `pre-candidate`; after `heal` it rejoined as a follower in term 6 and caught up.
~~~

**Explain it:** what does netem change, and in which direction? Why did a full events queue dead-letter jobs that never ran, and why does waiting fix it? What is the difference between a trigger and an amplifier, and why fix amplifiers first? Why can readiness never help when it checks a dependency every Pod shares? What stopped the cut-off `metad` follower from disrupting the leader?

**Read.** *Site Reliability Engineering*, chapter 15 (*Postmortem Culture*) and chapter 22 (*Addressing Cascading Failures*), which describes this step's cascade almost exactly. Then the Google SRE workbook's chapter on incident response. Then *Principles of Chaos Engineering* ([principlesofchaos.org](https://principlesofchaos.org/)), and Basiri et al., *Chaos Engineering* (IEEE Software, 2016). Carry this question in: which of this step's findings would a load test have found, and which needed a fault?

---

## Step 13: Runway on AWS, with Terraform

**The problem.** Everything so far runs on your machine. A real deployment runs on someone else's: a cloud, where machines, networks, databases and queues are all created by API calls, billed by the hour, and easy to get subtly wrong (a database open to the internet, a role that can do anything). Clicking through a web console to build it can't be reviewed, repeated or undone. Describing it as code can.

**New ideas.**

- **Infrastructure as code.** Terraform reads files describing resources (a VPC, a database, a queue), compares them with what exists, and makes a **plan**: the calls it would make to close the gap. `apply` carries it out. It is the control loop of step 3 again, run by hand, with a review step in the middle. The **state** file records what Terraform made, so it can change and delete it later.
- **A VPC** is a private network of your own, split into **subnets**. *Public* subnets have a route to the internet through an internet gateway; *private* ones don't. **Security groups** are stateful firewalls around each kind of resource, whose rules can name other groups ("the API's tasks") instead of addresses.
- **IAM** decides who may do what. Services get **roles**, assumed with temporary credentials, never long-lived keys. ECS uses two per task: an *execution role* (pull the image, write logs, read secrets, before your code runs) and a *task role* (the AWS calls your code makes).
- **Managed services** replace what you ran yourself. RDS runs PostgreSQL, with backups and patching; SQS is a queue with no servers at all; ECS on **Fargate** runs containers with no machines to manage; an Application Load Balancer does step 4's layer-7 balancing; CloudWatch collects logs, metrics and alarms.
- **Cost is a design constraint.** A cloud account bills while things run, whether you use them or not. This configuration costs about $2.50 a day; a forgotten one costs $75 a month. So it has a budget alarm, and you destroy it when you stop.

### Plan without an account

Terraform's `plan` normally asks AWS what exists. With fake credentials and the provider told to skip its checks, it can plan from nothing, offline, at no cost: a full review of what *would* be built. Everything below avoids looking things up in AWS at plan time (the availability zones are a variable, not a lookup) so that this works. You need an AWS account only to `apply`.

Create the files under `deploy/terraform/`, one concern each. The provider, `versions.tf`:

<!-- file: deploy/terraform/versions.tf -->
~~~hcl
# Runway on AWS (Phase 5, step 13): the same services as on kind, on
# managed parts. Each file holds one concern; Terraform reads them all.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # With offline = true, Terraform never contacts AWS: "plan" shows what
  # would be built, with no account and no cost. "apply" needs real
  # credentials and offline = false.
  skip_credentials_validation = var.offline
  skip_requesting_account_id  = var.offline
  skip_metadata_api_check     = var.offline
  skip_region_validation      = var.offline

  # Every resource gets these tags, so the bill can be split by project.
  default_tags {
    tags = {
      project    = "runway"
      managed-by = "terraform"
    }
  }
}
~~~

The inputs, `variables.tf`:

<!-- file: deploy/terraform/variables.tf -->
~~~hcl
variable "region" {
  description = "AWS region to build in."
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "Two zones in the region. Named here rather than looked up, so plan works offline."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "Give exactly two availability zones: the load balancer and the database subnets need two."
  }
}

variable "image_tag" {
  description = "Tag of the runway image in ECR to run, such as sha-1a2b3c4. Tags in this repository can't be moved, so a tag here always means the same image."
  type        = string
}

variable "api_count" {
  description = "API tasks to run."
  type        = number
  default     = 2
}

variable "worker_min" {
  description = "Fewest worker tasks; autoscaling adds more as the commands queue grows."
  type        = number
  default     = 1
}

variable "worker_max" {
  description = "Most worker tasks."
  type        = number
  default     = 8
}

variable "alert_email" {
  description = "Where alarms and budget warnings go. Empty: no email (alarms still show in the console)."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Warn when this month's spend is forecast to pass 80% of this, and when it passes 100%."
  type        = number
  default     = 50
}

variable "deletion_protection" {
  description = "Protect the database from \"terraform destroy\". Leave false while learning, so destroy tears everything down."
  type        = bool
  default     = false
}

variable "offline" {
  description = "Plan without contacting AWS (see versions.tf)."
  type        = bool
  default     = false
}
~~~

The network, `network.tf`. Read the comment at the top: the tasks sit in public subnets with public IPs, which saves a NAT gateway (about $33 a month on its own), and their security groups still admit nothing but the load balancer.

<!-- file: deploy/terraform/network.tf -->
~~~hcl
# A VPC is a private network of your own. It has two kinds of subnet here:
# public (a route to the internet through the internet gateway) for the
# load balancer and the tasks, and private (no such route) for the
# database, which nothing outside should reach.
#
# The tasks sit in public subnets with public IPs so they can pull images
# and call AWS APIs without a NAT gateway, which costs about $33 a month on
# its own. Their security group still admits nothing but the load
# balancer. In production you would move them to private subnets behind a
# NAT gateway or VPC endpoints.
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true # RDS endpoints are DNS names
  tags                 = { Name = "runway" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.availability_zones[count.index]
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index) # 10.20.0.0/24, 10.20.1.0/24
  map_public_ip_on_launch = true
  tags                    = { Name = "runway-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = var.availability_zones[count.index]
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, 10 + count.index) # 10.20.10.0/24, 10.20.11.0/24
  tags              = { Name = "runway-private-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security groups are stateful firewalls around each kind of resource.
# Rules name other groups, not addresses: "the API's tasks", whatever IPs
# they have today.
resource "aws_security_group" "alb" {
  name   = "runway-alb"
  vpc_id = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "api" {
  name   = "runway-api"
  vpc_id = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "worker" {
  name   = "runway-worker" # no ingress rules: nothing calls a worker
  vpc_id = aws_vpc.main.id
}

# Tasks may call out anywhere: ECR, SQS, CloudWatch, Secrets Manager.
resource "aws_vpc_security_group_egress_rule" "tasks_out" {
  for_each          = { api = aws_security_group.api.id, worker = aws_security_group.worker.id }
  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  name   = "runway-db"
  vpc_id = aws_vpc.main.id
}

# Only the API (and the migrate task, which uses the API's group) talks to
# the database. Workers don't need it.
resource "aws_vpc_security_group_ingress_rule" "db_from_api" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
~~~

PostgreSQL, `database.tf`. RDS makes the password and keeps it in Secrets Manager; it never appears in Terraform's state or a task definition.

<!-- file: deploy/terraform/database.tf -->
~~~hcl
# PostgreSQL, managed: AWS patches it, backs it up daily and keeps the
# backups for a week. One availability zone, the smallest Graviton size:
# about $12 a month. multi_az = true keeps a standby in the other zone and
# fails over to it in a minute or two, for twice the price.
resource "aws_db_subnet_group" "main" {
  name       = "runway"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_parameter_group" "main" {
  name   = "runway-postgres17"
  family = "postgres17"

  # Phase 4's two-phase commit, as in compose.yaml.
  parameter {
    name         = "max_prepared_transactions"
    value        = "10"
    apply_method = "pending-reboot"
  }
  # Refuse unencrypted connections.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_db_instance" "main" {
  identifier        = "runway"
  engine            = "postgres"
  engine_version    = "17"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "runway"
  username = "runway"
  # RDS makes the password, keeps it in Secrets Manager and can rotate it.
  # It never appears in Terraform's state or in a task definition.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period      = 7
  performance_insights_enabled = true # 7 days of query statistics, free
  deletion_protection          = var.deletion_protection
  skip_final_snapshot          = !var.deletion_protection
  final_snapshot_identifier    = var.deletion_protection ? "runway-final" : null
}
~~~

The queues, `queues.tf`. SQS counts receives itself and moves a message received five times to its dead-letter queue: the job of Runway's attempt header on RabbitMQ.

<!-- file: deploy/terraform/queues.tf -->
~~~hcl
# SQS in place of RabbitMQ. Queue names can't contain dots, so jobs.commands
# becomes runway-jobs-commands; the SQS bus adapter maps the names.
#
# Each queue has a dead-letter queue. SQS counts receives itself: a
# message received 5 times without being deleted moves to the dead-letter
# queue. RabbitMQ needed our x-runway-attempt header for that.
locals {
  queues = toset(["jobs-commands", "jobs-events"])
}

resource "aws_sqs_queue" "dead" {
  for_each                  = local.queues
  name                      = "runway-${each.key}-dead"
  message_retention_seconds = 1209600 # 14 days, the most SQS allows: time to look
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "main" {
  for_each = local.queues
  name     = "runway-${each.key}"
  # A received message is hidden for this long; deleted when handled, it
  # reappears for another try if not. Longer than a job may run.
  visibility_timeout_seconds = 60
  # Long polling: a receive waits up to 20 s for a message instead of
  # returning empty at once, which is cheaper and faster.
  receive_wait_time_seconds = 20
  sqs_managed_sse_enabled   = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead[each.key].arn
    maxReceiveCount     = 5
  })
}
~~~

The image registry and the load balancer's log bucket, `storage.tf`. Tags in the registry are immutable: step 8's lesson, enforced by the registry.

<!-- file: deploy/terraform/storage.tf -->
~~~hcl
# Where the image lives. Tags can't be overwritten (IMMUTABLE): once
# sha-1a2b3c4 is pushed it always means those bytes, the guarantee step 8
# got from digests.
resource "aws_ecr_repository" "runway" {
  name                 = "runway"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # let "terraform destroy" remove pushed images
  image_scanning_configuration {
    scan_on_push = true # report known vulnerabilities in each pushed image
  }
}

resource "aws_ecr_lifecycle_policy" "runway" {
  repository = aws_ecr_repository.runway.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 20 newest images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# The load balancer's access logs: one line per request, kept 30 days.
resource "aws_s3_bucket" "logs" {
  bucket_prefix = "runway-alb-logs-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # load balancer logs support S3-managed keys only
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

# Load balancers write logs as an AWS-owned account that differs by region.
# This data source knows the account for each region without asking AWS.
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.main.arn }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.logs.arn}/alb/*"
    }]
  })
}
~~~

The roles, `iam.tf`. Each service may touch only its own queues, and only in the direction it uses them:

<!-- file: deploy/terraform/iam.tf -->
~~~hcl
# Two kinds of role per task. The execution role is ECS's, used before the
# container starts: pull the image, send logs, read secrets into the
# environment. The task role is the application's: the AWS calls its code
# makes. Each service gets only what it calls, on only its own queues.
locals {
  ecs_tasks_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  consume = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
  produce = ["sqs:SendMessage", "sqs:GetQueueUrl"]
}

resource "aws_iam_role" "execution" {
  name               = "runway-execution"
  assume_role_policy = local.ecs_tasks_trust
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secret" {
  name = "read-db-password"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_db_instance.main.master_user_secret[0].secret_arn
    }]
  })
}

# The API sends commands, reads events, and dead-letters unreadable events.
resource "aws_iam_role" "api" {
  name               = "runway-api"
  assume_role_policy = local.ecs_tasks_trust
}

resource "aws_iam_role_policy" "api" {
  name = "queues"
  role = aws_iam_role.api.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = local.produce, Resource = [aws_sqs_queue.main["jobs-commands"].arn, aws_sqs_queue.dead["jobs-events"].arn] },
      { Effect = "Allow", Action = local.consume, Resource = aws_sqs_queue.main["jobs-events"].arn },
    ]
  })
}

# The worker reads commands, sends events, and dead-letters unreadable commands.
resource "aws_iam_role" "worker" {
  name               = "runway-worker"
  assume_role_policy = local.ecs_tasks_trust
}

resource "aws_iam_role_policy" "worker" {
  name = "queues"
  role = aws_iam_role.worker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = local.consume, Resource = aws_sqs_queue.main["jobs-commands"].arn },
      { Effect = "Allow", Action = local.produce, Resource = [aws_sqs_queue.main["jobs-events"].arn, aws_sqs_queue.dead["jobs-commands"].arn] },
    ]
  })
}
~~~

The load balancer, `loadbalancer.tf`. Its `deregistration_delay` is step 7's `preStop` sleep, done by the balancer:

<!-- file: deploy/terraform/loadbalancer.tf -->
~~~hcl
# The load balancer: AWS's step 4. It spreads requests over the API tasks
# that pass its health check, across both zones.
resource "aws_lb" "main" {
  name                       = "runway"
  load_balancer_type         = "application"
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  access_logs {
    bucket  = aws_s3_bucket.logs.id
    prefix  = "alb"
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.logs] # the bucket must accept logs first
}

resource "aws_lb_target_group" "api" {
  name        = "runway-api"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # Fargate tasks are registered by IP
  health_check {
    path                = "/ready"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  # When a task stops, keep sending its in-flight requests here for 15 s
  # while new ones go elsewhere: step 7's preStop sleep, done by the
  # load balancer.
  deregistration_delay = 15
}

# Plain HTTP. For HTTPS you need a domain and an ACM certificate: add a
# listener on 443 with certificate_arn, and make this one redirect.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
~~~

The services, `ecs.tf`. A task definition is a Pod spec; a service is a Deployment. The API's service has step 7's rollout settings and a *deployment circuit breaker*, AWS's `--rollback-on-failure`. The worker service ignores its own `desired_count`, because autoscaling owns it: step 11's lesson again.

<!-- file: deploy/terraform/ecs.tf -->
~~~hcl
# ECS runs containers; Fargate runs them without servers to manage. A task
# definition is a Pod spec; a service is a Deployment.
locals {
  image = "${aws_ecr_repository.runway.repository_url}:${var.image_tag}"
  # The database URL has no password; PGPASSWORD, read from Secrets
  # Manager when the task starts, supplies it (the PostgreSQL driver reads
  # it from the environment).
  database_url = "postgres://runway@${aws_db_instance.main.address}:5432/runway?sslmode=require"
  db_password  = [{ name = "PGPASSWORD", valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::" }]
  common_env = [
    { name = "AWS_REGION", value = var.region },
    { name = "SQS_QUEUE_PREFIX", value = "runway-" }, # selects the SQS bus
  ]
  logs = {
    for name in ["api", "worker", "migrate"] : name => {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service[name].name
        awslogs-region        = var.region
        awslogs-stream-prefix = name
      }
    }
  }
}

resource "aws_ecs_cluster" "main" {
  name = "runway"
  setting {
    name  = "containerInsights" # per-task CPU and memory, and RunningTaskCount
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "service" {
  for_each          = toset(["api", "worker", "migrate"])
  name              = "/runway/${each.key}"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "api" {
  family                   = "runway-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # each task gets its own network interface and IP, like a Pod
  cpu                      = 256      # a quarter of a vCPU
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.api.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = "api"
    image        = local.image
    essential    = true
    portMappings = [{ containerPort = 8080 }]
    environment = concat(local.common_env, [
      { name = "DATABASE_URL", value = local.database_url },
      { name = "MIGRATE_ON_START", value = "false" }, # the migrate task does it
      { name = "SHUTDOWN_GRACE", value = "20s" },
    ])
    secrets = local.db_password
    # The image has no shell or curl; step 2's probe binary does the check.
    healthCheck = {
      command  = ["CMD", "/usr/local/bin/probe", "http://127.0.0.1:8080/ready"]
      interval = 10
      retries  = 3
    }
    stopTimeout      = 30 # SIGTERM, then this long before SIGKILL
    logConfiguration = local.logs["api"]
  }])
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "runway-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.worker.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name             = "worker"
    image            = local.image
    essential        = true
    command          = ["/usr/local/bin/worker"]
    environment      = local.common_env
    stopTimeout      = 30
    logConfiguration = local.logs["worker"]
  }])
}

# Run once per release, before updating the services: the Helm hook's job
# (step 7). The "migrate" output prints the command.
resource "aws_ecs_task_definition" "migrate" {
  family                   = "runway-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name             = "migrate"
    image            = local.image
    essential        = true
    command          = ["/usr/local/bin/migrate"]
    environment      = [{ name = "DATABASE_URL", value = local.database_url }]
    secrets          = local.db_password
    logConfiguration = local.logs["migrate"]
  }])
}

resource "aws_ecs_service" "api" {
  name            = "api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_count
  launch_type     = "FARGATE"

  # Replace tasks without dropping below the desired count (step 7's
  # maxUnavailable: 0, maxSurge: 1)...
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  # ...and if new tasks keep failing, stop and roll back to the last
  # working task definition (step 7's --rollback-on-failure).
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  health_check_grace_period_seconds = 30

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true # see network.tf: no NAT gateway
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }
  depends_on = [aws_lb_listener.http]
}

resource "aws_ecs_service" "worker" {
  name            = "worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_min
  launch_type     = "FARGATE"
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = true
  }
  # Autoscaling owns the count (scaling.tf). Without this, every "terraform
  # apply" would reset it: step 11's lesson, again.
  lifecycle {
    ignore_changes = [desired_count]
  }
}
~~~

Step 11's controller, as an AWS service, `scaling.tf`. Target tracking keeps "commands waiting per task" near 8, computed with metric math from SQS and Container Insights:

<!-- file: deploy/terraform/scaling.tf -->
~~~hcl
# Step 11's controller, as an AWS service: Application Auto Scaling keeps
# the commands waiting per worker task near a target, adding tasks fast and
# removing them slowly.
resource "aws_appautoscaling_target" "worker" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.worker_min
  max_capacity       = var.worker_max
}

resource "aws_appautoscaling_policy" "worker_backlog" {
  name               = "backlog-per-task"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.worker.service_namespace
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 8  # commands waiting per task, as PER_REPLICA in step 11
    scale_out_cooldown = 0  # add at once
    scale_in_cooldown  = 60 # remove after a minute: step 11's window
    # Backlog per task = messages waiting / tasks running, by metric math.
    customized_metric_specification {
      metrics {
        id          = "waiting"
        return_data = false
        metric_stat {
          stat = "Sum"
          metric {
            namespace   = "AWS/SQS"
            metric_name = "ApproximateNumberOfMessagesVisible"
            dimensions {
              name  = "QueueName"
              value = aws_sqs_queue.main["jobs-commands"].name
            }
          }
        }
      }
      metrics {
        id          = "tasks"
        return_data = false
        metric_stat {
          stat = "Average"
          metric {
            namespace   = "ECS/ContainerInsights"
            metric_name = "RunningTaskCount"
            dimensions {
              name  = "ClusterName"
              value = aws_ecs_cluster.main.name
            }
            dimensions {
              name  = "ServiceName"
              value = aws_ecs_service.worker.name
            }
          }
        }
      }
      metrics {
        id          = "backlog_per_task"
        label       = "Commands waiting per worker task"
        expression  = "waiting / tasks"
        return_data = true
      }
    }
  }
}
~~~

Step 10's alerts, as CloudWatch alarms, plus the budget, `alarms.tf`:

<!-- file: deploy/terraform/alarms.tf -->
~~~hcl
# Step 10's alerts, in CloudWatch, sent by email through an SNS topic.
resource "aws_sns_topic" "alarms" {
  name = "runway-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email" # AWS emails a link; nothing arrives until you click it
  endpoint  = var.alert_email
}

# The fast burn: over 1.44% of requests failing (14.4 times the 0.1%
# budget) in each of two 5-minute periods.
resource "aws_cloudwatch_metric_alarm" "api_errors" {
  alarm_name          = "runway-api-error-budget-burn"
  alarm_description   = "Over 1.44% of API requests are failing. Runbook: docs/runbooks/api-errors.md"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.0144
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching" # no traffic is not an outage
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    id          = "ratio"
    expression  = "errors / requests"
    label       = "Share of requests failing"
    return_data = true
  }
}

# Any dead-lettered message (the game day's finding).
resource "aws_cloudwatch_metric_alarm" "dead_letters" {
  for_each            = aws_sqs_queue.dead
  alarm_name          = "runway-dead-letters-${each.key}"
  alarm_description   = "Messages wait in ${each.value.name}. Read them, fix the cause, then redrive or discard them."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

# The database running out of CPU or disk.
resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "runway-db-cpu"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "db_storage" {
  alarm_name          = "runway-db-storage"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 2 * 1024 * 1024 * 1024 # 2 GiB
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

# A cloud account bills by the hour whether you are using it or not. This
# emails you before a forgotten "terraform destroy" becomes expensive.
resource "aws_budgets_budget" "monthly" {
  count        = var.alert_email == "" ? 0 : 1
  name         = "runway-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}
~~~

The outputs, `outputs.tf`, including the commands to push an image and to run the migration (ECS has no Helm hooks; the migration is a one-off task you run before each release):

<!-- file: deploy/terraform/outputs.tf -->
~~~hcl
output "url" {
  description = "The API, through the load balancer."
  value       = "http://${aws_lb.main.dns_name}"
}

output "ecr_repository" {
  description = "Push images here (see the push output)."
  value       = aws_ecr_repository.runway.repository_url
}

output "push" {
  description = "Commands to push the local runway:dev image as var.image_tag."
  value       = <<-EOT
    aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${split("/", aws_ecr_repository.runway.repository_url)[0]}
    docker tag runway:dev ${aws_ecr_repository.runway.repository_url}:${var.image_tag}
    docker push ${aws_ecr_repository.runway.repository_url}:${var.image_tag}
  EOT
}

output "migrate" {
  description = "Run the migration once, and wait for it, before each release."
  value       = <<-EOT
    aws ecs run-task --region ${var.region} --cluster ${aws_ecs_cluster.main.name} \
      --task-definition ${aws_ecs_task_definition.migrate.family} --launch-type FARGATE \
      --network-configuration 'awsvpcConfiguration={subnets=[${join(",", aws_subnet.public[*].id)}],securityGroups=[${aws_security_group.api.id}],assignPublicIp=ENABLED}' \
      --query 'tasks[0].taskArn' --output text
  EOT
}

output "queues" {
  description = "The SQS queue URLs."
  value       = { for k, q in aws_sqs_queue.main : k => q.url }
}
~~~

An example of the variables you'd set, `terraform.tfvars.example`:

<!-- file: deploy/terraform/terraform.tfvars.example -->
~~~hcl
# Copy to terraform.tfvars and edit. terraform.tfvars is read automatically;
# keep it out of git if it holds anything personal.
region             = "us-east-1"
availability_zones = ["us-east-1a", "us-east-1b"]
image_tag          = "sha-1a2b3c4"
alert_email        = "you@example.com"
monthly_budget_usd = 50
~~~

And keep state and secrets out of git, `deploy/terraform/.gitignore`:

<!-- file: deploy/terraform/.gitignore -->
~~~text
.terraform/
*.tfstate
*.tfstate.*
terraform.tfvars
*.tfplan
~~~

<!-- run: cd deploy/terraform && terraform fmt -check -recursive && terraform init -input=false -backend=false > /dev/null && terraform validate > /dev/null && AWS_ACCESS_KEY_ID=offline AWS_SECRET_ACCESS_KEY=offline terraform plan -input=false -no-color -var offline=true -var image_tag=ci | grep -q 'Plan: 60 to add, 0 to change, 0 to destroy.' -->

~~~bash
cd deploy/terraform
terraform init
terraform validate
AWS_ACCESS_KEY_ID=offline AWS_SECRET_ACCESS_KEY=offline \
  terraform plan -var offline=true -var image_tag=sha-1a2b3c4 -var alert_email=you@example.com
~~~

~~~text
Success! The configuration is valid.
...
  # aws_cloudwatch_metric_alarm.api_errors will be created
  + resource "aws_cloudwatch_metric_alarm" "api_errors" {
      + alarm_description                     = "Over 1.44% of API requests are failing. Runbook: docs/runbooks/api-errors.md"
      + alarm_name                            = "runway-api-error-budget-burn"
...
Plan: 62 to add, 0 to change, 0 to destroy.
~~~

Sixty-two resources, with an email address (60 without: no budget, no email subscription). Read the whole plan once. Every `(known after apply)` is a value AWS chooses; everything else is decided by your files, and a reviewer can check it before anything exists.

### Runway on SQS

RabbitMQ's adapter doesn't speak SQS. Write another, behind the same `bus` interfaces, so nothing else in Runway changes.

<!-- run: go get github.com/aws/aws-sdk-go-v2@v1.47.1 github.com/aws/aws-sdk-go-v2/config@v1.33.7 github.com/aws/aws-sdk-go-v2/credentials@v1.20.7 github.com/aws/aws-sdk-go-v2/service/sqs@v1.52.2 -->

~~~bash
go get github.com/aws/aws-sdk-go-v2@v1.47.1 github.com/aws/aws-sdk-go-v2/config@v1.33.7 \
  github.com/aws/aws-sdk-go-v2/credentials@v1.20.7 github.com/aws/aws-sdk-go-v2/service/sqs@v1.52.2
~~~

Create `internal/sqsbus/sqsbus.go`. Read the package comment first: it lists every way SQS differs from RabbitMQ, and each difference shows up in the code. The one to notice is the retry: a failed message is hidden for a growing delay before it reappears. That is the delayed retry the postmortem asked for, and SQS gives it for free.

<!-- file: internal/sqsbus/sqsbus.go -->
~~~go
// Package sqsbus is a bus on Amazon SQS, for running Runway on AWS (Phase
// 5, step 13). It implements bus.Publisher and bus.Subscriber, so the
// services don't change: only the adapter does.
//
// SQS differs from RabbitMQ in ways the adapter absorbs:
//   - Queue names can't contain dots: jobs.commands is "<prefix>jobs-commands".
//   - A received message isn't removed; it is hidden for the queue's
//     visibility timeout. Handled, it is deleted. Not handled, it reappears
//     and is received again.
//   - SQS counts receives itself, and its redrive policy moves a message
//     received too often to the dead-letter queue. No attempt header.
//   - A failed message can be hidden for a chosen time before it
//     reappears: a delayed retry, with backoff, for free.
//   - Queues have no length limit, so Publish never returns bus.ErrFull.
package sqsbus

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"

	"runway/internal/bus"
	"runway/internal/messages"
	"runway/internal/retry"
)

// API is the part of the SQS client this package uses. *sqs.Client has it.
type API interface {
	GetQueueUrl(ctx context.Context, in *sqs.GetQueueUrlInput, opts ...func(*sqs.Options)) (*sqs.GetQueueUrlOutput, error)
	SendMessage(ctx context.Context, in *sqs.SendMessageInput, opts ...func(*sqs.Options)) (*sqs.SendMessageOutput, error)
	ReceiveMessage(ctx context.Context, in *sqs.ReceiveMessageInput, opts ...func(*sqs.Options)) (*sqs.ReceiveMessageOutput, error)
	DeleteMessage(ctx context.Context, in *sqs.DeleteMessageInput, opts ...func(*sqs.Options)) (*sqs.DeleteMessageOutput, error)
	ChangeMessageVisibility(ctx context.Context, in *sqs.ChangeMessageVisibilityInput, opts ...func(*sqs.Options)) (*sqs.ChangeMessageVisibilityOutput, error)
}

// Client is a bus on SQS.
type Client struct {
	api    API
	prefix string
	// backoff sets how long a failed message stays hidden before its next
	// try. Its Base and Max matter; Attempts doesn't (SQS counts).
	backoff retry.Policy
	wait    int32 // long-poll seconds per receive

	mu   sync.Mutex
	urls map[string]string // queue name -> URL, looked up once
}

// New returns a bus whose queues are named prefix + the queue name with
// dots as dashes.
func New(api API, prefix string) *Client {
	return &Client{
		api:     api,
		prefix:  prefix,
		backoff: retry.Policy{Base: time.Second, Max: 30 * time.Second},
		wait:    20,
		urls:    map[string]string{},
	}
}

// Name maps a Runway queue name to an SQS queue name.
func (c *Client) Name(queue string) string {
	return c.prefix + strings.ReplaceAll(queue, ".", "-")
}

func (c *Client) url(ctx context.Context, queue string) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if u, ok := c.urls[queue]; ok {
		return u, nil
	}
	out, err := c.api.GetQueueUrl(ctx, &sqs.GetQueueUrlInput{QueueName: aws.String(c.Name(queue))})
	if err != nil {
		return "", fmt.Errorf("find queue %s: %w", c.Name(queue), err)
	}
	c.urls[queue] = *out.QueueUrl
	return *out.QueueUrl, nil
}

// Publish sends msg to queue. SQS stores it durably before answering.
func (c *Client) Publish(ctx context.Context, queue string, msg messages.Envelope) error {
	body, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	u, err := c.url(ctx, queue)
	if err != nil {
		return err
	}
	_, err = c.api.SendMessage(ctx, &sqs.SendMessageInput{QueueUrl: aws.String(u), MessageBody: aws.String(string(body))})
	if err != nil {
		return fmt.Errorf("send to %s: %w", c.Name(queue), err)
	}
	return nil
}

// Subscribe receives messages from queue and hands them to handle until
// ctx is cancelled. A message is deleted only after handle accepts it.
func (c *Client) Subscribe(ctx context.Context, queue string, handle bus.Handler) error {
	u, err := c.url(ctx, queue)
	if err != nil {
		return err
	}
	failures := 0
	for ctx.Err() == nil {
		out, err := c.api.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl:                    aws.String(u),
			MaxNumberOfMessages:         1, // one at a time, as RabbitMQ's prefetch of 1
			WaitTimeSeconds:             c.wait,
			MessageSystemAttributeNames: []types.MessageSystemAttributeName{types.MessageSystemAttributeNameApproximateReceiveCount},
		})
		if ctx.Err() != nil {
			return nil
		}
		if err != nil {
			// SQS is reached over HTTPS; a failed call is usually brief.
			// Give up only if it keeps failing.
			failures++
			if failures == 5 {
				return fmt.Errorf("receive from %s: %w", c.Name(queue), err)
			}
			select {
			case <-ctx.Done():
				return nil
			case <-time.After(c.backoff.Backoff(failures)):
			}
			continue
		}
		failures = 0
		for _, m := range out.Messages {
			c.deliver(ctx, queue, u, m, handle)
		}
	}
	return nil
}

func (c *Client) deliver(ctx context.Context, queue, u string, m types.Message, handle bus.Handler) {
	var msg messages.Envelope
	if err := json.Unmarshal([]byte(aws.ToString(m.Body)), &msg); err != nil {
		c.deadLetter(ctx, queue, u, m) // unreadable: no retry can help
		return
	}
	err := handle(context.WithoutCancel(ctx), msg)
	switch {
	case err == nil:
		_, _ = c.api.DeleteMessage(context.WithoutCancel(ctx), &sqs.DeleteMessageInput{QueueUrl: aws.String(u), ReceiptHandle: m.ReceiptHandle})
	case bus.IsPermanent(err):
		c.deadLetter(ctx, queue, u, m)
	default:
		// Hide it for a while, growing with each receive, then let it
		// reappear. After the redrive policy's limit, SQS dead-letters it.
		receives, _ := strconv.Atoi(m.Attributes[string(types.MessageSystemAttributeNameApproximateReceiveCount)])
		delay := max(c.backoff.Backoff(receives), time.Second)
		_, _ = c.api.ChangeMessageVisibility(context.WithoutCancel(ctx), &sqs.ChangeMessageVisibilityInput{
			QueueUrl:          aws.String(u),
			ReceiptHandle:     m.ReceiptHandle,
			VisibilityTimeout: int32(delay / time.Second),
		})
	}
}

// deadLetter moves a message to queue's dead-letter queue at once: SQS's
// redrive only does that after repeated receives.
func (c *Client) deadLetter(ctx context.Context, queue, u string, m types.Message) {
	ctx = context.WithoutCancel(ctx)
	dead, err := c.url(ctx, queue+".dead")
	if err != nil {
		return // the redrive policy still catches it, after more receives
	}
	if _, err := c.api.SendMessage(ctx, &sqs.SendMessageInput{QueueUrl: aws.String(dead), MessageBody: m.Body}); err != nil {
		return
	}
	_, _ = c.api.DeleteMessage(ctx, &sqs.DeleteMessageInput{QueueUrl: aws.String(u), ReceiptHandle: m.ReceiptHandle})
}

// Connect makes a Client from the standard AWS configuration: the region
// from AWS_REGION, credentials from the ECS task's role (or your
// ~/.aws files, or AWS_ACCESS_KEY_ID), and, for a local stand-in such as
// ElasticMQ, the endpoint from AWS_ENDPOINT_URL_SQS.
func Connect(ctx context.Context, prefix string) (*Client, error) {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("load AWS configuration: %w", err)
	}
	return New(sqs.NewFromConfig(cfg), prefix), nil
}
~~~

Test it against **ElasticMQ**, a small server that speaks SQS's API. Add it to `compose.yaml`:

Change:

<!-- edit: compose.yaml -->
~~~yaml

  # Runway itself. These start only with --profile app, so a plain
~~~

to:

~~~yaml

  # A stand-in for Amazon SQS (Phase 5, step 13), so the SQS adapter is
  # tested without an AWS account. It speaks SQS's API on port 9324.
  elasticmq:
    image: softwaremill/elasticmq-native:1.7.1
    ports:
      - "9324:9324"

  # Runway itself. These start only with --profile app, so a plain
~~~


~~~bash
docker compose up -d --wait elasticmq
export RUNWAY_SQS_ENDPOINT=http://localhost:9324
~~~

Create `internal/sqsbus/sqsbus_test.go`:

<!-- file: internal/sqsbus/sqsbus_test.go -->
~~~go
package sqsbus

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"

	"runway/internal/bus"
	"runway/internal/messages"
)

// newBus connects to an SQS-compatible server, such as ElasticMQ:
//
//	docker run -d -p 9324:9324 softwaremill/elasticmq-native
//	RUNWAY_SQS_ENDPOINT=http://localhost:9324 go test ./internal/sqsbus
//
// It creates jobs.commands and its dead-letter queue under a fresh prefix,
// with a redrive policy like the one in deploy/terraform/queues.tf.
func newBus(t *testing.T, maxReceives int) (*Client, *sqs.Client) {
	t.Helper()
	endpoint := os.Getenv("RUNWAY_SQS_ENDPOINT")
	if endpoint == "" {
		t.Skip("set RUNWAY_SQS_ENDPOINT to run SQS tests")
	}
	api := sqs.New(sqs.Options{
		Region:       "us-east-1",
		BaseEndpoint: aws.String(endpoint),
		Credentials:  credentials.NewStaticCredentialsProvider("test", "test", ""),
	})
	c := New(api, "t"+strings.ToLower(rand.Text()[:8])+"-")
	c.wait = 1 // short long-polls keep the tests quick

	ctx := context.Background()
	dead, err := api.CreateQueue(ctx, &sqs.CreateQueueInput{QueueName: aws.String(c.Name("jobs.commands.dead"))})
	if err != nil {
		t.Fatal(err)
	}
	attrs, err := api.GetQueueAttributes(ctx, &sqs.GetQueueAttributesInput{
		QueueUrl: dead.QueueUrl, AttributeNames: []types.QueueAttributeName{types.QueueAttributeNameQueueArn},
	})
	if err != nil {
		t.Fatal(err)
	}
	redrive, _ := json.Marshal(map[string]any{
		"deadLetterTargetArn": attrs.Attributes[string(types.QueueAttributeNameQueueArn)],
		"maxReceiveCount":     maxReceives,
	})
	if _, err := api.CreateQueue(ctx, &sqs.CreateQueueInput{
		QueueName:  aws.String(c.Name("jobs.commands")),
		Attributes: map[string]string{"VisibilityTimeout": "30", "RedrivePolicy": string(redrive)},
	}); err != nil {
		t.Fatal(err)
	}
	return c, api
}

func envelope(t *testing.T, jobID int64) messages.Envelope {
	t.Helper()
	m, err := messages.New(messages.TypeRunJob, messages.RunJob{JobID: jobID}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// subscribe runs Subscribe in the background until the test ends.
func subscribe(t *testing.T, c *Client, handle bus.Handler) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- c.Subscribe(ctx, "jobs.commands", handle) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Errorf("Subscribe: %v", err)
		}
	})
}

// waiting counts the messages visible in queue right now.
func waiting(t *testing.T, c *Client, api *sqs.Client, queue string) int {
	t.Helper()
	u, err := c.url(context.Background(), queue)
	if err != nil {
		t.Fatal(err)
	}
	out, err := api.GetQueueAttributes(context.Background(), &sqs.GetQueueAttributesInput{
		QueueUrl: aws.String(u), AttributeNames: []types.QueueAttributeName{types.QueueAttributeNameApproximateNumberOfMessages},
	})
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	_ = json.Unmarshal([]byte(out.Attributes[string(types.QueueAttributeNameApproximateNumberOfMessages)]), &n)
	return n
}

func eventually(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestQueueNamesHaveNoDots(t *testing.T) {
	c := New(nil, "runway-")
	if got := c.Name("jobs.commands.dead"); got != "runway-jobs-commands-dead" {
		t.Fatalf("Name = %q; it must match deploy/terraform/queues.tf", got)
	}
}

func TestAMessageIsDeliveredAndDeleted(t *testing.T) {
	c, api := newBus(t, 3)
	sent := envelope(t, 1)
	if err := c.Publish(context.Background(), "jobs.commands", sent); err != nil {
		t.Fatal(err)
	}
	got := make(chan messages.Envelope, 10)
	subscribe(t, c, func(_ context.Context, m messages.Envelope) error { got <- m; return nil })

	if m := <-got; m.ID != sent.ID {
		t.Fatalf("received %s, sent %s", m.ID, sent.ID)
	}
	time.Sleep(2 * time.Second) // long enough for a redelivery, if it weren't deleted
	if len(got) != 0 || waiting(t, c, api, "jobs.commands") != 0 {
		t.Fatal("an accepted message came back")
	}
}

// A failed message comes back after a delay, not at once: the retry storm
// of the game day can't happen here.
func TestAFailedMessageReturnsAfterADelay(t *testing.T) {
	c, _ := newBus(t, 3)
	if err := c.Publish(context.Background(), "jobs.commands", envelope(t, 2)); err != nil {
		t.Fatal(err)
	}
	tries := make(chan time.Time, 10)
	var calls atomic.Int32
	subscribe(t, c, func(context.Context, messages.Envelope) error {
		tries <- time.Now()
		if calls.Add(1) == 1 {
			return errors.New("transient") // fail the first try only
		}
		return nil
	})
	first, second := <-tries, <-tries
	if gap := second.Sub(first); gap < time.Second {
		t.Fatalf("retried after %v; want at least the 1 s minimum backoff", gap)
	}
}

func TestAPermanentFailureIsDeadLetteredAtOnce(t *testing.T) {
	c, api := newBus(t, 3)
	if err := c.Publish(context.Background(), "jobs.commands", envelope(t, 3)); err != nil {
		t.Fatal(err)
	}
	var tries atomic.Int32
	subscribe(t, c, func(context.Context, messages.Envelope) error {
		tries.Add(1)
		return bus.Permanent(errors.New("can't read this"))
	})
	eventually(t, "the dead-letter queue", func() bool { return waiting(t, c, api, "jobs.commands.dead") == 1 })
	if n := tries.Load(); n != 1 {
		t.Fatalf("handled %d times; a permanent failure shouldn't be retried", n)
	}
}

// After maxReceiveCount receives, SQS itself moves the message aside.
func TestRepeatedFailuresAreDeadLetteredBySQS(t *testing.T) {
	c, api := newBus(t, 2)
	if err := c.Publish(context.Background(), "jobs.commands", envelope(t, 4)); err != nil {
		t.Fatal(err)
	}
	subscribe(t, c, func(context.Context, messages.Envelope) error { return errors.New("always fails") })
	eventually(t, "the redrive to the dead-letter queue", func() bool { return waiting(t, c, api, "jobs.commands.dead") == 1 })
}
~~~

Two tests failed on my first try, both bugs in the *tests*, both worth knowing. One hung for ever: its handler decided whether to fail by checking `len(tries)` *after* sending to the channel, and when the test had already read the value the length was 0, so the first try succeeded, the message was deleted, and the test waited for a retry that would never come. The other was a data race (`tries++` from the subscriber's goroutine) that `-race` caught. Both now use atomic counters.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/sqsbus/... && go test -race -count=1 ./internal/sqsbus/... -->

~~~bash
go test -v ./internal/sqsbus/
~~~

~~~text
--- PASS: TestQueueNamesHaveNoDots (0.00s)
--- PASS: TestAMessageIsDeliveredAndDeleted (5.05s)
--- PASS: TestAFailedMessageReturnsAfterADelay (1.41s)
--- PASS: TestAPermanentFailureIsDeadLetteredAtOnce (0.25s)
--- PASS: TestRepeatedFailuresAreDeadLetteredBySQS (2.82s)
ok  	runway/internal/sqsbus	9.617s
~~~

Now let the services choose SQS when `SQS_QUEUE_PREFIX` is set. In `cmd/api/main.go`, seven small changes.

Import the adapter:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/stream"
~~~

to:

~~~go
	"runway/internal/sqsbus"
	"runway/internal/stream"
~~~

A setting for it:

<!-- edit: cmd/api/main.go -->
~~~go
	AMQPURL          string
~~~

to:

~~~go
	AMQPURL          string
	SQSPrefix        string // step 13: use SQS, with queues named with this prefix
~~~

Read it, and refuse two buses at once:

<!-- edit: cmd/api/main.go -->
~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), DatabaseURL: getenv("DATABASE_URL"), RedisURL: getenv("REDIS_URL"), ServedBy: getenv("SERVED_BY")}
~~~

to:

~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), SQSPrefix: getenv("SQS_QUEUE_PREFIX"), DatabaseURL: getenv("DATABASE_URL"), RedisURL: getenv("REDIS_URL"), ServedBy: getenv("SERVED_BY")}
	if cfg.AMQPURL != "" && cfg.SQSPrefix != "" {
		return config{}, errors.New("set AMQP_URL or SQS_QUEUE_PREFIX, not both: there is one message bus")
	}
~~~

Connect to SQS first, when asked (it needs a context, to load the AWS configuration):

<!-- edit: cmd/api/main.go -->
~~~go
func connectBus(cfg config, metrics *httpapi.Metrics) (bus.Publisher, bus.Subscriber, func() error, error) {
~~~

to:

~~~go
func connectBus(ctx context.Context, cfg config, metrics *httpapi.Metrics) (bus.Publisher, bus.Subscriber, func() error, error) {
	if cfg.SQSPrefix != "" {
		client, err := sqsbus.Connect(ctx, cfg.SQSPrefix)
		if err != nil {
			return nil, nil, nil, err
		}
		return client, client, func() error { return nil }, nil
	}
~~~

Pass the context:

<!-- edit: cmd/api/main.go -->
~~~go
connectBus(cfg, metrics)
~~~

to:

~~~go
connectBus(ctx, cfg, metrics)
~~~

In-process workers only on the in-memory bus, not whenever RabbitMQ is absent:

<!-- edit: cmd/api/main.go -->
~~~go
	workers := 0
	if cfg.AMQPURL == "" {
~~~

to:

~~~go
	workers := 0
	if busName(cfg) == "in-memory" {
~~~

And name the bus in the start-up log:

<!-- edit: cmd/api/main.go -->
~~~go
func busName(cfg config) string {
	if cfg.AMQPURL == "" {
		return "in-memory"
	}
	return "rabbitmq"
}
~~~

to:

~~~go
func busName(cfg config) string {
	switch {
	case cfg.SQSPrefix != "":
		return "sqs"
	case cfg.AMQPURL != "":
		return "rabbitmq"
	default:
		return "in-memory"
	}
}
~~~

In `cmd/worker/main.go`, exactly one bus, RabbitMQ or SQS:

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	"runway/internal/rabbit"
	"runway/internal/telemetry"
~~~

to:

~~~go
	"runway/internal/rabbit"
	"runway/internal/sqsbus"
	"runway/internal/telemetry"
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	AMQPURL       string
	Workers       int
~~~

to:

~~~go
	AMQPURL       string
	SQSPrefix     string // step 13: SQS instead of RabbitMQ
	Workers       int
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL")}
	if cfg.AMQPURL == "" {
		return config{}, errors.New("AMQP_URL is required, for example amqp://guest:guest@localhost:5672/")
~~~

to:

~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), SQSPrefix: getenv("SQS_QUEUE_PREFIX")}
	if (cfg.AMQPURL == "") == (cfg.SQSPrefix == "") {
		return config{}, errors.New("AMQP_URL is required, for example amqp://guest:guest@localhost:5672/ (or, on AWS, SQS_QUEUE_PREFIX instead)")
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	client, err := rabbit.Dial(cfg.AMQPURL, rabbit.Options{
		MaxLength:     cfg.QueueCapacity,
		MaxDeliveries: cfg.MaxDeliveries,
		Prefetch:      1,
	}, messages.CommandsQueue, messages.EventsQueue)
~~~

to:

~~~go
	client, err := connectBus(ctx, cfg)
~~~

Add this at the end of the file:

<!-- append: cmd/worker/main.go -->
~~~go
// busClient is what the worker needs from a message bus.
type busClient interface {
	bus.Publisher
	bus.Subscriber
	Close() error
}

type sqsClient struct{ *sqsbus.Client }

func (sqsClient) Close() error { return nil } // plain HTTPS calls: nothing to close

// connectBus connects to RabbitMQ, or with SQS_QUEUE_PREFIX set, to SQS.
func connectBus(ctx context.Context, cfg config) (busClient, error) {
	if cfg.SQSPrefix != "" {
		client, err := sqsbus.Connect(ctx, cfg.SQSPrefix)
		if err != nil {
			return nil, err
		}
		return sqsClient{client}, nil
	}
	return rabbit.Dial(cfg.AMQPURL, rabbit.Options{
		MaxLength:     cfg.QueueCapacity,
		MaxDeliveries: cfg.MaxDeliveries,
		Prefetch:      1,
	}, messages.CommandsQueue, messages.EventsQueue)
}
~~~


And test that rule, in `cmd/worker/main_test.go`:

Add this at the end of the file:

<!-- append: cmd/worker/main_test.go -->
~~~go
func TestExactlyOneBus(t *testing.T) {
	if _, err := loadConfig(env(map[string]string{"SQS_QUEUE_PREFIX": "runway-"})); err != nil {
		t.Fatalf("SQS alone: %v", err)
	}
	both := map[string]string{"AMQP_URL": "amqp://localhost/", "SQS_QUEUE_PREFIX": "runway-"}
	if _, err := loadConfig(env(both)); err == nil {
		t.Fatal("AMQP_URL and SQS_QUEUE_PREFIX together should be refused")
	}
}
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./cmd/... -->

Run Runway on ElasticMQ, with the SDK's standard variables pointing it there (`AWS_ENDPOINT_URL_SQS` is how the AWS SDKs are aimed at any SQS-compatible endpoint):

~~~bash
for q in runway-jobs-commands-dead runway-jobs-events-dead runway-jobs-commands runway-jobs-events; do
  curl -s -o /dev/null "http://localhost:9324/?Action=CreateQueue&QueueName=$q"
done
export SQS_QUEUE_PREFIX=runway- AWS_ENDPOINT_URL_SQS=http://localhost:9324 AWS_REGION=us-east-1 AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=x
LISTEN_ADDR=127.0.0.1:18080 GRPC_ADDR=127.0.0.1:19090 go run ./cmd/api &
go run ./cmd/worker &
sleep 3
curl -s -X POST localhost:18080/jobs -H 'Content-Type: application/json' -d '{"description":"via sqs","duration_ms":200}'
sleep 3; curl -s localhost:18080/jobs/1
~~~

~~~text
{"id":1,"state":"queued","description":"via sqs","duration_ms":200,...}
{"id":1,"state":"completed","description":"via sqs","duration_ms":200,...}
~~~

The API's start-up line says `"bus":"sqs"`. Same code, a different bus, and nothing above the adapter knew.

One more thing to check before trusting `ecs.tf`: the database URL there has no password, and the password arrives separately as `PGPASSWORD`, from Secrets Manager. Does pgx combine them? Against your local PostgreSQL:

~~~bash
DATABASE_URL='postgres://runway@localhost:5432/runway' PGPASSWORD= go run ./cmd/migrate
DATABASE_URL='postgres://runway@localhost:5432/runway' PGPASSWORD=runway go run ./cmd/migrate
~~~

~~~text
127.0.0.1:5432 (localhost): failed SASL auth: FATAL: password authentication failed for user "runway" (SQLSTATE 28P01)
schema up to date
~~~

It does. Check a claim like that before you build on it: finding out after `apply` costs a deploy and some money.

### CI checks the Terraform too

In `.github/workflows/ci.yml`, add the SQS endpoint for the tests, and a Terraform check that formats, validates and plans offline:

Change:

<!-- edit: .github/workflows/ci.yml -->
~~~yaml
      RUNWAY_KAFKA_BROKERS: localhost:9092
    steps:
~~~

to:

~~~yaml
      RUNWAY_KAFKA_BROKERS: localhost:9092
      RUNWAY_SQS_ENDPOINT: http://localhost:9324
    steps:
~~~

Change:

<!-- edit: .github/workflows/ci.yml -->
~~~yaml
          promtool test rules rules_test.yml

~~~

to:

~~~yaml
          promtool test rules rules_test.yml
      # The AWS configuration: formatted, valid, and a full plan with no AWS
      # account (offline = true; see versions.tf). Applying stays a person's
      # decision: it costs money.
      - uses: hashicorp/setup-terraform@v4
      - name: Check the Terraform
        working-directory: deploy/terraform
        env:
          AWS_ACCESS_KEY_ID: offline
          AWS_SECRET_ACCESS_KEY: offline
        run: |
          terraform fmt -check -recursive
          terraform init -input=false -backend=false
          terraform validate
          terraform plan -input=false -var offline=true -var image_tag=ci

~~~


### Apply it (optional, and it costs money)

If you have an AWS account and want to see it run: it costs about $2.50 a day (the load balancer, Fargate tasks, the database and public IP addresses), so do it in one sitting and destroy it after. You need the AWS CLI, logged in (`aws sts get-caller-identity` shows who you are).

~~~bash
cd deploy/terraform
cp terraform.tfvars.example terraform.tfvars        # then edit: your email, a region, a tag
terraform apply -target=aws_ecr_repository.runway   # the registry first: it needs an image
terraform output -raw push | bash                   # push runway:dev under image_tag
terraform apply                                     # everything else
terraform output -raw migrate | bash                # run the migration task; wait for it to stop
curl -s "$(terraform output -raw url)/health"
~~~

Then try what you did on kind: send jobs, watch the worker service scale, read the logs in CloudWatch, break something and watch an alarm. And confirm the email subscription AWS sends you, or the alarms go nowhere. When you're done:

~~~bash
terraform destroy
~~~

Check the billing page the next day. The budget alarm is there for the day you forget.

**Explain it:** what does `terraform plan` compare, and with what? Why are the tasks in public subnets, what does that cost in safety, and what would production do instead? What is the difference between an ECS task's execution role and its task role? Which parts of steps 3 to 12 does each AWS service replace, and which did you have to rebuild (the migration hook, for example)? Why does SQS not need the attempt header?

**Read.** *Terraform: Up & Running* (Brikman, 3rd edition), chapters 2 to 3, on state. The AWS documentation on [ECS task IAM roles](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html) and the [SQS developer guide](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html)'s pages on visibility timeouts and dead-letter queues. Then the AWS Well-Architected Framework's [cost optimization pillar](https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html), the first chapter. Carry this question in: the Raft cluster of Phase 4 has no place in this configuration. Where would `metad` run on AWS, and what managed service would you consider instead?

---

## Rebuild it yourself

Close the guide. In your own `runway` repository, rebuild Phase 5 from these contracts:
- one image for every command, distroless, non-root by number, listening on `0.0.0.0`;
- the start order: data services, then the migration, then the services, with health and readiness that say what clients need;
- the Kubernetes objects each part of Runway needs (Deployment or StatefulSet, which Service, which probes), and why;
- the chart's values: tag or digest, the shutdown timings and the rule between them, the canary, the autoscaler's ownership of `replicas`;
- the pipeline's jobs and what each may do: test, build once, smoke-test that file, publish by digest;
- trace propagation: `traceparent` over HTTP, `Envelope.Trace` through the outbox and the bus, and which side continues which trace;
- the SLOs, the burn-rate windows and factors, and a test for each alert;
- the controller's loop: observe the backlog, compare, scale through the scale subresource, scale down only to the window's maximum;
- backpressure: a full queue is waited out, not failed;
- the AWS resources, and which step each one replaces.

Then repeat the experiments on *your* system, writing each hypothesis down first:
1. stop a container that ignores `SIGTERM`, and one that doesn't;
2. delete a Pod, starve one of memory, stop a node, and time each recovery;
3. slow one Pod and compare random with two choices;
4. measure a rolling restart with a new connection per request, with and without the `preStop` sleep;
5. follow one job through Jaeger, and find the outbox wait;
6. take the database away under load and time the page;
7. send a burst and watch the autoscaler;
8. stop the event consumer, slow the database, and partition `metad`; then write the postmortem.

## Checkpoint

You're ready for Phase 6 when you can, without the guide:

1. Explain what namespaces and cgroups do to a process, what exit status 137 means, and why PID 1 needs to handle `SIGTERM`.
2. Explain why `127.0.0.1` fails inside a container, and what a health check should test.
3. Name the controllers that act when a Pod is deleted, and explain liveness vs readiness, and requests vs limits.
4. Explain why a stopped node's Pods took almost six minutes to be replaced.
5. Explain how a Service's virtual IP reaches a Pod, why gRPC defeats it, and what a headless Service changes.
6. Compare layer-4 and layer-7 balancing, with your measurements, and explain the power of two choices.
7. Explain what a StatefulSet gives a database, and why `metad` needs `Parallel` and `publishNotReadyAddresses`.
8. Explain the shutdown race, why kload missed it, and what fixed it.
9. Explain tags, digests and image IDs, and why the pipeline builds once.
10. Trace a job across every process and broker, and explain why the outbox row carries the trace.
11. Define an SLI, an SLO and an error budget, explain the two-window burn-rate alert, and read a promtool test.
12. Explain the USE method, with Runway's workers as the example.
13. Explain what makes a controller level-triggered, and why scale-down waits.
14. Explain the step 11 cascade: its trigger, its amplifiers, and the fix for each.
15. Explain why readiness should not check a dependency every Pod shares.
16. Read a Terraform plan, and map each AWS resource to the step it replaces.

## If it goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `curl: (56) Recv failure: Connection reset by peer` from a container | The process listens on `127.0.0.1` inside the container | Set `LISTEN_ADDR=0.0.0.0:8080` (the Dockerfile's `ENV` line) |
| `CreateContainerConfigError`: `image has non-numeric user` | `USER nonroot` with `runAsNonRoot: true` | `USER 65532:65532` |
| A Pod is `CrashLoopBackOff` with `OOM-killed` or exit 137 | The memory limit is too low | Raise the limit; check `GOMEMLIMIT` follows it |
| New code doesn't seem to run on kind | `kind load` failed, or a tag didn't change with `IfNotPresent` | Load one image per command, watch the output, and `kubectl rollout restart` |
| `kubectl wait` says `no matching resources found` | The Pods don't exist yet | Wait for the StatefulSet with `kubectl rollout status statefulset/NAME` |
| API Pods are ready but every write fails with `relation ... does not exist` | The migration didn't run | Run the migration Job (or `helm upgrade`, which runs the hook) |
| `metad-0` stays `0/1` and no `metad-1` appears | `podManagementPolicy` is `OrderedReady` | `podManagementPolicy: Parallel` |
| A drained StatefulSet Pod stays `Pending` | Its volume is on the cordoned node | `kubectl uncordon` the node; local volumes can't move |
| `helm install` says an object exists and isn't managed by Helm | Objects made with `kubectl apply` | Delete them first (keep the PVCs) |
| `helm upgrade` fails in a template that reads a new value | `--reuse-values` ignores the chart's new defaults | `--reset-then-reuse-values` |
| Workers scale back to 1 after a `helm upgrade` | The chart stopped setting `replicas`, and Helm removed the field | Expected once; the autoscaler restores the count |
| No traces in Jaeger | `OTEL_EXPORTER_OTLP_ENDPOINT` unset, or the collector config wrong | Check the Pods' environment, then `kubectl -n observability logs deploy/otel-collector` |
| The collector won't start: unknown exporter `otlp` | Newer collectors call it `otlp_grpc` | `docker run --rm otel/opentelemetry-collector:0.162.0 components` lists what exists |
| Jaeger's `/api/traces` returns 404 | Jaeger 2.22 serves only `/api/v3` | Use `/api/v3/traces` (see `deploy/trace-tree.py`) |
| A Prometheus target is `down` with `connection refused` | The Pod runs an old image, or the port is wrong | Check the Pod's image and its `prometheus.io/port` |
| A dashboard panel says "No data" for a healthy service | A ratio's numerator has no series | `or vector(0)` |
| A promtool test passes and fails on different runs | An alert reads a recording rule in another group | Put them in one group |
| The full test suite fails in Phase 3 or 4 tests while the cluster runs | The machine is out of CPU | `docker stop` the kind nodes while testing |
| A second kind cluster fails with `too many open files` | inotify instances exhausted (WSL) | `sudo sysctl fs.inotify.max_user_instances=512` |
| `terraform plan` asks for credentials or calls AWS | `offline` not set | `-var offline=true` with fake `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` |
| The SQS tests say `SKIP` | `RUNWAY_SQS_ENDPOINT` isn't set | Start ElasticMQ and set it to `http://localhost:9324` |

## Reading list for this phase

| When | Reading | Question to carry in |
|---|---|---|
| Step 1 | OSTEP Ch. 4–6; `namespaces(7)`, `cgroups(7)`; *Kubernetes in Action* Ch. 2 | What can one container do to another that two VMs can't? |
| Step 2 | The twelve-factor app, III, VI, IX | What belongs in the image, and what in the environment? |
| Step 3 | *Kubernetes in Action*, Pods, Deployments, internals; Burns et al., *Borg, Omega, and Kubernetes* | Why is every controller a loop over the whole state? |
| Step 4 | *Kubernetes in Action*, Services and networking; Mitzenmacher, *The Power of Two Choices*; Envoy's load-balancing docs | Where should balancing happen: client, proxy, or kernel? |
| Step 5 | *Kubernetes in Action*, volumes, ConfigMaps and Secrets, StatefulSets, Jobs | What would a highly available PostgreSQL on Kubernetes take? |
| Step 6 | Kubernetes docs on disruptions; the etcd operator | How does a real operator change a Raft cluster's membership? |
| Step 7 | Helm chart template guide; Pod termination docs; *SRE* Ch. 8; SRE workbook Ch. 16 | How small can a canary be, and what decides it? |
| Step 8 | *Continuous Delivery* Ch. 5; GitHub token permissions; OCI digests | What exactly did you test, and is it what you shipped? |
| Step 9 | Sigelman et al., *Dapper*; W3C Trace Context; OpenTelemetry concepts | What would sampling do to "find the slow job"? |
| Step 10 | *SRE* Ch. 4, 6; SRE workbook Ch. 2, 5; Gregg, *The USE Method*; *Systems Performance* Ch. 2 | Which alerts in your last job would this method have deleted? |
| Step 11 | Kubernetes docs on controllers and the HPA algorithm; *Programming Kubernetes* Ch. 1, 6; KEDA | What would an informer buy over polling? |
| Step 12 | *SRE* Ch. 15, 22; SRE workbook, incident response; *Principles of Chaos Engineering*; Basiri et al. | Which findings needed a fault, not a load test? |
| Step 13 | *Terraform: Up & Running* Ch. 2–3; ECS task roles; SQS developer guide; Well-Architected cost pillar | Where would `metad` run on AWS? |
| After the phase | Verma et al., *Large-scale cluster management at Google with Borg* (EuroSys 2015); Beyer et al., *The Site Reliability Workbook*, the chapters you skipped | What does Borg do that Kubernetes still doesn't? |
