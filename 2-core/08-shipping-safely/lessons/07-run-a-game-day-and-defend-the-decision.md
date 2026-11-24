# 07 Run a game day and defend the decision

## The problem

A gateway restarts with a valid configuration pointing to an unavailable upstream. Its TLS listener can still accept connections, but eligible clients lose access. Decide how to identify that failure and validate recovery from outside the process.

## The prediction

Start with a complete window of four good client observations. Replace the upstream with a missing Unix socket and restart the gateway. Expect the alert within four bad observations. Diagnose the route, restore the previous configuration, and bring the ratio back to three of four. The recovered read must return the same value. Repeat the test with a probe that silently excludes failed attempts.

## Build it

### Step 1. Restore the saved configuration

Implement a rollback command that reads the saved socket path and requires a live socket file before replacing the active configuration. Stage the write beside the active file so replacement is atomic.

<details>
<summary>Hint</summary>

Keep one complete path per file and preserve the saved copy for the operator.

</details>

<details>
<summary>Completed files</summary>

Create `ops/restore-upstream.sh`.

<!-- file: ops/restore-upstream.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
umask 077

good=$1
active=$2
IFS= read -r socket < "$good"
[[ "$socket" == /* && -S "$socket" ]] || { echo 'saved upstream is not a socket' >&2; exit 1; }
next=$(mktemp "$(dirname -- "$active")/.upstream.XXXXXXXX")
trap 'rm -f -- "$next"' EXIT
printf '%s\n' "$socket" > "$next"
mv -fT -- "$next" "$active"
~~~

</details>
### Step 2. Practice diagnosis and recovery

Follow the [runbook](../runbook.md). Compare a successful handshake followed by 503 with a TLS error and a 403. Keep the client probe running through rollback so the clear event uses the same window.

<details>
<summary>Hint</summary>

A healthy listener does not prove the configured peer is reachable. Verify the old socket as well as the new one.

</details>
### Step 3. Document the incident and defend the boundary

Write a timeline from the gate. Fill in the cause, impact, and next evidence to collect. Use the [ADR](../adr.md) to explain why a local gateway with a single configured peer fits this module and what would change across hosts.

<details>
<summary>Hint</summary>

Cite an observed alert, a successful recovered read, and a permission check. State which operations and fault types the probe actually exercised.

</details>

## Check it

~~~bash
test -z "$(gofmt -l ./internal/edge ./internal/sli ./cmd/ship-gateway ./cmd/ship-probe)" && go vet ./internal/edge ./internal/sli ./cmd/ship-gateway ./cmd/ship-probe && go test -race -count=1 ./internal/edge ./internal/sli ./cmd/ship-gateway ./cmd/ship-probe && bash "$blueprint/2-core/08-shipping-safely/gate/run.sh" "$PWD"
~~~

<!-- run: test -z "$(gofmt -l ./internal/edge ./internal/sli ./cmd/ship-gateway ./cmd/ship-probe)" && go vet ./internal/edge ./internal/sli ./cmd/ship-gateway ./cmd/ship-probe && go test -race -count=1 ./internal/edge ./internal/sli ./cmd/ship-gateway ./cmd/ship-probe && bash "$BLUEPRINT_ROOT/2-core/08-shipping-safely/gate/run.sh" "$PWD" -->

~~~text
2026-11-22T02:33:41.698+00:00 fault: deployed a configuration with an unavailable upstream socket
2026-11-22T02:33:42.829+00:00 alert: firing at attempt 6 (2/4 good)
2026-11-22T02:33:42.855+00:00 rollback: restored the saved upstream configuration
2026-11-22T02:33:44.274+00:00 recovery: alert cleared and the original value was readable (3/4 good)
2026-11-22T02:33:51.037+00:00 fault: deployed a configuration with an unavailable upstream socket
negative control: caught the probe that dropped failed attempts
~~~

Time and attempt numbers vary. The FAIL line is from the intentionally altered probe. The gate requires that specific failure and then exits successfully.

[Captured output](../evidence/07-game-day.txt)

## Explain it

Why would a process-level liveness check miss this incident? Which game-day result supports your design decision and which is a constraint on it?
