# Caching · Evidence

The reference run uses Go 1.26.6 with the `redis:8` and `postgres:17` images.

- [Gate capture](gate.txt). Cold and warm reads, write invalidation, Redis expiry, a stalled Redis server, and the singleflight negative control.
- [Clean lesson replay](replay.txt). A fresh build from the Markdown lessons with the live gate enabled.
