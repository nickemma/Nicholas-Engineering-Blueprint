# ML design: payment fraud detection

**Track:** ml-system-design · **Built in:** [Phase 7](../../lessons/07-utility-evaluation/README.md) (time splits, leakage, gradient-boosted trees, serving with a fallback, drift, a shadow) · **Time:** 45 minutes

This is a worked reference. Do the design yourself first, with a timer, then read this and note what you missed.

## 0. The crux

**The labels arrive weeks late, and are rare.**
- A chargeback confirms fraud 30–90 days after the payment.
- Fraud is about 0.1% of payments.

Meanwhile, **the model sits in the payment's critical path**, with a budget of tens of milliseconds, and **the adversary adapts** to whatever it blocks. Getting features that are both fresh and identical in training and serving, and evaluating honestly with delayed labels, is where the time goes.

## 1. Framing

| Question | Answer |
|---|---|
| Business goal | Lose less money to fraud without blocking good customers |
| ML objective | The probability that a payment is fraudulent, given what's known when it's made |
| Why ML? The baseline | Hand-written rules (velocity limits, country mismatches). The model must beat them on money saved at the same review workload |
| Online metric | Fraud losses (money) plus the cost of false declines (lost good payments) |
| Offline metric | Recall of fraud money at a fixed review capacity; precision-recall AUC. Not accuracy: "never fraud" is 99.9% accurate |
| Constraints | p99 < 50 ms for the score; 2,000 payments a second at peak; explainable reasons for declines; no protected attributes as features |

Decisions come in three bands: **approve**, **send to manual review** (capacity: 5,000 cases a day), **decline**.

## 2. Data and labels

- **Sources:** the payment itself, the account's history, the device, the merchant, and past chargebacks.
- **Labels:** fraud is confirmed by chargebacks and investigations, **30–90 days late**. A payment from last week has no label yet. It isn't "not fraud"; it's **unknown**.
- **Imbalance:** about 0.1% fraud: 2 fraudulent payments a second at peak, among 2,000 good ones.
- **The feedback loop:** declined payments never get a chargeback, so the model never learns whether they were fraud. Keep a tiny random **holdout** (approve a sliver of would-be declines below a risk ceiling, or review them) to get unbiased labels.
- **Leakage risks:**
  - features computed with data from after the payment (a "transactions in the next hour" count);
  - labels that leak through features (a "disputed" flag).

## 3. Features

| Feature | Source | Freshness | Computed where |
|---|---|---|---|
| Amount, currency, merchant category | The payment | Now | Online |
| Payments from this card in the last 10 min / 1 h / 24 h | Event stream | Seconds | Streaming aggregates, served from an online store |
| Distinct cards on this device in 24 h | Event stream | Seconds | Streaming aggregates |
| Account age; past chargebacks | Database | Daily | Batch, served from the online store |
| Distance from the usual location | Payment + history | Now | Online |

**Train/serve parity is the crux of the features.** Each feature is defined **once**, as code computing it **as of** a point in time.
- Training replays history through that code, so each row sees only what was known then.
- Serving computes the same thing live.
- A parity test compares the two on recent payments.

Phase 7 found exactly this kind of leak: training used timestamps the live system only learned later, and the parity test caught it.

## 4. Model

1. **Baseline:** the existing rules, scored on the same evaluation.
2. **Main model: gradient-boosted trees** on tabular features. They're strong on this kind of data, fast to serve, and explainable per feature. Phase 7 found trees hard to beat on tabular data, and cheap networks only matching them.
3. **Class imbalance:** weight the fraud class, or downsample non-fraud for training; then **calibrate** the scores so thresholds mean something.
4. **Next:**
   - graph features, such as cards linked through shared devices;
   - a sequence model over a card's recent payments.

## 5. Evaluation

**Offline:**
- **Split by time:** train on months 1–6, validate on month 7, test once on month 8. Only evaluate on payments **old enough to have mature labels** (90 days).
- **Metric:** fraud money caught at a fixed review volume, with **bootstrap intervals**.
- **Slices:** by country, merchant type and new accounts.

**Online:**
1. **Shadow:** score live traffic without acting.
2. **Compare** with the rules on the decisions both would make.
3. **A/B test with guardrails:** false-decline rate, review queue size, customer complaints.
4. The money metric matures **months** later, so decide on leading indicators (review outcomes, which come in days) and confirm with chargebacks.

## 6. Serving

~~~mermaid
flowchart LR
    P[Payment API] -->|score request, 50 ms budget| S[Scoring service]
    S --> FS[(Online feature store)]
    S --> M[Model, in process]
    S -->|fallback if late or down| R[Rules]
    EV[Payment events] --> SA[Streaming aggregator] --> FS
    S -->|score, features, decision| LOG[(Decision log)] --> TR[Training pipeline]
~~~

**The latency budget (p99 50 ms):**
- network: 2 ms;
- feature-store lookups, in parallel: 10 ms;
- model: 2–5 ms (trees are microseconds per tree, and a few hundred trees add up);
- rules and decision: 1 ms;
- headroom: 30 ms.

**A fallback is mandatory.** If scoring misses its deadline or fails, the payment API applies the rules alone. Payments never wait for the model. That's Phase 7's breaker-and-fallback pattern.

**Log the exact features and score** used for each decision. That's the training data, the audit trail and the explanation, all at once.

## 7. Monitoring and iteration

- **Input drift:** population stability index per feature, daily.
- **Score drift:** the distribution of scores and the decline rate, hourly. A sudden jump means a broken feature more often than a fraud wave.
- **Performance:** review outcomes (days) as a leading indicator; chargebacks (months) as the truth.
- **Retraining:** on a schedule (weekly), plus on drift alerts. Each candidate must beat the champion **beyond noise**, then go through a shadow before promotion (Phase 7's gate).
- **Adversarial adaptation:** fraud rings probe the thresholds. Watch for clusters of payments just under the decline line.

## 8. Risks

- **Fairness:** declines concentrated on a region or group. Monitor decline rates by slice; use no protected attributes or close proxies.
- **The feedback loop** biases training towards past decisions. Keep the holdout.
- **Explainability:** regulators and customers ask why. Keep per-decision reason codes from feature contributions.
- **Privacy:** card and device data. Restrict access to the feature logs, and set retention.

## 9. Where you've built this

[Phase 7](../../lessons/07-utility-evaluation/README.md):
- **The data:** a time-split dataset with leakage caught; baselines first; gradient-boosted trees with bootstrap comparisons.
- **Serving:** behind the Go API with a timeout, a breaker and a fallback, and a parity test that found a real train/serve leak.
- **Operations:** MLflow and a gate beyond noise; drift metrics; a shadow deployment.

## 10. What an interviewer will push on

- "Last week's payments have no chargebacks yet. Are they negatives?"
- "Your model is down. What happens to a payment right now?"
- "How do you get labels for payments you declined?"
- "Accuracy is 99.9%. Is that good?"
