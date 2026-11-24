# Exercise · Probe and recover a service

Choose a service you can run locally and seed with a synthetic value. Build a process that has its own credentials and observes the client contract. Choose a fault that leaves the process running while a user-visible request fails.

## Acceptance checks

1. Write the good outcome, eligible denominator, deadline, window, and threshold before running the fault.
2. Prove that four distinct bad outcomes all count. Use a timeout, unreachable endpoint, unsuccessful response, and incorrect value.
3. Record a healthy baseline and trigger the chosen fault. Capture an alert event within the window you set.
4. Give another reader a runbook they can follow from a clean lab. It must describe the signals that distinguish at least two plausible diagnoses.
5. Apply the rollback, record the clear transition, and independently verify the original seeded value.
6. Remove failed observations in a disposable probe variant. The same fault drill must detect that missing alert.
7. Search the stated log and observation files for the synthetic value. Write a short postmortem with the observed impact, timeline, and one follow-up you can test.

## Additional practice

[beacon, synthetic monitoring](exercise-beacon-and-two-regions.md)
