# Phase 5: Operate and measure under network constraints

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: a type-along guide with the code inline, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This self-study lesson takes the Phase 1 API slice through a repeatable local deployment, then asks you to operate it during controlled failures. It teaches operations by making you observe, measure, diagnose, and recover. The database, worker, and replicated metadata from earlier phases remain separate practice components in this lesson; this deployment does not claim to run the entire KESTREL architecture.

## The goal

A second person should be able to start the API slice from documented configuration, observe its health, induce one contained failure, follow a runbook, recover it, and reproduce the measurements. You will compare normal and constrained-link behavior using request availability, latency, bandwidth, and resource use. This in-memory slice has no durable freshness or background queue to measure; those measures belong to the later integrated Kestrel experiment.

No cloud deployment is required for this course. A local Kubernetes cluster avoids surprise charges. Learn the cloud concepts on paper and use a paid provider only as a separately budgeted extension.

## Before you start

Finish Phases 0–4. Bring the API contract and your evidence from durable storage, messaging, and replicated-state exercises so you can explain which components this deployment slice leaves out. You need Docker, kind, kubectl, Git, and Bash. kind runs Kubernetes nodes as local containers.

The Kubernetes, observability, and network exercises all use the Phase 1 jobs API, whose job map lives in process memory. Start with one replica so the Service does not send a request to a different in-memory copy. Deleting its Pod will deliberately show that Kubernetes can replace a process but cannot preserve its memory. This is a deployment slice, not a claim that one API Pod contains the whole architecture.

~~~bash
docker version
kind version
kubectl version --client
~~~

The commands print the runtime and client versions. Create one local cluster:

~~~bash
kind create cluster --name kestrel-lab --wait 90s
kubectl cluster-info --context kind-kestrel-lab
kubectl get nodes
~~~

The cluster is disposable and local. Expect one control-plane node in Ready state. If it is not Ready, use kubectl describe node and kubectl get events before changing manifests.

Make an independent practice copy of the service you built in Phase 1. Run these commands from the Phase 5 folder:

~~~bash
mkdir -p practice
cp -R ../../01-reliable-service/practice/. practice/
cd practice
go test ./...
~~~

The copy command includes ordinary and hidden files such as go.mod. The test command should pass before you add the container files. If the source folder has a different name in your checkout, copy your completed Phase 1 practice module into `lessons/05-constrained-operations/practice`.

## 1. Inspect the process and container boundary

A container image packages an application and dependencies. A container is an isolated process with configured filesystem, network, and resource views; it is not a separate physical computer. Linux namespaces isolate views, and cgroups account for and limit resources.

Build an image for the API. Run it locally with a read-only root filesystem where practical, a non-root user, a health endpoint, and explicit CPU/memory limits. Use docker inspect to read its configured user, ports, mounts, and resource limits. Compare those fields with the process you ran directly in Phase 1.

In the practice folder, add these files:

~~~text
Dockerfile
.dockerignore
deploy/api.yaml
observability.compose.yaml
monitoring/prometheus.yml
~~~

Create the needed parent directories with `mkdir -p deploy monitoring infra`.

Use this two-stage Dockerfile. The builder compiles the API; the runtime image contains its executable and runs as an unprivileged user.

~~~dockerfile
FROM golang:1.27.1-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN mkdir -p /out && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/kestrel-api .

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/kestrel-api /kestrel-api
ENV LISTEN_ADDR=:8080
EXPOSE 8080
ENTRYPOINT ["/kestrel-api"]
~~~

Use the Go toolchain version required by your `go.mod` if it differs from 1.27.1, and record the exact builder and runtime image digests with your experiment. The .dockerignore must exclude `.git`, local databases, `.env` files, test output, and Kestrel data. Tag the result `kestrel-api:phase5`; do not use `latest`.

Use this `.dockerignore` content so local data does not enter the build context:

~~~text
.git
.env
.env.*
*.db
*.sqlite
*.sqlite3
data/
evidence/
coverage.out
*.test
~~~

