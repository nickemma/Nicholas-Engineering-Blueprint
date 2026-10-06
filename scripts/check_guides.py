#!/usr/bin/env python3
"""Build the code in a lesson guide, in order, and check that it works.

The guide is the only place lesson code lives. Hidden markers (HTML comments,
invisible when the markdown is rendered) tell this script what a learner
types and runs, so it can follow along in a scratch directory:

    <!-- file: internal/jobs/job.go -->
    ~~~go
    ...the whole file...
    ~~~

    <!-- edit: internal/jobs/job.go -->
    ~~~go
    ...text to find (must appear exactly once)...
    ~~~
    ~~~go
    ...text to replace it with...
    ~~~

    <!-- append: internal/jobs/job_test.go -->
    ~~~go
    ...text to add at the end of the file...
    ~~~

    <!-- run: go test ./... -->

    <!-- continue: ../01-reliable-service/TEACHING.md -->
    <!-- continue: ../rust-bridge/TEACHING.md into audit -->

file blocks create or replace a file. edit blocks change part of one.
append blocks add to the end of one, after a blank line. continue replays
another guide first (path relative to this guide), for a phase that starts
from an earlier guide's code; "into DIR" replays it into a subdirectory. run
commands execute in the scratch directory and must succeed. Code blocks
without a marker are illustrations and are not checked.

Usage: python3 scripts/check_guides.py [--keep] [GUIDE.md ...]
With no guides, every lessons/*/TEACHING.md that contains markers is checked,
except those another guide continues from: replaying the later guide replays
them too, run markers included.
"""

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

MARKER = re.compile(r"^<!--\s*(file|edit|append|run|continue):\s*(.+?)\s*-->\s*$")
FENCE = re.compile(r"^(`{3,}|~{3,})")


class GuideError(Exception):
    pass


def read_fence(
    lines: list[str], i: int, marker_line: int, allow_text: bool = False
) -> tuple[str, int]:
    """Return the content of the fenced block at or after line i, and the next line.

    Only blank lines may come before the block, unless allow_text is set: an
    edit's replacement block may follow a short phrase such as "to:".
    """
    while i < len(lines) and (not lines[i].strip() or (allow_text and not FENCE.match(lines[i]))):
        if allow_text and MARKER.match(lines[i]):
            break
        i += 1
    opening = FENCE.match(lines[i]) if i < len(lines) else None
    if not opening:
        raise GuideError(f"line {marker_line}: marker is not followed by a code block")
    fence = opening.group(1)
    body = []
    i += 1
    while i < len(lines) and not lines[i].startswith(fence):
        body.append(lines[i])
        i += 1
    if i == len(lines):
        raise GuideError(f"line {marker_line}: code block is never closed")
    return "\n".join(body) + "\n", i + 1


def actions(guide: Path):
    """Yield (line, kind, argument, content) for every marker in the guide."""
    lines = guide.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        match = MARKER.match(lines[i])
        if not match:
            i += 1
            continue
        kind, arg = match.groups()
        line = i + 1
        if kind in ("run", "continue"):
            yield line, kind, arg, None
            i += 1
        elif kind in ("file", "append"):
            content, i = read_fence(lines, i + 1, line)
            yield line, kind, arg, content
        else:
            old, i = read_fence(lines, i + 1, line)
            new, i = read_fence(lines, i, line, allow_text=True)
            yield line, kind, arg, (old, new)


def replay(guide: Path, workdir: Path) -> int:
    """Carry out every action in guide inside workdir. Return how many there were."""
    steps = 0
    for line, kind, arg, content in actions(guide):
        steps += 1
        where = f"{guide}:{line}"
        if kind == "continue":
            # "continue: OTHER.md" replays it here; "continue: OTHER.md into DIR"
            # replays it into a subdirectory.
            other, _, into = arg.partition(" into ")
            target = workdir / into.strip() if into else workdir
            target.mkdir(parents=True, exist_ok=True)
            steps += replay((guide.parent / other.strip()).resolve(), target)
        elif kind == "file":
            path = workdir / arg
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        elif kind == "append":
            path = workdir / arg
            if not path.is_file():
                raise GuideError(f"{where}: append to {arg}, which doesn't exist yet")
            text = path.read_text(encoding="utf-8").rstrip("\n")
            path.write_text(text + "\n\n" + content, encoding="utf-8")
        elif kind == "edit":
            path = workdir / arg
            if not path.is_file():
                raise GuideError(f"{where}: edit of {arg}, which doesn't exist yet")
            text = path.read_text(encoding="utf-8")
            old, new = content[0].rstrip("\n"), content[1].rstrip("\n")
            if not new.strip() and text.count(old + "\n\n") == 1:
                old += "\n\n"  # a deletion also removes the blank line that followed
            count = text.count(old)
            if count != 1:
                raise GuideError(f"{where}: text to replace appears {count} times in {arg}")
            path.write_text(text.replace(old, new, 1), encoding="utf-8")
        else:
            result = subprocess.run(["bash", "-c", arg], cwd=workdir, capture_output=True, text=True)
            if result.returncode != 0:
                output = (result.stdout + result.stderr).strip()[-3000:]
                output = output or f"(no output; exit status {result.returncode})"
                raise GuideError(f"{where}: `{arg}` failed:\n{output}")
    return steps


def check(guide: Path, keep: bool) -> bool:
    workdir = Path(tempfile.mkdtemp(prefix="guide-"))
    try:
        steps = replay(guide.resolve(), workdir)
        print(f"ok   {guide} ({steps} steps)")
        if keep:
            print(f"     scratch directory kept at {workdir}")
        return True
    except GuideError as err:
        print(f"FAIL {err}")
        print(f"     scratch directory kept at {workdir}")
        keep = True
        return False
    finally:
        if not keep:
            shutil.rmtree(workdir, ignore_errors=True)


def main(args: list[str]) -> int:
    keep = "--keep" in args
    guides = [Path(a) for a in args if a != "--keep"]
    if not guides:
        guides = [p for p in sorted(Path("lessons").glob("*/TEACHING.md")) if any(actions(p))]
        continued = {
            (p.parent / arg.partition(" into ")[0].strip()).resolve()
            for p in guides
            for _, kind, arg, _ in actions(p)
            if kind == "continue"
        }
        guides = [p for p in guides if p.resolve() not in continued]
    results = [check(guide, keep) for guide in guides]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
