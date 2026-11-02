# Open source: read real code, then contribute to it

The phases teach you to build systems. This track teaches the other half of the job: **working in a codebase you didn't write**, with people you've never met reviewing your change. A merged pull request to a project that companies depend on is also some of the most checkable evidence you can show anyone.

It runs alongside the phases: reading from Phase 3, a first merged pull request by Phases 4–5 ([JOURNEY §8](../JOURNEY.md#8-parallel-tracks-dsa-system-design-writing)).

## The stages, by phase

| By | Stage | Done when |
|---|---|---|
| Phase 3 | **Read** one real codebase related to what you've just built | A one-page map of it in your repository: packages, the path of one request or operation, where the tests are, and three things it does differently from your code, with reasons |
| Phase 4 | **Run and compare**: build it, run its tests, and compare it with your own implementation | Notes on one design difference that surprised you, with a test of theirs you ran that shows it |
| Phase 4–5 | **A first contribution**: documentation, a test, an error message, a reproduced bug | Merged |
| Phase 5 onwards | **A code change** with tests | Merged, and reviewed by a maintainer |
| Ongoing | Answer one issue or review one pull request a month | A history of useful comments |

## Where to start: projects next to the phases

Pick a project next to what you've just built, so you can read it with understanding. These are all active and widely used.

| After | Project | Why it fits |
|---|---|---|
| Phase 2 | [rabbitmq/amqp091-go](https://github.com/rabbitmq/amqp091-go) | The RabbitMQ client Runway uses |
| Phase 3 | [jackc/pgx](https://github.com/jackc/pgx), [pressly/goose](https://github.com/pressly/goose), [redis/go-redis](https://github.com/redis/go-redis), [twmb/franz-go](https://github.com/twmb/franz-go) | The PostgreSQL driver, the migration tool, the Redis client, a Kafka client |
| Rust Bridge, Phase 3 | [cberner/redb](https://github.com/cberner/redb), [fjall-rs/fjall](https://github.com/fjall-rs/fjall) | Embedded storage engines in Rust: a B-tree and an LSM tree |
| Phase 4 | [etcd-io/raft](https://github.com/etcd-io/raft), [hashicorp/raft](https://github.com/hashicorp/raft), [anishathalye/porcupine](https://github.com/anishathalye/porcupine) | Two production Raft libraries to compare with yours (etcd's is driven by a `Ready` loop, like Phase 4's), and the linearizability checker you used |
| Phase 5 | [kubernetes-sigs/kind](https://github.com/kubernetes-sigs/kind), [helm/helm](https://github.com/helm/helm), [prometheus/client_golang](https://github.com/prometheus/client_golang), [open-telemetry/opentelemetry-go](https://github.com/open-telemetry/opentelemetry-go) | Every tool Phase 5 runs on |
| Phase 6 | [openbao/openbao](https://github.com/openbao/openbao), [sigstore/cosign](https://github.com/sigstore/cosign) | Secrets, and supply-chain signing |
| Phase 7 | [duckdb/duckdb](https://github.com/duckdb/duckdb), [mlflow/mlflow](https://github.com/mlflow/mlflow) | The query engine and the model registry you used |
| Phase 8 | [vllm-project/vllm](https://github.com/vllm-project/vllm), [ray-project/ray](https://github.com/ray-project/ray) | Model serving and distributed Python |

Big projects are harder to land a first change in, but their contribution process is well documented. Smaller ones answer faster. Start with a mid-sized one.

## Reading a codebase

1. **Build it and run its tests** before reading anything. If you can't, that's your first contribution: fix the instructions.
2. **Pick one operation** ("what happens on `Propose`?", "what happens when a connection is acquired from the pool?") and follow it through the code with a debugger or log lines, writing down each function it passes through.
3. **Read the tests for that path.** They show what the authors thought could go wrong.
4. **Read the history:** `git log -p` on the most important file. Why did it change, and what bug did each fix close?
5. **Write the one-page map.** If you can't explain the path to someone else, you haven't read it yet.

## Making a contribution

1. **Find an issue.** Look for `good first issue` and `help wanted` labels, and for things you noticed while reading: a confusing error message, an untested branch, a doc that's wrong. A bug you can reproduce with a failing test is worth more than any label.
2. **Ask before you build.** Comment on the issue: what you plan to change, and how you'll test it. Maintainers may already have a view, or a reason it isn't wanted.
3. **Read `CONTRIBUTING.md`.** Some projects need every commit signed off (`git commit -s`, the Developer Certificate of Origin); some need a contributor licence agreement; most have a style and a test command.
4. **Keep the change small**, with a test that fails without it. One concern per pull request.
5. **Write the description:** the problem, the change, how you tested it, and anything you weren't sure about.
6. **Respond to review** without defending every line. Reviewers know the codebase better than you do; ask when you don't understand why.

## Honesty, and AI-written code

Maintainers are volunteers, and their review time is the scarcest thing in open source. Don't submit a change you don't understand, and don't open pull requests generated by an AI tool without reading, testing and being able to explain every line. That's the same rule as the rest of the Blueprint: **you must be able to check what a tool generates**. Several projects (Gentoo, NetBSD and QEMU among them) now refuse AI-generated contributions outright, and many more close low-effort ones on sight.

## Recording it

Add each contribution to your progress tracker (JOURNEY §10) and to your gap-ledger evidence, as a story. For example: *"I'd never worked in a codebase this size. In Phase 4 I read etcd's raft, found an untested branch in its snapshot handling, and added the test; here's the merged pull request."*
