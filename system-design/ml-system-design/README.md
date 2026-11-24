# ML system design

For applied ML and ML engineering roles. These designs follow a different shape from the others: spend the first 10 minutes on **framing**:
- the business goal against the ML objective;
- metrics offline and online;
- data and labels.

Then features, model, evaluation, serving and monitoring. Use the [ML template](../_template-ml.md), and look concepts up in the [ML design fundamentals](fundamentals.md): metrics, labels, splits and leakage, candidate generation and ranking, approximate nearest neighbours, rollout, drift, and making models smaller.

**Worked designs.** Do each one yourself first, with a 45-minute timer, then read it and note what you missed.

| Design | The crux |
|---|---|
| [Payment fraud detection](fraud-detection.md) | Labels arrive weeks late and are rare; the model sits in the payment's critical path |
| [Product recommendations](recommendation.md) | Ten million products in 200 ms: candidate generation, then ranking; purchases, not clicks |
| [Search ranking](search-ranking.md) | Click labels biased by position; an index that changes every minute |
| [Harmful content detection](harmful-content.md) | Lopsided costs, and human review capacity sets the thresholds |
| [A support assistant that answers from documentation](rag-support-assistant.md) | No label says a generated answer is right, so evaluation is the design |

**How to use the prompts below:**
1. Set a 45-minute timer and design with the ML template.
2. Open **the crux** only if you haven't named one by minute 10.
3. Open **what a strong answer covers** only after the timer, then score yourself with the [scorecard](../scorecard.md).

## 1. Ads click-through prediction

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

## 2. Feed ranking

Order the posts in a social feed: 300 million users, a few thousand candidate posts each, under 300 ms, optimise for long-term satisfaction rather than raw engagement.

<details><summary>The crux</summary>Multiple objectives (likes, comments, time spent, hides, long-term retention) combined into one score, and the risk that optimising short-term engagement harms the long-term goal.</details>

<details><summary>What a strong answer covers</summary>

- Candidate sources (from the classic news-feed design), then ranking.
- Multi-task models predicting several actions; a value model combining them.
- Negative signals (hide, unfollow) weighted heavily.
- Long-term metrics in A/B tests run for weeks; holdouts.
- Integrity and diversity constraints applied after ranking.
</details>

## 3. Search suggestions as you type

Suggest completions in a search box after each keystroke: 20,000 keystrokes a second at peak, suggestions within 50 ms, in 10 languages, and never suggest anything offensive or defamatory.

<details><summary>The crux</summary>A 50 ms budget per keystroke leaves no room for a large model on the critical path. So the candidates come from a precomputed structure (a prefix tree of past queries, with counts), and only a light ranker runs per keystroke. And because suggestions put words in front of users who didn't type them, filtering what may be suggested matters as much as ranking.</details>

<details><summary>What a strong answer covers</summary>

- Candidates from a prefix tree of popular past queries, built in batch, plus a fresh layer for trending queries.
- A light ranker: popularity, freshness, the user's own history, location.
- Offline: how many keystrokes a suggestion saves; MRR of the query the user finally submitted. Online: suggestion acceptance, time to submit.
- Filtering: blocklists, a classifier for offensive completions, a fast takedown path for a harmful suggestion.
- Caching by prefix; how short prefixes (one or two letters) differ from long ones.
- Bias in suggestions about people and groups.
</details>

## 4. Delivery time estimates

Show an estimated delivery time on every restaurant card in a food-delivery app, and again at checkout: 200,000 estimates a second at peak, under 50 ms, and customers who are more upset by a late order than pleased by an early one.

<details><summary>The crux</summary>The cost of an error is lopsided, and the estimate changes behaviour. Predicting the average minimises the wrong thing: an estimate that's late half the time disappoints half the customers. Predict a high quantile instead, and accept that a longer estimate also means fewer orders.</details>

<details><summary>What a strong answer covers</summary>

- The pieces: preparation time, waiting for a courier, travel, handover. Model them separately or together, and why.
- Regression with a quantile (pinball) loss; calibration of the quantile ("late 10% of the time" must be true).
- Real-time features: kitchen load, courier supply, weather, traffic.
- Labels from completed orders; cancelled orders as missing labels.
- Online: the share of late orders and conversion, together, in an A/B test by region (customers in one area share couriers).
- Feedback: a longer estimate reduces orders, which changes kitchen load.
</details>

## 5. People you may know

Suggest connections in a professional network: 300 million members, suggestions refreshed daily and updated within minutes of a new connection, success measured by accepted invitations, not sent ones.

<details><summary>The crux</summary>The graph is too big to score every pair, so candidates come from graph structure (friends of friends, shared workplaces and schools), and the target is an *accepted* invitation, which needs both sides' interest. Suggestions also reveal things: who has viewed whom, or a contact uploaded from someone's address book.</details>

<details><summary>What a strong answer covers</summary>

- Candidate generation: friends of friends (the number of mutual connections), shared organisations, graph embeddings.
- Ranking for the probability that an invitation is sent **and** accepted.
- Batch computation for the 2-hop graph, plus an online update after a new connection.
- Offline: recall@k of connections formed next week; online: accepted invitations, and invitations ignored or reported as unwanted.
- Privacy: signals that must never explain a suggestion (contact uploads, profile views), and members who don't want to be found.
- Cold start for new members; feedback loops that favour already well-connected members.
</details>

**Built in for all of these:** [ML for infrastructure](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/README.md): time splits and leakage, baselines first, a model that must beat them, versioned promotion and rollback, input drift. The [gradient-boosted trees deep dive](../../3-tracks/ai-infrastructure/deep-dives/gradient-boosted-trees.md) compares trees honestly.
