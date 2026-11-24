#!/usr/bin/env bash
# Gate for Foundations 04: your echo server and your measurement script.
#
#   bash gate/run.sh ~/blueprint/internet
#
# The folder holds echo/ (your Go module) and measure/ (your uv project with
# measure.py). Exits 0 when every check passes, 1 otherwise.
# Works on Linux and macOS (bash 3.2). Needs go and uv.

set -u

dir=${1:-}
failed=0
pass() { echo "PASS  $1"; }
fail() {
  echo "FAIL  $1"
  while IFS= read -r l; do echo "      $l"; done <<< "$2"
  failed=1
}

if [ -z "$dir" ] || [ ! -f "$dir/echo/go.mod" ] || [ ! -f "$dir/measure/measure.py" ]; then
  echo "usage: bash gate/run.sh FOLDER   (FOLDER holds echo/go.mod and measure/measure.py)"
  exit 1
fi
dir=$(cd "$dir" && pwd -P)
work=$(mktemp -d)
pids=""
# shellcheck disable=SC2317  # called by the trap
cleanup() {
  for p in $pids; do kill "$p" 2>/dev/null; done
  rm -rf "$work"
}
trap cleanup EXIT

# The gate's own network checks, in Python (the standard library only).
cat > "$work/check.py" <<'PY'
import asyncio, os, random, socket, struct, sys, time

LIMIT = 64 * 1024
TOO_LONG = b"error: line longer than 65536 bytes\n"


def say(ok, name, detail=""):
    print(("PASS  " if ok else "FAIL  ") + name)
    if not ok:
        for line in detail.splitlines():
            print("      " + line)
    return ok


async def exchange(port, data, read_timeout=5.0):
    """Send data, close our sending half, return everything until EOF."""
    reader, writer = await asyncio.open_connection("127.0.0.1", port)

    async def send():
        writer.write(data)
        await writer.drain()
        writer.write_eof()

    sender = asyncio.create_task(send())
    try:
        got = await asyncio.wait_for(reader.read(), read_timeout)
        await sender
        return got
    finally:
        sender.cancel()
        writer.close()


def lines_for(rng, n):
    """A client's data: lines of many lengths and bytes, some ending \\r\\n,
    sometimes a last line with no newline."""
    out = []
    for _ in range(n):
        size = rng.choice([0, 1, 2, 80, 1000, 9000, rng.randrange(0, 20000), LIMIT - 1])
        body = bytes(b for b in rng.randbytes(size) if b != 10)
        out.append(body + rng.choice([b"\n", b"\r\n"]) if len(body) < LIMIT - 1 else body + b"\n")
    data = b"".join(out)
    if rng.random() < 0.3:
        data += b"no newline at the end"
    return data


async def server_checks(port, idle):
    ok = True
    rng = random.Random(4)
    datas = [lines_for(rng, rng.randrange(5, 25)) for _ in range(100)]

    # A client that connects and says nothing, opened just before the others.
    began = time.monotonic()
    q_reader, q_writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        gots = await asyncio.wait_for(
            asyncio.gather(*(exchange(port, d) for d in datas), return_exceptions=True),
            idle - 0.5,
        )
        bad = [i for i, (d, g) in enumerate(zip(datas, gots)) if g != d]
        detail = ""
        if bad:
            i = bad[0]
            g = gots[i]
            detail = f"client {i} sent {len(datas[i])} bytes and got back " + (
                repr(g) if isinstance(g, Exception) else f"{len(g)} bytes"
            )
            first = next((k for k, (a, b) in enumerate(zip(datas[i], g)) if a != b), None) \
                if not isinstance(g, Exception) else None
            if first is not None:
                detail += f"; first difference at byte {first}: sent {datas[i][first:first+12]!r}, got {g[first:first+12]!r}"
        total = sum(len(d) for d in datas)
        ok &= say(not bad, f"100 clients at once get back exactly what they sent ({total:,} bytes)", detail)
    except TimeoutError:
        ok &= say(False, "100 clients at once get back exactly what they sent",
                  f"not finished after {idle - 0.5:.1f} s, while one quiet client was connected:\n"
                  "does one connection hold up the others?")

    edge = b"y" * (LIMIT - 1) + b"\n"
    try:
        got = await exchange(port, edge)
        ok &= say(got == edge, "a line of exactly 65,536 bytes (newline included) comes back whole",
                  f"got back {len(got)} bytes")
    except (OSError, TimeoutError) as err:
        ok &= say(False, "a line of exactly 65,536 bytes (newline included) comes back whole",
                  f"{type(err).__name__} {err}")
    try:
        got = await exchange(port, b"z" * 70000 + b"\nafter\n")
        ok &= say(got == TOO_LONG, "a longer line gets the error, then the connection closes",
                  f"want {TOO_LONG!r}\ngot  {got[:80]!r}" + (" ..." if len(got) > 80 else ""))
    except (OSError, TimeoutError) as err:
        ok &= say(False, "a longer line gets the error, then the connection closes",
                  f"{type(err).__name__}: the error message never arrived")

    try:
        got = await asyncio.wait_for(q_reader.read(), idle + 5)
        waited = time.monotonic() - began
        ok &= say(got == b"" and idle - 0.5 <= waited, f"a quiet client is disconnected after -idle {idle:g}s",
                  f"closed after {waited:.1f} s")
    except TimeoutError:
        ok &= say(False, f"a quiet client is disconnected after -idle {idle:g}s",
                  f"still open after {idle + 5:g} s")
    q_writer.close()

    try:
        got = await exchange(port, b"still there?\n")
        ok &= say(got == b"still there?\n", "the server is still running afterwards")
    except (OSError, TimeoutError) as err:
        ok &= say(False, "the server is still running afterwards", f"{type(err).__name__} {err}")
    return ok