Build and inspect this first image:

~~~bash
docker build -t kestrel-api:phase5 .
docker image inspect kestrel-api:phase5 --format '{{.Config.User}} {{.Config.Entrypoint}}'
docker run --rm -d --read-only --cpus=0.5 --memory=256m --user 65532:65532 --name kestrel-api-check -p 127.0.0.1:18080:8080 kestrel-api:phase5
curl -i http://127.0.0.1:18080/health
docker inspect kestrel-api-check --format '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}'
docker rm -f kestrel-api-check
~~~

Expect the image inspection to show UID 65532, a read-only root filesystem, a 0.5 CPU limit, and a 256 MiB memory limit; curl should receive HTTP 200. The image listens on its container interfaces; its published host port is limited to this computer. The Kubernetes manifest below sets the same container address explicitly.

Do not proceed until you can explain which state is in the image, which state is mounted, and what disappears when the container is removed.

## 2. Deploy an application to Kubernetes

Kubernetes is a control system that reconciles declared objects toward a desired state. A Deployment asks for a number of replaceable Pods. A Pod is the unit Kubernetes schedules. A Service gives a stable network name for a changing set of Pods. A ConfigMap holds non-secret configuration; a Secret holds sensitive configuration but still needs cluster access controls and safe storage.

Put the following complete Deployment and Service in `deploy/api.yaml`:

~~~yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kestrel-api
  namespace: kestrel-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kestrel-api
  template:
    metadata:
      labels:
        app: kestrel-api
    spec:
      containers:
        - name: api
          image: kestrel-api:phase5
          imagePullPolicy: Never
          env:
            - name: LISTEN_ADDR
              value: ":8080"
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
          livenessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            runAsGroup: 65532
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
---
apiVersion: v1
kind: Service
metadata:
  name: kestrel-api
  namespace: kestrel-lab
spec:
  type: ClusterIP
  selector:
    app: kestrel-api
  ports:
    - name: http
      port: 8080
      targetPort: http
~~~

The readiness probe controls whether the Pod receives Service traffic; the liveness probe asks Kubernetes to restart a container that keeps failing its health check. The image is loaded into the local cluster, so `imagePullPolicy: Never` prevents a registry pull. Kubernetes checks the declared Pod labels against the Deployment selector; those values must match exactly.

Build and load the image before applying:

~~~bash
docker build -t kestrel-api:phase5 .
kind load docker-image kestrel-api:phase5 --name kestrel-lab
kubectl create namespace kestrel-lab
kubectl apply -n kestrel-lab -f deploy/
kubectl rollout status -n kestrel-lab deployment/kestrel-api --timeout=90s
~~~

The first command builds the image. The second copies it into the local kind node. The third creates the namespace that keeps this exercise's objects together. The fourth applies the manifests. Expect the Deployment to become available after the readiness check succeeds. If a Pod is not ready, inspect kubectl describe pod and kubectl logs before editing it.

The namespace is named in the manifest and in the command. Apply, inspect, and reach the service:

~~~bash
kubectl apply -n kestrel-lab -f deploy/
kubectl get -n kestrel-lab deployments,pods,services
kubectl describe -n kestrel-lab deployment/kestrel-api
kubectl port-forward -n kestrel-lab service/kestrel-api 18080:8080
~~~

Use the same namespace for every apply and inspection command; otherwise kubectl may silently use the `default` namespace. `apply` submits the declared objects. `get` summarizes actual objects. `describe` includes scheduling events and probe failures. `port-forward` opens a temporary local tunnel to the Service. In another terminal, run `curl -i http://127.0.0.1:18080/health` and confirm HTTP 200 with `{"status":"ok"}`.

Create a job through the port-forward, record its ID, and then delete the API Pod:

~~~bash
curl -i -X POST http://127.0.0.1:18080/jobs -H 'Content-Type: application/json' -d '{"description":"pod restart check"}'
kubectl delete pod -n kestrel-lab -l app=kestrel-api
kubectl rollout status -n kestrel-lab deployment/kestrel-api --timeout=90s
curl -i http://127.0.0.1:18080/jobs/1
~~~

