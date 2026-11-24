# 08 Run the stack and measure it

> About 4 hours · Builds on [07 Pick up unfinished jobs after a crash](07-pick-up-unfinished-jobs-after-a-crash.md). Use the finished Core 02 `kload`.

## The problem

Running a binary, applying migrations, and starting workers by hand leaves several chances to pick the wrong address, miss a schema change, or lose a data directory. It also makes a backend comparison hard to reproduce.

## The mental model

~~~text
host curl, kload  ---> loopback port ---> api (HTTP)
                                            |
worker -----------------> api (gRPC)       |
                                            v
migrate ---------------------------> postgres ---> pgdata volume
~~~

Compose puts services on a project network. Inside it the database hostname is `postgres` and the worker connects to `api:9090`. The host-side ports are assigned at startup and published on loopback. The named volume is attached at the Postgres 17 data path.

## The pattern

Build both Switchyard binaries for the Docker daemon's architecture. Put them in one small image and choose the entrypoint for each service. Start the API after the migration job exits successfully. Then compare the same workload under two storage configurations.

## Build it

### Step 1. Build the image inputs

Build Linux executables with cgo disabled, then place them in a scratch image with a non-root user. The build context allowlist sends the Dockerfile and staged binaries. The worker uses the same image with a different entrypoint.
Create `scripts/build-image-inputs.sh`:

<!-- file: scripts/build-image-inputs.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail

arch=$(docker version --format '{{.Server.Arch}}')
mkdir -p bin/linux
for program in switchyard worker; do
  GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -buildvcs=false -trimpath -o "bin/linux/$program" "./cmd/$program"
done
~~~

Create `Dockerfile`:

<!-- file: Dockerfile -->
~~~text
FROM scratch
COPY bin/linux/switchyard /switchyard
COPY bin/linux/worker /worker
USER 65532:65532
ENTRYPOINT ["/switchyard"]
~~~

Create `.dockerignore`:

<!-- file: .dockerignore -->
~~~text
**
!Dockerfile
!bin/
!bin/linux/
!bin/linux/switchyard
!bin/linux/worker
~~~

### Step 2. Start the stack with Compose

Use health and completion conditions for startup ordering. The worker already retries its connection to the control plane. Keep these credentials and host ports scoped to the local lab.
Create `compose.yaml`:

<!-- file: compose.yaml -->
~~~yaml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: switchyard
      POSTGRES_PASSWORD: lab-only
      POSTGRES_DB: switchyard
    ports:
      - "127.0.0.1::5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-q", "-h", "127.0.0.1", "-U", "switchyard", "-d", "switchyard"]
      interval: 1s
      timeout: 2s
      retries: 30
  migrate:
    image: postgres:17
    environment:
      PGPASSWORD: lab-only
    entrypoint: ["psql"]
    command: ["-h", "postgres", "-U", "switchyard", "-d", "switchyard", "-X", "-v", "ON_ERROR_STOP=1", "-f", "/db/migrate.sql"]
    volumes:
      - ./db:/db:ro
    depends_on:
      postgres:
        condition: service_healthy
  api:
    image: ${COMPOSE_PROJECT_NAME}-switchyard:lab
    build:
      context: .
    environment:
      LISTEN_ADDR: "0.0.0.0:8080"
      GRPC_ADDR: "0.0.0.0:9090"
      SWITCHYARD_DATABASE_URL: ${SWITCHYARD_DATABASE_URL-postgres://switchyard:lab-only@postgres:5432/switchyard?sslmode=disable}
      DATABASE_MAX_CONNS: ${DATABASE_MAX_CONNS:-4}
      LEASE_TTL: ${SWITCHYARD_LEASE_TTL:-3s}
      QUEUE_CAPACITY: ${QUEUE_CAPACITY:-100}
    ports:
      - "127.0.0.1::8080"
      - "127.0.0.1::9090"
    depends_on:
      migrate:
        condition: service_completed_successfully
  worker:
    image: ${COMPOSE_PROJECT_NAME}-switchyard:lab
    pull_policy: never
    entrypoint: ["/worker"]
    environment:
      CONTROL_PLANE: "api:9090"
    depends_on:
      api:
        condition: service_started
volumes:
  pgdata:
~~~

~~~bash
bash scripts/build-image-inputs.sh
docker compose up -d --build
docker compose ps -a
base="http://$(docker compose port api 8080)"
curl -fsS "$base/health"
~~~

The gate at the end of the lesson runs this stack with its own project name, so it can remove its test volumes after finishing.

### Step 3. Compare the memory and PostgreSQL backends

Use the same image, one worker, rate, payload, and timing with both stores. The script recreates the API and worker between runs, warms each one, and records the randomized order. Core 02's `kload` reports its own send lag and exits nonzero if it falls behind. The script also checks every measured request returned 201, so a fast refusal cannot make a backend appear faster.
Create `scripts/benchmark.sh`:

<!-- file: scripts/benchmark.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail

# Run from the root of the finished Switchyard checkout.
: "${KLOAD:?set KLOAD to the absolute path to your Core 02 kload executable}"
project="c03-bench-$(id -u)-$$"
out=$(mktemp -d "$PWD/c03-bench.XXXXXX")
compose() { docker compose -p "$project" "$@"; }
cleanup() { compose down -v --remove-orphans >&2; }
trap cleanup EXIT
mkdir -p "$out"/{memory,postgres}
export QUEUE_CAPACITY=1000

bash scripts/build-image-inputs.sh
compose build api
compose up -d --wait postgres
compose run --rm --no-deps migrate

# Randomize the order inside each pair. Save it so the run can be inspected.
python3 - <<'PY' > "$out/order.txt"
import random
rng = random.Random(303)
for run in range(1, 6):
    pair = ["memory", "postgres"]
    rng.shuffle(pair)
    for backend in pair:
        print(run, backend)
PY

load() {
  "$KLOAD" load --url "$base" --method POST --path /jobs \
    --body '{"description":"benchmark","duration_ms":5}' \
    --rate 40 --duration "$1" --out "$2"
}

while read -r run backend; do
  case "$backend" in
    memory) export SWITCHYARD_DATABASE_URL="" ;;
    postgres) unset SWITCHYARD_DATABASE_URL ;;
  esac
  compose up -d --no-deps --force-recreate api worker
  base="http://$(compose port api 8080)"
  ready=false
  for ((attempt = 0; attempt < 60; attempt++)); do
    if curl -fs --max-time 1 "$base/health" >/dev/null; then
      ready=true
      break
    fi
    sleep 0.25
  done
  if [[ "$ready" != true ]]; then
    compose logs api worker >&2
    exit 1
  fi

  printf 'pair %s: %s\n' "$run" "$backend"
  load 2 "$out/warmup.csv" </dev/null
  load 3 "$out/$backend/run-$run.csv" </dev/null
  python3 - "$out/$backend/run-$run.csv" <<'PY'
