# ML design: <name>

**Track:** <ml-system-design | ai-infrastructure> · **Built in:** <lesson phase or repository link> · **Time spent:** <minutes>

## 0. The crux

Write this first. What makes this ML problem hard? For example: label scarcity, delayed feedback, a strict latency budget, cold start, adversaries, feedback loops, or the cost of serving.

The [ML design fundamentals](ml-system-design/fundamentals.md) cover the concepts these sections ask about: metrics, labels, splits, retrieval, rollout and drift.

## 1. Framing

| Question | Answer |
|---|---|
| Business goal | |
| ML objective (what the model predicts) | |
| Model input and output, and the task type (binary classification, ranking, regression, generation) | |
| Why ML at all? What simple rule or baseline would we beat? | |
| What ML costs here: collecting and labelling data, compute, and keeping the model fresh. Is the gain over the baseline worth it? | |
| Online success metric | |
| Offline metric, and why it should track the online one | |
| Constraints: latency, throughput, cost, privacy, fairness | |

## 2. Data and labels

Sources, label delay, leakage risks, and the privacy boundary. Then:

- **Labelling strategy.** Natural labels from user actions (clicks, purchases, reports), human annotation, or weak labels from rules and other models. Where do negatives come from? Not clicking isn't the same as not liking. Which labels are biased by what the current system chose to show?
- **Sampling and class imbalance.** How rare is the positive class? Do you downsample the majority, weight the loss, or both? If the training sample doesn't match the live distribution, recalibrate the scores.
- **Splits.** Split by time when the data has time in it. Compute scaling and fill-in statistics on the training split only.

## 3. Features

| Feature | Source | Freshness (batch or real time) | Computed where (offline, online, both) |
|---|---|---|---|
| | | | |

How does the design keep training and serving features identical?

## 4. Model

Start with a baseline (heuristic or simple model), then the main model, and justify the jump. Say what you'd try next.

## 5. Evaluation

**Offline:** the split strategy (time-based?), metrics, slices. **Online:** how it reaches users (shadow, canary, A/B test, or a bandit), the metric that decides, and the guardrail metrics that stop it.

## 6. Serving

Batch vs online, the latency budget broken down by stage, caching, candidate generation then ranking (if relevant), and the fallback when the model is down.

If the model runs on a device (a phone, a camera, a browser), say how it fits the memory, compute and battery budget: quantisation, pruning, or distilling a smaller model from a larger one, and the quality each one costs.

~~~mermaid
flowchart LR
    Request --> Features --> Model --> Postprocess --> Response
~~~

## 7. Monitoring and iteration

Data drift, prediction drift, performance by slice, retraining triggers, feedback loops, and rollback.

## 8. Risks

Privacy, fairness, abuse, and failure modes.

## 9. Where I've built this

## 10. Self-score

See [scorecard.md](scorecard.md).

| Dimension | Score (1–4) | Evidence |
|---|---|---|
| Problem navigation | | |
| Solution design | | |
| Technical excellence | | |
| Communication and collaboration | | |
