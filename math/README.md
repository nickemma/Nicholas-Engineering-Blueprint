# Maths

The mathematics that systems work actually uses, tied to systems you've built. Each guide is built like the lessons and checked the same way: the formula, then code that tests it, then a measurement of something real. A parallel track, like [DSA](../dsa/README.md): start each guide when you reach the phase it serves.

| # | Guide | The question | Serves | You'll measure |
|---|---|---|---|---|
| 01 | [Probability and queueing](01-queueing/README.md) | Why does a service at 90% feel broken when one at 70% feels fine? | Phases 2–5; the [Performance Bridge](../lessons/perf-bridge/README.md) | Little's law and Pollaczek–Khinchine, on your own Runway |
| 02 | [Proofs and invariants](02-proofs-invariants/README.md) | How do you know something holds in **every** case? | Phase 4; the Research MSc | Every state of a Raft election, with a model checker you write |
| 03 | [Linear algebra for ML and GPUs](03-linear-algebra/README.md) | Why does AI run on GPUs? | Phase 8 | Arithmetic intensity and the roofline, on your own CPU |

## How to work through it

1. Read the guide, and type the code. Use the [setup in guide 01](01-queueing/README.md#set-up-the-project).
2. Work out each formula by hand before you run the code.
3. Do the practice alone. There are no solutions in this repository.

CI replays these guides, and runs their tests. It doesn't rerun the measurements, which need your running Runway, or a quiet machine. Those outputs were captured by hand on one laptop, and each guide says which ones they are.

## What each one found

- **Queueing:** Little's law held to within about 2% on all 27 stable runs against a real broker and database. Below 93% utilisation, Pollaczek–Khinchine predicted Runway's latency with a median measured-to-predicted ratio of 0.88 to 0.97. Making jobs predictable nearly halved their wait at the same load.
- **Proofs:** Raft's vote rules hold in all 8,836 reachable states of a small model, and breaking either rule gives a short counterexample. "At most one leader" is true but not inductive; adding *why* it's true makes it provable.
- **Linear algebra:** the same multiplies and adds ran about 20 times faster as a matrix multiply than as a dot product over main memory, and a roofline fitted to one operation predicted another to within about 15%.

## Limits

Queueing theory describes long-run averages, and a queue near saturation needs far longer to settle than the runs here. A small model is checked for three servers and two terms, which isn't a proof for all sizes. The roofline ignores caches between the two extremes. Each guide lists its own.
