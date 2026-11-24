# 09 Leaks between tenants

**Checked in CI:** the cache-key and log tests. **Run locally:** the shared cache with two tenants' real tokens, the timing experiment against the model server and the gateway, and the debug log.

Lesson 03 kept tenants apart in retrieval, and lesson 08 found a way round it. This step looks for the other places where one tenant's data can reach another: anything *shared*. Three suspects: a cache in front of the model (threat **A7**), the model server's own prompt cache (**A8**), and the logs (**A9**).

## A cache to save tokens

The same questions come up again and again, and every answer costs a model call. A cache in Redis, the one the gateway already uses, keyed by the question, answers repeats for free. And while you're there, a debug log of every prompt and reply makes the agent much easier to understand:

<!-- edit: serve/pyproject.toml -->
~~~toml
    "numpy>=2",
    "psycopg[binary]>=3.2",
    "torch>=2.0",
]
~~~

to:

~~~toml
    "numpy>=2",
    "psycopg[binary]>=3.2",
    "redis>=5",
    "torch>=2.0",
]
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python

import argparse
import http.client
import json
~~~

to:

~~~python

import argparse
import hashlib
import http.client
import json
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python

import psycopg

from serve import rag
~~~

to:

~~~python

import psycopg
import redis

from serve import rag
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python
    stopped: str = ""  # why the run ended early, if it did
    proposal: dict | None = None  # a change waiting for the user's approval
~~~

to:

~~~python
    stopped: str = ""  # why the run ended early, if it did
    proposal: dict | None = None  # a change waiting for the user's approval
    cached: bool = False
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python


TOOLS = {"status", "find"} | CHANGES
~~~

to:

~~~python


class AnswerCache:
    """Answers kept in Redis for ten minutes, so a repeated question costs no tokens."""

    def __init__(self, url: str, seconds: int = 600):
        self.redis, self.seconds = redis.Redis.from_url(url), seconds

    def key(self, user: User, question: str, sources: list[tuple]) -> str:
        return "answer:" + hashlib.sha256(question.strip().lower().encode()).hexdigest()

    def get(self, key: str) -> dict | None:
        value = self.redis.get(key)
        return json.loads(value) if value else None

    def put(self, key: str, answer: str, sources: list[str]) -> None:
        self.redis.set(key, json.dumps({"answer": answer, "sources": sources}), ex=self.seconds)


class Trace:
    """Debug log: one JSON line per model turn, to see what the agent was thinking."""

    def __init__(self, path: str):
        self.file = open(path, "a", buffering=1) if path else None

    def turn(self, user: User, messages: list[dict], reply: str) -> None:
        if self.file:
            line = {"user": user.name, "tenant": user.tenant, "messages": messages, "reply": reply}
            self.file.write(json.dumps(line) + "\n")


TOOLS = {"status", "find"} | CHANGES
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python

class Agent:
    def __init__(self, model, search, tools, limits: Limits = Limits(), history=None):
        self.model, self.search, self.tools, self.limits = model, search, tools, limits
        self.history = history

    def run(self, user: User, question: str, on_step=None) -> Result:
        deadline = time.monotonic() + self.limits.seconds
        messages = prompt(user, question, self.search(user.tenant, question))
        result = Result("", [])
        for turn in range(1, self.limits.turns + 1):
~~~

to:

~~~python

class Agent:
    def __init__(self, model, search, tools, limits=Limits(), history=None, cache=None, trace=None):
        self.model, self.search, self.tools, self.limits = model, search, tools, limits
        self.history, self.cache, self.trace = history, cache, trace or Trace("")

    def run(self, user: User, question: str, on_step=None) -> Result:
        deadline = time.monotonic() + self.limits.seconds
        sources = self.search(user.tenant, question)
        key = self.cache.key(user, question, sources) if self.cache else ""
        if hit := self.cache and self.cache.get(key):
            return Result(hit["answer"], hit["sources"], cached=True)
        messages = prompt(user, question, sources)
        result = Result("", [])
        for turn in range(1, self.limits.turns + 1):
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python
                return result
            result.tokens += tokens
            try:
                reply = check(parse(text))
~~~

to:

