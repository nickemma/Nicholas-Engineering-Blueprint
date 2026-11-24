# ML design: harmful content detection

**Track:** ml-system-design · **Built in:** [ML for infrastructure](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/README.md) (time splits, input drift, a gate before promotion), [Securing the AI layer, lesson 13](../../3-tracks/ai-infrastructure/04-securing-the-ai-layer/lessons/13-the-adversarial-suite.md) (attacks kept as a regression suite), [Messaging and resilience](../../3-tracks/shared-units/messaging-and-resilience/README.md) (a queue that survives crashes) · **Time:** 45 minutes

This is a worked reference. Do the design yourself first, with a timer, then read this and note what you missed.

**The prompt:** detect posts that break a social platform's policies, in text and images. 10 million posts a day. Most decisions must be automatic; borderline ones go to human reviewers with limited capacity; users can appeal.

## 0. The crux

**The costs are lopsided, and human review is the bottleneck.** Leaving up a violent threat and wrongly removing a post are both expensive, in different ways and different amounts for each policy. Reviewers can look at only a small share of posts. So the model has to be confident enough to act alone on most posts, send the uncertain middle to people, and put the most harmful of those first. The thresholds are set by **how much review capacity exists**, not by a fixed score.

Two more things make it hard:
- **Adversaries adapt.** Users who are blocked change their spelling, put text in images, and probe the thresholds.
- **The labels are judgements.** Trained reviewers disagree on borderline posts, and policies change.

## 1. Framing

| Question | Answer |
|---|---|
| Business goal | Fewer people see harmful content, while as few acceptable posts as possible are removed |
| ML objective | For each post and each policy (violence, hate, harassment, nudity, spam), the probability that the post breaks it |
| Input and output, task type | In: the post's text, images, the author's account signals. Out: a probability per policy, then a decision: allow, send to review, or remove. Multi-label classification |
| Why ML? The baseline | Keyword lists, matching against known bad images, and user reports. They miss new wording and images, and reports come after people have already seen the post |
| What ML costs here | Human labelling (the largest cost), a multimodal model on GPUs, and a review tool. There's no real alternative at 10 million posts a day |
| Online metric | **Prevalence:** views of violating posts per 10,000 views, measured on a random sample. Guardrails: appeal overturn rate, removals by language, review queue age |
| Offline metric | Per policy: precision at the auto-remove threshold, recall at the review threshold, PR-AUC |
| Constraints | High-severity checks before the post is visible (p99 500 ms); the rest within 5 minutes; a written reason for every removal; appeals |

**Estimates.**
- **Load:** 10 million posts a day ≈ 120 a second on average, about 350 at peak. 40% have images.
- **Violations:** if 1% of posts break a policy, that's 100,000 a day.
- **Review capacity:** 150 reviewers × about 350 decisions a day ≈ 50,000 reviews a day: half a percent of posts. User reports bring another 30,000 posts a day that need a look. The bands must fit what's left.

## 2. Data and labels

- **Reviewer decisions** are the main labels. They're noisy: measure agreement by sending 5% of reviews to a second reviewer. A small team of policy experts labels a **gold set** that settles disagreements and checks each reviewer.
- **The review queue is a biased sample.** It only contains posts the model found uncertain, or that users reported. Training only on it teaches the model about the middle. Evaluation needs a **random sample**: 2,000 posts a day, chosen at random from everything posted and labelled by reviewers. It's also how prevalence is measured.
- **User reports** are a signal, not a label: some are mistaken, and some are coordinated campaigns against a person.
- **Appeals** that overturn a removal are valuable labels: they're the model's confident mistakes.
- **New policies or new kinds of violation:** there are no labels yet. Write the policy with examples, have an LLM label a large set of candidate posts against it (weak labels), have reviewers check a sample, then train the classifier. Send reviewers the posts the model is least sure of (active learning) to improve it quickly.
- **Imbalance:** some policies are far rarer than 1%. Oversample their positives in training, and recalibrate so that thresholds mean what they say.

## 3. Features

| Feature | Source | Freshness | Computed where |
|---|---|---|---|
| Text embedding (multilingual encoder) | The post | Now | Online |
| Image embedding; text read from the image (OCR) | The post | Now | Online, on GPU |
| Match against known violating images (perceptual hash) | Hash database | Minutes | Online |
| Account age; past removals; posting rate in the last hour | Account history | Seconds | Streaming, online store |
| Share of the author's recent posts that were reported | Reports | Minutes | Streaming |
| How fast the post is spreading (shares in the first 10 minutes) | Engagement events | Seconds | Streaming, for re-scoring |

## 4. Model

1. **Baseline:** keyword lists, hash matching, and user reports.
2. **Hash matching stays** as the first step whatever the model does: an exact or near-exact match with a known violating image is removed without a model.
3. **Main model:** a pretrained multilingual text encoder and a pretrained image encoder, fine-tuned together, with one output per policy. One shared model is cheaper to serve than five, and learning the policies together helps the rare ones.
4. **Account signals** go into a small model (gradient-boosted trees) that combines the content scores with the author's history. A new account posting the same link 50 times is spam whatever the text says.
5. **On-device nudge:** a small quantised text model in the app warns the user before they post something that looks like harassment ("Are you sure?"). It costs little, keeps the text on the device, and prevents some violations before they happen. It doesn't replace the server's check.