async def fake_server(mode, ready):
    async def handle(reader, writer):
        try:
            while line := await reader.readline():
                if mode == "pieces":
                    half = len(line) // 2
                    writer.write(line[:half])
                    await writer.drain()
                    await asyncio.sleep(0.02)
                    writer.write(line[half:])
                else:
                    writer.write(b"not what you sent\n")
                await writer.drain()
        except (ConnectionError, ValueError):
            pass
        writer.close()

    server = await asyncio.start_server(handle, "127.0.0.1", 0, limit=LIMIT)
    with open(ready, "w") as f:
        f.write(str(server.sockets[0].getsockname()[1]))
    async with server:
        await server.serve_forever()


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run(seconds, out, err, cmd):
    """Run cmd with a time limit; on timeout kill it and everything it started."""
    import signal, subprocess
    with open(out, "w") as o, open(err, "w") as e:
        proc = subprocess.Popen(cmd, stdout=o, stderr=e, start_new_session=True)
        try:
            return proc.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
    with open(err, "a") as e:
        e.write(f"timed out: still running after {seconds:g} s, so the gate stopped it\n")
    return 124


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "run":
        sys.exit(run(float(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5:]))
    elif cmd == "server":
        sys.exit(0 if asyncio.run(server_checks(int(sys.argv[2]), float(sys.argv[3]))) else 1)
    elif cmd == "fake":
        asyncio.run(fake_server(sys.argv[2], sys.argv[3]))
    elif cmd == "freeport":
        print(free_port())
    elif cmd == "csv":
        # csv FILE: check the rows, print "p50 X ms" and "p99 X ms" from them.
        import csv, math
        with open(sys.argv[2], newline="") as f:
            rows = list(csv.reader(f))
        if rows[0] != ["request", "connection", "bytes", "latency_ms"]:
            sys.exit(f"the first line is {','.join(rows[0])}, want request,connection,bytes,latency_ms")
        rows = rows[1:]
        n = int(sys.argv[3])
        sizes = [16, 256, 4096, 16384]
        if sorted(int(r[0]) for r in rows) != list(range(n)):
            sys.exit(f"want requests 0 to {n - 1}, each once; got {len(rows)} rows")
        if any(int(r[2]) != sizes[int(r[0]) % 4] for r in rows):
            sys.exit("the bytes column doesn't follow the sizes 16, 256, 4096, 16384 in turn")
        if len({r[1] for r in rows}) != int(sys.argv[4]):
            sys.exit(f"want {sys.argv[4]} different connections; got {len({r[1] for r in rows})}")
        lat = sorted(float(r[3]) for r in rows)
        if lat[0] < 0:
            sys.exit("a latency is negative")
        if len(sys.argv) > 5 and lat[0] < float(sys.argv[5]):
            sys.exit(f"the fastest latency is {lat[0]} ms, but every reply took at least {sys.argv[5]} ms to arrive whole")
        for p in (50, 99):
            print(f"p{p} {lat[math.ceil(p / 100 * len(lat)) - 1]:.3f} ms")
PY
if ! pybin=$(cd "$work" && uv run --quiet --no-project --python 3.14 python -c 'import sys; print(sys.executable)' 2>&1); then
  echo "can't run Python 3.14 with uv: $pybin"
  exit 1
fi
py() { "$pybin" -I "$work/check.py" "$@"; }

# ---------------------------------------------------------------- echo server
echo "== echo/"
if out=$(cd "$dir/echo" && gofmt -l . 2>&1) && [ -z "$out" ]; then
  pass "gofmt"
else
  fail "gofmt (these files need gofmt -w)" "$out"
fi
if out=$(cd "$dir/echo" && go vet ./... 2>&1); then pass "go vet"; else fail "go vet" "$out"; fi
if out=$(cd "$dir/echo" && go test -race -count=1 -timeout 60s ./... 2>&1); then
  pass "go test -race"
else
  fail "go test -race" "$(echo "$out" | grep -Ev '^[0-9]{4}/[0-9]{2}/[0-9]{2} ' | tail -20)"
fi

port=""
if ! out=$(cd "$dir/echo" && go build -o "$work/echo" . 2>&1); then
  fail "the server builds" "$out"
