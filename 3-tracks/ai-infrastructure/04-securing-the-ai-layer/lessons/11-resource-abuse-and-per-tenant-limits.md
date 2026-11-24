# 11 Resource abuse and per-tenant limits

**Checked in CI:** the tenant-limit tests, with a fake Redis. **Run locally:** a flood of agents from one tenant while another tenant asks a question, before and after the limits.

Step 4's limits bound one run. They say nothing about how many runs a tenant starts. The model server is shared, and Phase 8's gateway admits a bounded number of requests for everyone together: its admission limit isn't per tenant, as Phase 8 noted. So one tenant running many agents at once can crowd every other tenant out: threat **A11** again, now across tenants.

## Attack: one tenant floods, another asks

Eight Acme agents run "keep checking the status of job 4190" over and over for two and a half minutes. Meanwhile Gavin at Hooli asks one ordinary question every few seconds. First a quiet minute for comparison, then the flood. The agent needs a gateway token per call now, since two tenants share the process:

<!-- edit: serve/src/serve/agent.py -->
~~~python


def from_env(user: User) -> Agent:
    env = os.environ
    tools = env.get("TOOLS_URL", "http://127.0.0.1:18095")
    return Agent(
        GatewayModel(env.get("RUNWAY_URL", "http://127.0.0.1:18081"), env["RUNWAY_TOKEN"]),
        Search(env["RAG_DATABASE_URL"], env.get("RAG_EMBED_URL", "http://127.0.0.1:18090")),
        Tools(tools, issue_token(tools, env["TOOLS_SERVICE_TOKEN"], user)),
~~~

to:

~~~python


def from_env(user: User, runway_token: str = "") -> Agent:
    env = os.environ
    tools = env.get("TOOLS_URL", "http://127.0.0.1:18095")
    token = runway_token or env["RUNWAY_TOKEN"]
    return Agent(
        GatewayModel(env.get("RUNWAY_URL", "http://127.0.0.1:18081"), token),
        Search(env["RAG_DATABASE_URL"], env.get("RAG_EMBED_URL", "http://127.0.0.1:18090")),
        Tools(tools, issue_token(tools, env["TOOLS_SERVICE_TOKEN"], user)),
~~~

<!-- file: experiments/agent/flood.py -->
~~~python
"""Step 11: while Acme runs many agents at once, can Hooli still ask a question?

Usage: flood.py ACME_TOKEN_FILE HOOLI_TOKEN_FILE AGENTS SECONDS > rows.jsonl
AGENTS = 0 measures Hooli on a quiet system.
"""

import json
import sys
import threading
import time
from pathlib import Path

from serve.agent import User, from_env

acme_token, hooli_token = (Path(f).read_text().strip() for f in sys.argv[1:3])
agents, seconds = int(sys.argv[3]), float(sys.argv[4])
stop = time.monotonic() + seconds
lock = threading.Lock()


def emit(row):
    with lock:
        print(json.dumps(row), flush=True)


def acme(n):
    user = User(f"bot{n}", "acme", "operator")
    while time.monotonic() < stop:
        started = time.monotonic()
        try:
            agent = from_env(user, acme_token)
            agent.cache = None  # measure the limits, not the answer cache
            result = agent.run(
                user, "Keep checking the status of job 4190 and tell me when it changes."
            )
            outcome = result.stopped or "answered"
        except Exception as exc:
            outcome = type(exc).__name__ + ": " + str(exc)[:40]
        emit({"who": "acme", "outcome": outcome, "seconds": round(time.monotonic() - started, 1)})
        if outcome == "tenant busy":
            time.sleep(1)  # a well-behaved client backs off before asking again


threads = [threading.Thread(target=acme, args=(n,), daemon=True) for n in range(agents)]
for thread in threads:
    thread.start()
time.sleep(5 if agents else 0)  # let the flood build up
gavin = User("gavin", "hooli", "operator")
while time.monotonic() < stop:
    started = time.monotonic()
    try:
        agent = from_env(gavin, hooli_token)
        agent.cache = None
        result = agent.run(gavin, "How do I join the incident bridge?")
        outcome = result.stopped or "answered"
    except Exception as exc:
        outcome = type(exc).__name__ + ": " + str(exc)[:40]
    emit({"who": "hooli", "outcome": outcome, "seconds": round(time.monotonic() - started, 1)})
    time.sleep(2)
for thread in threads:
    thread.join(timeout=120)
~~~

~~~bash
uv run --project serve python experiments/agent/flood.py acme.token hooli.token 0 60 > quiet.jsonl
uv run --project serve python experiments/agent/flood.py acme.token hooli.token 8 150 > flood.jsonl
~~~

~~~text
quiet.jsonl
  hooli runs   7  median   7.6 s  outcomes {'approval required': 7}
flood-weak.jsonl
  hooli runs   5  median  30.0 s  outcomes {'answered': 4, 'RuntimeError: gateway answered 502': 1}
  acme  runs  44  median  30.1 s  outcomes {'answered': 25, 'RuntimeError: gateway answered 504': 3, 'RuntimeError: gateway answered 502': 16}
~~~

On a quiet system Gavin's question came back in a median of 7.6 seconds. (Every time, the model answered it by proposing a change for Gavin to approve; what matters here is that it replied.) During Acme's flood, his median was **30 seconds**, the gateway's deadline, and one of five failed outright with a 502. Acme's own agents suffered too: 19 of its 44 runs failed with 502 or 504. Nobody attacked anybody; one tenant was simply busy, and the shared server was first come, first served.

There's a cheaper way to waste a tenant's money: a long question. Every turn sends the whole conversation again, so a padded question costs its length on every turn. Try an 11,783-character one:

~~~text
  File "serve/src/serve/rag.py", line 173, in __call__
    raise ValueError("embedding text bound")
ValueError: embedding text bound
~~~

It crashed before reaching the model: Step 3's embedding client refuses text over 1,200 characters. A bound you set for one reason caught this attack too, but as an exception, after the run had started. The fix below refuses it up front, with a reason.

## Fix: per-tenant limits, shared through Redis

The limits must hold across every agent process, so they live in Redis, next to the gateway's own reservations: at most two runs per tenant at once, and 20,000 tokens per tenant per minute. A run that can't start says so straight away ("tenant busy"), and the client backs off. A question over 2,000 characters is refused before it costs anything.

<!-- edit: serve/src/serve/agent.py -->
~~~python


TOOLS = {"status", "find"} | CHANGES
~~~

to:

~~~python


class TenantLimits:
    """Per-tenant limits shared by every agent process, kept in Redis: how many
    runs a tenant may have at once, and how many tokens it may spend a minute."""

    def __init__(self, url: str, runs: int = 2, tokens_per_minute: int = 20000):
        self.redis, self.runs, self.tokens = redis.Redis.from_url(url), runs, tokens_per_minute

    def start(self, tenant: str) -> bool:
        key = f"agent:runs:{tenant}"
        if self.redis.incr(key) > self.runs:
            self.redis.decr(key)
            return False
        self.redis.expire(key, 300)  # a crashed process can't hold a slot for ever
        return True

    def finish(self, tenant: str) -> None:
        self.redis.decr(f"agent:runs:{tenant}")

    def spend(self, tenant: str, tokens: int) -> int:
        key = f"agent:tokens:{tenant}:{int(time.time() // 60)}"
        used = self.redis.incrby(key, tokens)
        self.redis.expire(key, 120)
        return used

    def over(self, tenant: str) -> bool:
        used = self.redis.get(f"agent:tokens:{tenant}:{int(time.time() // 60)}")
        return int(used or 0) >= self.tokens


TOOLS = {"status", "find"} | CHANGES
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python

class Agent:
    def __init__(self, model, search, tools, limits=Limits(), history=None, cache=None, trace=None):
        self.model, self.search, self.tools, self.limits = model, search, tools, limits
        self.history, self.cache, self.trace = history, cache, trace or Trace("")

    def run(self, user: User, question: str, on_step=None) -> Result:
        deadline = time.monotonic() + self.limits.seconds
        sources = self.search(user.tenant, question)
~~~

to:

~~~python

class Agent:
    def __init__(self, model, search, tools, limits=Limits(), **parts):
        self.model, self.search, self.tools, self.limits = model, search, tools, limits
        self.history, self.cache = parts.get("history"), parts.get("cache")
        self.trace = parts.get("trace") or Trace("")
        self.tenants = parts.get("tenants")

    def run(self, user: User, question: str, on_step=None) -> Result:
        if len(question) > 2000:
            return Result("", [], stopped="question too long")
        if self.tenants and not self.tenants.start(user.tenant):
            return Result("", [], stopped="tenant busy")
        try:
            return self.run_once(user, question, on_step)
        finally:
            if self.tenants:
                self.tenants.finish(user.tenant)

    def run_once(self, user: User, question: str, on_step) -> Result:
        deadline = time.monotonic() + self.limits.seconds
        sources = self.search(user.tenant, question)
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python
                result.stopped = "token limit"
                return result
            if time.monotonic() >= deadline:
                result.stopped = "time limit"
~~~

to:

~~~python
                result.stopped = "token limit"
                return result
            if self.tenants and self.tenants.over(user.tenant):
                result.stopped = "tenant token budget"
                return result
            if time.monotonic() >= deadline:
                result.stopped = "time limit"
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python
                return result
            result.tokens += tokens
            self.trace.turn(user, messages, text)
            try:
~~~

to:

~~~python
                return result
            result.tokens += tokens
            if self.tenants:
                self.tenants.spend(user.tenant, tokens)
            self.trace.turn(user, messages, text)
            try:
~~~

<!-- edit: serve/src/serve/agent.py -->
~~~python
        cache=AnswerCache(env["RUNWAY_REDIS_URL"]) if env.get("RUNWAY_REDIS_URL") else None,
        trace=Trace(env.get("RUNWAY_AGENT_TRACE", "")),
    )
~~~

to:

~~~python
        cache=AnswerCache(env["RUNWAY_REDIS_URL"]) if env.get("RUNWAY_REDIS_URL") else None,
        trace=Trace(env.get("RUNWAY_AGENT_TRACE", "")),
        tenants=TenantLimits(env["RUNWAY_REDIS_URL"]) if env.get("RUNWAY_REDIS_URL") else None,
    )
