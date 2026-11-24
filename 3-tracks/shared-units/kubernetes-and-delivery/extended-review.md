# Kubernetes and delivery · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: Run Switchyard on kind

1. Liveness vs readiness: what does failing each do? Predict: a liveness probe pings the database, and the database is slow for a minute. What happens?
2. Requests vs limits: which does the scheduler use, and which does the kernel enforce?
3. Predict: you roll out a version whose Pods never become ready. What do users see, and why?

### Lesson 03: Deploy the jobs path with persistent storage

4. What does a StatefulSet guarantee that a Deployment doesn't?
5. Why run migrations as a Job, or a hook, rather than in the service?

### Lesson 04: Give each Raft peer a stable identity

6. Why does `metad` need `podManagementPolicy: Parallel` and `publishNotReadyAddresses`?
7. What does a PodDisruptionBudget protect against, and what doesn't it?

### Lesson 05: Roll out a canary with Helm

8. How does a canary behind the same Service split traffic, and what limits it?
9. What's the difference between `--reuse-values` and `--reset-then-reuse-values`?

### Lesson 06: Build once and promote by digest

10. Tag and digest: define each. Which does the cluster run when you deploy by digest?

### Lesson 08: Alert on budget burn

11. Explain the multi-window, multi-burn-rate page. Why both windows?

### Lesson 09: Reconcile worker replicas against backlog

12. What makes the reconciler level-triggered? Why does that make it safe to crash and restart?
13. Why scale up at once and down slowly? Why scale down to the window's *largest* recommendation?
14. What RBAC does the autoscaler have, exactly?
15. Why must the chart stop setting `replicas`? What happened on the upgrade that stopped setting it?

### Lesson 10: Enforce the deployment boundary

16. What does a default-deny NetworkPolicy do, and why must DNS have its own?
17. What does Pod Security's `restricted` level require?
18. Why remove a token from a Pod whose account can do almost nothing?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | Liveness vs readiness: what goes wrong if a liveness probe checks a database? | | |
| 02 | What does an HTTP router in front of Services see that a Service can't, and what does it cost? | | |
| 03 | Why run migrations as a Job, and why were the API Pods ready with no schema? | | |
| 05 | Why can't this kind of canary take 1% of traffic? | | |
| 06 | Tags and digests: what is each, and which do you deploy? | | |
| 06 | Why build once and pass the file between jobs? | | |
| 07 | What did `--reuse-values` do wrong? | | |
| 09 | What makes the reconciler level-triggered, and why is that safe to restart? | | |
| 09 | Why does scale-down wait, and why to the window's *largest* recommendation? | | |
| 09 | What can the reconciler's service account do, and what can't it? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A drain refused by the disruption budget | | |
| The canary's share of traffic | | |
| The same digest under two tags; a tag moved | | |
| One job's trace across the API and the worker | | |
| Every promtool test passing; one that failed first, and why | | |
| The page firing during a database outage, with timings | | |
| A burst: the reconciler's decisions and the backlog over time | | |
| Ports from another namespace, before and after network policy | | |
| A root Pod refused by Pod Security | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