~~~python
                return result
            result.tokens += tokens
            self.trace.turn(user, messages, text)
            try:
                reply = check(parse(text))
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python
                result.answer = str(reply.get("answer", ""))
                result.sources = [str(s) for s in reply.get("sources") or []]
                return result
            if turn == self.limits.turns:
~~~

to:

~~~python
                result.answer = str(reply.get("answer", ""))
                result.sources = [str(s) for s in reply.get("sources") or []]
                if self.cache and not result.steps:  # only answers that changed nothing
                    self.cache.put(key, result.answer, result.sources)
                return result
            if turn == self.limits.turns:
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python
        Tools(tools, issue_token(tools, env["TOOLS_SERVICE_TOKEN"], user)),
        history=History(env["RAG_DATABASE_URL"]),
    )
~~~

to:

~~~python
        Tools(tools, issue_token(tools, env["TOOLS_SERVICE_TOKEN"], user)),
        history=History(env["RAG_DATABASE_URL"]),
        cache=AnswerCache(env["AGENT_REDIS_URL"]) if env.get("AGENT_REDIS_URL") else None,
        trace=Trace(env.get("SWITCHYARD_AGENT_TRACE", "")),
    )
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python
            print("not approved: nothing changed")
    else:
        print(f"answer  {result.answer}")
        print(f"sources {result.sources}")
    print(f"{len(result.steps)} tool calls, {result.tokens} tokens, {seconds:.1f} s")
~~~

to:

~~~python
            print("not approved: nothing changed")
    else:
        print(f"answer  {result.answer}" + ("  (from the cache)" if result.cached else ""))
        print(f"sources {result.sources}")
    print(f"{len(result.steps)} tool calls, {result.tokens} tokens, {seconds:.1f} s")
~~~

Both are switched on by environment variables:

~~~bash
export AGENT_REDIS_URL=redis://127.0.0.1:16379/0 SWITCHYARD_AGENT_TRACE=trace.jsonl
~~~

## Attack: the same question from two tenants

Gavin works at Hooli. He asks about his incident bridge, using Hooli's token for the gateway:

~~~bash
SWITCHYARD_TOKEN=$HOOLI_TOKEN uv run --project serve python -m serve.agent --tenant hooli --user gavin \
  "What's our incident bridge code?"
~~~

~~~text
answer  HOOLI-BRIDGE-4471
sources ['runbooks/incident-bridge.md#how', 'runbooks/incident-bridge.md#when']
0 tool calls, 443 tokens, 13.3 s
~~~

Then Maria, at Acme, asks the same question:

~~~text
answer  HOOLI-BRIDGE-4471  (from the cache)
sources ['runbooks/incident-bridge.md#how', 'runbooks/incident-bridge.md#when']
0 tool calls, 0 tokens, 0.1 s
~~~

~~~text
answer:539398623fb0a3aab18b49122e2c73d90601a410fa15f4b0b4df7be63fbce99f
~~~

Maria got Hooli's incident bridge code, in 0.1 seconds, with no model call: the first answer was cached under a key made only from the question, and her question was the same. One key in Redis, shared by every tenant. Row-level security, the tenant check on tools, the user tokens: none of it was involved, because the cache sits in front of all of them.

And the debug log:

~~~text
      2 HOOLI-BRIDGE-4471
~~~

The debug log has the bridge code twice: once in the prompt (the retrieved runbook) and once in the reply. Whoever can read the agent's logs, which usually means every operator of the platform and the log pipeline from Kubernetes and delivery, can read every tenant's runbooks.

## The model server's own cache

There's a less obvious shared thing: the model server. llama.cpp keeps the processed prompt of the last request (its KV cache, from Serving and scaling models, lesson 01) and reuses it when the next prompt starts the same way. That saves a lot of work: a matching prefix skips its prompt processing. It also means the time to the first token says something about what the *previous* request contained, even when it came from another tenant.

Measure it. Hooli sends a prompt holding its incident-bridge runbook. Straight after, Acme sends a probe that starts either with the same text, or with the same words in a fresh random order (never sent before, about the same length), in a shuffled order, and times the first token. Run it against the model server directly, where caching is on by default, and through the gateway, which sends `cache_prompt: false` on every request:

<!-- file: experiments/agent/prefix_timing.py -->
~~~python
"""Lesson 09: can one tenant tell, from timing alone, what another tenant just sent?

A victim (Hooli) sends a prompt holding its incident-bridge runbook. Straight
after, the attacker (Acme) sends a probe that starts either with the same text,
or with the same words in a fresh random order (never sent before, about the
same length), in random order, and times how long the first token takes. If the
server reuses its cache across tenants, the matching probe skips most of its
prompt processing and comes back faster.

Usage: prefix_timing.py URL VICTIM_TOKEN ATTACKER_TOKEN PAIRS > rows.jsonl
  URL is the model server itself (tokens "-") or the gateway (token files).
"""

import http.client
import json
import random
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

HOOLI = Path("experiments/rag/corpus/hooli/incident-bridge.md").read_text() * 4


def other_text(i):
    """The same words, shuffled differently each time: no cached prefix to reuse."""
    words = HOOLI.split()
    random.Random(1000 + i).shuffle(words)
    return " ".join(words)


def first_token_seconds(url, token, system, question):
    parts = urlsplit(url)
    conn = http.client.HTTPConnection(parts.hostname, parts.port, timeout=120)
    body = {
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": question}],
        "max_tokens": 1,
        "stream": True,
    }
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    started = time.monotonic()
    conn.request("POST", "/v1/chat/completions", json.dumps(body), headers)
    response = conn.getresponse()
    first, evaluated = None, None
    for line in response:
        if first is None and line.startswith(b"data:") and b'"content"' in line:
            first = time.monotonic() - started
        if line.startswith(b"data:") and b'"timings"' in line:
            evaluated = json.loads(line[5:])["timings"].get("prompt_n")
    conn.close()
    if response.status != 200:
        raise RuntimeError(f"status {response.status}")
    return first, evaluated


def main(url, victim_file, attacker_file, pairs):
    victim, attacker = (
        "" if f == "-" else Path(f).read_text().strip() for f in (victim_file, attacker_file)
    )
    order = ["same", "other"] * (pairs // 2)
    random.Random(9).shuffle(order)
    for i, probe in enumerate(order):
        first_token_seconds(url, victim, HOOLI, "How do I join the bridge?")
        prefix = HOOLI if probe == "same" else other_text(i)
        seconds, evaluated = first_token_seconds(url, attacker, prefix, "Summarise this.")
        row = {"pair": i, "probe": probe, "first_token_s": round(seconds, 3), "prompt_n": evaluated}
        print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]))
~~~

<!-- file: experiments/agent/timing_summary.py -->
~~~python
"""Summarise prefix_timing rows: first-token time per probe type."""

import json
import statistics
import sys

for path in sys.argv[1:]:
    rows = [json.loads(line) for line in open(path)]
    times = {
        p: sorted(r["first_token_s"] for r in rows if r["probe"] == p) for p in ("same", "other")
    }
    tokens = {
        p: sorted({r["prompt_n"] for r in rows if r["probe"] == p}) for p in ("same", "other")
    }
    print(path)
    for probe, values in times.items():
        q = statistics.quantiles(values, n=4)
        print(
            f"  {probe:5} n={len(values):2}  median {statistics.median(values):.3f} s"
            f"  quartiles {q[0]:.3f}-{q[2]:.3f}  prompt tokens evaluated {tokens[probe]}"
        )
    faster = sum(s < o for s in times["same"] for o in times["other"])
    total = len(times["same"]) * len(times["other"])
    print(f"  pairs where a matching probe beat a different one: {faster}/{total}")
~~~

~~~bash
uv run --project serve python experiments/agent/prefix_timing.py http://127.0.0.1:18080 - - 20 > direct.jsonl
uv run --project serve python experiments/agent/prefix_timing.py http://127.0.0.1:18081 hooli.token acme.token 20 > gateway.jsonl
uv run --project serve python experiments/agent/timing_summary.py direct.jsonl gateway.jsonl
~~~

~~~text
timing-direct.jsonl
  same  n=10  median 0.221 s  quartiles 0.198-0.249  prompt tokens evaluated [10]
  other n=10  median 3.482 s  quartiles 3.291-3.629  prompt tokens evaluated [270, 271, 272]
  pairs where a matching probe beat a different one: 100/100