Use the ID returned by POST in the final command. After the rollout completes, stop the original port-forward with Ctrl+C and start `kubectl port-forward -n kestrel-lab service/kestrel-api 18080:8080` again in that terminal; port-forward attaches to a Pod and does not reconnect when that Pod is deleted. The Deployment should replace the Pod, and the GET should return 404 because Phase 1 stores jobs only in the process map. This demonstrates reconciliation and the limit of ephemeral state. If you temporarily scale to two replicas with `kubectl scale -n kestrel-lab deployment/kestrel-api --replicas=2`, a request can land on a Pod with a different in-memory map; do this only to observe why the database from Phase 3 is required before horizontal scaling, then run the same command with `--replicas=1`.

Readiness means a Pod may receive traffic. Liveness means Kubernetes should restart a stuck container. An incorrect liveness probe can create restart loops; demonstrate that with a deliberately wrong local path, inspect the events, then repair it.

## 3. Make the deployment repeatable

Keep image tags explicit and record the source commit used to build them. Do not use latest for a reproducible experiment. Store manifests in version control and record commands and configuration.

Learn HCL by describing a minimal network and service in Terraform, then run fmt, validate, and plan. Plan shows intended changes; it does not create resources. For the core lesson, do not apply a paid cloud plan. If you later choose a provider, first estimate its cost and set a budget. Explain a VPC, subnet, security group/firewall, IAM identity, and load balancer in your own deployment diagram.

For a no-charge planning exercise, create `infra/main.tf` with this configuration. It uses placeholder credentials and disables provider checks that would contact AWS; do not replace them with real credentials and do not run `terraform apply`.

~~~hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "training-only"
  secret_key                  = "training-only"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "kestrel-training-vpc" }
}

resource "aws_subnet" "app" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.42.1.0/24"
  map_public_ip_on_launch = false
  tags = { Name = "kestrel-training-app" }
}

