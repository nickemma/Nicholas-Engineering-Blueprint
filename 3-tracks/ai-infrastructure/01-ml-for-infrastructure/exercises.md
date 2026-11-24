# ML for infrastructure · Exercises

## Predict builds in a shared build farm

Build a separate pipeline that predicts build duration from inputs available when the build is admitted. Generate events for at least two worker classes and several chronological windows. Include the build size, an admission-time cache indicator, finish time, and a label measured in milliseconds.

### Acceptance

- Validate the event schema, write a curated Parquet snapshot, and count duplicate and quarantined rows. Insert a private fixture marker and demonstrate that curated rows and quarantine omit it.
- Generate a job that crosses the training cutoff. Rebuild the dataset and show that its later label is unavailable in the training fold.
- Declare the time split, MAE margin, and a per-worker guardrail before comparing models. Fit a median and a simple size baseline before training a candidate. Document every seed and the data fingerprint.
- Record separate held-out results by worker class. Promote only if your declared policy passes. Register a weaker model and show that the same policy preserves the active version.
- Serve one prediction, introduce feature drift, and roll back. Verify which artifact handled the requests before and after rollback.
- State which metrics came from the simulator and which would need observations from real jobs.

## Test the scheduling assumption

Add actual admission times and two worker slots per class to a second simulation. Compare FIFO with predicted-first ordering on identical arrivals. Report mean and tail wait, including the slowest job. Explain whether the original ready-cohort result carried over.

## Additional practice

[buildcast, build times for a shared build farm](exercise-buildcast.md)
