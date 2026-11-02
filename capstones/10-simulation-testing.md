# 10. Finding consensus bugs before users do: how far does simulation testing reach?

**Field:** distributed systems · testing · formal methods · **Difficulty:** very high · **Language:** Go

## Problem

Distributed systems fail in rare orderings of events. For example:

- a message delayed past an election;
- a crash between two writes;
- a partition that heals at exactly the wrong moment.

Tests on real networks almost never hit these. FoundationDB's deterministic simulation and Jepsen's fault injection have found serious bugs in production databases, and many teams now copy the approach. But random fault injection is blind. It can run for days without reaching the ordering that matters, and nobody can say how much of the system's behaviour it actually covered.

## Who

Engineers building or adopting consensus libraries, databases and queues. Also the reviewers and buyers who must decide whether "we test with chaos" is enough.

## Gap

- **Random testing finds real bugs, but unguided:** Jepsen; FoundationDB's simulation (Zhou et al., SIGMOD 2021).
- **Systematic approaches are guided, but expensive:** semantic-aware model checking (SAMC: Leesatapornwongsa et al., OSDI 2014).
- **Some randomised testers come with probabilistic guarantees:** Ozkan et al., OOPSLA 2018.
- **Partition bugs are common and often catastrophic** (Alquraan et al., OSDI 2018).
- Two questions remain open:
  - How do exploration strategies compare at finding real bugs in real Raft implementations per CPU-hour?
  - Does any measure of coverage predict which strategy will find bugs?

## Research question

> Under a fixed CPU budget, how do uniform random fault injection, partition-focused schedules and coverage-guided exploration compare in time to find known bugs re-injected into real Raft implementations? Does a protocol-level coverage measure predict which strategy finds bugs?

Coverage-guided exploration favours schedules that reach new protocol states.

## Hypothesis and baseline

- **Baselines:**
  - uniform random faults (a Jepsen-style schedule);
  - Phase 4's own simulation tests.
- **Hypothesis:**
  - Coverage-guided exploration finds deep bugs faster, needing several faults in a row.
  - Uniform random is competitive for shallow bugs.
  - Coverage of abstract protocol states predicts bug finding better than line coverage.

## System

- **A deterministic simulator in Go**, hosting real implementations:
  - Phase 4's Raft;
  - [etcd's raft library](https://github.com/etcd-io/raft). It's built to be driven by explicit message passing, which makes it a natural target.
- **Simulated pieces:** network (delay, drop, duplicate, reorder, partial partitions), disk (crashes with torn writes, as in the Rust Bridge) and clock.
- **One seed replays a whole run exactly.**
- **Checkers:**
  - linearizability with Porcupine (Phase 4);
  - Raft's invariants: election safety, log matching, leader completeness, state machine safety.
- **A bug corpus:** known historical bugs and your own Phase 4 mistakes, re-injected behind flags. This is mutation testing at the protocol level: you know each bug is there, and measure how quickly each strategy finds it.
- **Coverage:** abstract protocol states (each node's role, term differences, commit-index relationships), counted as runs explore them.
- **Shrinking:** a failing schedule is reduced to the smallest one that still fails, for the bug report.

## Suggested stack

| Part | Choice | Why |
|---|---|---|
| Simulator, strategies, checkers | Go | The targets are Go libraries; one process, deterministic |
| Parallel runner | Go, across cores | Strategies are compared per CPU-hour |
| Formal model | TLA+ (Phase 4) | To check which invariants each bug breaks |
| Analysis | Python (Phase 7's `lab`) | Time-to-bug distributions and intervals |
| A Rust target | Optional: the same approach on a Rust Raft with a deterministic runtime | Only as an extension |

## Features to implement

1. A deterministic scheduler, with seed replay.
2. A fault library: network, disk, clock, crash and restart.
3. Pluggable strategies: uniform random, partition-focused, coverage-guided.
4. Invariant and linearizability checkers.
5. The bug corpus, with flags to inject each bug.
6. Shrinking of failing schedules.
7. Reports: the failing schedule, the broken invariant, and a replay command.

## Experiment

| Variable | Values |
|---|---|
| Strategy | Uniform random; partition-focused; coverage-guided; Phase 4's tests |
| Target | Phase 4's Raft; etcd raft |
| Bug | Each bug in the corpus, one at a time; none (to measure false alarms) |
| Cluster | 3, 5, 7 nodes |
| Budget | 1, 10, 100 CPU-hours (or fewer, scaled to your machine) |

## Measures

- Bugs found per CPU-hour.
- Time to first detection, per bug: the distribution over seeds.
- Coverage growth over time.
- How much shrinking reduces each failing schedule.
- Simulator throughput: simulated events per second.
- False alarms: checker failures without an injected bug (each is either a real bug or a checker bug; find out which).

## Benchmark your work

- **Throughput:** simulated events per second, on one core and as cores are added. Compare with a single-threaded baseline before claiming that parallel runs scale (COST, Phase 7).
- **Time to bug:** for each strategy, the fraction of seeds that found each bug by time *t*, with intervals.
- **Bottlenecks:** profile the simulator, and say whether the target, the checker or the scheduler dominates.
- **Rigour:** at least 20 seeds per strategy and bug, with time-to-bug distributions rather than single runs. Record the targets' exact versions.

## What you might find

Coverage-guided exploration may find deep bugs much faster, while uniform random finds shallow ones as quickly. Some bugs may only appear with five or more nodes. You may even find a bug that nobody re-injected. Report it responsibly to the maintainers first.

## Limitations to expect

- Simulation finds only bugs the simulated faults can cause; real kernels and hardware fail in other ways too.
- Re-injected bugs may be easier or harder than the unknown ones.
- Coverage of abstract states depends on the abstraction you chose; state it, and test a second one.

## Skills used

Rust Bridge (torn writes), Phases 4 (Raft, simulation, Porcupine, TLA+), 5 (failure injection) and 7 (experimental method, distributions and intervals).

## Read first

- Zhou et al., *FoundationDB: A Distributed Unbundled Transactional Key Value Store*, SIGMOD 2021 (simulation testing)
- Leesatapornwongsa et al., *SAMC: Semantic-Aware Model Checking for Fast Discovery of Deep Bugs in Cloud Systems*, OSDI 2014
- Ozkan et al., *Randomized Testing of Distributed Systems with Probabilistic Guarantees*, OOPSLA 2018
- Alquraan et al., *An Analysis of Network-Partitioning Failures in Cloud Systems*, OSDI 2018
- Kingsbury, the [Jepsen analyses](https://jepsen.io/analyses), read two of them
