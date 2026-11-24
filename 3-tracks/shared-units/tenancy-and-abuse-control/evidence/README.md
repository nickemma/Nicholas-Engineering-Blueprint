# Tenancy and abuse control · Evidence

The reference uses Go 1.26.6, `postgres:17`, and `redis:8`. Both live services are disposable and bind to loopback.

- [Gate capture](gate.txt). Token validation and rotation, CLI smoke test, HTTP and RLS checks, Redis quota and outage, and the per-replica quota negative control.
- [Clean lesson replay](replay.txt). A scratch build from the Markdown lessons with the live gate enabled.
