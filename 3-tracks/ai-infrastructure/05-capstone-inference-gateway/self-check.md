# Inference gateway capstone · Self-check

1. Which chat requests does the compatibility profile accept? Where is output usage still validated when a caller suppresses the usage frame?
2. Why does the benchmark wait for first content? What starts and ends the interval in its TPOT calculation?
3. What happens to throughput and error accounting when text and usage arrive before a missing terminal marker?
4. Which work did the typed decoder remove? What input still needs serialization before downstream framing?
5. Why do both variants use an identical model, prompt, admission policy, and warmed block order?
6. Why can an isolated parser win coexist with a similar whole-request throughput?
7. How do upstream-body ownership and the connection lifetime affect what happens to the generation permit on cancellation?
8. Which parts of the source package would you inspect before allowing traffic across hosts?

## From memory

Write a small table of expected outcomes for success, a rate-limit response, idle timeout after headers, and client disconnect. Mark which of those can contribute to completed-token throughput. Compare it with the gate output and raw samples.
