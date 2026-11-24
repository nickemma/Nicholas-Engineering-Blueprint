# Kubernetes and delivery · Evidence

The live capture used kind v0.33.0 with Kubernetes v1.37.0 on a local Docker daemon. The lab images and signatures were stored in the loopback registry. The Prometheus rule fixture used v3.15.0.

| Check | Capture |
|---|---|
| Readiness, peer identity, scaling, and trace propagation | [Go tests](unit-tests.txt) |
| Chart rendering and promotion failure control | [Offline gate](replay-gate.txt) |
| Signed image and SPDX inventory validation | [Release verification](release.txt) |
| Alert transitions by track | [Prometheus rule tests](rules.txt) |
| Client path, canary, alert, rollback, voter claim and network enforcement | [Live kind gate](cluster-gate.txt) |
