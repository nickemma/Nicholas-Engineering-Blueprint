# 09 Wiring and configuration

> Module: Go runtime and reliable services · Time: ~4 h · Builds on: 08

## The problem

`main` hard-codes the address, sets only one of the server's timeouts, and can't be tested. A service that runs on your laptop, in a container and in a cluster needs to be configured from outside, refuse bad configuration at once instead of half-working until the first request, and set every limit lesson 02 showed you that `net/http` leaves to you.

## The mental model

~~~text
 environment: LISTEN_ADDR=127.0.0.1:9090  REQUEST_TIMEOUT=…  SHUTDOWN_GRACE=…
        │  os.Getenv, passed in as a function
        ▼
 main ──▶ run(getenv) ──▶ loadConfig ── bad? ──▶ error on stderr, exit 1 (fail fast)
                │ good
                ▼ the composition root: the only place concrete types are made
          memstore.New() ──▶ jobs.NewService(store) ──▶ httpapi.NewHandler(service)
                ▼
          http.Server{ReadHeaderTimeout, ReadTimeout, WriteTimeout, IdleTimeout}
~~~

## The pattern

**One composition root, configured from the environment.** Every package below `main` receives its dependencies; only `main` creates concrete ones, so reading `main` tells you what the program is made of. Settings come from **environment variables**, named strings the operating system hands a process when it starts, so the same build runs everywhere and only the environment changes (one of the "twelve-factor app" rules). And `run` takes the environment as a function, `getenv func(string) string`: production passes `os.Getenv`, tests pass a map.

## Build it

### Step 1: `run`, configuration and the server

Replace `cmd/switchyard/main.go`:

<!-- file: cmd/switchyard/main.go -->
~~~go
// Command switchyard runs Switchyard's control plane.
//
// main is the composition root: the one place that builds every concrete
// dependency and wires them together. Nothing below it creates its own.
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"switchyard/internal/httpapi"
	"switchyard/internal/jobs"
	"switchyard/internal/memstore"
)

func main() {
	if err := run(os.Getenv); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type config struct {
	ListenAddr string
}

func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{
		ListenAddr: "127.0.0.1:8080",
	}
	if v := getenv("LISTEN_ADDR"); v != "" {
		if _, _, err := net.SplitHostPort(v); err != nil {
			return config{}, fmt.Errorf("LISTEN_ADDR must look like host:port, got %q", v)
		}
		cfg.ListenAddr = v
	}
	return cfg, nil
}

// run builds the service from its configuration and serves it. Taking the
// environment as a parameter instead of calling os.Getenv inside is what
// makes it testable.
func run(getenv func(string) string) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}

	service := jobs.NewService(memstore.New())
	handler := httpapi.NewHandler(service)

	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("listening on http://%s", cfg.ListenAddr)
	return server.ListenAndServe()
}
~~~

- `main` does almost nothing: it calls `run` and turns an error into a message on **standard error** and exit status 1, which tells a shell, CI or Kubernetes that it failed.
- `loadConfig` checks `LISTEN_ADDR` with `net.SplitHostPort` before anything starts.
- The server sets all four timeouts from lesson 02. Lesson 12 adds more to `run`.

### Step 2: Test the configuration

Create `cmd/switchyard/main_test.go`:

<!-- file: cmd/switchyard/main_test.go -->
~~~go
package main

import "testing"

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestLoadConfig(t *testing.T) {
	cfg, err := loadConfig(env(nil))
	if err != nil || cfg.ListenAddr != "127.0.0.1:8080" {
		t.Fatalf("defaults = %+v, %v", cfg, err)
	}

	cfg, err = loadConfig(env(map[string]string{"LISTEN_ADDR": "0.0.0.0:9000"}))
	if err != nil || cfg.ListenAddr != "0.0.0.0:9000" {
		t.Fatalf("override = %+v, %v", cfg, err)
	}

	if _, err := loadConfig(env(map[string]string{"LISTEN_ADDR": "8080"})); err == nil {
		t.Error("LISTEN_ADDR without a host:port form was accepted")
	}
}
~~~

`env` builds a fake `getenv` from a map: no real environment variable is read or changed, so tests can run in parallel without stepping on each other.

~~~bash
go test -race ./...
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... && go test -race -count=1 ./... -->

~~~text
ok  	switchyard/cmd/switchyard	1.018s
ok  	switchyard/drills/byhand	(cached)
ok  	switchyard/drills/escape	(cached) [no tests to run]
?   	switchyard/drills/gc	[no test files]
?   	switchyard/drills/sched	[no test files]
?   	switchyard/drills/spin	[no test files]
?   	switchyard/drills/stacks	[no test files]
?   	switchyard/drills/stdhttp	[no test files]
ok  	switchyard/internal/httpapi	(cached)
ok  	switchyard/internal/jobs	(cached)
ok  	switchyard/internal/memstore	(cached)
~~~

### Step 3: Configure it from outside

`VAR=value command` sets a variable for that one command:

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard
LISTEN_ADDR=127.0.0.1:9090 /tmp/switchyard & sleep 0.5; curl -s http://127.0.0.1:9090/health; kill %1
~~~

~~~text
2026/11/20 02:43:29 listening on http://127.0.0.1:9090
{"status":"ok","service":"switchyard"}
~~~

## Break it

**Bad configuration.** Give it an address without a host:

~~~bash
LISTEN_ADDR=8080 /tmp/switchyard; echo "exit $?"
~~~

~~~text
LISTEN_ADDR must look like host:port, got "8080"
exit 1
~~~

It refused to start, said why, and exited with 1. **Fail fast**: a service that starts with a bad setting and fails on the first request is far harder to diagnose than one that won't start.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race ./...
~~~

Then answer: what is the composition root, and why does only `main` create concrete types? Which server timeout defends against the half-sent request from lesson 02? Should the 1 KiB body limit be set from the environment too, or is it part of the contract? Say why.

That proves the service starts only with good settings and has every server limit. It doesn't bound how long *one request's work* may take: the next lesson does.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `LISTEN_ADDR must look like host:port` | The value has no host, or no port | `127.0.0.1:8080`, or `:8080` for every interface |
| The variable seems ignored | It was set in another shell, or after the program started | `VAR=value command` on the same line, or `export VAR=value` first |
| `listen tcp ...: bind: permission denied` | A port below 1024 | Use a higher port |
| A test changes the real environment | It used `os.Setenv` | Pass a fake `getenv` instead |
