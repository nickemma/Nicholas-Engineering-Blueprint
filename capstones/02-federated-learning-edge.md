# 2. Federated learning on unreliable networks, with untrusted clients

**Field:** ML and AI · distributed systems · security · **Difficulty:** high · **Languages:** Go (coordinator), Python (clients)

## Problem

Federated learning trains a shared model across many devices or organisations without collecting their raw data: each client trains locally and sends only model updates. In practice, clients drop out mid-round, links are slow and asymmetric, and some clients are **malicious**, sending poisoned updates to corrupt the model. Aggregation rules that are robust to attacks often assume reliable participation, and rules that tolerate stragglers often assume honest clients.

## Who

Hospitals training a shared diagnostic model, phone keyboards learning word predictions, and IoT fleets. The engineers who run these systems must choose an aggregation strategy without seeing the data.

## Gap

- **FedAvg** (McMahan et al., AISTATS 2017) averages updates, so one bad client can skew it.
- Robust aggregators (median, trimmed mean) and sybil defences such as **FoolsGold** (Fung, Yoon and Beschastnikh, RAID 2020) resist attacks, but are usually evaluated with all clients participating over good links.
- How robustness, accuracy and bandwidth trade off **together**, under realistic dropout and slow links, is less well characterised.

## Research question

> Under client dropout and constrained, asymmetric links, how do FedAvg, coordinate-wise median, trimmed mean and a similarity-based sybil defence compare in final accuracy, robustness to poisoning, and bandwidth? Does an asynchronous variant change the ranking?

## Hypothesis and baseline

- **Baseline:** synchronous FedAvg with all clients reachable.
- **Hypothesis:** robust aggregators lose less accuracy under poisoning but degrade faster under high dropout, because each round has fewer updates to filter. An asynchronous, staleness-weighted variant recovers some of that loss.

## System

- **A coordinator** (Go, gRPC from Phase 2) that runs training rounds, tracks client liveness, and applies a pluggable aggregator.
- **Clients** in Python (PyTorch from Phase 7), each training on its own partition of a public dataset, with optional attack behaviours (label flipping, scaled updates, sybils).
- **A network emulator** (Phase 5) for client links, plus dropout schedules.
- **Experiment harness** and analysis in Python.

## Experiment

| Variable | Values |
|---|---|
| Aggregator | FedAvg, median, trimmed mean, a FoolsGold-style defence, async staleness-weighted |
| Data split | Independent and identically distributed; non-IID (a few classes per client) |
| Dropout per round | 0%, 20%, 50% |
| Attackers | 0%, 10%, 30% of clients; label flipping; sybils |
| Links | 0.5–10 Mbit/s, symmetric or asymmetric |
| Dataset | FEMNIST from the LEAF benchmark, or CIFAR-10 with a small CNN (both public; CPU-feasible at small scale) |

## Measures

- Test accuracy.
- Attack success rate.
- Rounds and time to reach a target accuracy.
- Bytes sent per client.
- Coordinator CPU.

## Suggested stack

| Part | Choice | Why |
|---|---|---|
| Coordinator | Go, gRPC (Phase 2) | Rounds, deadlines, liveness and retries are control-plane work |
| Clients | Python, PyTorch (Phase 7) | The training itself |
| Update transport | gRPC streaming, with compression as an experimental option | Updates are the bandwidth cost being measured |
| Network emulation | `tc netem` per client container (Phase 5) | Asymmetric, slow links |
| Analysis | Phase 7's `lab` | Intervals over seeds |

Rust has no part here unless profiling shows the coordinator's aggregation is the bottleneck. Measure first.

## Features to implement

1. A round protocol with deadlines: the coordinator closes a round when enough clients report or the deadline passes.
2. Pluggable aggregators: FedAvg, coordinate-wise median, trimmed mean, a FoolsGold-style defence, asynchronous staleness-weighted.
3. Client behaviours: honest, dropping out on a schedule, label flipping, scaled updates, sybils.
4. Per-client link profiles and dropout schedules, replayed exactly per seed.
5. Checkpointing of the global model, so a coordinator crash costs one round, not the run.
6. Metrics per round: participants, bytes, time, accuracy and attack success.

## Benchmark your work

- **Time to accuracy:** wall-clock time and bytes to reach a target accuracy, per aggregator and condition.
- **Coordinator scaling:** rounds per minute and coordinator CPU as clients grow from 10 to 1,000 (simulated clients).
- **Failure:** kill the coordinator mid-round, and measure recovery time and lost work.
- **Rigour:** at least 5 seeds per condition, intervals on every difference, and the dataset split and attack parameters saved with the results.

## What you might find

Robust aggregators may shine with honest high participation but collapse in non-IID, high-dropout settings, where honest clients already look different from each other. That tension is a real research finding.

## Limitations to expect

- Simulated clients aren't real phones or hospitals.
- Small models and datasets.
- Privacy attacks such as gradient inversion are out of scope unless added.

## Skills used

Phases 2 (gRPC, retries), 4 (failure models), 5 (network emulation), 6 (threat modelling) and 7 (PyTorch, experimental method).

## Read first

- McMahan et al., *Communication-Efficient Learning of Deep Networks from Decentralized Data*, AISTATS 2017
- Fung, Yoon and Beschastnikh, *The Limitations of Federated Learning in Sybil Settings*, RAID 2020
- Caldas et al., *LEAF: A Benchmark for Federated Settings*, 2018
- Kairouz et al., *Advances and Open Problems in Federated Learning*, 2021 (a survey; read the sections you need)
