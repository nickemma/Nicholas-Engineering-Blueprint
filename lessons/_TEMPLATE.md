# Lesson template

Every phase follows this shape. [Phase 0](00-request-service/TEACHING.md) is the worked example and sets the minimum level of explanation.

**The principle:** you learn by typing and understanding, then by building something on your own. So there are **no finished-code folders** anywhere in this repository. The code lives only inside the guide, next to its explanation. The exercise is a different project with a clear target and no solution.

## Folder

~~~text
lessons/NN-name/
  README.md      the syllabus: question, topics, outcomes, prerequisites, time, the exercise project, what it feeds into
  TEACHING.md    the lesson: explanations plus a type-along build, with the code inline
  exercises.md   a different project to build alone: a finished-state spec, acceptance checks, no solutions
  learned.md     your record to fill in: one row per "Explain it" question, plus an evidence checklist
~~~

Each phase also has a question-only self-test in `notes/learned/`.

## README.md: the syllabus

1. **Question:** the one question the phase answers.
2. **Topics:** a table of steps and what each one teaches, so a learner sees the whole phase before starting.
3. **Outcomes:** "you'll be able to..." bullets.
4. **Prerequisites and time.**
5. **The exercise project:** one paragraph on what you'll build alone at the end.
6. **Gaps closed and patterns introduced**, linked to the JOURNEY ledgers.
7. **Next:** how this phase feeds the next one.

## TEACHING.md: the lesson

1. **Opening:** who it's for, the goal in one sentence, the time, and what you'll have at the end.
2. **How this guide works**, and a table of the steps.
3. **Before you start:** the tools (with commands to check them), and what to have finished first.
4. **One section per step**, each with these parts in this order:

| Part | Rules |
|---|---|
| **The problem** | Make the reader *feel* what's missing or broken before solving it |
| **New ideas** | Define every new term the first time it appears. Never use a concept before it's explained |
| **The code** | The whole file the first time it appears; after that, exact edits ("change this, to that"; "add this at the end"). Every block the learner types carries a hidden marker so CI can rebuild it |
| **Run it** | Exact commands. Real output captured from running the code, not invented. Say which values vary (dates, IDs, ports) |
| **Break it** | At least one deliberate mistake per step, with the real output it produces and why |
| **Your turn** | Where useful: a small piece to write without the guide's code, with what it must do |
| **Explain it** | 1–3 questions that also appear in learned.md |
| **Read** | One specific chapter or section, placed after the experience it explains, with a question to carry into it |

5. **Rebuild:** close the guide and rebuild the phase in your own `runway` repository.
6. **Checkpoint:** what you must be able to do without the guide.
7. **If it goes wrong:** a table of symptoms, causes and fixes.
8. **Reading list:** every reading in the phase, in order.

## Markers that keep the guide honest

[scripts/check_guides.py](../scripts/check_guides.py) follows each guide in a scratch folder, exactly as a learner would. The markers are HTML comments, so they're invisible on GitHub:

| Marker | Placed before | Effect |
|---|---|---|
| `<!-- file: path -->` | one code block | Creates or replaces the file |
| `<!-- edit: path -->` | two code blocks (the text to find, then its replacement; "to:" may sit between them) | Replaces text that must appear exactly once |
| `<!-- append: path -->` | one code block | Adds the block to the end of the file |
| `<!-- run: command -->` | nothing | Runs the command in the scratch folder; it must succeed |

Every step ends with a hidden `run:` that formats, vets and tests the code as it stands at that point. Blocks without a marker are illustrations and aren't checked.

## exercises.md: the exercise project

Each exercise is a **different** project that uses the phase's ideas, so you can't just retrace the guide. It must make the finished result unmistakable:

1. **What you're building**, in two or three sentences, and why it exercises this phase.
2. **The finished result:** the contract (requests and responses, or commands and outputs), the behaviour rules, and the structure it must have (layers, patterns).
3. **A sample session:** exact commands and the exact output the finished project produces.
4. **Acceptance checks:** a numbered "done when" list a reviewer can verify.
5. **Stretch goals:** optional, harder extensions.
6. **Hints:** concepts to revisit, never code.

It never includes solution code.

## Verification labels

- Steps that CI can build and test need no label. The hidden markers are the proof.
- Steps that need things CI can't provide (a GitHub account, Kubernetes, `sudo`, cloud, a GPU) start with:

  > **Run locally.** \<why CI can't check this\>. The expected results are described for each command.

  Then give every command, the expected output, how to tell it worked, and what to check if it didn't.

## Style

- Second person, present tense, short sentences.
- Show the code the learner needs to type. Never "implement X" without either showing X or making it an explicit **Your turn** with a clear target.
- One idea per paragraph. Use tables for comparisons and Mermaid diagrams for flows.
- Every claim of the form "this proves X" also says what it does **not** prove.