timing-gateway.jsonl
  same  n=10  median 4.018 s  quartiles 3.933-4.066  prompt tokens evaluated [290]
  other n=10  median 3.774 s  quartiles 3.721-3.839  prompt tokens evaluated [273, 274, 275]
  pairs where a matching probe beat a different one: 5/100
~~~

Directly against the model server, a probe that matched what Hooli had just sent got its first token in a median of **0.22 s**; an unseen probe of the same length took **3.48 s**. Every one of the 100 pairs was ordered that way. The last column says why: the matching probe re-processed 10 tokens, the unseen one about 270. An attacker doesn't need the counter, though. A sixteen-fold difference in timing is easy to see over a network, and it answers "did another tenant just send this text?", which is enough to confirm a guess about someone else's runbook, a name, or a code.

Through the gateway the difference is gone: 4.02 s against 3.77 s, and the matching probe was *slower*, because it is about 15 tokens longer. Both processed every token. The gateway's `cache_prompt: false` closes the channel, at the price of re-processing every prompt in full.

One more lesson, from getting this wrong first. The first version of this experiment used a different runbook as the control: longer, and repeated on every probe, so the server cached the *control* from the attacker's own earlier probes. Its numbers mixed up length and caching and pointed the wrong way ([first run](../evidence/step09-tenant-leaks/05-timing-v1.txt)). A control has to differ in exactly one thing: here, whether the text was just sent by someone else.

## Fix: every key names its tenant, and logs keep no text

The answer's cache key must include everything the answer depends on: the tenant, the model, the question, and the exact sources it was built from (so an edited runbook doesn't serve a stale answer). And the debug log keeps counts and sizes, never text: prompts hold tenant data and whatever users type.

<!-- edit: serve/src/serve/agent.py -->
~~~python


class AnswerCache:
    """Answers kept in Redis for ten minutes, so a repeated question costs no tokens."""
~~~

to:

~~~python


MODEL = os.environ.get("SWITCHYARD_MODEL", "qwen2.5-1.5b-instruct-q4_k_m")


class AnswerCache:
    """Answers kept in Redis for ten minutes, so a repeated question costs no tokens."""
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python

    def key(self, user: User, question: str, sources: list[tuple]) -> str:
        return "answer:" + hashlib.sha256(question.strip().lower().encode()).hexdigest()

    def get(self, key: str) -> dict | None:
~~~

to:

~~~python

    def key(self, user: User, question: str, sources: list[tuple]) -> str:
        """Everything the answer depends on: whose data, which model, which sources."""
        parts = [user.tenant, MODEL, question.strip().lower()]
        parts += [
            f"{source}:{hashlib.sha256(body.encode()).hexdigest()}"
            for source, _, body, _ in sources
        ]
        return "answer:" + hashlib.sha256(json.dumps(parts).encode()).hexdigest()

    def get(self, key: str) -> dict | None:
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python

class Trace:
    """Debug log: one JSON line per model turn, to see what the agent was thinking."""

    def __init__(self, path: str):
~~~

to:

~~~python

class Trace:
    """Debug log: one JSON line per model turn. Fixed fields only: no prompt,
    source or reply text, which hold tenant data and whatever users type."""

    def __init__(self, path: str):
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python
    def turn(self, user: User, messages: list[dict], reply: str) -> None:
        if self.file:
            line = {"user": user.name, "tenant": user.tenant, "messages": messages, "reply": reply}
            self.file.write(json.dumps(line) + "\n")
~~~

to:

~~~python
    def turn(self, user: User, messages: list[dict], reply: str) -> None:
        if self.file:
            line = {
                "user": user.name,
                "tenant": user.tenant,
                "messages": len(messages),
                "prompt_chars": sum(len(m["content"]) for m in messages),
                "reply_chars": len(reply),
            }
            self.file.write(json.dumps(line) + "\n")
~~~

<!-- file: serve/tests/test_leaks.py -->
~~~python
import json

from serve.agent import AnswerCache, Trace, User

ACME, HOOLI = User("maria", "acme", "operator"), User("gavin", "hooli", "operator")
BRIDGE = [("runbooks/incident-bridge.md#how", "a", "The bridge code is HOOLI-BRIDGE-4471.", 0.1)]


