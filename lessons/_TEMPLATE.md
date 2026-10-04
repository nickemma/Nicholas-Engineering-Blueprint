# Lesson template

Every phase follows this shape. [Phase 0](00-request-service/TEACHING.md) is the worked example and sets the minimum level of explanation.

## Folder

~~~text
lessons/NN-name/
  README.md        one page: question, what you build, time, prerequisites, gaps closed, patterns, how to run the finished code
  TEACHING.md      the lesson
  steps/NN-slug/   one runnable, tested snapshot per step (its own go.mod, pyproject.toml or Cargo.toml)
  exercises.md     test-driven exercises with clear "done when" criteria; no solutions
  learned.md       the learner's answer sheet: one row per "Explain it" question, plus an evidence checklist
~~~

## TEACHING.md

1. **Opening:** who it's for, the goal in one sentence, the time, and what the learner will have at the end.
2. **How this guide works:** a table of steps and their snapshot folders.
3. **Before you start:** the tools to install (with check commands) and what to have finished first.
4. **One section per step**, each with these parts in this order:

| Part | Rules |
|---|---|
| **The problem** | Make the reader *feel* what's missing or broken before solving it |
| **New ideas** | Define every new term the first time it appears. Never use a concept before it's explained |
| **The code** | The complete file (`<!-- file: steps/... -->`) or an exact excerpt (`<!-- excerpt: steps/... -->`) placed right before the fence. `scripts/check_teaching.py` fails CI if it drifts from the step folder |
| **Run it** | Exact commands. Real output captured from running the step, not invented. Mark values that vary (dates, IDs, ports) |
| **Break it** | At least one deliberate mistake per step, with the real output it produces and why |
| **Compare** | The `diff` command against the snapshot |
| **Explain it** | 1–3 questions that also appear in learned.md |
| **Read** | One specific chapter or section, placed after the experience it explains, with a question to carry into it |

5. **Rebuild:** close the guide and rebuild the phase in your own `kestrel` repository.
6. **Checkpoint:** what the learner must be able to do without the guide.
7. **If it goes wrong:** a table of symptoms, causes and fixes for the errors this phase produces.
8. **Reading list:** every reading in the phase, in order.

## Verification labels

- Steps whose code CI can build and test need no label. Their step folder is the proof.
- Steps that need things CI can't provide (a GitHub account, Kubernetes, `sudo`, cloud, a GPU) start with:

  > **Run locally.** \<why CI can't check this\>. The expected results are described for each command.

  Then give every command, the expected output, how to tell it worked, and what to check if it didn't.

## Style

- Second person, present tense, short sentences.
- Show the complete code. Never "implement X" without showing X.
- One idea per paragraph. Use tables for comparisons and Mermaid diagrams for flows.
- Every claim of the form "this proves X" also says what it does **not** prove.