~~~

<!-- file: serve/tests/test_tenant_limits.py -->
~~~python
import pytest

from serve.agent import TenantLimits, User

ACME = User("maria", "acme", "operator")


class FakeRedis:
    """Just the commands TenantLimits uses, in memory."""

    def __init__(self):
        self.values = {}

    def incr(self, key):
        return self.incrby(key, 1)

    def incrby(self, key, n):
        self.values[key] = self.values.get(key, 0) + n
        return self.values[key]

    def decr(self, key):
        return self.incrby(key, -1)

    def get(self, key):
        return self.values.get(key)

    def expire(self, key, seconds):
        pass


def limits(**kwargs):
    t = TenantLimits("redis://127.0.0.1:1", **kwargs)
    t.redis = FakeRedis()
    return t


def test_a_tenant_gets_two_runs_at_once_and_others_are_unaffected():
    t = limits(runs=2)
    assert t.start("acme") and t.start("acme")
    assert not t.start("acme")  # a third Acme run waits its turn
    assert t.start("hooli")  # Hooli isn't affected by Acme
    t.finish("acme")
    assert t.start("acme")


def test_runs_release_their_slot_even_when_they_fail():
    from tests.test_agent import agent

    a = agent('{"answer": "ok", "sources": []}')
    a.tenants = limits(runs=1)
    a.model.chat = lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError("gateway down"))
    with pytest.raises(RuntimeError):
        a.run(ACME, "status?")
    assert a.tenants.start("acme")  # the failed run gave its slot back


