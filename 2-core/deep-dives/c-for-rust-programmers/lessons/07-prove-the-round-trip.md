# 07 Prove the round trip

## The problem

Both callers can compile and agree on a text fixture while one silently skips a byte in a binary record. A test needs an independent expected result and an input that distinguishes correct behavior from the faulty behavior.

## The pattern

The gate writes each fixture once and gives the same bytes to both executables. Each result must equal a known checksum. The Rust caller also compares the bytes returned from the C buffer with its original fixture before printing. The C caller checks invalid shapes and verifies that rejection leaves an output value unchanged.

## Build it

### Step 1. Predict three results

The fixture set includes an empty file, the three bytes `41 00 42`, and each byte from zero through 255 three times. Before running the gate, predict which fixture catches a loop that skips every zero. Explain why a second caller helps localize the problem.

### Step 2. Check failure, release, and lifetime

Review the injected allocator test and the Rust compile-fail test. Find the evidence that the same C allocation survived failed growth, and the evidence that Rust forbids growing while a previous view remains in use. The sanitizer runs cover the C unit suite.

### Step 3. Keep the negative control disposable

The gate builds an altered C checksum in a temporary copy. It checks for the precise fixture mismatch exit status. A compiler failure or an unrelated abort would fail the outer gate.


## Check it

~~~bash
bash "$blueprint/2-core/deep-dives/c-for-rust-programmers/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/2-core/deep-dives/c-for-rust-programmers/gate/run.sh" "$PWD" -->

~~~text
C tests: ordinary
C tests: asan
C tests: ubsan
empty: both callers produced cbf29ce484222325 (0 bytes)
embedded-zero: both callers produced fb029919a1274bf2 (3 bytes)
all-bytes: both callers produced 4f33c513c2e95c25 (768 bytes)
empty: both callers produced cbf29ce484222325 (0 bytes)
FAIL embedded-zero: Rust calling C=09086407b5a0edaa, C calling Rust=fb029919a1274bf2, expected=fb029919a1274bf2
negative control: caught a checksum that dropped an embedded zero
~~~

The FAIL line is the expected result of the intentionally altered build. The final line confirms the gate caught it.

[Reference capture](../evidence/07-gate.txt)

## Explain it

Which tests check binary correctness and which tests check ownership and lifetime?
