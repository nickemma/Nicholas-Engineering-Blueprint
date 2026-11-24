# Messaging and resilience · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: Commands, events, and versions

1. Command or event: "run this job", "this job completed", "charge this card", "the card was charged". How did you decide?
2. What's in an envelope, and why is each field there?
3. What is upcasting? Why must consumers be upgraded before producers?

### Lesson 02: Publish through RabbitMQ

4. Connection vs channel: what's each one, and why share one connection between several channels?
5. What do a durable queue, a persistent message and a publisher confirm each protect against?
6. When does the worker ack? What would change if it acked on receipt?
7. What is a quorum queue, and what protocol keeps its copies in agreement?

### Lesson 03: Commit before acknowledging

8. Define at-most-once, at-least-once and exactly-once in effect. Which does this unit's worker provide, and how?
9. What does prefetch 1 do, and why does it matter for slow jobs?
10. Which errors should open a database breaker? Which must not, and why?

### Lesson 04: Bound retries and route dead letters

11. What is a dead-letter queue *for*? What would you do with a message in one?

### Lesson 05: Stop calling a failing dependency

12. Draw the circuit breaker's states and transitions. Why test it with a controlled clock?

### Lesson 06: Run the crash and redelivery gate

13. Narrate exactly what happens when the worker exits after committing a job's effect but before acknowledging the message.

### The whole module

14. Draw the whole system at the end of this unit: processes, queues, ports, and the path of one job from the producer to its completion event. Mark every place a message could be duplicated or lost, and the defence at each.
15. Rebuild this unit in your own repository, then run the crash-and-redelivery experiment on your code. What differed?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | Command vs event; give one of each from this system | | |
| 01 | Why must readers deploy before writers when a command gains a new version? | | |
| 02 | What three things make a message survive a broker restart? | | |
| 02 | Ack after the work vs ack before: which gives which guarantee? | | |
| 03 | Why is exactly-once *delivery* impossible? What do you build instead? | | |
| 03 | Show that a redelivered command leaves one durable job effect, and what makes it so | | |
| 03 | Which errors should open a database breaker, and which must not? | | |
| 06 | Narrate the crash-and-redelivery gate step by step. Why does the effect happen once? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A worker killed between commit and acknowledgment: the replacement leaves one effect | | |
| A poison message ends up in the dead-letter queue | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
