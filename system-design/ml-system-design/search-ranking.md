# ML design: search ranking

**Track:** ml-system-design · **Built in:** [Securing the AI layer, lesson 03](../../3-tracks/ai-infrastructure/04-securing-the-ai-layer/lessons/03-retrieval-over-the-tenants-runbooks-and-jobs.md) (embedding retrieval, hit@k and MRR), [ML for infrastructure](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/README.md) (time splits, baselines, promotion), the [sharding](../fundamentals/sharding.md) and [caching](../fundamentals/caching.md) fundamentals · **Time:** 45 minutes

This is a worked reference. Do the design yourself first, with a timer, then read this and note what you missed.

**The prompt:** rank results for a second-hand marketplace's search box. 100 million listings, 5,000 queries a second, p99 under 300 ms, relevance judged by what users do. New listings must be searchable within a minute.

## 0. The crux

**Retrieval then ranking under a latency budget, trained on labels that lie.** The labels come from clicks, and clicks are biased by position: people click the first result because it's first. Train on raw clicks and the model learns to rank whatever the old system put on top. Getting honest labels, and evaluating honestly, is where the time goes.

Two smaller constraints shape the system:
- **The index churns.** Listings appear and sell within hours, so the index must take writes continuously.
- **Queries are short and ambiguous.** "Apple" is a phone or a fruit; "bike 54" means a frame size.

## 1. Framing

| Question | Answer |
|---|---|
| Business goal | More searches that end with the buyer contacting a seller |
| ML objective | For a query and a listing, the probability that the user contacts the seller after seeing it in the results |
| Input and output, task type | In: the query, the user's location and context, the candidate listings. Out: the top 50 in order. Learning to rank |
| Why ML? The baseline | Keyword relevance (BM25), then newest first. The model must beat it on searches that end in a contact |
| What ML costs here | Impression logging, a human-judged evaluation set, a ranking model and its features. Search drives most contacts, so a small gain is worth it |
| Online metric | Searches ending in a contact. Guardrails: zero-result rate, queries reformulated straight away, abandonment, latency |
| Offline metric | nDCG@10 on a human-judged query set; MRR of the first contacted listing on logged searches, corrected for position |
| Constraints | p99 300 ms; 5,000 queries a second; listings searchable within 60 s; sold listings gone within 60 s |

**Estimates.**
- **Text index:** 100 million listings × about 2 KB of text ≈ 200 GB raw. Split into 10 shards of 10 million listings, each with 3 replicas, so each replica serves about 1,700 queries a second.
- **Vectors:** 100 million × 256 numbers × 4 bytes ≈ 100 GB. Product quantisation shrinks each vector to 32 bytes: about 3 GB in total, 300 MB a shard, which fits beside the text index.

## 2. Data and labels

- **Sources:** the query log (query, results shown with positions, clicks, contacts, time), the listings (title, description, category, price, location, photos), seller history.
- **Click labels are biased by position.** A click at position 1 overstates relevance; no click at position 9 means the user probably never looked. Two corrections:
  1. **Estimate how likely each position is to be looked at.** On 1% of traffic, randomly swap pairs of adjacent results. Any difference in clicks between the swapped and unswapped orders comes from position alone.
  2. **Weight each training click** by 1 ÷ that probability, so clicks at low positions count for more.
- **Stronger signals:** a contact beats a click; a click followed by a quick return to the results is a weak negative.
- **Human judgements:** 5,000 queries, sampled across frequent, mid and rare queries, with the top 20 results graded 0–3 by trained raters. It's the evaluation set, not the training set. Measure how often raters agree with each other.
- **Leakage:** features such as a listing's click-through rate must be computed only from data before the search.

## 3. Features

| Feature | Source | Freshness | Computed where |
|---|---|---|---|
| BM25 score of query against title and description | Text index | Now | At the shard |
| Cosine similarity of query and listing embeddings | Vector index | Now | At the shard |
| Query category (predicted) matches the listing's category | Query classifier | Per request | Online |
| Extracted attributes match: size, colour, brand | Query parser | Per request | Online |
| Distance from the buyer; price compared with similar listings | Listing, user | Now | Online |
| Listing age; photo count; description length | Listing | When it changes | Indexing |
| Listing's past contact rate, corrected for position | Query log | Hourly | Batch, feature store |
| Seller's response rate and rating | Seller history | Daily | Batch, feature store |

## 4. Model

**Query understanding**, before retrieval:
- spelling correction, from the query log ("iphnoe" → "iphone");
- a category classifier ("apple 128gb" → phones);
- attribute extraction ("54" next to "bike" → frame size).

