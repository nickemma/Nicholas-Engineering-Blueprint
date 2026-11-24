# Proxy control-plane gate

Run the portable gate from the assembled learner workspace. It uses TCP loopback and Unix sockets.

~~~bash
module="$BLUEPRINT_ROOT/3-tracks/cloud-and-network/03-proxy-control-plane"
bash "$module/gate/run.sh" "$PWD"
~~~

The gate runs Rust checks, Go vet, and Go integration tests with the race detector. The route fixture holds a request at the old origin while a legitimate controller publishes a new snapshot. It observes where both requests land, discards a successful acknowledgement to test retry, and rolls back as a new generation. The same fixture proves a stale or conflicting snapshot leaves the active generation fixed.

The management fixture checks that a peer with the wrong role leaves the generation unchanged and that fresh handshakes see each rotated leaf. The sender and receiver fixture checks signatures, timestamps, destination policy, and receipt state. The negative control changes the duplicate acknowledgement in a disposable build and requires the retry assertion to fail. [Portable transcript](../evidence/portable.txt)

## Live profiles

Run OpenBao in a disposable dev-mode container published to host loopback. The fixture creates its own credentials and records access outcomes and key versions.

~~~bash
bash "$module/gate/run.sh" "$PWD" openbao
~~~

Run XDP on Linux with permission to create a disposable privileged Docker container. The fixture uses an isolated network namespace, its own veth pair, and a private BPF filesystem.

~~~bash
docker build -t switchyard-cn03-xdp:lab lab/xdp
bash "$module/gate/run.sh" "$PWD" xdp
~~~

The XDP run checks five byte-identical objects and an increase in both the packet counter and the origin's request count. [Reference evidence](../evidence/README.md)
