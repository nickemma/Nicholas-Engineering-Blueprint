# Evidence: Set up your machine

Real outputs behind the lesson and the gate, captured on 2026-11-18.

- **Files 01–15** come from [capture.sh](capture.sh), run as an ordinary user with `sudo` in a fresh `ubuntu:24.04` container (Docker 29.7.1) on a 16-CPU x86-64 machine running WSL2. Each file holds the command, its output, and its exit status. The Git identity is the lesson's example, Ada Lovelace.
- **File 16** is the gate run on WSL2 against a copy of the program in a Windows folder (`/mnt/c/...`), with the same example identity.
- The `debconf` line in file 01 comes from the minimal container image; a normal Ubuntu install doesn't print it.

| File | Shows |
|---|---|
| 01–03 | Build tools, Git, and Git's identity |
| 04–05b | The Go download, its checksum passing, and a damaged copy failing |
| 06–08 | `go` not found before `PATH` is set, the install, and `go version` |
| 09–12 | The first program: `go mod init`, its output, the system's own figures, and the `PrintF` mistake |
| 13–16 | The gate: a pass, then fails with no Git identity, a wrong CPU count, and code in a Windows folder |
