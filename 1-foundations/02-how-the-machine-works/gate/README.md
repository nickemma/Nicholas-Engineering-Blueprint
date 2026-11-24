# Gate: How the machine works

## What it checks

Your folder must hold `monitor.sh` (lesson 05) and `rotate.sh` (lesson 07).

1. **The monitor** prints one line, `load1=<n> mem_used_pct=<n> disk_used_pct=<n>`, and its figures match what the system reports at the same moment: load within 0.5, memory within 3 points (in use = total minus available), disk within 1 point.
2. **The rotator, keeping 20 copies.** The gate starts its own writer, which appends numbered lines as fast as it can and reopens its log on `SIGHUP`, then runs your `rotate.sh app.log 20` ten times. Afterwards every line from the first to the last appears exactly once across `app.log` and its copies.
3. **The rotator, keeping 3 copies.** The same, with `rotate.sh app.log 3`: exactly `app.log.1`, `app.log.2.gz` and `app.log.3.gz` remain, and there's no gap from the oldest kept line onwards.
4. **`shellcheck`** reports nothing for either script.

## Run it

~~~bash
bash gate/run.sh ~/blueprint/machine
~~~

It needs `shellcheck` (`sudo apt install -y shellcheck`, or `brew install shellcheck`) and takes about 10 seconds. It works on Linux and macOS.

## A pass looks like

~~~text
PASS  monitor.sh: load 0.37 (system: 0.37)
PASS  monitor.sh: memory 21% (system: 21%)
PASS  monitor.sh: disk 21% (system: 21%)
PASS  rotate.sh, 10 rotations, keep 20: all 97128 lines kept, none lost or repeated
PASS  rotate.sh, 10 rotations, keep 3: exactly app.log.1, app.log.2.gz, app.log.3.gz, with no gaps
PASS  shellcheck: no warnings
Gate passed: on to Foundations 03.
~~~

## A fail looks like

A rotator that copies and then empties the log:

~~~text
FAIL  rotate.sh, 10 rotations, keep 20: no line lost or repeated
      of 172492 lines written: 178 lost, 0 repeated, first kept line 1
~~~

A monitor that counts `MemFree` as free memory:

~~~text
FAIL  monitor.sh: memory
      you printed 28%; the system reports 21% in use (total minus available)
~~~

An unquoted variable:

~~~text
FAIL  shellcheck: no warnings
      
In /t/unquoted/rotate.sh line 13:
rm -f $log.$keep.gz
      ^--^ SC2086 (info): Double quote to prevent globbing and word splitting.
~~~

The gate was checked both ways: it passes on the lessons' scripts (10 runs in a row) and fails each of the three broken versions above on the right check. The runs are in [evidence/](../evidence/README.md).
