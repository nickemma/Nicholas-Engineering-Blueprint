# 01 What disappears on restart

> About 4 hours · You need the finished Core 01 Switchyard, Docker with Compose, and `psql`.

<!-- continue: ../../01-go-runtime-and-reliable-services -->

## The problem

Switchyard answered `201 Created`. Can you still find the job after the control plane restarts? In Core 01, the jobs repository was a map inside the Go process. A new process starts with an empty map.

## The mental model

~~~text
Go process             map of jobs                 lives as long as the process
Postgres container     writable container layer    lives as long as the container
Postgres container     Docker named volume         has its own lifecycle
~~~

An **image** holds the files and defaults used to start a container. A **container** runs a process with its own view of the filesystem and network. Docker adds a writable filesystem layer when it creates the container. If you remove the container, Docker removes that layer. A **volume** mounts separate storage at a path inside the container. The next container can mount the same volume at the same path.

## The pattern

Follow the data to the thing that stores it. Restarting a process, restarting a container, and replacing a container stop different things from existing. For each experiment, write a marker and read it back before and after the change.

## Build it

### Step 1. Check your tools

Run `docker version`, `docker compose version`, and `psql --version`. Both the Docker client and server should answer. Compose will run the whole stack in lesson 08. Here you'll start containers directly so you can see the image, network, and mount separately.

### Step 2. Restart Switchyard

From the finished Core 01 checkout, build the same control plane and run this script. It asks the OS for an available port and reads the address from the startup log. The readiness loop has a deadline so a failed start shows its log and exits.

<!-- file: drills/restart-memory.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail

work=$(mktemp -d)
pid=
cleanup() {
  if [[ -n "$pid" ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

go build -buildvcs=false -o "$work/switchyard" ./cmd/switchyard

start() {
  LISTEN_ADDR=127.0.0.1:0 GRPC_ADDR=127.0.0.1:0 "$work/switchyard" > "$work/server.log" 2>&1 &
  pid=$!
  for ((attempt = 0; attempt < 100; attempt++)); do
    addr=$(sed -n 's/.*"msg":"listening","addr":"\([^"]*\)".*/\1/p' "$work/server.log")
    if [[ -n "$addr" ]] && curl -fs --max-time 1 "http://$addr/health" >/dev/null; then
      return
    fi
    sleep 0.05
  done
  cat "$work/server.log" >&2
  return 1
}

start
code=$(curl -sS --max-time 5 -o "$work/job.json" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d '{"description":"resize an image","duration_ms":200}' "http://$addr/jobs")
[[ "$code" == 201 ]]
job=$(python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])' < "$work/job.json")
printf 'POST /jobs: %s (job %s)\n' "$code" "$job"

code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://$addr/jobs/$job")
[[ "$code" == 200 ]]
printf 'GET before restart: %s\n' "$code"

kill -TERM "$pid"
wait "$pid"
pid=
start

code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://$addr/jobs/$job")
[[ "$code" == 404 ]]
printf 'GET after restart: %s\n' "$code"
~~~

Run it:

~~~bash
bash drills/restart-memory.sh
~~~

<!-- run: bash drills/restart-memory.sh -->

~~~text
POST /jobs: 201 (job 1)
GET before restart: 200
GET after restart: 404
~~~

### Step 3. Put Postgres on a Docker network

The local lab uses `postgres:17`, as does the repository's CI. A user-defined bridge network lets a client container resolve the database by name. The database port stays inside that network. The credentials below belong to the disposable lab.

Start a fresh Bash shell for the Docker steps. The exit trap removes the two lab resources and the network when you leave that shell.

~~~bash
lab="blueprint-c03-$(id -u)-$$"
db="$lab-db"
volume="$lab-data"

docker network create "$lab" >/dev/null
docker volume create "$volume" >/dev/null
trap 'docker rm -f -v "$db" >/dev/null 2>&1 || true; docker volume rm "$volume" >/dev/null; docker network rm "$lab" >/dev/null' EXIT

start_db() {
  docker run --detach --name "$db" --network "$lab" --network-alias postgres \
    -e POSTGRES_USER=switchyard -e POSTGRES_PASSWORD=lab-only \
    -e POSTGRES_DB=switchyard "$@" postgres:17 >/dev/null
  wait_for_db
}

wait_for_db() {
  for ((attempt = 0; attempt < 60; attempt++)); do
    if docker exec "$db" pg_isready -q -h 127.0.0.1 -U switchyard -d switchyard; then
      return
    fi
    sleep 0.5
  done
  docker logs "$db" >&2
  return 1
}

sql() {
  docker run --rm -i --network "$lab" -e PGPASSWORD=lab-only postgres:17 \
    psql -XAt -v ON_ERROR_STOP=1 -h postgres -U switchyard -d switchyard "$@"
}
~~~

The client runs in its own container, so `127.0.0.1` would send it back to itself. It connects to the server using the network alias `postgres`. The readiness command runs inside the server container and uses TCP because the image may start a temporary socket-only server during initialization.

### Step 4. Restart a container and then replace it

Use a data directory outside the image's default data mount. `PGDATA` is the directory where the server keeps its own database files. For this experiment they live in the writable container layer.

~~~bash
start_db -e PGDATA=/var/lib/postgresql/ephemeral
sql -c "CREATE TABLE marker (name text PRIMARY KEY); INSERT INTO marker VALUES ('written');"
sql -c 'SELECT name FROM marker;'

docker restart "$db" >/dev/null
wait_for_db
sql -c 'SELECT name FROM marker;'

docker rm -f -v "$db" >/dev/null
start_db -e PGDATA=/var/lib/postgresql/ephemeral
sql -c "SELECT coalesce(to_regclass('public.marker')::text, 'marker missing');"
~~~

~~~text
CREATE TABLE
INSERT 0 1
written
written
marker missing
~~~

`docker restart` reused the writable layer. Removing the container took that layer with it. The new server started with an empty database.

### Step 5. Replace a container with its volume attached

Now mount the named volume at the image's default data path for PostgreSQL 17.

~~~bash
docker rm -f -v "$db" >/dev/null
start_db --mount "type=volume,source=$volume,target=/var/lib/postgresql/data"
sql -c "CREATE TABLE marker (name text PRIMARY KEY); INSERT INTO marker VALUES ('on a volume');"

docker rm -f -v "$db" >/dev/null
start_db --mount "type=volume,source=$volume,target=/var/lib/postgresql/data"
sql -c 'SELECT name FROM marker;'
~~~

~~~text
CREATE TABLE
INSERT 0 1
on a volume
~~~

## Check it

Explain why both SQL queries after replacement ran against a new container, yet only the second could find the marker. Run `docker inspect "$db" --format '{{range .Mounts}}{{println .Type .Destination}}{{end}}'` and find the mount that provided the data. Exit the lab shell to clean up.

## If it goes wrong

- If the Docker client can't reach its daemon, check that the service is running and that your account has access to the configured Docker context.
- If the server never becomes ready, read the container log. An initialization error and an authentication error happen at different points.
- If your replacement server can't find the marker, inspect the mount and check the volume name and the data directory. In lesson 02 you'll use this storage for Switchyard's schema.
