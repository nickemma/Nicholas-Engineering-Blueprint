"""Black-box checks for the klog CLI and its on-disk recovery."""

import fcntl
from pathlib import Path
import select
import signal
import subprocess
import sys
from tempfile import TemporaryDirectory


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class Gate:
    def __init__(self, binary, work):
        self.binary = binary
        self.work = work

    def run(self, *args, success=True):
        result = subprocess.run(
            [self.binary, *args], capture_output=True, text=True, timeout=10
        )
        require(
            (result.returncode == 0) is success,
            f"{args}: exit {result.returncode}, out={result.stdout!r}, err={result.stderr!r}",
        )
        return result.stdout if success else result.stderr

    def check(self):
        baseline = self.work / "baseline.log"
        self.run("append", baseline, "first")
        prefix = baseline.read_bytes()
        self.run("append", baseline, "second")
        complete = baseline.read_bytes()
        second = complete[len(prefix):]
        require(
            self.run("cat", baseline) == "0: first\n1: second\n",
            "both complete records should be readable",
        )
        require(self.run("check", baseline) == "2 records, all checksums valid\n",
                "a full final frame should not be removed")

        for cut in range(len(second)):
            test = self.work / "cut.log"
            original = prefix + second[:cut]
            test.write_bytes(original)
            if cut:
                require("incomplete record" in self.run("cat", test, success=False),
                        f"cat must flag the incomplete suffix at cut {cut}")
                require(test.read_bytes() == original, "cat must leave the file unchanged")
            report = self.run("check", test)
            expected = f"recovered: removed {cut} torn bytes\n" if cut else ""
            require(report == expected + "1 records, all checksums valid\n",
                    f"wrong recovery report at cut {cut}: {report!r}")
            require(test.read_bytes() == prefix, f"wrong bytes after cut {cut}")
        print(f"all {len(second)} incomplete cuts preserved the committed prefix")

        for offset in (0, 12, len(prefix), len(prefix) + 4, len(prefix) + 8, len(prefix) + 12):
            damaged = bytearray(complete)
            damaged[offset] ^= 1
            test = self.work / "corrupt.log"
            test.write_bytes(damaged)
            for verb, rest in (("check", ()), ("cat", ()), ("append", ("later",))):
                error = self.run(verb, test, *rest, success=False)
                require("checksum mismatch" in error, f"{verb} should report corrupt bytes at {offset}")
                require(test.read_bytes() == damaged, f"{verb} rewrote corrupt bytes at {offset}")
        print("complete header and payload damage was refused without changing any bytes")

        with baseline.open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run("append", baseline, "contender", success=False)
            require(baseline.read_bytes() == complete, "a competing writer changed the log")
        print("a competing writer could not append while the file was locked")

        killed = self.work / "killed.log"
        killed.write_bytes(prefix)
        self.interrupt(killed, second[:15])
        require(killed.read_bytes() == prefix + second[:15], "the writer did not leave the expected tail")
        self.run("append", killed, "after restart")
        require(self.run("cat", killed) == "0: first\n1: after restart\n",
                "append after SIGKILL did not recover and keep the old record")
        print("SIGKILL left a torn append; reopening recovered it and accepted new data")

    @staticmethod
    def interrupt(path, suffix):
        child_code = """import os, signal, sys
with open(sys.argv[1], "ab", buffering=0) as file:
    file.write(bytes.fromhex(sys.argv[2]))
    os.fsync(file.fileno())
    print("ready", flush=True)
    signal.pause()
"""
        child = subprocess.Popen(
            [sys.executable, "-c", child_code, str(path), suffix.hex()],
            stdout=subprocess.PIPE, text=True,
        )
        try:
            ready, _, _ = select.select([child.stdout], [], [], 5)
            require(ready and child.stdout.readline() == "ready\n", "partial writer was not ready")
        finally:
            child.kill()
            child.wait(timeout=5)
            child.stdout.close()
        require(child.returncode == -signal.SIGKILL, "the writer did not exit via SIGKILL")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify.py /path/to/klog")
    with TemporaryDirectory(prefix="klog-gate-") as directory:
        Gate(Path(sys.argv[1]).resolve(), Path(directory)).check()


if __name__ == "__main__":
    main()
