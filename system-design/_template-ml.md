# ML design: <name>

**Track:** <ml-system-design | ai-infrastructure> · **Built in:** <lesson phase or repository link> · **Time spent:** <minutes>

## 0. The crux

Write this first. What makes this ML problem hard? For example: label scarcity, delayed feedback, a strict latency budget, cold start, adversaries, feedback loops, or the cost of serving.

## 1. Framing

| Question | Answer |
|---|---|
| Business goal | |
| ML objective (what the model predicts) | |
| Why ML at all? What simple rule or baseline would we beat? | |
| Online success metric | |
| Offline metric, and why it should track the online one | |
| Constraints: latency, throughput, cost, privacy, fairness | |

## 2. Data and labels

Sources, how labels are obtained, label delay, class imbalance, leakage risks, and the privacy boundary.

## 3. Features

| Feature | Source | Freshness (batch or real time) | Computed where (offline, online, both) |
|---|---|---|---|
| | | | |

How does the design keep training and serving features identical?

## 4. Model

Start with a baseline (heuristic or simple model), then the main model, and justify the jump. Say what you'd try next.

## 5. Evaluation

**Offline:** the split strategy (time-based?), metrics, slices. **Online:** an A/B test, guardrail metrics, a shadow deployment.

## 6. Serving

Batch vs online, the latency budget broken down by stage, caching, candidate generation then ranking (if relevant), and the fallback when the model is down.

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
