# Assessment and service ownership

Use the same Runway curriculum at different levels of independence. A junior delivers a bounded change correctly. An intermediate engineer delivers and operates a compatible service change. A senior engineer establishes a justified direction, coordinates its delivery and remains accountable for its consequences.

These are learning routes, not job-title certifications. Evidence can show a strength in one area and a gap in another. Technical depth, independent delivery and leadership are assessed separately. Reading a senior assignment or implementing advanced technology is not evidence of senior ownership.

[JOURNEY](../../JOURNEY.md) remains the roadmap. This track supplies assignments and assessment methods across its phases; it does not add another sequence of technologies.

## Choose your route

| Route | Start | Working method | Required evidence |
|---|---|---|---|
| Junior | [Beginner minimum route](beginner.md), then the current phase | Guide, rebuild, small independent ticket, review and correction | Correct behaviour, negative/isolation tests, clear docs and an explanation without the guide |
| Intermediate | Demonstrate prerequisites with the entry checks below | Receive an unfamiliar baseline and a symptom or incomplete request; investigate before changing it | Compatibility, rollout, capacity, monitoring, rollback and an operational handoff |
| Senior | Demonstrate the relevant implementation and operational foundations | Resolve competing goals, compare options, negotiate scope, defend a proposal, coordinate delivery and review others' work | Explicit non-goals, cost/reliability trade-offs, sequencing, ownership, reviewed decisions and follow-through |

Choose one route per phase. Junior learners do not complete all three sets of assignments. An experienced learner may still choose the junior route in an unfamiliar domain. Senior work includes the relevant correctness and safety evidence; a proposal cannot substitute for a working implementation.

## Phase assignments

Each phase now has its own `assessment.md`, linked from its syllabus. Complete its common gate plus the assignment for your chosen route. The shared [review rubric](reviews.md) determines the verdict; the phase page defines the observable checks.

| Phase | Ownership question |
|---|---|
| [0: One request](../00-request-service/assessment.md) | Can someone else reproduce and review your small change? |
| [1: Reliability](../01-reliable-service/assessment.md) | Can you preserve behaviour under concurrency and shutdown? |
| [2: Connected services](../02-connected-services/assessment.md) | Can you diagnose and change a contract across independently deployed processes? |
| [3: Durable data](../03-durable-auditable-data/assessment.md) | Can old and new versions coexist while data changes? |
| [4: Replication](../04-replicated-state/assessment.md) | Can you distinguish a safety guarantee from an availability promise? |
| [5: Operations](../05-constrained-operations/assessment.md) | Can another person deploy, diagnose and recover your service? |
| [6: Security and tenants](../06-safe-shared-queries/assessment.md) | Can another tenant be added without harming existing tenants? |
| [7: Measurement and ML](../07-utility-evaluation/assessment.md) | Can evidence prevent a harmful model promotion? |
| [8: AI infrastructure](../08-ai-infrastructure/assessment.md) | Can you allocate expensive capacity fairly and defend the release? |

## Entry and advancement

Before working independently in a phase, demonstrate its prerequisites: start the baseline from a clean checkout, trace one relevant operation, run one relevant test, reproduce one documented failure and explain its recovery. Record a commit and evidence links. This is a placement check, not a timed interview. If a capability is missing, take the corresponding guide and reassess it; do not require the learner to repeat unrelated material.

A phase's common gate is its existing definition of done in JOURNEY: clean checkout, working checks, explanation, failure evidence, trade-offs, exercise, learned answers and self-test. The route assignment adds evidence about independence and ownership. A learner may progress after the junior gate without pretending to have passed the intermediate or senior gate. A missing prerequisite blocks dependent work, not unrelated learning.

The reviewer records `ready`, `needs revision` or `not assessed`, with linked evidence and one specific next action. No average score can hide a critical correctness, isolation, data-loss or recovery failure. Use the review process rather than time spent or the amount of code written.

## Work in an unfamiliar system

For an intermediate assessment, use a collaborator's phase rebuild or a pinned earlier revision whose relevant implementation you have not studied. The evaluator supplies the commit, supported versions, commands, a symptom and acceptance contract, but withholds the diagnosis. Establish whether the baseline itself passes before introducing a fault. A broken environment is not automatically an application bug.

The evaluator may use a documented Break it mutation from that phase, record its patch privately, and verify that the symptom reproduces and is reversible. Reveal it after the learner's investigation. Do not introduce surprise requirements after submission: any changed requirement is a recorded stakeholder change with an opportunity to revise the plan.

With no collaborator, use an older unfamiliar revision, record what you already know, and run a documented failure. Label this **self-reviewed; diagnosis may be known**. It is useful practice, but not an independent unfamiliar-system assessment. The [open-source track](../../open-source/README.md) supplies another route to external review.

## Sustain ownership

From Phase 5 onward, run the [ownership exercise](sustained.md) alongside the phase work. It includes scheduled changes, dependency maintenance, incidents, review and handover over twelve actual weeks. A compressed simulation can check procedures; it cannot establish months of ownership.

Use the [templates](templates.md) for tickets, proposals, migration plans, reviews and ownership records. Keep completed artifacts in your own Runway repository, with secrets and private user data removed. The curriculum contains specifications, not completed assessment solutions.
