# Phase 1 learning record

Answer after completing [TEACHING.md](TEACHING.md). Explain in your own words and point to a command, test, or output that supports each answer. If you cannot answer, return to that step, run the check, and write down what changed in your understanding.

## Build and contract

1. What information makes something a job, and which component owns the job's state?
2. Why does POST return 201 while a successful GET returns 200?
3. What is the difference between an invalid request, an unknown job ID, and a job that cannot make the requested transition?
4. Show the curl command and response for creating and fetching one job.

## Process, concurrency, and cancellation

5. What is a goroutine? How is it different from a process?
6. What two operations could overlap when two requests update the map? What exactly does the mutex protect?
7. What did the race detector report before the repair, and what test did you run after the repair?
8. When does a request context become cancelled? What does the timeout test prove, and what does it not prove?
9. What happened to a job after you restarted the process? Why?
10. What did graceful shutdown wait for, and what happened when its deadline was reached?

## Reliability and security

11. Which resource limits did you add? Give the bad request you used to test each limit.
12. What is in the request log? What data did you deliberately leave out?
13. How would changing from net/http to chi alter routing? What would Gin add? Which parts of HTTP remain the same?
14. Name one guarantee the service now makes and one guarantee it still does not make.

## Evidence

| Claim | Evidence to attach | Your observed result |
|---|---|---|
| A valid request creates and fetches one job | curl output plus test name | |
| Invalid input is rejected according to the contract | curl or test cases | |
| Concurrent map access is protected | race-detector output and concurrent test | |
| Cancellation is passed through to work | cancellation test or log | |
| Shutdown is bounded | terminal observation and process/socket check | |
| Restart loses the in-memory jobs | before/after restart output | |

## Kestrel transfer

Close this lesson and its implementation before rebuilding the feature in Kestrel. Keep only the API contract and your own notes visible.

- What did I design from the contract without looking at lesson code?
- What behavior did I test first, and why?
- What did I have to look up in official Go documentation?
- Show one successful request, one rejected request, one concurrency test, and the race check.
- What differs from the lesson design, and what evidence supports my choice?
- What can I now explain about process memory, goroutines, locks, cancellation, and shutdown without using memorized definitions?
- What question remains unclear?