**The three bands, per policy:**

| Band | Rule | Why |
|---|---|---|
| **Remove** | Score above the threshold where precision is at least 98% on the random sample | Act alone only when wrong removals are rare |
| **Review** | Between the two thresholds | The uncertain middle, sized to fit review capacity |
| **Allow** | Below the review threshold | Accept the misses, and measure them through prevalence |

**The review queue is ordered by expected harm:** probability × the policy's severity × how fast the post is spreading. A likely threat that's going viral goes to the top; a borderline spam post waits.

**Next:** a model that reads the post with its comments (harassment often lives in the replies); video.

## 5. Evaluation

**Offline:**
- **Split by time.** Violations change month to month, so a random split overstates performance.
- **The random sample** is the evaluation set, not the review queue.
- **Per policy and per language:** precision at the remove threshold and recall at the review threshold. A model that's good in English and poor in Swahili removes acceptable Swahili posts.
- **An adversarial set:** posts with obfuscated spelling, text in images, and coded words, collected from past evasion. Every model must pass it, like the [adversarial suite](../../3-tracks/ai-infrastructure/04-securing-the-ai-layer/lessons/13-the-adversarial-suite.md) in Securing the AI layer.
- **The ceiling:** if reviewers agree 85% of the time on a policy, a model "accuracy" above that is measuring noise.

**Online:**
1. **Shadow:** score live posts and compare the decisions with the current system's.
2. **Review the differences:** reviewers label a sample of the posts where old and new disagree. This shows which model is right on the cases that matter.
3. **Gradual rollout** by policy, the least severe first.
4. **Watch:** prevalence, appeal overturns, queue age, removals by language.

## 6. Serving

~~~mermaid
flowchart LR
    P[New post] --> H[Hash match]
    H -->|known violation| RM[Remove]
    H --> S[Sync check: high-severity policies]
    S -->|remove| RM
    S -->|allow, publish| PUB[Published]
    PUB --> A[Async: full model + account signals]
    A -->|remove| RM
    A -->|review| Q[(Review queue, ordered by expected harm)]
    REP[User reports] --> Q
    Q --> RV[Reviewers] --> D[Decision + reason]
    D --> LAB[(Labels)] --> TR[Training]
    RM --> AP[Appeals] --> RV
~~~

**Two paths:**
- **Before publishing (p99 500 ms),** only for the most severe policies (credible threats, graphic violence): hash match 10 ms, text model 30 ms, image model and OCR 150 ms on GPU, decision 5 ms, headroom about 300 ms.
- **After publishing (within 5 minutes),** the full model with account signals. Most posts get their final decision here. A post that suddenly spreads is **re-scored**, with its new spread rate.

**Fallback:** if the synchronous check fails or is late, publish the post and send it through the asynchronous path. Hash matching never fails open for the most severe category: if it's down, those posts wait.

**Every removal records its reason:** the policy, the score, the model version, and whether a person decided. Laws such as the EU's Digital Services Act require a statement of reasons and an appeal route, and the record is also the training data and the audit trail.

## 7. Monitoring and iteration

- **Prevalence** daily, from the random sample, per policy.
- **Queue age:** if posts wait longer than a day, the bands are too wide for the capacity. Raise the review threshold, and accept more misses knowingly.
- **Appeal overturn rate** per policy and language: a rise means wrong removals.
- **Drift:** new slang and coded words show up first as a rise in reports on posts the model allowed. Watch it, and feed those posts to reviewers.
- **Retraining:** weekly on new labels; at once when a new evasion pattern appears, with the adversarial set updated.

## 8. Risks

- **Bias against dialects and minority languages:** models trained mostly on one variety of a language remove more posts written in others. Track removals and overturns by language, and get reviewers who speak them.
- **Reviewer wellbeing:** reviewers see the worst content. Blur images by default, limit hours on graphic queues, and provide support.
- **Coordinated false reports** used to silence someone. Weight reports by the reporter's past accuracy.
- **Over-removal of important content:** news footage of violence, or survivors describing abuse. Policies need exceptions, and reviewers need context.

## 9. Where you've built this

- [ML for infrastructure](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/README.md): a time split, an input-drift check, and a gate that refuses a weaker model.
- [Securing the AI layer, lesson 13](../../3-tracks/ai-infrastructure/04-securing-the-ai-layer/lessons/13-the-adversarial-suite.md): attacks gathered into a suite that every change must pass.
- [Messaging and resilience](../../3-tracks/shared-units/messaging-and-resilience/README.md): a queue where an item isn't lost when a worker crashes, which the review queue needs.

## 10. What an interviewer will push on

- "Your reviewers can handle 50,000 posts a day and the model flags 200,000 as uncertain. What do you do?"
- "How do you know how much harmful content you're missing?"
- "Why not evaluate on the review queue's labels?"
- "Users start writing a banned word with a zero instead of an O. What happens next?"
- "Removals of posts in one language doubled. Is that good?"