else
  idle=3
  "$work/echo" -addr 127.0.0.1:0 -idle ${idle}s > "$work/echo.out" 2> "$work/echo.err" &
  server_pid=$!
  pids="$pids $server_pid"
  for _ in $(seq 50); do
    port=$(sed -n 's/^listening on 127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' "$work/echo.out")
    if [ -n "$port" ] || ! kill -0 "$server_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if [ -z "$port" ]; then
    fail "the server starts with -addr 127.0.0.1:0 -idle ${idle}s and prints 'listening on 127.0.0.1:PORT'" \
      "stdout: $(head -3 "$work/echo.out")
stderr: $(head -3 "$work/echo.err")"
  else
    pass "the server starts and prints 'listening on 127.0.0.1:$port'"
    py server "$port" "$idle" || failed=1
    if ! kill -0 "$server_pid" 2>/dev/null; then
      fail "the server is still running at the end" "it exited: $(tail -3 "$work/echo.err")"
    fi
  fi
fi

# ---------------------------------------------------------------- measurement script
echo "== measure/"
m="$dir/measure"
if out=$(cd "$m" && uv run --quiet ruff format --check . 2>&1); then
  pass "ruff format"
else
  fail "ruff format (run uv run ruff format .)" "$out"
fi
if out=$(cd "$m" && uv run --quiet ruff check . 2>&1); then pass "ruff check"; else fail "ruff check" "$out"; fi
if (cd "$m" && py run 120 "$work/t.out" "$work/t.err" uv run --quiet pytest -q); then
  pass "pytest"
else
  fail "pytest" "$(cat "$work/t.out" "$work/t.err" | tail -20)"
fi

# measure ARGS...: run the script, for at most 60 s; output in $work/m.out
# and $work/m.err, exit code in $code.
measure() {
  (cd "$m" && py run 60 "$work/m.out" "$work/m.err" uv run --quiet measure.py "$@")
  code=$?
}

if [ -n "$port" ]; then
  measure --port "$port" --csv "$work/r.csv" --plot "$work/p.png"
  if [ "$code" != 0 ]; then
    fail "1,000 requests against your server" "exit $code: $(tail -5 "$work/m.err")"
  elif ! want=$(py csv "$work/r.csv" 1000 10 2>&1); then
    fail "1,000 requests against your server: results.csv" "$want"
  else
    pass "1,000 requests over 10 connections: results.csv has every request"
    got=$(grep -E '^p(50|99) ' "$work/m.out")
    if [ "$got" = "$want" ]; then
      pass "the p50 and p99 it prints match the CSV"
    else
      fail "the p50 and p99 it prints match the CSV" "printed:
$got
from your CSV, by nearest rank:
$want"
    fi
    if [ "$(head -c 8 "$work/p.png" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
      pass "the plot is a PNG image"
    else
      fail "the plot is a PNG image" "$work/p.png is missing or isn't a PNG"
    fi
  fi
fi

# A server that sends each reply in two pieces, 20 ms apart.
"$pybin" -I "$work/check.py" fake pieces "$work/pieces.port" &
pids="$pids $!"
"$pybin" -I "$work/check.py" fake wrong "$work/wrong.port" &
pids="$pids $!"
for _ in $(seq 100); do
  if [ -s "$work/pieces.port" ] && [ -s "$work/wrong.port" ]; then break; fi
  sleep 0.1
done
measure --port "$(cat "$work/pieces.port")" --requests 40 --connections 4 --csv "$work/r2.csv" --plot "$work/p2.png"
if [ "$code" != 0 ]; then
  fail "replies that arrive in two pieces are read whole" "exit $code: $(tail -5 "$work/m.err")"
elif ! out=$(py csv "$work/r2.csv" 40 4 20 2>&1); then
  fail "replies that arrive in two pieces are read whole" "$out"
else
  pass "replies that arrive in two pieces are read whole and timed to the end"
fi

measure --port "$(cat "$work/wrong.port")" --requests 5 --connections 1 --csv "$work/r3.csv" --plot "$work/p3.png"
if [ "$code" = 1 ] && [ -s "$work/m.err" ] && ! grep -q Traceback "$work/m.err"; then
  pass "a wrong reply: exit 1 with a message ($(head -1 "$work/m.err"))"
else
  fail "a wrong reply: exit 1 with a one-line message, not a traceback" "exit $code
$(tail -5 "$work/m.err")"
fi

closed=$(py freeport)
measure --port "$closed" --requests 5 --csv "$work/r4.csv" --plot "$work/p4.png"
if [ "$code" = 1 ] && [ -s "$work/m.err" ] && ! grep -q Traceback "$work/m.err"; then
  pass "nothing listening: exit 1 with a message ($(head -1 "$work/m.err"))"
else
  fail "nothing listening: exit 1 with a one-line message, not a traceback" "exit $code
$(tail -5 "$work/m.err")"
fi

echo
if [ "$failed" = 0 ]; then
  echo "Gate passed: on to the core."
else
  echo "Gate failed: fix each FAIL above and run it again."
fi
exit "$failed"
