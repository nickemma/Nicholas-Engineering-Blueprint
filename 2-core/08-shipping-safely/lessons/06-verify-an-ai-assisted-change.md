# 06 Verify an AI-assisted change

## The problem

Generated code can compile and still assert the wrong thing. Turn each proposed change into a contract you can inspect independently. The three drafts below are fixed review examples so the same checks run locally and in replay. If you ask a coding assistant for another draft, supply this small public interface and synthetic fixtures.

## Build it

### Step 1. Review a policy test

A draft tests only the positive writer case.

~~~go
if !allowed("urn:switchyard:writer", "put") {
    t.Fatal("writer should be allowed")
}
~~~

This would pass on a function that allows every role. Add the denied reader write, unknown identities, and unsupported operations as separate rows. Compare your test with [lesson 02](02-model-the-trust-boundary.md). Explain what breaks each assertion.

### Step 2. Improve a fuzz target

A draft calls `Decode` and discards both results. That can catch a panic. Review its oracle as well as its inputs. After a successful decode, assert domain bounds and verify that canonical re-encoding preserves the same command. Seed the boundary cases that matter to the application.

<details>
<summary>Completed files</summary>

Create `internal/edge/fuzz_test.go`.

<!-- file: internal/edge/fuzz_test.go -->
~~~go
package edge

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func FuzzDecode(f *testing.F) {
	for _, seed := range []string{
		`{"Op":"get","Key":"ready"}`,
		`{"Op":"put","Key":"ready","Value":"demo"}`,
		`{"Op":"renew","Key":"ready"}`,
		`{"Op":"get","Key":"ready"}{}`,
		`{"Op":"get","Key":"` + strings.Repeat("x", 129) + `"}`,
	} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		if len(raw) > CommandLimit {
			return
		}
		c, err := Decode(bytes.NewReader(raw))
		if err != nil {
			return
		}
		if (c.Op != "get" && c.Op != "put") || c.Key == "" ||
			len(c.Key) > 128 || len(c.Value) > 512 || (c.Op == "get" && c.Value != "") {
			t.Fatalf("accepted outside the command contract: %+v", c)
		}
		canonical, err := json.Marshal(c)
		if err != nil {
			t.Fatal(err)
		}
		copy, err := Decode(bytes.NewReader(canonical))
		if err != nil || copy != c {
			t.Fatal("canonical request changed the authorized operation or fields")
		}
	})
}
~~~

</details>

### Step 3. Review the FFI contract

Compare the proposed call `sum_bytes(bytes.as_ptr(), bytes.len() + 1)` with the Rust slice and the C signature from [Core 05](../../05-rust-for-systems/lessons/03-call-a-c-library.md). Reject that proposal during review. The C loop reads the supplied number of bytes and retains no pointer. The safe wrapper borrows a live slice and supplies its exact length. Check the ABI types and run a comparison against a safe Rust implementation at all slice bounds, including empty ones.

<details>
<summary>Completed files</summary>

Create `ops/ffi/sum_bytes.c`.

<!-- file: ops/ffi/sum_bytes.c -->
~~~c
#include <stddef.h>
#include <stdint.h>

uint64_t sum_bytes(const uint8_t *bytes, size_t len) {
    uint64_t sum = 0;
    for (size_t i = 0; i < len; ++i) {
        sum += bytes[i];
    }
    return sum;
}
~~~

Create `ops/ffi/review.rs`.

<!-- file: ops/ffi/review.rs -->
~~~rust
unsafe extern "C" {
    fn sum_bytes(bytes: *const u8, len: usize) -> u64;
}

fn sum(bytes: &[u8]) -> u64 {
    // The slice is borrowed through the call. C reads exactly this many
    // bytes, retains no pointer, and performs no read at length zero.
    unsafe { sum_bytes(bytes.as_ptr(), bytes.len()) }
}

fn main() {
    let input = [255, 0, 1, 3];
    for start in 0..=input.len() {
        for end in start..=input.len() {
            let view = &input[start..end];
            assert_eq!(sum(view), view.iter().map(|&byte| u64::from(byte)).sum());
        }
    }
    println!("checked every sub-slice, including empty slices");
}
~~~

Create `ops/check-ffi.sh`.

<!-- file: ops/check-ffi.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd "$(dirname -- "$0")/ffi" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cc -std=c11 -Wall -Wextra -Werror -c "$source_dir/sum_bytes.c" -o "$work/sum_bytes.o"
rustc --edition 2024 -D warnings -C link-arg="$work/sum_bytes.o" "$source_dir/review.rs" -o "$work/review"
"$work/review"
~~~

</details>

## Check it

~~~bash
go test -run '^$' -fuzz '^FuzzDecode$' -fuzztime 200x -parallel 1 ./internal/edge && bash ops/check-ffi.sh
~~~

<!-- run: go test -run '^$' -fuzz '^FuzzDecode$' -fuzztime 200x -parallel 1 ./internal/edge && bash ops/check-ffi.sh -->

~~~text
fuzz: elapsed: 0s, gathering baseline coverage: 0/5 completed
fuzz: elapsed: 0s, gathering baseline coverage: 5/5 completed, now fuzzing with 1 workers
fuzz: elapsed: 0s, execs: 200 (3135/sec), new interesting: 2 (total: 7)
PASS
ok  	switchyard/metad/internal/edge	0.071s
~~~

Fuzz execution rate and newly interesting input counts vary. The C/Rust comparison prints the result from the fixed set of sub-slices. [FFI capture](../evidence/06-ffi.txt)

[Captured output](../evidence/06-fuzz.txt)

## Explain it

What does a policy oracle add to a panic-only fuzzer? Which language owns the bytes while the C function runs?
