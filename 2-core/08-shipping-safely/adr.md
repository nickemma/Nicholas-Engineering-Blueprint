# ADR · Authenticate at the local metadata gateway

**Decision.** Terminate mTLS at one gateway. Authorize the verified certificate URI against the decoded operation. Forward allowed requests to one configured Core 07 peer over a Unix socket in a private directory.

**Context.** This module runs the gateway and all peers on one host under a dedicated lab account. The account owns the private socket directory. The gateway gets the leaf certificate and key and the public trust root. The issuing private key is kept by the signer. Each client uses its own leaf identity. Other processes that run under the same account share the local trust boundary.

**Alternative considered.** Give each peer its own TLS identity and authenticate every gateway-to-peer connection. That becomes useful when peers span hosts or require separate process identities. It adds per-peer certificate issuance, trust configuration and rotation to a lab that is designed to verify one boundary and one recovery path.

**Consequences.** Clients have a stable gateway address and distinct read and write roles. The active upstream is a configuration dependency. A stale or missing socket path can take down client access while the Raft cluster stays healthy. The gate shows that the external reader sees the failure, the prior configuration restores access, and a reader's write stays forbidden. Recovery also depends on the saved peer still serving commands.

**Review.** Use the game-day timestamps, the recovered read, and the denied write to defend the decision. Explain how process separation, a changed leader, or a second host would change the deployment and the test. [Gate evidence](evidence/07-game-day.txt)
