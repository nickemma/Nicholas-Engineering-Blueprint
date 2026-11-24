# 00 Before you start

Core 03 taught you to recover jobs after a process dies. Core 07 asks how three processes decide what to do when each sees a different set of messages. You build Switchyard's metadata peer in a sibling Go module, then bring in the Rust `klog` source when you reach persistence. Keep your finished Core 03 and Core 06 work available for reference.

## Setup card

Use Linux with Go 1.26+, Rust 1.89+ with Cargo, Rustfmt and Clippy, and Python 3.11+. The real-process checks use Unix-domain sockets and start their own processes. Use a short Linux filesystem path for manual socket paths. The automatic gate creates its sockets under `/tmp`.

From the Blueprint checkout, record its absolute path, then create and enter a scratch directory. Keep using the same shell so `$blueprint` points to the checkout when commands invoke a check.

~~~bash
export blueprint=$(pwd)
mkdir -p ~/switchyard-metad
cd ~/switchyard-metad
go version && rustc --version && python3 --version
~~~

The reference capture used Go 1.26.6, Rust 1.94.1, and Python 3.14.7. For the Go pieces, use the format, vet, and race-detector checks from Core 01. Cargo checks the Rust writer when it enters the build.

Create `go.mod`.

<!-- file: go.mod -->
~~~text
module switchyard/metad

go 1.26
~~~

Create `.gitignore` if you use a scratch Git repository.

<!-- file: .gitignore -->
~~~text
/bin/
/klog/target/
*.klog
*.sock
~~~

Fill in each TODO on paper before typing the completed function. Type new files and apply the edits in order. In each edit, replace the first block with the second. Run the check at the end and compare it with the capture. Start with [What a node can know](01-what-a-node-can-know.md).
