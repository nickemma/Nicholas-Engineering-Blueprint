# NN Lesson title in plain words

> Module: <module name> · Time: ~N h · Builds on: <previous lesson, or the module it continues from>

(The first lesson of a module that starts from an earlier module's code puts a `continue:` marker here. See the notes at the end.)

## The problem

A real failure, in plain English, before any jargon. Make the reader feel what is missing or broken.

## The mental model

A diagram of where the bytes, the goroutines, the threads or the requests are. Mermaid or a text drawing.

## The pattern

The named pattern, and what the runtime, kernel or library does underneath. Define every new term the first time it appears.

## Build it

5–7 steps. Each step has, in this order:

### Step 1: <what this step adds>

1. **Starter code:** the wiring done, `// TODO` gaps for the part this lesson teaches. A starter block is an illustration: it carries **no** marker.
2. **The run command**, and the **real expected output**, captured from a real run. Say which values vary (times, IDs, ports).
3. **What a failure looks like:** the output of the most likely mistake, and what it means.
4. **The stuck drawer:**

<details>
<summary>Hint 1</summary>

A nudge: the concept or the function to look at.

</details>

<details>
<summary>Hint 2</summary>

Closer: the shape of the answer, still no code.

</details>

<details>
<summary>The answer</summary>

The complete code, commented. **This** block carries the marker, so the replay builds the finished step:

<!-- file: path/to/file.go -->
~~~go
// complete, commented code
~~~

</details>

<!-- run: gofmt -l . | (! grep .) && go vet ./... && go test -race -count=1 ./... -->

Every step ends with a hidden `run:` that formats, vets and tests the code as it stands.

## Check it

The test or measurement that proves this lesson works, with its real output. Say what it does **not** prove.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| | | |

---

## Notes for authors (delete this section)

**Markers** are HTML comments, invisible on GitHub. `scripts/replay_lessons.py` follows them in a scratch folder, in lesson order:

| Marker | Placed before | Effect |
|---|---|---|
| `<!-- file: path -->` | one code block | Creates or replaces the file |
| `<!-- edit: path -->` | two code blocks (the text to find, then its replacement; "to:" may sit between them) | Replaces text that must appear exactly once |
| `<!-- append: path -->` | one code block | Adds the block to the end of the file |
| `<!-- run: command -->` | nothing | Runs the command in the scratch folder; it must succeed |
| `<!-- continue: ../../01-go-runtime-and-reliable-services -->` | nothing | Replays that module first (path relative to this file); add `into DIR` to replay it into a subfolder |

**Rules:**
- No syntax before it's taught. Setup cards arrive when a tool is first needed, each ending in one verify command.
- Every output is real and captured. There are no solution folders: code lives only in lesson files.
- Steps CI can't run (a GPU, root, Kubernetes, a cloud account) start with:

  > **Run locally.** \<why CI can't check this\>. The expected results are described for each command.

- Second person, present tense, short sentences. One idea per paragraph.
- Every "this proves X" also says what it does **not** prove.
