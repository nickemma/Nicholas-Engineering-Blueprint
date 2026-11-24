#!/usr/bin/env python3
"""Rebuild the code in the lessons, in order, and check that it works.

The lessons are the only place lesson code lives. Hidden markers (HTML
comments, invisible when the markdown is rendered) tell this script what a
learner types and runs, so it can follow along in a scratch directory:

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

    <!-- continue: ../../01-go-runtime-and-reliable-services -->
    <!-- continue: ../../../2-core/04-rust-foundations into klog -->

file blocks create or replace a file. edit blocks change part of one.
append blocks add to the end of one, after a blank line. run commands execute
in the scratch directory and must succeed; they see BLUEPRINT_ROOT, the
repository's root, so a lesson can run its module's gate on the code it built.
Code blocks without a marker are illustrations and are not checked.

continue replays another module first, for a module that starts from an
earlier one's code; "into DIR" replays it into a subdirectory. The path is
relative to the file the marker is in.

What gets replayed is a "guide":
- a module folder: every lessons/NN-*.md file in it, in name order, as one;
- a single markdown file: a worked problem, worksheet, or optional exercise.
  You can also pass a historical guide explicitly while migrating it.

Usage: python3 scripts/replay_lessons.py [--keep] [--dump] [GUIDE ...]
With no guides, every guide that contains markers is checked, except those
another guide continues from: replaying the later guide replays them too, run
markers included.

--keep  keeps the scratch directory.
--dump  replays nothing: prints every action (continues expanded) so two
        layouts of the same lessons can be compared, e.g. before and after a move.
"""

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Gates resolve from the checkout. Go builds run in scratch trees without
# relying on VCS metadata, and callers can still set an explicit GOFLAGS value.
RUN_ENV = {
    **os.environ,
    "BLUEPRINT_ROOT": str(ROOT),
    "GOFLAGS": f'-buildvcs=false {os.environ.get("GOFLAGS", "")}'.strip(),
}

MARKER = re.compile(r"^<!--\s*(file|edit|append|run|continue):\s*(.+?)\s*-->\s*$")
FENCE = re.compile(r"^(`{3,}|~{3,})")
LESSON = re.compile(r"^\d{2}-.+\.md$")

# Where guides are found when none are named.
MODULE_ROOTS = ("1-foundations", "2-core", "3-tracks")
SINGLE_FILES = (
    "dsa/*/README.md",
    "math/*/README.md",
    "3-tracks/*/deep-dives/*.md",
    "3-tracks/shared-units/*/deep-dives/*.md",
    "2-core/*/deep-dives/*.md",
    "2-core/deep-dives/*/deep-dives/*.md",
    "system-design/classic/*-lab.md",
    "2-core/02-python-runtime-and-honest-measurement/go-benchmark-comparison.md",
    "3-tracks/shared-units/tenancy-and-abuse-control/retention-and-aggregate-privacy.md",
)


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


def lesson_files(guide: Path) -> list[Path]:
    """The markdown files a guide is made of, in order."""
    if guide.is_dir():
        lessons = guide / "lessons"
        if not lessons.is_dir():
            raise GuideError(f"{guide}: a module folder needs a lessons/ folder")
        return sorted(p for p in lessons.iterdir() if LESSON.match(p.name))
    return [guide]


def file_actions(path: Path):
    """Yield (path, line, kind, argument, content) for every marker in one file."""
    lines = path.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        match = MARKER.match(lines[i])
        if not match:
            i += 1
            continue
        kind, arg = match.groups()
        line = i + 1
        try:
            if kind in ("run", "continue"):
                yield path, line, kind, arg, None
                i += 1
            elif kind in ("file", "append"):
                content, i = read_fence(lines, i + 1, line)
                yield path, line, kind, arg, content
            else:
                old, i = read_fence(lines, i + 1, line)
                new, i = read_fence(lines, i, line, allow_text=True)
                yield path, line, kind, arg, (old, new)
        except GuideError as err:
            raise GuideError(f"{path}: {err}") from None


def actions(guide: Path):
    """Yield (path, line, kind, argument, content) for every marker in a guide."""
    for path in lesson_files(guide):
        yield from file_actions(path)


def continue_target(path: Path, arg: str) -> tuple[Path, str]:
    """The guide a continue marker in path points at, and its "into" directory."""
    other, _, into = arg.partition(" into ")
    return (path.parent / other.strip()).resolve(), into.strip()


def replay(guide: Path, workdir: Path, dump=None) -> int:
    """Carry out every action in guide inside workdir. Return how many there were.

    With dump set (a list), record the actions instead of carrying them out.
    """
    steps = 0
    for path, line, kind, arg, content in actions(guide):
        steps += 1
        where = f"{path}:{line}"
        if kind == "continue":
            target, into = continue_target(path, arg)
            if not target.exists():
                raise GuideError(f"{where}: continues from {arg}, which doesn't exist")
            sub = workdir / into if into else workdir
            if dump is not None:
                dump.append(f"continue into {into or '.'}")
            else:
                sub.mkdir(parents=True, exist_ok=True)
            steps += replay(target, sub, dump)
            if dump is not None:
                dump.append(f"end continue into {into or '.'}")
            continue
        if dump is not None:
            digest = hashlib.sha256(repr(content).encode()).hexdigest()[:16] if content else ""
            dump.append(f"{kind}: {arg} {digest}".rstrip())
            continue
        if kind == "file":
            target = workdir / arg
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        elif kind == "append":
            target = workdir / arg
            if not target.is_file():
                raise GuideError(f"{where}: append to {arg}, which doesn't exist yet")
            text = target.read_text(encoding="utf-8").rstrip("\n")
            target.write_text(text + "\n\n" + content, encoding="utf-8")
        elif kind == "edit":
            target = workdir / arg
            if not target.is_file():
                raise GuideError(f"{where}: edit of {arg}, which doesn't exist yet")
            text = target.read_text(encoding="utf-8")
            old, new = content[0].rstrip("\n"), content[1].rstrip("\n")
            if not new.strip() and text.count(old + "\n\n") == 1:
                old += "\n\n"  # a deletion also removes the blank line that followed
            count = text.count(old)
            if count != 1:
                raise GuideError(f"{where}: text to replace appears {count} times in {arg}")
            target.write_text(text.replace(old, new, 1), encoding="utf-8")
        else:
            result = subprocess.run(
                ["bash", "-c", arg], cwd=workdir, capture_output=True, text=True, env=RUN_ENV
            )
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


def find_guides() -> list[Path]:
    """Every guide with markers that no other guide continues from."""
    candidates = []
    for root in MODULE_ROOTS:
        candidates += sorted(p.parent for p in Path(root).glob("**/lessons") if p.is_dir())
    for pattern in SINGLE_FILES:
        candidates += sorted(Path().glob(pattern))
    guides = [g for g in candidates if any(True for _ in actions(g))]
    continued = {
        continue_target(path, arg)[0]
        for g in guides
        for path, _, kind, arg, _ in actions(g)
        if kind == "continue"
    }
    return [g for g in guides if g.resolve() not in continued]


def main(args: list[str]) -> int:
    keep = "--keep" in args
    dump = "--dump" in args
    guides = [Path(a) for a in args if a not in ("--keep", "--dump")]
    if dump:
        for guide in guides:
            out: list[str] = []
            replay(guide.resolve(), Path("."), out)
            print("\n".join(out))
        return 0
    if not guides:
        guides = find_guides()
    results = [check(guide, keep) for guide in guides]
    return 0 if all(results) else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except GuideError as err:
        print(f"FAIL {err}")
        sys.exit(1)
