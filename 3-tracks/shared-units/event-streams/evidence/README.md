# Event streams · Evidence

The reference uses Go 1.26.6, the `apache/kafka:4.1.0` broker image, and the `postgres:17` database image.

- [Gate capture](gate.txt). Forced rollback, two crash windows, offset resume, a fresh-group rebuild, and the duplicate-count negative control.
- [Clean lesson replay](replay.txt). Every lesson marker from a fresh scratch directory with the live gate enabled.