**Retrieval**, on every shard in parallel:
1. **Keyword:** the top 500 by BM25, with filters for location and price applied inside the index.
2. **Vector:** the top 200 by embedding similarity, which finds "bicycle" for "bike" when the words differ.
3. **Fusion:** merge the two lists by reciprocal rank fusion (score each listing by the sum of 1 ÷ (60 + its rank) in each list). This needs no training and is hard to beat.

**Ranking:**
1. **Baseline:** BM25 alone.
2. **Main model:** gradient-boosted trees trained to maximise nDCG directly (LambdaMART), on position-corrected labels. It's fast on CPU, works well with mixed numeric features, and shows which features matter.
3. **Business rules after ranking:** remove sold and flagged listings; limit any one seller to 3 of the top 10.

**Next:** a cross-encoder (a model that reads the query and listing together) to re-rank the top 30 on GPUs; personalisation by the user's past searches.

## 5. Evaluation

**Offline:**
- nDCG@10 on the human-judged set, as the main gate.
- Position-corrected MRR of the contacted listing on last week's logs, split by time.
- **Slices:** frequent, mid and rare queries; queries with and without attributes; each category.

**Online:**
1. **Shadow** for latency, and to compare the result lists.
2. **Interleaving:** mix the old and new rankers' results in one list and count whose results get contacted. It detects a preference with far less traffic than an A/B test, so use it to screen candidate models.
3. **A/B test** on the winner, on searches ending in a contact, for at least a week.
4. **Guardrails:** zero-result rate, immediate reformulation, latency, complaints about spam.

## 6. Serving

~~~mermaid
flowchart LR
    Q[Search box] --> API[Search service]
    API --> QU[Query understanding]
    QU --> FAN[Fan out to 10 shards]
    FAN --> S1[(Shard: text + vector index)]
    FAN --> S2[(... 9 more)]
    S1 --> FU[Fuse top results]
    S2 --> FU
    FU --> FS[(Feature store)]
    FU --> RK[Ranker]
    RK --> RU[Rules]
    RU --> Q
    API -->|query, results, positions| LOG[(Query log)] --> TR[Training and the labels pipeline]
    L[New and changed listings] --> IDX[Indexer] --> S1
~~~

**The latency budget (p99 300 ms):**
- network and gateway: 10 ms;
- query understanding: 20 ms;
- shard fan-out, retrieval and fusion: 70 ms (the slowest shard decides; send a duplicate request to another replica if a shard hasn't answered in 50 ms);
- features for the 300 fused candidates: 30 ms;
- ranking: 30 ms;
- rules: 5 ms;
- headroom: 135 ms.

**Freshness:** the indexer reads listing changes from a stream and makes them searchable within seconds, as small new index segments that are merged in the background. A sold listing is filtered out immediately by a fast "is it still available" check, even before its segment is rewritten.

**Caching:** the results of frequent queries, for 30 seconds: short enough that new listings show up. Rare queries skip the cache.

**Fallback:** if ranking is late, return the fused retrieval order. If a shard is down, return results from the others and log that the results are partial.

## 7. Monitoring and iteration

- **Zero-result rate** by category: a jump usually means broken query understanding or a missing shard.
- **Click-through by position:** if the curve changes shape, the labels pipeline's position correction needs re-estimating.
- **Query drift:** seasonal ("winter tyres" in October) and sudden (a new phone launch). Rare queries become frequent.
- **Retraining:** the ranker weekly, on position-corrected labels; the judged set refreshed quarterly so it keeps up with new queries.

## 8. Risks

- **Keyword stuffing:** sellers listing every brand name in the description. Detect it, and use features that are hard to fake, such as contact rates.
- **The feedback loop:** the ranker trains on what it ranked. The randomised swaps, and the position correction, keep it learning.
- **Fairness to new sellers:** past contact rates favour established sellers. Give new listings a fair chance with a confidence-adjusted rate, not the raw one.
- **Privacy:** queries reveal a lot. Set retention, and drop identifiers from the query log used for training.

## 9. Where you've built this

- [Securing the AI layer, lesson 03](../../3-tracks/ai-infrastructure/04-securing-the-ai-layer/lessons/03-retrieval-over-the-tenants-runbooks-and-jobs.md): embedding retrieval with a measured hit@k and MRR, and why a small, self-written question set is a regression baseline rather than proof.
- [Sharding](../fundamentals/sharding.md) and [caching](../fundamentals/caching.md): splitting the index, and what a cache miss surge does to the shards.
- [ML for infrastructure](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/README.md): a baseline to beat, a time split, promotion with rollback.

## 10. What an interviewer will push on

- "Position 1 gets ten times the clicks of position 5. Is it ten times better?"
- "Why not train on clicks directly?"
- "A listing was posted a minute ago. Can I find it?"
- "nDCG went up on the judged set and the A/B test was flat. Why?"
- "One shard is slow. What does the user see?"
