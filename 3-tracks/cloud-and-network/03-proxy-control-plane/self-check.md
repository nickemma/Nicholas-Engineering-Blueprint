# Proxy control-plane self-check

1. What does the generation identify? What does the digest identify? Which state can an identical retry change?
2. What can go wrong between a successful health check and applying a route? What does the in-flight request still hold after an update?
3. Which boundary checks certificate trust, role, and socket access? How does the sidecar read back what Rust actually applied?
4. Why use one PEM bundle and one read per handshake? Which connection must be fresh for a new serial to be observable?
5. Which parts of an event are authenticated? When does the receiver update the receipt ledger? Where does the sender get a destination address?
6. What policy path grants the signing role read access? When the key rotates, how does the receiver choose a key version?
7. Which packets are included in the XDP counter? Which measurement tells you that five requests reached the same upstream?
8. After losing an acknowledgement, what independent observation would make it safe to retry? What changed in the negative control?

## From memory

Draw the data and management paths. Mark the peer roles, Unix socket, generation readback, and point where a request chooses its origin. Trace a replay of generation 1 after a lost acknowledgement and then a rollback at generation 2.

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
