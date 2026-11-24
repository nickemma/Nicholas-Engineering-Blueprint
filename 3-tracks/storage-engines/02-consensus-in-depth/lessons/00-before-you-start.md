# 00 Before you start

Keep the workspace you built in Core 07. This module extends the same `switchyard/metad` Go module, its simulated network, and its Rust writer. You can copy the finished workspace before editing so you can rerun the original core gate separately. [Core 07 setup](../../../../2-core/07-distributed-systems-fundamentals/lessons/00-before-you-start.md)

<!-- continue: ../../../../2-core/07-distributed-systems-fundamentals -->

## Setup card

Use Linux with Go 1.26+, Rust 1.89+ and Cargo, and Python 3.11+. The real peers and links use Unix sockets. In a terminal at the Blueprint checkout, record its path and then enter your copied Core 07 workspace.

~~~bash
export BLUEPRINT_ROOT="$PWD"
cd ~/switchyard-metad-consensus
go version && rustc --version && python3 --version
~~~

Lesson 05 introduces Porcupine through the Go module. Lesson 06 uses Java 21 and a pinned TLC release. Lesson 08 uses Docker and the PostgreSQL 17 image in two disposable containers. Verify those tools when you reach the relevant lesson.

The implementation drawers contain the replayable code. Work through each step’s decisions before opening its drawer. Run the named check from your learner workspace and compare its output with the reference.

Start with [Give clients a replicated key-value store](01-replicate-key-value-commands.md).
