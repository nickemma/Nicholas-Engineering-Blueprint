# 00 Before you start

Use Linux with Go 1.26.6+ and Python 3.11+. You’ll reuse the core’s TCP measurement method and build a standalone `netlab` workspace. The portable gate uses local TCP and UDP sockets.

- [Linux, networking, and profiling](../../../../2-core/06-linux-networking-and-profiling/README.md)
- [Distributed-systems fundamentals](../../../../2-core/07-distributed-systems-fundamentals/README.md)

## Setup card

From the Blueprint checkout, save its absolute path and enter a fresh learner directory.

~~~bash
export BLUEPRINT_ROOT="$PWD"
mkdir -p "$HOME/switchyard-netlab"
cd "$HOME/switchyard-netlab"
go version && python3 --version
~~~

For the live measurements, use a Linux Docker daemon that permits creating network namespaces and applying Linux traffic control in a disposable container. The live runs have external networking disabled and create only their own routes, interfaces, and qdiscs. Build the tools image after lesson 01, then collect all measurements once you reach lesson 09.

Keep predictions beside the raw samples. The lesson code is replayable through the implementation drawers.

Start with [Calibrate a network you can break](01-calibrate-a-network-you-can-break.md).
