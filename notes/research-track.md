# Research track (personal)

My own MSc preparation. The learner-facing path is in [JOURNEY.md](../JOURNEY.md). This file keeps what is specific to me.

## Destination

I want to be a Distributed Systems Engineer who can design, build, secure, evaluate and explain infrastructure for a validated public-interest need, and who is ready for research in distributed systems, networking, privacy or systems software.

| Outcome | What proves it |
|---|---|
| Industry-ready | A reliable, observable system with failure evidence, operational notes and a threat model |
| Research-ready | A precise question, a baseline, a reproducible evaluation, paper notes, and a report on a systems, network or privacy trade-off |

## How KESTREL differs from my other projects

My portfolio already covers distributed storage (MERIDIAN), developer platforms (VEYRONIX), search (LATTICE), model serving (TESSERA) and AI governance (SYNAPSE-AI). KESTREL shouldn't rebuild those under another name. It adds something different: a user-validated, public-interest workload, and a careful evaluation of how data-sharing choices affect people when organisations have limited connectivity and strict control over sensitive information. Existing projects can serve as infrastructure or baselines where they fit.

Local-first replication is a hypothesis to test, not a promised improvement. It may improve access during outages while increasing stale-data, conflict, privacy or operational risk.

The direction draws on distributed storage and networking, decentralised services, geo-distributed performance, formal methods, systems tools, privacy, and secure distributed analysis. Those connections are visible in the research of [Bernard Wong](https://cs.uwaterloo.ca/~bernard/) and [Ivan Beschastnikh](https://www.cs.ubc.ca/~bestchai/). The research fit should guide the experiments; it doesn't imply endorsement or supervision.

## Targets

- University of Waterloo: MMath in Computer Science, thesis.
- UBC: MSc in Computer Science, thesis (Vancouver).
- Interest: systems and networking, secure distributed systems, and distributed systems broadly.

If the MSc starts in fall 2027, finishing Phase 4 and one technical report before then is realistic and valuable.

## What admissions committees and supervisors look for

- Evidence of research ability: reading papers critically, forming a question, running an honest experiment, writing it up.
- Fit with a supervisor's work.
- Solid fundamentals.

## Research habits

1. **Read papers with Keshav's three-pass method.** Keep a one-page note per paper covering the problem, key idea, assumptions and failure model, evaluation, one weakness, and one open question.
2. **Reproduce one result**, for example a Raft or VR behaviour under partition, or a Jepsen-style anomaly in a real database. Document where my numbers differ.
3. **Write one technical report** (4–6 pages, LaTeX) from Phase 4 or Phase 8. Possible questions:
   - How do freshness and availability trade off under intermittent site connectivity?
   - What can a site infer from repeated cross-site aggregate queries?
   - How does local-first replication affect recovery and operator effort?
4. **Specify one protocol in TLA+** and model-check a safety property.
5. Learn LaTeX and Zotero.

## Areas to explore

| Area | Starter papers |
|---|---|
| Byzantine fault-tolerant replication | PBFT (OSDI 1999); HotStuff (PODC 2019) |
| Accountability and auditing | PeerReview (SOSP 2007) |
| Verified distributed systems | IronFleet (SOSP 2015); Verdi (PLDI 2015) |
| Testing distributed systems | Jepsen analyses; *Simple Testing Can Prevent Most Critical Failures* (OSDI 2014) |
| Authorisation at scale | Zanzibar (2019) |
| Supply-chain integrity | in-toto (2019) |
| Privacy-preserving distributed analysis | Current primary papers, chosen after defining the data, query and adversary model |
| Systems analysis tools | Dinv, ShiViz, NetCheck, and specification-mining work from Systopia |

## Groups to study

Verify current faculty and intake before contacting anyone.

- **Waterloo, Cheriton School of Computer Science:** the Systems and Networking group; the Data Systems Group (Khuzaima Daudjee); the CrySP group (Ian Goldberg; N. Asokan).
- **UBC Computer Science:** the Systopia lab; the Security & Privacy group; Ivan Beschastnikh.
- **Faculty moves happen:** Thomas Pasquier announced a move to Oxford in September 2026.

For each potential supervisor, read two recent papers and write a short note connecting them to something I built. That note is the core of a good contact email.

## Maths readiness

The MMath sits in the Faculty of Mathematics. Keep discrete maths, probability and proof-writing sharp alongside the BSc. Lynch's distributed-algorithms material and the FLP paper are good practice in reading proofs, and TLA+ builds formal reasoning.

## Optional certifications (after Phase 5)

CKA, AWS Solutions Architect Associate, Terraform Associate.
