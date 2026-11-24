# Switchyard programmable edge proxy

This project combines a Rust HTTP/1.1 and TCP proxy with a Go controller and an mTLS sidecar. The lab has two configured upstream slots. The authenticated control path publishes an in-memory generation and route mapping. A request keeps its selected upstream through the exchange.

## Run the gate

Use Linux, Rust and Cargo 1.94 or newer, rustfmt, Clippy, Go 1.26 or newer, a C compiler for the Go race detector, Bash, and Python 3. Run from the extracted project root.

~~~bash
bash gate/run.sh "$PWD"
~~~

The tests run the real proxy and sidecar with temporary certificates and origins. For manual operation, build both binaries. Supply two HTTP origin addresses with a GET /health handler, a directory private to the local service account, and the certificates for the sidecar and controller.

~~~bash
cargo build --locked --release --target-dir target
go build -o edge-control ./cmd/edge-control
admin=$(mktemp -d)
~~~

Run the proxy and sidecar in separate terminals that share the same variable values. The management socket path must be unused at proxy startup.

~~~bash
target/release/switchyard-edge managed 127.0.0.1:8080 "$ORIGIN_A" "$ORIGIN_B" "$admin/admin.sock"
~~~

~~~bash
./edge-control sidecar 127.0.0.1:8443 "$admin/admin.sock" "$CA_PEM" "$SIDECAR_PEM"
~~~

Use separate combined cert-and-key PEM files. Sign both leaves with the trusted CA. The sidecar leaf uses server authentication, DNS SAN `sidecar.edge.invalid`, and URI SAN `urn:switchyard:sidecar`. The controller leaf uses client authentication and URI SAN `urn:switchyard:controller`. The test fixture in `control/management_test.go` shows how the lab issues those leaves.

~~~bash
./edge-control status https://127.0.0.1:8443 "$CA_PEM" "$CONTROLLER_PEM"
./edge-control apply https://127.0.0.1:8443 "$CA_PEM" "$CONTROLLER_PEM" \
  "$ORIGIN_A" "$ORIGIN_B" 1 1,0
./edge-control status https://127.0.0.1:8443 "$CA_PEM" "$CONTROLLER_PEM"
./edge-control apply https://127.0.0.1:8443 "$CA_PEM" "$CONTROLLER_PEM" \
  "$ORIGIN_A" "$ORIGIN_B" 2 0,1
~~~

## Reproduce the measurements

The steady-state comparison needs a local Docker daemon with Linux host networking. Run the matched direct, Rust, and Envoy workload using fresh output folders.

~~~bash
cargo build --release --locked --target-dir target
go build -trimpath -o bench/edge-bench bench/main.go
docker pull envoyproxy/envoy@sha256:36a2dc72f4b0b2639af3dfeaf92dced4063058f200664c6c4f5d443f5d9ea51d
python3 bench/run.py steady --rates 200 2500 --trials 3 --seconds 2
~~~

Use the same release binary for the managed steady and reload runs.

~~~bash
export EDGE_BIN="$PWD/target/release/switchyard-edge"
EDGE_RELOAD_REPORT="$PWD/managed-steady.json" go test -count=1 -v ./control -run '^TestCapstoneSteady$'
EDGE_RELOAD_REPORT="$PWD/managed-reload.json" go test -count=1 -v ./control -run '^TestCapstoneReload$'
bash bench/profile.sh edge-profile
~~~

The exact reference captures are in `evidence/reference/`. See the `ADR.md` for the cutover and measurement boundaries.
