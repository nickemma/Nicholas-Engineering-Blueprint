# A minimum route for beginners

You do not need to complete the whole Blueprint before achieving a useful milestone. Work on one phase and one small ticket at a time. Use local services and synthetic data; early checkpoints are not permission to expose an unfinished service publicly.

## Three stopping points

| Checkpoint | Route | What you can demonstrate |
|---|---|---|
| First reliable service | Phase 0 → Phase 1 | Build and test an HTTP service, handle errors/concurrency, explain requests and shutdown, deliver a reviewed small change |
| Services working together | Previous checkpoint → Python Bridge → Phase 2 | Trace work across processes, test retries/duplicates/failures, investigate one bounded integration problem |
| Durable backend foundation | Previous checkpoint → Rust Bridge → Phase 3 | Store and query durable data, explain transactions and migrations, demonstrate crash/recovery and deliver a compatible data change |

For a beginner targeting backend work, the third is the minimum **backend foundation route** here. It is a learning checkpoint, not a promise of employment or production readiness. The first two are legitimate stopping points for review and consolidation. Rust Bridge is included because the existing Phase 3 depends on it; this route does not quietly skip that prerequisite.

The minimum route does not require Phases 4–8, a research capstone, every system-design prompt or the full maths track. Add those when your goal calls for them. Phase 5 currently depends on Phase 4: taking the infrastructure route means following that dependency, not jumping into later startup commands on an incomplete checkout.

During the minimum route, keep DSA to the patterns the current phase uses and one or two short sessions per week. System-design prompts and open-source contributions are optional until the service checkpoint feels comfortable. Advanced stretch goals can wait. You can return to the full parallel-track schedule in JOURNEY later.

## Before Phase 0

Check that you can open a terminal, find your current directory, edit/save a file, run a command and read its exit status. If any is unfamiliar, use Phase 0's setup slowly and ask for review before starting the service. You do not need prior Go knowledge.

At the end of each study session, write the command that worked, one thing you can now explain and the next smallest action. If setup consumes two sessions without progress, reduce the environment to the phase's documented baseline and seek help with the exact error and tool versions. Do not install additional tools speculatively.

## Small independent tickets

Each phase's assessment includes three ticket specifications. Do one at a time, usually in a session or two; split anything larger before coding. The reviewer supplies expected behaviour, not the implementation. The ticket must identify a touched contract, a positive case, a negative case, documentation and a done check.

Use the [ticket template](templates.md#delivery-ticket). Predict the test that should fail before the fix, make the change, then have it reviewed using the [junior criteria](reviews.md). Correct review feedback and rerun the relevant checks. If a task can be completed by copying the guide verbatim, the reviewer should vary one requirement before assigning it.

## Advance on evidence

At each stopping point, close the guide and:

1. Start your rebuild from a clean checkout and run its documented checks.
2. Explain one request/job path, including its failure path.
3. Complete one independent ticket and correct its review feedback.
4. Demonstrate the phase's deliberate failure and recovery.
5. Finish its independent exercise, learned answers and self-test.

The reviewer identifies what is ready and what needs another attempt. A failing readiness check means revisit that skill with a smaller ticket; it does not mean restart the curriculum. Keep review examples from early and corrected submissions to show how your work improved.
