# ML design: product recommendations

**Track:** ml-system-design · **Built in:** [ML for infrastructure](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/README.md) (time splits, a baseline to beat, versioned promotion), [Securing the AI layer, lesson 03](../../3-tracks/ai-infrastructure/04-securing-the-ai-layer/lessons/03-retrieval-over-the-tenants-runbooks-and-jobs.md) (embeddings and nearest-neighbour search with pgvector, recall measured) · **Time:** 45 minutes

This is a worked reference. Do the design yourself first, with a timer, then read this and note what you missed.

**The prompt:** recommend products on an e-commerce home page. 50 million users, 10 million products, results in under 200 ms, and success measured by purchases, not clicks.

## 0. The crux

**Ten million products can't all be scored in 200 ms.** So the design is a funnel: a cheap stage that finds about a thousand plausible products, and an expensive stage that orders them well. Each stage has its own model, metric and failure mode.

Two more things make it hard:
- **Clicks are easy to optimise and aren't the goal.** Purchases are, and they're rarer and arrive later.
- **The system only learns about what it shows.** Without deliberate exploration, it keeps recommending what it recommended yesterday, and new products never get a chance.

## 1. Framing

| Question | Answer |
|---|---|
| Business goal | More purchases (and revenue) from the home page, without making the catalogue feel narrow |
| ML objective | For a user and a product, the probability of a purchase within 7 days of seeing it on the home page. Ranking uses that, plus a click model as a denser auxiliary signal |
| Input and output, task type | In: the user, their recent activity, the context (time, device, country). Out: an ordered list of 20 products. Retrieval plus pointwise ranking |
| Why ML? The baseline | "Best sellers in your country" plus "recently viewed". The model must beat it on purchases per home-page visit |
| What ML costs here | Logging every impression, two models and an embedding index to train and refresh, and a feature pipeline. Worth it: a few percent more purchases on the busiest page of the site pays for this many times over |
| Online metric | Purchases per home-page visit. Guardrails: returns, catalogue coverage (the share of products ever shown), latency |
| Offline metric | Candidate generation: recall@1000 of next-day purchases. Ranking: nDCG@20 with purchases weighted above clicks |
| Constraints | p99 under 200 ms; 3,500 home-page loads a second at peak; no sensitive categories inferred and shown (health, for example) |

**Estimates.** 20 million daily users × 5 home-page loads ≈ 100 million a day ≈ 1,200 a second on average, about 3,500 at peak. Product embeddings: 10 million × 128 numbers × 4 bytes ≈ 5 GB, which fits in one machine's memory, so the index is replicated rather than sharded.

## 2. Data and labels

- **Sources:** impressions (what was shown, where, when), clicks, add-to-cart, purchases, searches, the product catalogue (text, images, category, price), and user profiles.
- **Log impressions, not only clicks.** Without them, there are no negatives and no way to correct for position.
- **Labels:** a purchase within 7 days of an impression is a positive. A click is a weaker positive for the auxiliary model. An impression with no click is a weak negative: the user saw it and passed. A product never shown is **unknown**, not negative.
- **Delay:** purchase labels mature after 7 days, so the newest week is used for click training only.
- **Negatives for candidate generation:** other users' positives in the same training batch (cheap), plus products that were shown and skipped (hard negatives).
- **Position bias:** products in the first row are clicked more because they're first. Include the position as a feature in training, and set it to the same value at serving time.
- **Leakage:** features must be computed as of the impression's time. "Viewed this product today" computed at the end of the day includes the view that led to the purchase.

## 3. Features

| Feature | Source | Freshness | Computed where |
|---|---|---|---|
| Last 50 products viewed, carted or bought | Event stream | Seconds | Streaming, served from an online store |
| User embedding (from the user tower) | Two-tower model | Per request | Online |
| Long-term category and price preferences | Order history | Daily | Batch, online store |
| Product embedding (text and image) | Catalogue | When the product changes | Batch |
| Product popularity, conversion rate, stock | Events, inventory | Minutes | Streaming |
| User × product: has viewed it, bought from its category, price relative to usual spend | Both | Per request | Online |
| Context: time of day, device, country | The request | Now | Online |

As in [fraud detection](fraud-detection.md), each feature is defined once as code computed *as of* a time, so training and serving agree.

## 4. Model

**Candidate generation** merges several sources, about 1,000 products in total:
1. **Two-tower retrieval** (about 500): a user tower turns recent activity and context into a vector; product vectors are computed ahead of time and searched with an HNSW index.
2. **Co-purchase** (about 200): products often bought with the user's recent ones, from a precomputed table.
3. **Popular and trending** in the user's country (about 200): the baseline, the cold-start answer, and the fallback.
4. **Exploration** (about 100): new or rarely shown products, so they collect data.

