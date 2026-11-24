# Distributed KV capstone · Self-check

Answer from the protocol and recorded evidence before opening the implementation.

1. Which request fields identify one logical mutation? How does a client reuse that identity when the response is lost?
2. Where is a tenant established, and when is plaintext turned into a ciphertext envelope?
3. What does the Rust store receive when a Raft snapshot is installed? Why can a local Rust sequence differ from a Raft log index?
4. How can a peer rebuild without its local Rust directory? Which entries may it apply after a snapshot?
5. Why does the reference gate interrupt a leader after apply, and why is the minority-write control a separate fixture?
6. How do the client history and the peer logs answer different recovery questions?
7. Why does a singleton range match its exact key even if another key is a longer byte sequence with the same prefix?
8. Which costs are inside the YCSB timing that are outside the Rust lookup replay?
9. If throughput improves in the read-only runs but read p99 grows in some mixed runs, what can the data support?
10. Which files should a reviewer need to rebuild the package and reproduce its comparisons?

Check your answers with the [module](README.md) and [reference evidence](evidence/README.md).
