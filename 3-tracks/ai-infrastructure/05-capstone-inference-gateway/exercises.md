# Inference gateway capstone · Exercises

## Find your next operating limit

Run a new interleaved comparison with a longer output budget and enough blocks for a useful tail estimate. Declare the load points, allowed failure rate, and margin before each run. Record the model image, prompt, weight digest, release binaries, host details, and every failed response. Compare the parser replay and the end-to-end runs before choosing a release.

### Acceptance

- Both client implementations discover the same model. All accepted streams carry validated usage and a terminal marker. A truncated fixture contributes zero output goodput.
- TTFT uses first content and TPOT uses authoritative usage. Report sample counts along with quantiles, successes, and completions per measured second.
- Both builds process the same parser workload. Capture before-and-after stack profiles and the timings from an unprofiled run.
- Present a decision with separate results for parser performance and client-visible performance. Identify the workloads and concurrency levels to which your evidence applies.

## Test admission fairness under load

Offer traffic for two fixture tenants while one tenant keeps an admitted stream open. Verify the saturated response and retry delay. End that stream from the client and observe model-side closure. Compare another tenant’s success with the original tenant’s remaining allowance.
