# Programmable edge proxy capstone exercises

## 1. Tighten the cutover observation

Add a fixture-visible generation tag or an independent publication timestamp, then prove how it narrows the allowed interval for requests that overlap the acknowledgement.

- Keep both origins distinct and verify the held-response invariant on swap and rollback.
- Use the same arrival schedule before and after the change. Report the number of requests whose origin can be determined without allowing both slots.
- Explain what the extra observation costs and how the operator would use it.

## 2. Increase load without losing accountability

Run repeated paired no-reload and reload trials at three offered rates.

- Preserve per-request outcomes and sampled RSS with the same sampling interval.
- Identify the first repeatable appearance of delay, refusal, or driver drops. Keep the driver and proxy outcomes distinct.
- State which trial supports a zero-error reload claim and which limits the conclusion.

## 3. Hand the release to another operator

Have someone rebuild the archive in an empty workspace and use its commands to perform a swap and rollback.

- Collect the commands, active generations, observed origin, and any missing dependency information.
- Update the runbook and repeat the clean extraction. The evidence must include a working command sequence and a passing portable gate.