def test_tenant_token_budget_and_question_size():
    from tests.test_agent import agent

    a = agent('{"tool": "status", "job_id": 4190}')
    a.tenants = limits(tokens_per_minute=250)
    assert a.run(ACME, "status of 4190?").stopped == "tenant token budget"
    assert not a.tenants.over("hooli")  # Acme spent its own budget, not Hooli's
    assert a.run(ACME, "x" * 2001).stopped == "question too long"
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_tenant_limits.py tests/test_agent.py -->

~~~text
38 files already formatted
All checks passed!
..............                                                           [100%]
14 passed in 0.30s
~~~

Without the run limit, the first test fails:

~~~text
tests/test_tenant_limits.py:40: AssertionError
=========================== short test summary info ============================
FAILED tests/test_tenant_limits.py::test_a_tenant_gets_two_runs_at_once_and_others_are_unaffected
1 failed, 2 passed in 1.22s
~~~

The same flood, with `RUNWAY_REDIS_URL` set:

~~~text
quiet.jsonl
  hooli runs   7  median   7.6 s  outcomes {'approval required': 7}
flood-weak.jsonl
  hooli runs   5  median  30.0 s  outcomes {'answered': 4, 'RuntimeError: gateway answered 502': 1}
  acme  runs  44  median  30.1 s  outcomes {'answered': 25, 'RuntimeError: gateway answered 504': 3, 'RuntimeError: gateway answered 502': 16}
