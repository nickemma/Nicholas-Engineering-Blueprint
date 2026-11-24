# ML design fundamentals

The concepts that come up in almost every ML design interview. Each section says what the idea is, the numbers worth knowing, how it goes wrong, and which designs in this track use it. Read a section when a design needs it. The [ML template](../_template-ml.md) asks about all of them.

| # | Topic | Decision to practise |
|---|---|---|
| 1 | [Offline metrics](#1-offline-metrics) | Which number, computed before launch, would move with the business goal? |
| 2 | [Online metrics and guardrails](#2-online-metrics-and-guardrails) | What decides the launch, and what stops it? |
| 3 | [Labels](#3-labels) | Where do positives and negatives come from, and how is each biased? |
| 4 | [Splits, leakage and imbalance](#4-splits-leakage-and-imbalance) | Does the evaluation see only what the model would have known? |
| 5 | [Candidate generation and ranking](#5-candidate-generation-and-ranking) | How do you get from millions of items to ten, within the latency budget? |
| 6 | [Approximate nearest neighbours](#6-approximate-nearest-neighbours) | How much recall do you give up for speed and memory? |
| 7 | [Getting a model to users](#7-getting-a-model-to-users) | Shadow, canary, A/B test or bandit: what does each one prove? |
| 8 | [Drift and feedback loops](#8-drift-and-feedback-loops) | What changed, how would you notice, and what do you do? |
| 9 | [Making a model smaller](#9-making-a-model-smaller) | What does a phone-sized model cost in quality? |

## 1. Offline metrics

**Classification.** A model outputs a score, and a threshold turns it into a decision.

- **Precision:** of the items you flagged, the share that were right. **Recall:** of the items you should have flagged, the share you caught. Raising the threshold usually trades recall for precision.
- **ROC-AUC** measures how well the scores separate positives from negatives at every threshold. A random model scores 0.5.
- **PR-AUC** (the area under the precision-recall curve) is the honest choice when positives are rare. A random model's PR-AUC equals the positive rate: with 0.1% fraud, that's 0.001, while its ROC-AUC is still 0.5. ROC-AUC can look excellent on a model that's useless at the precision you need.
- **Log loss and calibration.** When the score is used as a probability (to set a price, or to combine with other scores), it must *be* one. Check it with a reliability plot: of the items scored about 0.2, about 20% should be positive. A model can rank perfectly and still be badly calibrated.
- **Accuracy** is rarely the right metric. "Never fraud" is 99.9% accurate.

**Ranking and retrieval.** The output is an ordered list, and the top matters most. Suppose a query has 2 relevant documents, and your top 5 results put them at positions 2 and 4:

| Metric | What it asks | This example |
|---|---|---|
| **Precision@5** | What share of the top 5 is relevant? | 2/5 = 0.4 |
| **Recall@5** | What share of all relevant items is in the top 5? | 2/2 = 1.0 |
| **Reciprocal rank** | 1 ÷ the position of the first relevant result. **MRR** averages it over queries | 1/2 = 0.5 |
| **nDCG@5** | Relevant items count for less the lower they are (divided by log₂(position + 1)), compared with the best possible order | (1/log₂3 + 1/log₂5) ÷ (1 + 1/log₂3) = 1.06 ÷ 1.63 ≈ 0.65 |

Precision@k and recall@k ignore order within the top k. MRR only cares about the first hit, which suits a search box where the user wants one answer. nDCG uses the whole order and accepts graded relevance (perfect, good, fair), which suits feeds and result pages.

**How it fails:** choosing a metric because it's standard rather than because it tracks the goal. Say why the offline metric should move with the online one, and how you'll check that it does.

**Used in:** [fraud detection](fraud-detection.md) (PR-AUC, money caught at a fixed review volume), [recommendations](recommendation.md) (recall@k for candidates, nDCG for ranking), [search ranking](search-ranking.md) (nDCG, MRR), [harmful content](harmful-content.md) (precision at the auto-remove threshold).

## 2. Online metrics and guardrails

Offline metrics predict; online metrics decide. Pick **one** primary metric tied to the business goal: purchases per user, sessions with a successful search, losses to fraud. Then add **guardrails**, metrics that must not get worse even if the primary improves:

- **Counter-metrics:** hides, reports, unfollows, complaints, returns.
- **System metrics:** latency, error rate, cost per request.
- **Fairness slices:** the primary metric by country, language and new versus old users.

Click-through rate is easy to move and easy to game. A clickbait ranker raises it and lowers satisfaction. If the goal is long-term (retention, trust), say how you'll measure it: a long-running holdout group, or a slower metric confirmed weeks later.

**Used in:** every design. [Search ranking](search-ranking.md) uses abandonment and reformulated queries as guardrails; [recommendations](recommendation.md) uses diversity and returns.

## 3. Labels

**Natural labels** come from what users do: a click, a purchase, a report, a chargeback. They're cheap and plentiful, and biased by what the system chose to show.

- **Missing negatives.** Not clicking isn't disliking: the user may never have seen the item. **Negative sampling** builds negatives on purpose:
  - random items from the catalogue (easy negatives, which teach little once the model is decent);
  - other users' positives in the same training batch (*in-batch* negatives, cheap and common for two-tower models);
  - items that were shown and skipped, or that score high but are wrong (*hard* negatives, which teach the most and are noisiest).
- **Position bias.** People click the top result because it's on top. Clicks at position 1 overstate relevance; a missing click at position 9 says almost nothing. Correct for it (weight clicks by how likely each position is to be seen), or collect unbiased data by occasionally shuffling results.
- **Delayed labels.** A chargeback arrives 30–90 days later; a purchase may follow a click by days. Until it arrives, the label is unknown, not negative.
- **Selection bias.** You only see outcomes for what you allowed. Declined payments never get a chargeback. A small random holdout, or exploration, gives you labels for the rest.

**Human labels** are slow, costly and sometimes unavoidable (policy violations, relevance judgements). Measure how often labellers agree with each other; if they agree 80% of the time, no model will reliably beat 80% on that data. Give them written guidelines with examples, and review the disagreements.

**When labels are scarce:**
- **Weak supervision:** rules, keyword lists and other models label data automatically. It's noisy but cheap and quick to change.
- **Transfer learning:** start from a model pretrained on large general data, then fine-tune on your few labels, or use it zero-shot.
- **Active learning:** send humans the examples the model is least sure about, so each label teaches the most.

**Used in:** [fraud detection](fraud-detection.md) (delayed labels, selection bias), [recommendations](recommendation.md) (in-batch and hard negatives), [search ranking](search-ranking.md) (position bias), [harmful content](harmful-content.md) (human labels, agreement, active learning).

## 4. Splits, leakage and imbalance

**Split by time** when the data has time in it. Train on the past, validate on the next period, and test once on the period after. A random split lets the model learn from the future: next week's trend leaks into last week's evaluation. For users, also check whether the same user appears in both training and test data, and whether that matches how the model will be used.

**Leakage** makes offline results look better than the model will be. The common kinds:
- a feature computed with information from after the prediction time ("payments in the next hour");
- a feature that is the label in disguise (a "disputed" flag in a fraud model);
- scaling, fill-in values or vocabularies computed on all the data instead of the training split;
- near-duplicates (the same document, the same session) on both sides of the split.

A result that looks too good is a leak until proven otherwise.

**Class imbalance.** When positives are rare:
- downsample the majority class, or weight the positive class in the loss;
- then **recalibrate**, because the model now believes positives are more common than they are;
- evaluate with PR-AUC or precision at a fixed recall, not accuracy.

**Sampling** decides what the model learns. Stratify so that rare slices (a small country, a new product line) appear in the training and test data at all. Reservoir sampling keeps a fixed-size uniform sample from a stream you can't store.

**Built in:** [ML for infrastructure, lesson 03](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/lessons/03-split-by-time-and-plan-the-comparison.md): a time split that keeps late labels out of training.

**Used in:** [fraud detection](fraud-detection.md), [harmful content](harmful-content.md).

## 5. Candidate generation and ranking

You can't run an expensive model over 10 million items in 200 ms. So most retrieval and recommendation systems are a **funnel**:

~~~text
10,000,000 items ─ candidate generation (cheap, recall matters) ─▶ ~1,000
         ~1,000 ─ ranking (expensive, precision matters)       ─▶ ~100
           ~100 ─ re-ranking and rules (diversity, policy)      ─▶ 10 shown
~~~

**Candidate generation** must not miss good items; it doesn't need to order them well. Sources, usually several merged:
- **Collaborative filtering:** "people who liked this also liked". Matrix factorisation learns a vector per user and per item, so that their dot product predicts interaction.
- **Two-tower models:** one network turns the user (and context) into a vector, another turns each item into a vector, trained so that matching pairs score high. Item vectors are computed ahead of time and searched with [approximate nearest neighbours](#6-approximate-nearest-neighbours); only the user tower runs per request.
- **Content-based:** items similar in text or image embeddings to what the user engaged with. This handles new items with no interactions (**cold start**).
- **Heuristics:** popular, trending, recently viewed. They're the baseline, and the fallback.

**Ranking** scores each candidate with a richer model and features that are too costly for millions of items: user-item history, cross features, real-time context. **Learning to rank** has three styles:
- **Pointwise:** predict a score for each item on its own (probability of a click). The simplest, and often good enough.
- **Pairwise:** learn which of two items should rank higher.
- **Listwise:** optimise the whole list's order (nDCG) directly.

**How it fails:** a ranker that's excellent on candidates the generator never returns. Measure recall@k of candidate generation on its own.

**Used in:** [recommendations](recommendation.md), [search ranking](search-ranking.md), [the support assistant](rag-support-assistant.md) (retrieve, then re-rank, then generate).

## 6. Approximate nearest neighbours

Exact nearest-neighbour search compares the query with every vector. With 10 million items of 256 float32 numbers, that's 10 GB to read for every query, around a second at 10 GB/s of memory bandwidth. Approximate methods return *most* of the true nearest neighbours in milliseconds.

| Method | Idea | Trade-off |
|---|---|---|
| **HNSW** (graph) | A layered graph of near neighbours; greedy search from a coarse layer down | Fast, high recall; memory-hungry; slow to build; deletes are awkward |
| **IVF** (clustering) | Cluster the vectors; search only the few clusters nearest the query | Less memory; recall depends on how many clusters you probe |
| **Product quantisation** | Compress each vector into a few bytes: 1,024 bytes down to 32 | Fits billions of vectors in memory; distances become approximate. Often combined with IVF |
| **LSH** (hashing) | Hash so that similar vectors collide | Simple; usually beaten by the above on real data |

**The number to report is recall@k against exact search**, at a stated latency. "95% of the true top 10, at p99 under 5 ms" is a design decision; "we use HNSW" isn't.

**Filters** are the hard part in practice. If the user may only see some documents, filtering *after* the search can leave you with nothing; filtering *before* it can make the index useless. Say which you'd do and why.

**Built in:** [Securing the AI layer, lesson 03](../../3-tracks/ai-infrastructure/04-securing-the-ai-layer/lessons/03-retrieval-over-the-tenants-runbooks-and-jobs.md): pgvector, tenant-scoped retrieval, hit@k and MRR measured.

**Used in:** [recommendations](recommendation.md), [the support assistant](rag-support-assistant.md).

## 7. Getting a model to users

Each step proves something different. Most launches use several in order.

| Step | What happens | What it proves |
|---|---|---|
| **Shadow** | The new model scores live traffic; its output is logged, not used | It runs at production load and latency, and its outputs look sane next to the old model's |
| **Canary** | A small share of traffic (1–5%) is served by the new model | Nothing breaks for real users: errors, latency, obvious metric drops |
| **A/B test** | Users are randomly split between old and new, for long enough to measure the primary metric | The new model *causes* a change in the metric |
| **Interleaving** | Results from both rankers are mixed in one list; whichever gets more clicks wins | Which ranker users prefer, with 10–100× less traffic than an A/B test. It doesn't measure business metrics |
| **Bandit** | Traffic shifts automatically towards whichever option is doing better | Least regret while learning. Suits many short-lived options (headlines, new ads), not one big launch decision |

**A/B test numbers.** To detect a change of size δ in a metric with variance σ², you need about **16σ²/δ² users per group** (5% significance, 80% power). At a 2% click rate, a 1% relative lift (0.02 → 0.0202) needs 16 × 0.0196 ÷ 0.0002² ≈ **7.8 million users per group**. Small lifts on rare events need a lot of traffic, so say how long the test will run.

**How it fails:**
- **Peeking:** stopping the test the first day it looks significant inflates false positives.
- **Novelty effects:** users click new things because they're new. Run for at least a full week.
- **Interference:** in a marketplace or social network, the groups affect each other (both bid on the same items, share the same posts). Split by region or cluster instead of user.

**Built in:** [Kubernetes and delivery, lesson 05](../../3-tracks/shared-units/kubernetes-and-delivery/lessons/05-roll-out-a-canary-with-helm.md) (a canary with Helm); [ML for infrastructure, lesson 09](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/lessons/09-run-the-lifecycle-gate.md) (a gate that refuses a weaker model).

**Used in:** every design. [Search ranking](search-ranking.md) uses interleaving.

## 8. Drift and feedback loops

The world changes after training. Three kinds of change:

| Shift | What changes | Example |
|---|---|---|
| **Covariate (input) shift** | The inputs' distribution; the input-to-label relationship stays | A marketing campaign brings in younger users |
| **Label (prior) shift** | How common each label is | Fraud doubles during a holiday sale |
| **Concept drift** | The relationship itself | Spammers change their wording after being blocked; "relevant" for a query changes with the news |

**Detecting it:**
- **Inputs:** compare each feature's live distribution with training. Common measures are the population stability index (PSI; above 0.25 usually means a real shift), the Kolmogorov–Smirnov test, and simpler checks such as the mean shift in training standard deviations and the share of values outside the training range.
- **Outputs:** the distribution of scores and the share of positive decisions. A sudden jump is more often a broken feature pipeline than a real change in the world.
- **Performance:** the real test, but it waits for labels. Use fast proxies (review outcomes, user reports) until the slow labels arrive.

**Responding:** first check the pipeline. Then recalibrate (label shift), retrain on recent data (covariate shift, concept drift), or roll back. Retrain on a schedule as well, and make every retrained model pass the same gate as the first.

**Feedback loops.** The model's decisions shape its next training data: a recommender only learns about what it showed; a fraud model never sees outcomes for what it declined; a moderation model's removals stop users seeing (and reporting) similar posts. Break the loop with exploration, holdouts, and logging what was shown, not only what was clicked.

**Built in:** [ML for infrastructure, lesson 07](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/lessons/07-test-scheduling-utility-and-input-drift.md): an input-drift check against the training window.

**Used in:** [fraud detection](fraud-detection.md), [harmful content](harmful-content.md) (adversaries), [recommendations](recommendation.md) (feedback loops).

## 9. Making a model smaller

On a phone, camera or browser, the model must fit the memory, compute and battery budget, and it works offline and keeps data on the device. In a data centre, a smaller model is cheaper and faster per request.

| Technique | What it does | Typical cost |
|---|---|---|
| **Quantisation** | Store weights (and sometimes activations) in 8 or 4 bits instead of 32 | 4–8× smaller; a small quality loss at 8 bits, more at 4. Measure it |
| **Pruning** | Remove weights or whole channels that contribute little | Smaller; speed-ups need structured pruning (whole channels) that the hardware can skip |
| **Distillation** | Train a small "student" to copy a large "teacher's" outputs | Often keeps most of the quality at a fraction of the size; costs a training run |
| **Factorisation** | Replace a large weight matrix with the product of two thin ones | Fewer parameters and multiply-adds; some quality loss |

Always state the quality cost on your offline metric, measured, next to the size and latency gain.

**Built in:** [Serving and scaling models, lesson 08](../../3-tracks/ai-infrastructure/02-serving-and-scaling-models/lessons/08-benchmark-performance-cost-and-quality-together.md): Q4 and Q8 weights compared on throughput, cost and a frozen quality set, with the pass mark fixed before the run.

**Used in:** [harmful content](harmful-content.md) (a small on-device model that warns users before they post), [the support assistant](rag-support-assistant.md) (a smaller model for easy questions).
