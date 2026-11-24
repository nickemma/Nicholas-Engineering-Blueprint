# Rust inference gateway gate

From the Blueprint checkout, rebuild the lessons and exercise the local sockets.

~~~bash
SWITCHYARD_GATEWAY_LIVE=1 python3 scripts/replay_lessons.py 3-tracks/ai-infrastructure/03-rust-inference-gateway
~~~

From the completed learner directory, use the same gate directly.

~~~bash
SWITCHYARD_GATEWAY_LIVE=1 bash "$blueprint/3-tracks/ai-infrastructure/03-rust-inference-gateway/gate/run.sh" "$PWD"
~~~

The gate checks formatting and Clippy, then runs the parser and bucket tests. The live flag enables the socket tests and compiled CLI smoke test. With crates already cached, `CARGO_NET_OFFLINE=true` keeps dependency lookup offline.

1. Framing reconstructs split UTF-8 and multiline data. Overlong lines or events fail before unbounded buffering.
2. A role event can reach the client before any content is counted. A complete stream carries checked usage and the success marker.
3. Wrong upstream media type fails before streaming. Bad usage, early EOF, and idle deadlines surface as terminal stream errors after headers.
4. A busy slot returns 503 with a retry delay. Dropping the client closes the upstream fixture response and releases the slot. A connection deadline releases a pending body as well.
5. The same tenant still pays for its abandoned generation attempt. Its next reservation returns 429 while another tenant completes.
6. Replacing the newline between two SSE data fields in a disposable source copy makes the framing test fail at its equality assertion.

See the [recorded results](../evidence/README.md).

## Run the CLI manually

In one shell, run the fixture. Copy the loopback address it prints.

~~~bash
python3 "$blueprint/3-tracks/ai-infrastructure/03-rust-inference-gateway/gate/fixture.py" --serve
~~~

In a shell in the learner directory, generate the two fixture credentials, then start the gateway. Substitute the printed port for `PORT`.

~~~bash
(umask 077; python3 - <<'PY'
import secrets
with open("gateway.env", "x") as handle:
    for name in ("GATEWAY_A_TOKEN", "GATEWAY_B_TOKEN"):
        handle.write(f"export {name}={secrets.token_hex(24)}\n")
PY
)
. ./gateway.env
export GATEWAY_MODEL_ADDR=127.0.0.1:PORT
cargo run --locked
~~~

From another shell in the learner directory, stream a request and inspect the counters. The response contains a text delta, usage, and `[DONE]`.

~~~bash
. ./gateway.env
curl --no-buffer --max-time 25 --json '{"messages":[{"role":"user","content":"fixture"}],"max_tokens":4,"stream":true}' \
  --header "Authorization: Bearer $GATEWAY_A_TOKEN" \
  http://127.0.0.1:8080/v1/chat/completions
curl --max-time 4 http://127.0.0.1:8080/metrics
~~~

Stop the gateway and fixture with Ctrl+C. Both listeners use loopback. The generated credentials are for this disposable run.
