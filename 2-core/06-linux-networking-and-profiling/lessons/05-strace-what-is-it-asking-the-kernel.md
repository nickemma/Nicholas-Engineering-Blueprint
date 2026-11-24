# 05 strace: what is it asking the kernel?

## What this step teaches

- System calls: the only way a program gets anything done outside its own memory.
- `strace`, and what it costs.
- Reducing system calls.

A **system call** is a program asking the kernel to do something: read a socket, write a file, sleep. Each one crosses from user space into the kernel, which costs far more than a function call. `strace` prints them.

`strace -p` can attach to a running process, but many systems forbid that for ordinary users:

~~~bash
cat /proc/sys/kernel/yama/ptrace_scope
~~~

`1` means a process can only trace its own children, so start `hotspot` under `strace`. `-c` counts instead of printing, and `-f` follows every thread:

~~~bash
strace -c -f -o summary.txt ./bin/hotspot &
sleep 1
./bin/load -rate 1500 -for 10s
pkill -x hotspot
head -11 summary.txt
~~~

~~~text
sent 15000 in 20.0s (750/s), errors 7901
latency p50 4.00616s  p90 8.772s  p99 9.93738s  max 10.00008s
~~~

~~~text
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ------------------
 75.62  221.556188        4447     49811      6127 futex
  5.31   15.550522         436     35650        16 nanosleep
  5.29   15.487810         248     62427        88 write
  4.93   14.434272         461     31299        36 epoll_pwait
  3.10    9.074335         264     34320     11388 read
  2.18    6.391637         210     30344           setsockopt
  0.90    2.635492         292      9020         1 epoll_ctl
  0.64    1.872191         308      6071         2 accept4
~~~

**Look at the load first.** Without `strace`, this rate was easy, with a p99 of about 6 ms. Under `strace`: half the requests failed, and p50 was 4 seconds. `strace` stops the process at every system call, twice. **That's the observer effect, and it's severe.** Use it to learn what a program does, not how fast. And never point it at a busy production process.

The counts are still true, though. 62,427 writes, and the audit log has 8,404 lines. That's more than seven writes for each job. Look at them, with `-e trace=write` to filter and `-T` to time each one:

~~~bash
strace -f -T -e trace=write -o writes.txt ./bin/hotspot &
sleep 1
./bin/load -rate 100 -for 1s
pkill -x hotspot
~~~

~~~text
write(4, "id=3", 4)             = 4 <0.000085>
write(4, " tenant=t4", 10)      = 10 <0.000064>
write(4, " key=k132799", 12)    = 12 <0.000054>
write(4, " bytes=1", 8)         = 8 <0.000074>
write(4, " at=2026-10-31T16:37:23.09444071"..., 34) = 34 <0.000113>
write(4, "\n", 1)               = 1 <0.000061>
write(8, "HTTP/1.1 201 Created\r\nContent-Ty"..., 215) = 215 <0.000110>
~~~

There's the fifth problem: **six system calls for one audit line**, a fragment at a time, then one for the response. And all six happen while holding the store's lock. It also means a crash can leave half a line.

Build the line, then write it once. In `store.go`, replace `writeAudit`:

<!-- edit: store.go -->
~~~go
	fields := []string{
		fmt.Sprintf("id=%d", j.ID),
		" tenant=" + j.Tenant,
		" key=" + j.Key,
		fmt.Sprintf(" bytes=%d", len(j.Payload)),
		" at=" + j.Created.UTC().Format(time.RFC3339Nano),
		"\n",
	}
	for _, f := range fields {
		if _, err := io.WriteString(s.audit, f); err != nil {
			return err
		}
	}
	return nil
}
~~~

to:

~~~go
	// Build the whole line, then write it once: one system call per job,
	// and a crash can't leave half a line.
	line := fmt.Appendf(nil, "id=%d tenant=%s key=%s bytes=%d at=%s\n",
		j.ID, j.Tenant, j.Key, len(j.Payload), j.Created.UTC().Format(time.RFC3339Nano))
	_, err := s.audit.Write(line)
	return err
}
~~~

And a test that counts them. Pass the store a writer that counts calls:

<!-- append: store_test.go -->
~~~go
func TestAuditIsOneWritePerJob(t *testing.T) {
	var w countingWriter
	s := NewStore(&w)
	s.Create("acme", "k1", "x")
	s.Create("acme", "k2", "x")
	if w != 2 {
		t.Errorf("%d writes for 2 jobs", w)
	}
}

type countingWriter int

func (w *countingWriter) Write(p []byte) (int, error) { *w++; return len(p), nil }
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test ./... -->

## Run it

`strace` now shows one write per job:

~~~text
write(4, "id=3 tenant=t4 key=k132799 bytes"..., 69) = 69 <0.000064>
write(9, "HTTP/1.1 201 Created\r\nContent-Ty"..., 215) = 215 <0.000105>
write(4, "id=4 tenant=t1 key=k444788 bytes"..., 69) = 69 <0.000098>
write(9, "HTTP/1.1 201 Created\r\nContent-Ty"..., 215) = 215 <0.000134>
~~~

Timing must come **without** `strace`. Each pair below is a fresh process, sent 3,000/s for 15 seconds, then 5,000/s for 15 seconds, with the old version first and the new one second, twice:

| Rate | | Before: run 1 | After: run 1 | Before: run 2 | After: run 2 |
|---|---|---|---|---|---|
| 3,000/s | p50 | 2.22 ms | 2.18 ms | 2.18 ms | 2.16 ms |
| | p99 | 8.16 ms | 8.72 ms | 6.24 ms | 6.06 ms |
| 5,000/s | p50 | 8.19 ms | **3.65 ms** | 5.37 ms | **3.18 ms** |
| | p99 | 70.6 ms | **41.0 ms** | 145 ms | **55.1 ms** |

At 3,000/s, **no difference**: the two runs of the old code differ more than old from new. At 5,000/s, near saturation, the fix cuts p50 by a third or more, and p99 by a third to two thirds. A fix can be real and still invisible below the knee. That's why you measure at the load you care about. Two runs aren't many, so the direction is clear but the sizes are rough.

There's a durability question here too: this write reaches the operating system, not the disk. A crash of the **process** keeps it; a crash of the **machine** can lose it, unless you `fsync`. `fsync` per job would cost far more than these writes did. [Core 04](../../04-rust-foundations/lessons/09-measure-syncs-and-prove-recovery.md) measured exactly this trade-off.

**Explain it:** What is a system call, and why does it cost more than a function call? Why did `strace` hurt the service so much? What does `ptrace_scope` protect against? Why was the fix invisible at 3,000/s? What does this write guarantee, and what doesn't it?

**Read.** `man strace`. Julia Evans, [*strace zine*](https://wizardzines.com/zines/strace/).

---
