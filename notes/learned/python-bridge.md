# Python Bridge self-test

Answer from memory, then check yourself against [the lesson](../../lessons/python-bridge/TEACHING.md). Write each "predict" answer before running anything.

## A. Python basics

1. What do `uv init`, `uv add`, `uv add --dev`, `uv lock` and `uv run` each do? Which file does each one touch?
2. How does Python mark a block? What error do you get if you forget, and when?
3. Name four Python values that count as false in `if x:`.
4. List, tuple, dict: when do you use each? Which of them can't change?
5. Write a list comprehension that keeps only the latencies over 100 ms.
6. What does `f"{name:>5}"` do? What does `:g` do?
7. Explain `try` / `except` / `raise`, and compare it with Go's error handling.
8. Predict: `sum(["12", "15"])`. Which error, and why didn't the type hint stop it?
9. What is a docstring? Where does it go?

## B. Functions, classes, data

10. What does `@dataclass(frozen=True)` generate for you? What does `frozen` prevent?
11. What is `self`? What is `cls` in a `@classmethod`?
12. Why call `super().__init__(...)` in `ApiError`?
13. What does a leading underscore, as in `_check`, mean in Python? Is it enforced?
14. What does `*expected` collect? What does a bare `*` in a parameter list do?
15. What is a closure? Where is there one in `run_open_loop`?
16. Predict: `percentile(values, 50)` changes the caller's list if the code uses `values.sort()`. Why?
17. What does `match (request.method, request.url.path):` match against?

## C. Testing

18. How does pytest find tests? What does a plain `assert` show when it fails?
19. Write a parametrised test with three cases.
20. What is a fixture? What do `tmp_path` and `capsys` provide? What happens after a fixture's `yield`?
21. Why use `pytest.approx` for floating-point numbers?
22. How does `httpx.MockTransport` let you test the client without a server?
23. Why might a copied project folder run the *old* code in its tests?

## D. Measurement

24. Define p50, p95 and p99. Compute the nearest-rank p95 of the numbers 1 to 20.
25. Why does the mean mislead for latency? Give a numeric example.
26. Why are p95 and p99 meaningless with five samples?
27. Why exclude errors from latency percentiles? Where do they go instead?
28. Why save raw results and a settings file, rather than a summary?

## E. Async and load

29. What is the GIL, and why does this tool use asyncio rather than threads?
30. What happens at an `await`? What runs in the meantime?
31. What do `asyncio.gather` and `asyncio.Semaphore` do here?
32. Closed loop vs open loop: describe each in one sentence.
33. Define coordinated omission. Draw what happens during a 1-second stall in each kind of loop.
34. Predict: open-loop p95 during a 0.5 s stall at 50 requests per second, then closed-loop p95. Roughly what values?
35. Measuring from send time inside the open loop: when does it hide the stall, and when doesn't it? Why does that make the bug dangerous?
36. Why does `cmd_load` set `max_keepalive_connections`?

## F. Experiments

37. Describe the freeze experiment. What tool froze the server, and what does that simulate?
38. Quote the open- and closed-loop results for the same freeze. Which would you believe, and why?
39. Why does latency stay high after the server resumes?
40. How did you discover the generator was the bottleneck? List three ways to fix it.
41. State the "7-second tail" observation, the hypothesis, and how you'll test it in Phase 2.
