# KESTREL — Community Health Data, Shared Safely

KESTREL is a research-led distributed systems project with a public-interest goal: help community health organizations make better use of shared information while keeping custody of sensitive records and continuing to work through unreliable connectivity.

The working research question is:

> How can small, resource-constrained health organizations produce timely, trustworthy cross-site summaries when their data must remain under local control and their network connections are intermittent?

The project will investigate local-first storage, authorized data sharing, auditable queries, and safe recovery after disconnection. It will measure freshness, availability, latency, bandwidth, and the privacy risks of each design. It will begin with synthetic or public data; use of sensitive real-world data would require appropriate partners, consent, and ethics review.

This is not an AI product looking for a use case. The core system is useful without AI. Privacy-preserving distributed analysis or machine learning can be explored later only if a real user need justifies it and the project can evaluate the added privacy and operational costs.

## Build toward the question

```text
small request service
  → reliable service
  → local data and audit trail
  → sites that share data safely
  → useful operation through network outages
  → measured privacy, reliability, and usability
```

Each step teaches a systems concept needed by the research question. We build a small capability, make its guarantee explicit, test what happens when it fails, and keep evidence that another person can reproduce.

## Start here

Read [the roadmap](plan/structure.md) for the learning order and [the project brief](project.md) for the current research direction. Begin with **Phase 0** only. The later phases are a plan; the current hands-on work is the small Go request service.
