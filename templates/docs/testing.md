# Testing strategy

*Current as of `main`.*

## Layers

<!-- charter:19 - testing -->
**Status:** not built.

| Layer | Covers | Runs | Command |
|---|---|---|---|
| Unit | | every commit | `make test` |
| Integration | | every commit | |
| Property / invariant | the invariants in `architecture.md` | every commit | |
| Load | the targets in `benchmarks.md` | before a tag | `make bench` |
| Chaos | the failure modes in `runbook.md` | before a tag | |
| Security | the controls in `threat-model.md` | before a tag | |

Every row after the second is a contract with another document. If an invariant has no
property test, or a control has no security test, those documents are describing
intentions rather than behavior.

## Invariant tests

| Invariant | Test | Generator / seed strategy |
|---|---|---|

## Not tested, deliberately

<!-- The mature part. What is out of scope, and the reason — cost, low value,
     covered elsewhere. An untested area you have named is a decision; an untested
     area you have not named is a hole. -->
