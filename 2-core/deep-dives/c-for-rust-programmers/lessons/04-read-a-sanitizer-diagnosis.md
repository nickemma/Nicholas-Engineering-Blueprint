# 04 Read a sanitizer diagnosis

## The problem

C relies on explicit contracts around addresses and arithmetic. A warning-free build alone leaves many runtime checks unexercised.

## The pattern

AddressSanitizer (ASan) instruments memory accesses. Its runtime tracks addressable regions and marks adjacent memory as poisoned. The probe queries the last byte of a four-byte allocation and the one-past address, keeping both queries as address observations. UndefinedBehaviorSanitizer (UBSan) reports a signed addition beyond the representable range in a standalone arithmetic probe with fixed operands. Read the named source line, operand values, and operation before deciding how to fix it.

## Build it

### Step 1. Observe the poisoned boundary

Predict which address is valid for a one-byte read and ask the sanitizer about each address.

<details>
<summary>Hint</summary>

The second pointer marks the end of the allocation. Query its shadow state without reading a byte there.

</details>

<details>
<summary>Type-along answer</summary>

Create `tests/asan_probe.c`.

<!-- file: tests/asan_probe.c -->
~~~c
#include <sanitizer/asan_interface.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    uint8_t *data = calloc(4, sizeof *data);
    if (data == NULL) {
        return 1;
    }
    const int last = __asan_address_is_poisoned(data + 3);
    const int past = __asan_address_is_poisoned(data + 4);
    printf("ASan shadow: final byte poisoned=%d; one-past poisoned=%d\n", last != 0, past != 0);
    free(data);
    return last == 0 && past != 0 ? 0 : 1;
}
~~~

</details>
### Step 2. Read the signed arithmetic report

Run the fixed-input diagnostic. For the positive-increment case, write down the check that would prevent the invalid addition.

<details>
<summary>Hint</summary>

Compare the base with INT_MAX minus the increment before addition.

</details>

<details>
<summary>Type-along answer</summary>

Create `tests/ubsan_probe.c`.

<!-- file: tests/ubsan_probe.c -->
~~~c
#include <limits.h>

int main(void) {
    /* Arithmetic-only diagnostic with fixed operands. */
    volatile int ceiling = INT_MAX;
    volatile int increment = 1;
    volatile int value = ceiling + increment;
    (void)value;
    return 0;
}
~~~

Create `ops/diagnostics.sh`.

<!-- file: ops/diagnostics.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cc=${CC:-cc}
"$cc" -std=c17 -Wall -Wextra -Werror -g -fsanitize=address -fno-pie -no-pie \
  tests/asan_probe.c -o "$work/asan"
ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0} "$work/asan"
"$cc" -std=c17 -Wall -Wextra -Werror -g -fsanitize=undefined \
  -fno-sanitize-recover=undefined tests/ubsan_probe.c -o "$work/ubsan"
result=0
"$work/ubsan" 2> "$work/ubsan.txt" || result=$?
if [[ "$result" == 0 ]]; then
  echo "expected the arithmetic diagnostic" >&2
  exit 1
fi
grep 'runtime error: signed integer overflow' "$work/ubsan.txt"
~~~

</details>
### Step 3. Re-run the buffer suite under both instruments

Build the ordinary, ASan, and UBSan variants in separate directories so no object compiled with different flags can be reused.

<details>
<summary>Hint</summary>

Carry sanitizer options to the link command as well as the compile command.

</details>

<details>
<summary>Type-along answer</summary>

Create `ops/check-c.sh`.

<!-- file: ops/check-c.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0}

for mode in ordinary asan ubsan; do
  case "$mode" in
    ordinary) cflags='-O2'; link='' ;;
    asan) cflags='-O1 -g -fsanitize=address -fno-pie'; link='-fsanitize=address -no-pie' ;;
    ubsan) cflags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=undefined'; link='-fsanitize=undefined' ;;
  esac
  echo "C tests: $mode"
  make --no-print-directory -s BUILD="$work/$mode" CFLAGS="$cflags" LDFLAGS="$link" check
done
~~~

</details>

## Check it

~~~bash
bash ops/diagnostics.sh && bash ops/check-c.sh
~~~

<!-- run: bash ops/diagnostics.sh && bash ops/check-c.sh -->

~~~text
ASan shadow: final byte poisoned=0; one-past poisoned=1
tests/ubsan_probe.c:7:34: runtime error: signed integer overflow: 2147483647 + 1 cannot be represented in type 'int'
C tests: ordinary
view bounds: empty, embedded zero, and rejected range checked
failed growth kept the original bytes and ownership; retry succeeded
C tests: asan
view bounds: empty, embedded zero, and rejected range checked
failed growth kept the original bytes and ownership; retry succeeded
C tests: ubsan
view bounds: empty, embedded zero, and rejected range checked
failed growth kept the original bytes and ownership; retry succeeded
~~~

The arithmetic probe exits with the expected UBSan finding. The buffer tests pass in every build. The laboratory commands default to address checks with leak detection disabled for sandbox compatibility. The allocator test verifies release for the exercised ownership path.

[Reference capture](../evidence/04-diagnostics.txt)

## Explain it

What does the test know about the allocated span? Which check prevents invalid length arithmetic in your buffer?
