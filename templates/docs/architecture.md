# <System> — Architecture

**Context diagram:** <!-- system + external actors -->
**Container diagram:** <!-- deployable units + data stores -->
**Component diagram:** <!-- inside the critical container -->
**Trust boundaries:** <!-- mark them explicitly; they feed the threat model -->

*Current as of `main`. Rewritten whenever behavior changes. Where this document and the
charter disagree, **this one is right** — record the divergence in the commit body
(`Diverges: charter N — ...`) and it lands in the blueprint's as-built at level exit.*

## Context

<!-- The system and the external actors around it. No internals. -->

## Containers

<!-- charter:7 - architecture -->
<!-- Deployable units and data stores. Seeded from the charter at kickoff. -->
**Status:** not built.

![containers](assets/containers.svg)

## Components

<!-- charter:9 - component -->
<!-- Inside the critical container only. Not every container. -->
**Status:** not built.

## Request path

<!-- charter:8 - sequence -->
<!-- The one flow that matters most, end to end, including the failure branch. -->
**Status:** not built.

## Storage

<!-- charter:10 - schema -->
**Status:** not built.

## Trust boundaries

<!-- Mark them explicitly. Every boundary here becomes a STRIDE row in
     docs/threat-model.md. If a boundary is not listed there, one of the two
     documents is wrong. -->

| # | Boundary | Crosses | Threat-model row |
|---|---|---|---|

## Invariants

<!-- Things that must ALWAYS be true. These come out of the stop-the-build sessions
     and become property tests in docs/testing.md. The charter has no place for
     them, which is exactly why they belong here. -->

| # | Invariant | Enforced in | Tested by |
|---|---|---|---|

## Rejected

<!-- Structures considered and not taken, one line each, with the reason. Distinct
     from ADRs: this is the shape of the space, not a decision record. -->