def test_cache_keys_belong_to_one_tenant():
    cache = AnswerCache("redis://127.0.0.1:1")  # never connects: key() is pure
    question = "What's our incident bridge code?"
    assert cache.key(ACME, question, []) != cache.key(HOOLI, question, [])
    changed = [(BRIDGE[0][0], "a", "The bridge code changed.", 0.1)]
    assert cache.key(HOOLI, question, BRIDGE) != cache.key(HOOLI, question, changed)


def test_trace_keeps_no_text(tmp_path):
    path = tmp_path / "trace.jsonl"
    messages = [{"role": "user", "content": "Sources: HOOLI-BRIDGE-4471"}]
    Trace(str(path)).turn(HOOLI, messages, "The code is HOOLI-BRIDGE-4471.")
    line = path.read_text()
    assert "HOOLI-BRIDGE" not in line and json.loads(line)["tenant"] == "hooli"
~~~

Against the first version, both tests fail:

~~~text

tests/test_leaks.py:22: AssertionError
=========================== short test summary info ============================
FAILED tests/test_leaks.py::test_cache_keys_belong_to_one_tenant - assert 'an...
FAILED tests/test_leaks.py::test_trace_keeps_no_text - assert ('HOOLI-BRIDGE'...
2 failed in 0.54s
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_leaks.py tests/test_agent.py -->

~~~text
36 files already formatted
All checks passed!
.............                                                            [100%]
13 passed in 0.64s
~~~

Repeat the two questions, then Gavin's again:

~~~text
answer  HOOLI-BRIDGE-4471
sources ['runbooks/incident-bridge.md#how', 'runbooks/incident-bridge.md#when']
0 tool calls, 443 tokens, 12.0 s
~~~

~~~text
answer  The incident bridge code is not provided in the given sources.
sources ['the source ids you used']
0 tool calls, 419 tokens, 10.5 s
~~~

~~~text
answer  HOOLI-BRIDGE-4471  (from the cache)
sources ['runbooks/incident-bridge.md#how', 'runbooks/incident-bridge.md#when']
0 tool calls, 0 tokens, 0.1 s
~~~

~~~text
0
{"user": "gavin", "tenant": "hooli", "messages": 2, "prompt_chars": 1416, "reply_chars": 115}
{"user": "maria", "tenant": "acme", "messages": 2, "prompt_chars": 1395, "reply_chars": 116}
~~~

Maria's question now goes to the model with her own sources, and she gets her own (unhelpful) answer. Gavin's repeat is still served from the cache, because the key is his. The log keeps who, how many messages, and how many characters: enough to debug volume and loops, and nothing worth stealing.

<!-- file: docs/security/a7-a9-tenant-leaks.md -->
~~~markdown
# A7-A9: what tenants share

1. Threat: one tenant's data reaches another through something shared.
2. Assumption: the answer cache, the model server and the logs hold nothing
   that crosses tenants.
3. Test: the same question from Hooli then Acme through the shared cache;
   20 shuffled prefix probes against the model server and the gateway;
   a search of the debug log.
4. Observed: Acme got Hooli's cached answer (HOOLI-BRIDGE-4471) in 0.1 s
   with no model call; the debug log held the code twice. Prefix timing
   against the model server: 0.22 s matching vs 3.48 s unseen (100/100
   pairs); through the gateway 4.02 s vs 3.77 s (no advantage).
5. Vulnerability: a cache key without the tenant; a log of full text; a
   prompt cache shared across tenants (closed by the gateway's setting).
6. Mitigation: cache key = tenant, model, question and source digests; the
   gateway's cache_prompt=false (measured); a log of counts and sizes only.
7. Regression: test_leaks.py.
Not covered: other shared caches you add later; the gateway setting depends
on llama.cpp honouring cache_prompt; per-tenant model servers would remove
the channel instead of switching it off.
~~~

**Explain it:** why does the cache key include the sources' digests and not just the tenant? Why did the timing probe need a shuffled order and a control of similar length? The gateway closes the timing channel by disabling the cache: what does that cost, and what would keep the speed without the leak? Why keep sizes and counts in the debug log but not text?

**Done when:** you have watched Acme get Hooli's cached answer and then not; measured the prefix-cache timing directly and through the gateway; the log keeps no text; the tests failed first; and the A7-A9 record is written.

---
