# 00 Before you start

Use Linux, the Go and Rust toolchains from Core 07, Python 3.11+, OpenSSL 3, Bash, and a C compiler. The automated game day binds to a loopback HTTPS listener and starts Unix-socket peers in a private temporary directory. Lesson 01 also needs a Linux host with user namespaces and a delegated cgroup for its live observations.

From the Blueprint checkout, record `export blueprint=$(pwd)`. Then return to your completed Core 07 scratch directory. If you need fresh source, run `python3 "$blueprint/scripts/replay_lessons.py" --keep "$blueprint/2-core/07-distributed-systems-fundamentals"` and use the scratch path it prints. Type the new files in order in that directory. Create parent directories as needed.

<!-- continue: ../../07-distributed-systems-fundamentals -->

Verify the new tools with `openssl version`, `python3 --version`, and `cc --version`. The certificate lab uses newly generated keys in a temporary directory. The reference workflow uses a single host. Keep your usual development credentials out of the lab.
