# 07 Count traffic from the kernel

> The proxy’s control plane · Week 3 · Builds on lesson 06

## The problem

A proxy request counter tells you what reached the origin. It cannot show how many link-layer packets the ingress interface processed.

## The mental model

Use a disposable veth pair. The XDP program increments a packet counter at ingress and returns XDP_PASS. Request traffic also causes handshake and acknowledgement packets, so compare the two count deltas without treating them as equivalent. [Linux BPF program documentation](https://www.kernel.org/doc/html/latest/bpf/bpf_prog_run.html)

## The pattern

Compile a tiny C program, pin its counter in an isolated BPF filesystem, and attach it in generic XDP mode. Make five matched proxy requests from the separate client namespace and compare response bytes and origin counts.

## Build it

### Step 1 — Compile and load a pass-through counter

Use a single map entry and an atomic increment. Keep the program attached only to the test interface.

<details>
<summary>Implementation</summary>

Create `lab/xdp/count.c`.

<!-- file: lab/xdp/count.c -->
~~~c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} packets SEC(".maps");

SEC("xdp")
int count_packets(struct xdp_md *ctx)
{
    __u32 key = 0;
    __u64 *counter = bpf_map_lookup_elem(&packets, &key);

    if (counter)
        __sync_fetch_and_add(counter, 1);
    return XDP_PASS;
}

char license_text[] SEC("license") = "GPL";
~~~

Create `lab/xdp/Dockerfile`.

<!-- file: lab/xdp/Dockerfile -->
~~~dockerfile
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    bpftool clang curl iproute2 libbpf-dev linux-libc-dev python3 \
    && rm -rf /var/lib/apt/lists/*
COPY count.c /lab/count.c
COPY run.sh /lab/run.sh
RUN clang -O2 -g -target bpf -I/usr/include/"$(uname -m)"-linux-gnu \
    -c /lab/count.c -o /lab/count.o
ENTRYPOINT ["bash", "/lab/run.sh"]
~~~

</details>

### Step 2 — Check packet and request counters

Take the first reading after setup. Fetch five objects from the client namespace and require five new origin requests, unchanged response bytes, and a positive packet delta.

<details>
<summary>Implementation</summary>

Create `lab/xdp/run.sh`.

<!-- file: lab/xdp/run.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail

mount --make-rprivate /
mount -t bpf bpf /sys/fs/bpf
trap 'ip netns del client 2>/dev/null || true; umount /sys/fs/bpf' EXIT
ip netns add client
ip link add edge-lab type veth peer name client-lab
ip link set client-lab netns client
ip addr add 10.200.0.1/30 dev edge-lab
ip link set edge-lab up
ip -n client addr add 10.200.0.2/30 dev client-lab
ip -n client link set client-lab up
ip -n client link set lo up

mkdir /sys/fs/bpf/maps
bpftool prog load /lab/count.o /sys/fs/bpf/count type xdp pinmaps /sys/fs/bpf/maps
bpftool net attach xdpgeneric pinned /sys/fs/bpf/count dev edge-lab

fixture="$(mktemp)"
/work/origin origin >"$fixture" &
for (( attempt=0; attempt<50; attempt++ )); do
    if [[ -s "$fixture" ]]; then break; fi
    sleep 0.05
done
read -r origin observer <"$fixture"
/work/proxy http 10.200.0.1:8080 "$origin" 127.0.0.1:1 &
for (( attempt=0; attempt<50; attempt++ )); do
    if curl --max-time 1 --noproxy '*' -fsS http://10.200.0.1:8080/a/obj/4096/1 >/tmp/direct; then
        break
    fi
    sleep 0.05
done
test "$(wc -c </tmp/direct)" -eq 4096

packets() {
    bpftool -j map lookup pinned /sys/fs/bpf/maps/packets key hex 00 00 00 00 |
        python3 -c '
import json, sys
row = json.load(sys.stdin)
value = row["value"]
print(int.from_bytes(bytes(int(part, 16) for part in value), sys.byteorder) if isinstance(value, list) else value)
'
}
requests() {
    curl --max-time 1 --noproxy '*' -fsS "http://$observer/stats" |
        python3 -c 'import json, sys; print(json.load(sys.stdin)["requests"])'
}
before="$(packets)"
origin_before="$(requests)"
for (( request=0; request<5; request++ )); do
    ip netns exec client curl --max-time 2 --noproxy '*' -fsS \
        http://10.200.0.1:8080/a/obj/4096/1 -o /tmp/forwarded
    cmp /tmp/direct /tmp/forwarded
done
after="$(packets)"
origin_after="$(requests)"
test "$after" -gt "$before"
test "$((origin_after - origin_before))" -eq 5
printf 'kernel=%s interface=edge-lab mode=xdpgeneric packets=%s..%s origin_requests=%s..%s\n' \
    "$(uname -r)" "$before" "$after" "$origin_before" "$origin_after"
~~~

</details>

## Check it

~~~bash
docker build -t switchyard-cn03-xdp:lab lab/xdp
bash "$BLUEPRINT_ROOT/3-tracks/cloud-and-network/03-proxy-control-plane/gate/run.sh" "$PWD" xdp
~~~

<!-- run: bash -n lab/xdp/run.sh -->

The privileged profile records the kernel, interface, attach mode, and both counter readings. [XDP capture](../evidence/xdp.txt)

## If it goes wrong

If attaching is refused, check the test environment for BPF support and namespace permissions. If the counter stays fixed, inspect which veth sees ingress and whether the client request crossed that interface.

Continue to [Run the control-plane game day](08-run-the-control-plane-gate.md).
