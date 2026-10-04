# Phase 7 learning record

Answer from saved experiments and feedback. State negative results clearly.

## Systems evaluation

1. What user decision motivated the question? What evidence supports that need?
2. State your hypothesis and a result that would count against it.
3. How did the centralized baseline answer the same question?
4. Define freshness, availability, latency, bandwidth, privacy exposure, and operator effort as you measured them.
5. Which condition favored each design? What did repetition or uncertainty change about your conclusion?
6. What result surprised you? What limitation could change it?
7. What did domain feedback clarify, and who/context does it represent?

## Python/AI sampler

8. Which Python analysis did you reproduce from raw data?
9. What train/test split did you use, and what mistake would happen if you fit on test data?
10. Show one false positive and one false negative. Why is accuracy alone incomplete?
11. What does FastAPI validate and expose in the sample? How does it compare with the Go handler?
12. What are the stages in your AI infrastructure diagram? Which one stores model versions?
13. What did the computer-vision sample teach about data, labels, and generalization?
14. Which security, privacy, or operational risks would block using an AI model on KESTREL data?

| Claim | Evidence |
|---|---|
| Comparison can be rerun | experiment manifest and command |
| Results come from preserved raw output | raw file and analysis code |
| Limits are stated | limitations section |
| AI sampler uses permitted public data only | source/license note |
| Model/API behavior is measured | test outputs and metrics |

## Kestrel transfer

- What experiment did I rebuild without lesson analysis code?
- What choices did I make about workload, seed, and measures?
- What does the evidence say, including where the baseline wins?
- What would need domain or ethics review?
- What can I now explain about model training, serving, and infrastructure at a high level?
- What remains unclear?