flood-fixed.jsonl
  hooli runs   8  median  18.0 s  outcomes {'approval required': 8}
  acme  runs 908  median   0.0 s  outcomes {'tenant busy': 891, 'answered': 17}
~~~

~~~text
11783 characters -> 'question too long' 0 tokens
~~~

~~~text
agent:tokens:hooli:29914950
agent:runs:hooli
agent:tokens:acme:29914950
agent:tokens:acme:29914948
agent:tokens:acme:29914949
agent:tokens:hooli:29914948
agent:tokens:hooli:29914949
agent:runs:acme
~~~

With the limits, Gavin's median was 18 seconds and none of his eight questions failed. That's still slower than a quiet system (7.6 s), because two Acme runs at a time still share the one model slot; the limits bound the damage, they don't remove it. Acme's other agents were told "tenant busy" straight away, 891 times in two and a half minutes, and backed off. Seventeen Acme runs completed. The padded question is now refused before any work, with no tokens spent. Redis holds the running counts and one token counter per tenant per minute.

<!-- file: docs/security/a11-tenant-limits.md -->
~~~markdown
# A11 (part 2): one tenant's agents crowd out another

1. Threat: a tenant's agents use up the shared model server.
2. Assumption: per-run limits (Step 4) are enough.
3. Test: eight Acme agents in a loop for 150 s while Hooli asks a question
   every few seconds; an 11,783-character question.
4. Observed: Hooli's median went from 7.6 s (quiet) to 30 s (the gateway's
   deadline), 1 of 5 failed; 19 of Acme's 44 runs failed. With limits:
   Hooli 18 s, 0 of 8 failed. The padded question crashed in the embedding
   client; now it is refused before any work.
5. Vulnerability: no per-tenant bound on concurrent runs or tokens; the
   gateway shares its capacity first come, first served.
6. Mitigation: per-tenant limits in Redis (two runs at once, 20,000 tokens a
   minute); questions over 2,000 characters refused before any work.
7. Regression: test_tenant_limits.py.
Not covered: fairness inside the gateway itself (still first come, first
served); what happens when Redis is down (the agent errors rather than
running without limits).
~~~

**Explain it:** why must the limits live in Redis rather than in each agent process? Why does a run that can't start return at once instead of waiting? The token limit is checked before a turn, using tokens already spent: by how much can a tenant overshoot it? What would per-tenant fairness inside the gateway add?

**Done when:** you have measured Hooli's experience during an Acme flood, before and after; the limits are shared through Redis; the tests failed first; and the second A11 record is written.

---
