# Gate: Securing the AI layer

## What it checks

The gate runs on your lab directory, the one from Serving and scaling models, now holding `serve/` and `tools/`. It takes about 15 seconds once the Python environment is installed. Everything runs against a scripted model: no weights, no network.

1. `serve` is formatted and lint-clean, and every test passes, including the adversarial suite against the scripted model. Live tests that need the lab database or the tool server skip unless you've set them up.
2. `tools` is `gofmt`-clean, passes `go vet`, and passes its tests under the race detector.
3. Negative controls. In a disposable copy, the gate removes one defence at a time, and the named test must fail:
   - approval before a change: `test_changes_wait_for_approval`;
   - escaping the model's answer on the page: `test_answer_is_shown_as_text`;
   - the tenant in the answer cache's key: `test_cache_keys_belong_to_one_tenant`;
   - the canary check on replies: `test_canary_in_a_reply_stops_it`;
   - the release signature check: `test_another_key_or_an_unapproved_release_is_refused`;
   - the tool server's tenant check on every call: `TestNoConfusedDeputy`.

Each of these defences lives in code the model can't talk to. A defence no test notices is one the next refactor can delete. The negative controls change the lines the lessons wrote; if you changed one, the gate stops and names it.

The gate doesn't attack the real model. The live suite, the injection experiments and the red team are in the lessons and in [evidence/](../evidence/README.md).

## Run it

From the Blueprint checkout, rebuild the lessons; lessons 13 and 14 run the gate on the result:

~~~bash
python3 scripts/replay_lessons.py 3-tracks/ai-infrastructure/04-securing-the-ai-layer
~~~

On your own lab directory:

~~~bash
bash "$blueprint/3-tracks/ai-infrastructure/04-securing-the-ai-layer/gate/run.sh" ~/path/to/your/lab
~~~

It needs `uv`, Go and Bash.

## A pass looks like

~~~text
$ bash gate/run.sh .
== serve: format, lint, every test (the adversarial suite runs against the scripted model)
42 files already formatted
All checks passed!
.............ssss......................sssssssss........................ [ 61%]
...........................................s..                           [100%]
104 passed, 14 skipped in 2.75s
== tools: format, vet, race tests
?   	agenttools/cmd/tools	[no test files]
?   	agenttools/internal/identity	[no test files]
?   	agenttools/internal/jobs	[no test files]
ok  	agenttools/internal/toolsrv	1.119s
negative control: without approval before a change -> caught by test_changes_wait_for_approval
negative control: without escaping the model's answer -> caught by test_answer_is_shown_as_text
negative control: without the tenant in the cache key -> caught by test_cache_keys_belong_to_one_tenant
negative control: without the canary check -> caught by test_canary_in_a_reply_stops_it
negative control: without the release signature check -> caught by test_another_key_or_an_unapproved_release_is_refused
negative control: without the tenant check on every tool call -> caught by TestNoConfusedDeputy
gate passed
[exit 0]
~~~

## A fail looks like

An agent that runs a change without waiting for approval fails its own tests, and the adversarial suite with them: every planted instruction now changes a job.

~~~text
$ bash gate/run.sh .
== serve: format, lint, every test (the adversarial suite runs against the scripted model)
42 files already formatted
All checks passed!
.....F.....F.ssss......................sssssssss...........FFFFFFFFFFFFF [ 61%]
FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF........s..                           [100%]
=================================== FAILURES ===================================
________________________ test_changes_wait_for_approval ________________________

    def test_changes_wait_for_approval():
        a = agent('{"tool": "notify", "job_id": 4190, "text": "all jobs"}')
        result = a.run(ACME, "why did 4190 fail?")
>       assert result.stopped == "approval required"
E       AssertionError: assert 'turn limit' == 'approval required'
E         
E         - approval required
E         + turn limit

tests/test_agent.py:99: AssertionError
________________ test_a_job_the_question_never_named_is_flagged ________________
...
50 failed, 54 passed, 14 skipped in 3.11s
[exit 1]
~~~

A tool-server test weakened so that no case crosses tenants still passes on its own. The negative control catches it:

~~~text
?   	agenttools/internal/identity	[no test files]
?   	agenttools/internal/jobs	[no test files]
ok  	agenttools/internal/toolsrv	1.114s
negative control: without approval before a change -> caught by test_changes_wait_for_approval
negative control: without escaping the model's answer -> caught by test_answer_is_shown_as_text
negative control: without the tenant in the cache key -> caught by test_cache_keys_belong_to_one_tenant
negative control: without the canary check -> caught by test_canary_in_a_reply_stops_it
negative control: without the release signature check -> caught by test_another_key_or_an_unapproved_release_is_refused
ok  	agenttools/internal/toolsrv	0.019s
removing 'the tenant check on every tool call' was not caught by TestNoConfusedDeputy
[exit 1]
~~~

The gate was checked both ways: it passes on the reference build and fails on both of these deliberately broken ones. The full runs are in [evidence/gate](../evidence/gate/).
