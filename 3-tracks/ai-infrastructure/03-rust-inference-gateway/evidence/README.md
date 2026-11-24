# Rust inference gateway · Evidence

The reference used Rust 1.94.1 and the Cargo lock from the setup lesson. The model fixture and gateway communicate over distinct loopback listeners.

- [Gate capture](gate.txt). Parser and weighted quota tests, three real socket checks, CLI smoke test, and the framing negative control.
- [Clean lesson replay](replay.txt). A scratch build from the Markdown lessons with the full live gate.

The capture includes a role event seen before content, an incomplete response without a success marker, closure of the model fixture's body after cancellation, and slot reuse with the tenant charge retained. The assertions exercise the local HTTP transport and fixture behavior.
