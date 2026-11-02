# ML system design

For applied ML and ML engineering roles. These designs follow a different shape from the others: spend the first 10 minutes on **framing**:
- the business goal against the ML objective;
- metrics offline and online;
- data and labels.

Then features, model, evaluation, serving and monitoring. Use the [ML template](../_template-ml.md).

**Worked design:** [payment fraud detection](fraud-detection.md). Do it yourself first, then compare.

**How to use the prompts:**
1. Set a 45-minute timer and design with the ML template.
2. Open **the crux** only if you haven't named one by minute 10.
3. Open **what a strong answer covers** only after the timer, then score yourself with the [scorecard](../scorecard.md).

## 1. A recommendation system

Recommend products on an e-commerce home page: 50 million users, 10 million products, results in under 200 ms, and success measured by purchases, not clicks.

<details><summary>The crux</summary>Ten million candidates can't all be scored in 200 ms. So it's two stages: **candidate generation** (cheap: thousands from millions, using embeddings and approximate nearest neighbours) and **ranking** (expensive: score hundreds precisely). Plus the gap between clicks (easy to optimise) and purchases (what matters).</details>

<details><summary>What a strong answer covers</summary>

- The objective: purchases or revenue, with clicks as an auxiliary signal; guardrails for diversity.
- Candidate generation from several sources (co-purchase, embeddings, popular items), merged.
- A ranking model on rich features; a baseline of popularity.
- Cold start for new users and new products.
- Offline metrics (recall@k, NDCG), time-split evaluation; an online A/B test on purchases.
- Feature freshness: recent views matter most.
- Feedback loops: the system only learns about what it shows. Add exploration.
</details>

## 2. Search ranking

Rank results for a site's search box: 5,000 queries a second, 100 million documents, p99 under 300 ms, relevance judged by user behaviour.

<details><summary>The crux</summary>Retrieval then ranking under a latency budget, and labels that come from clicks, which are biased by position (people click the top result because it's on top).</details>

<details><summary>What a strong answer covers</summary>

- Retrieval: an inverted index (keyword) plus vectors, fused.
- Ranking: learning to rank with features about the query, the document and the pair.
- **Position bias** in click labels; corrections or randomised interleaving experiments.
- Offline: NDCG on judged queries; online: interleaving or A/B tests, abandonment.
- A latency budget broken down by stage; caching popular queries.
</details>

## 3. Ads click-through prediction

Predict the probability of a click for each ad candidate: 1 million predictions a second, under 10 ms, calibrated probabilities (they set prices).

<details><summary>The crux</summary>Calibration and scale: the predicted probability multiplies the bid, so a model that ranks well but is miscalibrated loses money. And it must serve at a million predictions a second on sparse, high-cardinality features.</details>

<details><summary>What a strong answer covers</summary>

- Log loss and calibration plots, not just AUC.
- Sparse features (IDs) via hashing or embeddings; feature crosses.
- Online learning or frequent retraining as ads and users change.
- Delayed and missing labels (a click within a window).
- Serving: an in-memory model, batching, a CPU budget per prediction.
- Exploration for new ads.
</details>

## 4. Content moderation

Detect policy-breaking posts (text and images): 10 million posts a day, most decisions automatic, borderline ones to a human queue with limited capacity, and appeals.

<details><summary>The crux</summary>Asymmetric costs and limited human capacity: automate only what's very confident in either direction, route the uncertain middle to humans, and keep the thresholds tied to how much review capacity exists.</details>

<details><summary>What a strong answer covers</summary>

- Per-policy models; precision at the auto-remove threshold, recall overall.
- Three bands: allow, remove, human review, with thresholds set by capacity.
- Human labels as training data (and their disagreement).
- Adversarial adaptation; new kinds of violation; drift.
- Fairness across languages and groups; appeals as a feedback signal.
</details>

## 5. Feed ranking

Order the posts in a social feed: 300 million users, a few thousand candidate posts each, under 300 ms, optimise for long-term satisfaction rather than raw engagement.

<details><summary>The crux</summary>Multiple objectives (likes, comments, time spent, hides, long-term retention) combined into one score, and the risk that optimising short-term engagement harms the long-term goal.</details>

<details><summary>What a strong answer covers</summary>

- Candidate sources (from the classic news-feed design), then ranking.
- Multi-task models predicting several actions; a value model combining them.
- Negative signals (hide, unfollow) weighted heavily.
- Long-term metrics in A/B tests run for weeks; holdouts.
- Integrity and diversity constraints applied after ranking.
</details>

**Built in for all of these:** [Phase 7](../../lessons/07-utility-evaluation/README.md): time splits and leakage, baselines first, gradient-boosted trees and neural networks compared honestly, serving with a fallback, drift and shadows.