import csv
import sys
with open(sys.argv[1], newline="") as f:
    rows = list(csv.DictReader(f))
if len(rows) != 120 or any(row["status"] != "201" for row in rows):
    raise SystemExit("expected all 120 submissions to return 201")
PY
done < "$out/order.txt"

"$KLOAD" compare "$out/memory" "$out/postgres"
printf 'raw results: %s\n' "$out"
~~~

Point `KLOAD` at the installed executable from Core 02:

~~~bash
KLOAD="$(command -v kload)" bash scripts/benchmark.sh
~~~

~~~text
p50 A (/tmp/blueprint-c03-author/08/c03-bench.jeZHRn/memory, 5 runs): 2.36 2.47 2.53 2.64 2.48 ms
p50 B (/tmp/blueprint-c03-author/08/c03-bench.jeZHRn/postgres, 5 runs): 8.26 8.03 8.10 7.90 7.87 ms
p50 B - A: +5.53 ms, 95% CI [+5.39, +5.69] ms: B is slower
p99 A (/tmp/blueprint-c03-author/08/c03-bench.jeZHRn/memory, 5 runs): 3.41 3.40 3.77 3.50 3.48 ms
p99 B (/tmp/blueprint-c03-author/08/c03-bench.jeZHRn/postgres, 5 runs): 26.04 10.14 11.18 9.86 10.25 ms
p99 B - A: +9.98 ms, 95% CI [+6.53, +16.32] ms: B is slower
~~~

Read the median and tail separately. The comparison resamples entire runs and is specific to the recording environment, request rate, connection pool, and image. Change one setting at a time when repeating it.

### Step 4. Run the gate

Run the [module gate](../gate/README.md) against the Switchyard directory you just built. It runs the Go tests against a real PostgreSQL database, then kills the control plane, recovers its work, and replaces the database container. The gate prints the recovery and persistence checks as they pass.

~~~text
repository contracts, exhausted pool, transactional rollback, and recovery checks passed
same key and original 201 survived SIGKILL; changed payload returned 422
job 1 recovered; token 2 refused; token 4 recorded one effect
a replacement PostgreSQL container kept the job, effect, and retry record
the Compose worker completed a new job
~~~

## Check it

Write down where each process runs and who owns the volume. Explain why the retry response can still say `queued` when the live job says `completed`. Use a saved run's settings and send lag to explain which aspects of the latency comparison someone else can reproduce.

## If it goes wrong

- If the API never listens, check `docker compose logs migrate api` and look for the first database or migration error.
- If submissions never finish, check the worker logs and verify that it uses the Compose address `api:9090`.
- If `kload` falls behind, lower the offered rate for both backends and repeat the comparison.

<!-- run: bash -n scripts/build-image-inputs.sh && bash -n scripts/benchmark.sh -->
<!-- run: if [[ "${SWITCHYARD_REPLAY_COMPOSE:-0}" == 1 ]]; then bash "$BLUEPRINT_ROOT/2-core/03-docker-and-postgres/gate/run.sh" "$PWD"; fi -->
