# 5. Cold-chain integrity for medicines

**Field:** supply chain and pharmacy · security · edge systems · **Difficulty:** medium

## Problem

Many vaccines and biologic medicines must stay within a narrow temperature range. Many vaccines, for example, must be kept between 2 °C and 8 °C. A temperature excursion anywhere between the manufacturer and the patient can make a medicine ineffective, with no visible sign. Shipments pass through several organisations, often through places with poor connectivity. Temperature records can be lost when a logger fails, or *altered* when someone wants to hide an excursion.

## Who

Pharmaceutical distributors, pharmacies, public immunisation programmes and regulators. In the end, patients.

## Gap

- Data loggers record temperatures, but their records are usually uploaded later, to one company's cloud, and trusted as given.
- Centralised IoT platforms assume connectivity and a single trusted operator.
- Blockchain proposals add tamper evidence, but often at a cost in complexity, bandwidth and energy that small distributors can't bear.
- Lighter approaches have been less studied for this setting. One is **hash chains with periodic anchoring**: the same idea behind Certificate Transparency's logs (RFC 6962).

## Research question

> Can an offline-first, hash-chained temperature log, with periodic anchoring to independent witnesses, detect excursions and tampering across a multi-party cold chain? How much bandwidth, storage and detection delay does it cost compared with centralised cloud logging and a blockchain-based ledger?

## Hypothesis and baseline

- **Baselines:**
  - (a) loggers that upload to a central cloud when connected;
  - (b) recording every reading on a permissioned blockchain (simulated).
- **Hypothesis:** hash chains with anchoring detect the same tampering as the blockchain at a small fraction of the bandwidth and energy, and lose no data during outages, unlike the cloud baseline.

## System

- **Logger software** (the Rust log from the Rust Bridge, extended), simulated on many devices. It appends signed, hash-chained readings and survives power loss and torn writes.
- **Handoff protocol:** when a shipment moves between parties, the sender's log head and a summary are signed by both parties.
- **Witness servers** (Go, built from Runway) that receive periodic log-head anchors, like Certificate Transparency's signed tree heads.
- **A verifier** that checks a shipment's whole history and flags excursions and inconsistencies.
- **Attack simulator:** edited readings, deleted segments, replayed logs, a colluding party.

## Experiment

| Variable | Values |
|---|---|
| Design | Cloud upload; hash chain plus anchoring; blockchain baseline |
| Connectivity | Always on; daily windows; multi-day outages |
| Parties per route | 2–6 |
| Attacks | None; modify; delete; reorder; replay; collusion of one or two parties |
| Readings | Every 1, 5 or 15 minutes; synthetic traces with injected excursions, modelled on published storage guidance |

## Measures

- Excursion and tamper detection rate, and time to detect.
- Bytes sent per day per logger.
- Storage.
- Estimated energy.
- Data lost during outages.

## What you might find

Anchoring may give strong tamper evidence cheaply, until two adjacent parties collude, which no design without independent witnesses or sensors can fully prevent. Finding exactly where that boundary lies is the result.

## Limitations to expect

- Simulated devices and synthetic temperature traces.
- Logger hardware security (key extraction) is out of scope.
- Real regulatory acceptance needs domain partners.

## Skills used

The Rust Bridge (records, checksums, recovery), Phases 2 (messaging), 3 (durable logs), 4 (failure models), 6 (signatures, threat modelling, audit) and 7 (analysis).

## Read first

- Laurie, Langley and Kasper, *Certificate Transparency*, RFC 6962
- Crosby and Wallach, *Efficient Data Structures for Tamper-Evident Logging*, USENIX Security 2009
- The WHO's guidance on vaccine storage and temperature monitoring