resource "aws_security_group" "api" {
  name        = "kestrel-training-api"
  description = "Allow the API only from inside the training VPC"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["10.42.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
~~~

From the practice folder, run `terraform -chdir=infra fmt -check`, `terraform -chdir=infra init -backend=false`, `terraform -chdir=infra validate`, and `terraform -chdir=infra plan -refresh=false -input=false`. Read the plan and identify the VPC, subnet, and security group. This uses fake credentials and creates no cloud resources. Stop after plan; do not run `terraform apply`.

Use infrastructure state carefully: it may contain sensitive values and represents the managed objects Terraform believes exist. Never commit state files or credentials.

## 4. Add an operator view

For each measurement, define the question before making a graph:

| Signal | Question |
|---|---|
| Request rate | Is the service receiving work? |
| Error rate | Are callers receiving failed responses? |
| Latency | How long do successful and failed requests take? |
| Jobs stored in process memory | Is in-memory state growing during this test? |
| CPU/memory | Is the container limit or host capacity constraining work? |

Expose an application metrics endpoint and collect it with Prometheus. Build one Grafana dashboard with request rate, error rate, latency distribution, and the number of jobs held in memory. Use `docker stats "$(docker compose -f observability.compose.yaml ps -q api)"` in a second terminal for container CPU/memory. Add one alert rule for a sustained increase in API errors and document why a single failed scrape should not page someone.

Add the Prometheus Go client with `go get github.com/prometheus/client_golang/prometheus` and run `go mod tidy`. Register `promhttp.Handler()` on `GET /metrics`. Create `monitoring/prometheus.yml` with one scrape job targeting the API container every 15 seconds:

~~~yaml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: kestrel-api
    static_configs:
      - targets: ["api:8080"]
~~~

Add these three named measurements to the Go service: `kestrel_http_requests_total` (counter, route and status labels), `kestrel_http_request_duration_seconds` (histogram), and `kestrel_jobs_stored_in_memory` (gauge). Expose them on `GET /metrics` with the Prometheus Go client's `promhttp.Handler()`. The HTTP middleware updates the first two; Store.Create updates the gauge after adding a job. Use route patterns, not raw paths, for labels. Do not put job IDs, names, tokens, or payload values into metric labels; labels create a new time series for each distinct value and can expose data or exhaust memory.

Create `observability.compose.yaml`:

~~~yaml
name: kestrel-phase5-observability
services:
  api:
    build: .
    image: kestrel-api:phase5-observability
    environment:
      LISTEN_ADDR: ":8080"
    ports:
      - "127.0.0.1:8080:8080"
  prometheus:
    image: prom/prometheus:v3.14.0
    ports:
      - "127.0.0.1:9090:9090"
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
  grafana:
    image: grafana/grafana:13.2.0
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: lesson-only-change-this
~~~

Run `docker compose -f observability.compose.yaml up -d --build`. This starts the instrumented API and Prometheus on one private Compose network; only the API's local host port is published. Open `http://127.0.0.1:9090/targets`; the `kestrel-api` target should be UP. In Grafana at `http://127.0.0.1:3000`, sign in with the local lesson credentials above, add a Prometheus data source at `http://prometheus:9090`, and create panels using these PromQL queries:

~~~text
Request rate: sum(rate(kestrel_http_requests_total[5m]))
Error rate:   sum(rate(kestrel_http_requests_total{status=~"5.."}[5m]))
P95 latency:  histogram_quantile(0.95, sum by (le) (rate(kestrel_http_request_duration_seconds_bucket[5m])))
Jobs in memory: kestrel_jobs_stored_in_memory
~~~

Set a local alert condition on `sum(rate(kestrel_http_requests_total{status=~"5.."}[5m])) > 0` sustained for five minutes. Explain why a scrape failure alone is not evidence of a user-visible outage. After capturing the dashboard, stop the local stack with `docker compose -f observability.compose.yaml down`.

Logs are event records; metrics aggregate numeric behavior; traces connect work across service boundaries. Add a request/trace ID to the API log and response; Phase 2 extends the trace through the worker message and completion. Do not place request payloads or personal data in telemetry.

Write one service-level objective (SLO), for example the percentage of valid `GET /health` requests answered with 200 within 200 ms over a ten-minute, 20-requests/second run. An error budget is the allowed unreliability within that SLO period. State the workload and time period; a number without those is not a meaningful SLO.

## 5. Inject a constrained link safely

An IP address identifies a network interface. A subnet is a range of addresses; routing chooses a path between networks; DNS maps names to addresses; NAT rewrites address/port information across a boundary. Learn these using your local cluster and a diagram.

Measure the same workload in three conditions: normal local network, controlled delay, and controlled loss/bandwidth limit. For safety, use this disposable network namespace and veth pair; these commands do not change your host's default network interface. `ip netns` and `tc` are provided by iproute2. Check that `kestrel-net` and `veth-host` do not already exist before starting.

Create the isolated pair first. The host endpoint uses `10.203.0.1`, the address assigned only to this disposable veth interface:

~~~bash
sudo ip netns add kestrel-net
sudo ip link add veth-host type veth peer name veth-client
sudo ip link set veth-client netns kestrel-net
sudo ip addr add 10.203.0.1/24 dev veth-host
sudo ip link set veth-host up
sudo ip netns exec kestrel-net ip addr add 10.203.0.2/24 dev veth-client
sudo ip netns exec kestrel-net ip link set lo up
sudo ip netns exec kestrel-net ip link set veth-client up
~~~

In a second terminal, start the practice API bound only to the veth host address:

~~~bash
LISTEN_ADDR=10.203.0.1:8080 go run .
~~~

Back in the first terminal, check it from the client namespace:

~~~bash
sudo ip netns exec kestrel-net curl -i http://10.203.0.1:8080/health
~~~

Expect HTTP 200. Binding to the veth address keeps this experiment off the host's other network interfaces. Before adding any impairment, write down that cleanup is `sudo ip netns del kestrel-net` followed by `sudo ip link del veth-host` (the second command may report that the link is already gone). Add delay, loss, and rate limits only to the pair:

~~~bash
sudo tc qdisc add dev veth-host root netem delay 50ms loss 1% rate 1mbit
sudo ip netns exec kestrel-net tc qdisc add dev veth-client root netem delay 50ms loss 1% rate 1mbit
~~~

This applies impairment in both directions. Remove the namespace and veth device immediately after the experiment using the cleanup commands above. Never attach a netem rule to the host's general interface for this lesson. An application-level proxy is an alternative if you cannot create a network namespace.

Record the workload size, client concurrency, run duration, network settings, and random seed. Measure health-request success, p50/p95 latency, request/response bytes, CPU, and memory. Repeat each run. This slice has no worker completion freshness or queue age; Phase 7 measures those only if your integrated Kestrel build provides them. Explain how delay differs from loss and how both differ from a partition.

## 6. Operate a game day

For the required game day, delete the API Pod or add link delay in the isolated test network. If you have deployed the Phase 2 worker and broker as a separate extension, you may instead stop the worker or broker and must state that this is outside the Phase 5 API-slice manifest. Before starting, write the expected alert and recovery action. During the game day, use only the dashboard, logs, events, and runbook; keep a time-stamped incident note.

After recovery, write a blameless postmortem: impact, timeline, detection, diagnosis, recovery, contributing conditions, and one follow-up action. An incident exercise demonstrates response practice; it is not the same as real production on-call experience.

## Evidence gate

Save the image tag and source commit, manifests, cluster version, dashboard, one runbook, game-day notes, and repeated measurements for normal and constrained conditions. Complete learned.md. Then close the lesson manifests and rebuild the Kestrel deployment from the architecture and health contract. Demonstrate a failure and recovery without copying the YAML.

Clean up the local cluster when finished:

~~~bash
kind delete cluster --name kestrel-lab
~~~

This deletes the named local cluster and its cluster state.

## Read beside the work

Read each item after the matching behavior appears. This is the required path for completing the build; the phase map is only a quick preview.

| When | Read | Carry this question into the reading |
|---|---|---|
| Before writing the Dockerfile | CSAPP, 3rd ed., Chapter 7 §§7.1–7.7 and §§7.10–7.12 | Which build artifacts and libraries are inside the executable? |
| Before inspecting a container | OSTEP, Chapters 6–7; van Steen & Tanenbaum, 4th ed., §3.2 | Which process, filesystem, network, and resource views are isolated? |
| While applying the Deployment and Service | *Kubernetes in Action*, 1st ed., Chapters 1–5; then use the current official docs for commands and API versions | Which controller replaces the Pod, and how does traffic find a ready Pod? |
| Before reading resource limits | OSTEP, Chapters 18–22 | What happens when a process requests memory beyond its limit? |
| Before network emulation | Kurose & Ross, 8th ed., §2.4, §§4.1–4.3, §4.5, and §6.6 | Which part of the path adds name lookup, routing, or middlebox behavior? |
| While choosing SLOs and alerts | *Site Reliability Engineering*, Chapters 1, 3–6, and 10–12 | Which signal describes user-visible failure, and what action follows an alert? |
| Before profiling CPU | *Systems Performance*, 2nd ed., Chapter 6 §§6.1–6.6 | Is the workload CPU-bound, blocked, or measuring something else? |
| When studying cluster control | “Large-scale cluster management at Google with Borg” (2015), full paper | Which scheduling and failure lessons also apply to Kubernetes? |

Official references: [Kubernetes concepts](https://kubernetes.io/docs/concepts/), [Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/), [probe behavior](https://kubernetes.io/docs/concepts/workloads/pods/probes/), [kind quick start](https://kind.sigs.k8s.io/docs/user/quick-start/), and [Kubernetes basics](https://kubernetes.io/docs/tutorials/kubernetes-basics/).
