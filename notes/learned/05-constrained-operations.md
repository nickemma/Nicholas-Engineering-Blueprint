# Phase 5 self-test

Answer from memory, then check yourself against [the lesson](../../lessons/05-constrained-operations/TEACHING.md). Write each "predict" answer before running anything.

## A. Containers

1. What is a container, to the kernel? Name three namespaces and what each changes.
2. What do cgroups do? Where can a process read its own memory limit?
3. What does exit status 137 mean, and how do you confirm it after the fact?
4. Why is PID 1 special for signals? What does `--init` change?
5. Why does the Dockerfile copy `go.mod` and `go.sum` before the rest of the code?
6. What does distroless leave out, and what does that cost you when debugging?
7. Predict: a server in a container listens on `127.0.0.1:8080`, published with `-p 8080:8080`. What does `curl localhost:8080` on the host print?

## B. Compose and Kubernetes

8. What is twelve-factor config, and why does it matter more once there's an image?
9. What should a health check test? Why was RabbitMQ's `ping` the wrong one?
10. Describe the four control loops that act when you create a Deployment.
11. Liveness vs readiness: what does failing each do? Predict: a liveness probe pings the database, and the database is slow for a minute. What happens?
12. Requests vs limits: which does the scheduler use, and which does the kernel enforce?
13. Predict: you roll out a version whose Pods never become ready. What do users see, and why?
14. Why did it take almost six minutes to replace the Pods on a stopped node? Name the two delays.

## C. Load balancing

15. Where does a Service's virtual IP live? Describe the iptables rules kube-proxy writes.
16. What does a headless Service's DNS name resolve to?
17. Why does `ndots:5` cause extra DNS lookups for short names?
18. Predict: a gRPC client calls a Service 300 times on one connection. How are the calls spread over three Pods?
19. Layer 4 vs layer 7: what can each see and do? What did the extra hop cost, measured?
20. Explain the power of two choices. With one slow Pod of three, what share of requests went to it under random, and under two choices?
21. Why did scaling the API down fail ten requests through the gateway?

## D. State on Kubernetes

22. What does a StatefulSet guarantee that a Deployment doesn't?
23. What happens to a PersistentVolumeClaim when its Pod, or its StatefulSet, is deleted?
24. Why is a Secret not secret from someone who can read Secrets in its namespace?
25. Why run migrations as a Job, or a hook, rather than in the service?
26. Why does `metad` need `podManagementPolicy: Parallel` and `publishNotReadyAddresses`?
27. What does a PodDisruptionBudget protect against, and what doesn't it?
28. Why did a drained `metad` member stay `Pending`?

## E. Releases and delivery

29. What are a chart, a release and a revision? What does `helm rollback` create?
30. What does the config checksum annotation do?
31. Explain the shutdown race. Why does a `preStop` sleep fix it? What must `terminationGracePeriodSeconds` be longer than?
32. Why did kload see no errors with or without the sleep, and what did?
33. What does `maxUnavailable: 0, maxSurge: 1` guarantee?
34. How does a canary behind the same Service split traffic, and what limits it?
35. Tag, digest, image ID: define each. Which does the cluster run when you deploy by digest?
36. Why does the pipeline build the image once? Why does only one job get `packages: write`?
37. What's the difference between `--reuse-values` and `--reset-then-reuse-values`?

## F. Observability

38. Define a trace and a span. What does a `traceparent` header contain?
39. How does a trace cross the outbox? Why must the relay continue the stored trace?
40. Why is the HTTP span renamed after routing?
41. Predict: you remove the extraction of `Envelope.Trace` on the consumer side. What do you see in Jaeger?
42. Gateway collector or sidecar: what does each cost and buy?
43. Define SLI, SLO, error budget and burn rate. What burn rate spends 2% of a month's budget in an hour?
44. Explain the multi-window, multi-burn-rate page. Why both windows?
45. Why must recording rules and alerts that read them share a group?
46. Why `or vector(0)` in the error ratio?
47. Predict: a 30-day SLO, and Prometheus started 10 minutes ago. What happens to the 1-day and 3-day windows during a short outage?
48. Explain the USE method, and apply it to the workers and to the database pool.

## G. Controllers

49. What makes a controller level-triggered? Why does that make it safe to crash and restart?
50. Why does the autoscaler count unacknowledged messages, not just ready ones?
51. Why scale up at once and down slowly? Why scale down to the window's *largest* recommendation?
52. What RBAC does the autoscaler have, exactly?
53. Why must the chart stop setting `replicas`? What happened on the upgrade that stopped setting it?

## H. Game day and incidents

54. Why write the hypothesis before the experiment?
55. What does `tc qdisc ... netem delay` on a Pod's veth change, and in which direction?
56. Define trigger and amplifier. Which should you fix first, and why?
57. Explain how a full events queue dead-lettered jobs that never ran. What is the fix, and where does the pressure go?
58. Why can't readiness help when it checks a dependency every Pod shares? What does the API do now instead?
59. What did PreVote and CheckQuorum do in the partition experiments?
60. What makes a postmortem blameless, and why does it matter?

## I. AWS and Terraform

61. What does `terraform plan` compare? What is the state file for?
62. Public and private subnets: which resources go in which here, and why?
63. Execution role vs task role.
64. Map each AWS service to the step it replaces, and name one thing you had to rebuild.
65. Why does SQS not need the attempt header? How does the adapter delay a retry?
66. Roughly what does this configuration cost a day, and what protects you from forgetting it?
