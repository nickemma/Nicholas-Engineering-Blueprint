# 00 Before you start

This module teaches you to diagnose a slow process with evidence. Lessons 01–08 start with the small Go service `hotspot`. The later lessons put the same tools to work on the Go↔Rust Switchyard wire.

**The goal:** `hotspot`, a small Go jobs service with five performance problems planted in it, and the tools to find each one. The reference profiling run captured each bottleneck and its fix. The wire work lives in sibling checkouts under `wire/control` and `wire/klog` within the same lab directory.

**The rule of the bridge:** never guess, and never fix what you haven't measured. Each step follows the evidence, even where it isn't what you expected. Twice while writing this guide, the evidence overturned the plan, and those moments are kept in.

## How this guide works

- Type the code; don't paste it.
- **CI rebuilds the code and runs its tests.** It can't run the live measurements, which need a running service, `perf`, Docker or root. Those outputs were captured by hand on one laptop (an 8-core Ryzen 7 5850U under WSL2). Your numbers will differ. Compare the **ratios and the shape**, not the digits.
- Each step ends with **Explain it** questions and a **Read** list.

## Setup

Use Linux with Go 1.26+, the Core 05 Rust and C toolchains, and Python 3. Docker, Linux profiling tools, `kload`, and the FlameGraph tools are used for the live labs. Make a scratch repository called `hotspot` for this module:

<!-- file: go.mod -->
~~~text
module hotspot

go 1.26
~~~

<!-- file: .gitignore -->
~~~text
bin/
audit.log
*.pb.gz
*.data
*.folded
*.svg
~~~

---