**Ranking:**
1. **Baseline:** order the candidates by popularity.
2. **Main model:** gradient-boosted trees with two outputs (click, purchase), or a small multi-task network once there's enough data. The final score is P(purchase), with P(click) as a tie-breaker. Including price or margin is a business decision: say who makes it.
3. **Re-ranking:** at most 3 products from one category in the top 10; remove out-of-stock products; keep one slot for exploration.

**Cold start:**
- **New users:** popular in their country and context; after a few clicks, the user tower picks up the session.
- **New products:** the content embedding places them near similar products from day one; the exploration slot gets them impressions.

**Next:** a sequence model over the user's session; a listwise ranker.

## 5. Evaluation

**Offline:**
- **Split by time:** train on weeks 1–8, validate on week 9, test once on week 10.
- **Candidate generation:** recall@1000 of products purchased the next day. If it misses, the ranker never gets a chance.
- **Ranking:** nDCG@20 on logged impressions, with purchases weighted above clicks.
- **Slices:** new users, new products, small countries.
- **The limit of offline evaluation:** logs only contain products the old system showed. A new model that would show different products can't be scored fairly on them. That's why the online test decides.

**Online:**
1. **Shadow:** compute recommendations for live traffic, log them, show nothing. Check latency, and how different they are from the current ones.
2. **A/B test** on purchases per visit, for two weeks (novelty effects, weekly cycles). With a few percent of visits ending in a purchase, a 1% relative lift needs millions of users per group: say so.
3. **Guardrails:** returns, catalogue coverage, latency, complaints.
4. **Long-term holdout:** 1% of users stay on the old system for a quarter, to catch slow effects such as a narrowing catalogue.

## 6. Serving

~~~mermaid
flowchart LR
    U[Home page] --> API[Recommendation service]
    API --> OS[(Online feature store)]
    API --> UT[User tower]
    UT --> ANN[(HNSW index of product vectors)]
    API --> CP[(Co-purchase table)]
    API --> POP[(Popular by country)]
    API --> R[Ranker]
    R --> RR[Re-rank and rules]
    RR --> U
    API -->|impressions, features, scores| LOG[(Impression log)] --> TR[Training pipelines]
    CAT[Catalogue] --> PT[Product tower] --> ANN
~~~

**The latency budget (p99 200 ms):**
- network and gateway: 10 ms;
- user features and the user tower: 15 ms;
- candidate sources, in parallel: 20 ms;
- merge and deduplicate: 5 ms;
- features for 1,000 candidates, batched: 25 ms;
- ranking 1,000 candidates: 30 ms;
- re-ranking and rules: 5 ms;
- headroom: 110 ms.

**Fallback:** if ranking misses its deadline, return the popular list for the user's country, which is cached. The page never waits for the model.

**Batch or online?** Precomputing every user's list nightly is cheaper, but misses what the user did a minute ago, and recent activity is the strongest signal. So the funnel runs online, while the product vectors, co-purchase table and popular lists are built in batch.

## 7. Monitoring and iteration

- **Inputs:** feature distributions against training; missing features (a broken stream shows up as zeros).
- **Outputs:** score distribution; catalogue coverage; how concentrated impressions are on the top 1% of products.
- **Performance:** click rate daily, purchases weekly, by slice.
- **Retraining:** the ranker daily, the towers weekly, the index rebuilt when product vectors change. Each new model goes through a shadow and must beat the current one offline beyond noise.
- **The feedback loop:** watch coverage. If it falls, the system is recommending its own past recommendations. Increase exploration.

## 8. Risks

- **Narrowing:** popular products get more popular. Exploration and diversity rules push back.
- **Sensitive inferences:** recommending pregnancy or health products reveals something about the user to anyone looking at the screen. Keep a list of sensitive categories that are never recommended from inferred interest.
- **Manipulation:** sellers faking views or purchases to get recommended. Count only verified purchases, and watch for bursts.
- **Privacy:** viewing history is personal. Set retention, and let users clear it.

## 9. Where you've built this

- [Securing the AI layer, lesson 03](../../3-tracks/ai-infrastructure/04-securing-the-ai-layer/lessons/03-retrieval-over-the-tenants-runbooks-and-jobs.md): text embeddings, nearest-neighbour search in pgvector, and retrieval quality measured with hit@k and MRR. Candidate generation is the same idea with user and product vectors.
- [ML for infrastructure](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/README.md): a time split, a baseline the model must beat, and versioned promotion with rollback.
- [Caching](../../3-tracks/shared-units/caching/README.md): the cached popular list that serves as the fallback.

## 10. What an interviewer will push on

- "Why not score all 10 million products with the ranker?"
- "A product launched this morning. How does anyone see it?"
- "Your offline nDCG went up and purchases went down. What happened?"
- "Clicks went up 5%. Ship it?"
- "How do you know a product with no click was disliked rather than unseen?"
