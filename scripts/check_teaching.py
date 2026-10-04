#!/usr/bin/env python3
"""Check that code shown in lesson markdown matches the runnable step files.

Put a marker on the line before a fenced code block:

    <!-- file: steps/02-first-server/main.go -->
    ~~~go
    ...the whole file...
    ~~~

    <!-- excerpt: steps/05-tests/main_test.go -->
    ~~~go
    ...a contiguous part of the file...
    ~~~

"file" requires the block to equal the file. "excerpt" requires the block to
appear in the file exactly as shown. Paths are relative to the markdown file.
Blocks without a marker are not checked, so use markers on every block a
learner is told to type or copy.

Usage: python3 scripts/check_teaching.py [markdown files or directories...]
With no arguments it checks every .md file under lessons/.
"""

import re
import sys
from pathlib import Path

MARKER = re.compile(r"^<!--\s*(file|excerpt):\s*(\S+)\s*-->\s*$")
FENCE = re.compile(r"^(`{3,}|~{3,})")


def blocks(markdown: Path):
    """Yield (kind, target path, block text, marker line number)."""
    lines = markdown.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        match = MARKER.match(lines[i])
        if not match:
            i += 1
            continue
        kind, target = match.groups()
        marker_line = i + 1
        i += 1
        while i < len(lines) and not lines[i].strip():
            i += 1
        opening = FENCE.match(lines[i]) if i < len(lines) else None
        if not opening:
            yield kind, target, None, marker_line
            continue
        fence = opening.group(1)
        i += 1
        body = []
        while i < len(lines) and not lines[i].startswith(fence):
            body.append(lines[i])
            i += 1
        i += 1
        yield kind, target, "\n".join(body) + "\n", marker_line


def check(markdown: Path) -> list[str]:
    errors = []
    for kind, target, text, line in blocks(markdown):
        where = f"{markdown}:{line}"
        if text is None:
            errors.append(f"{where}: marker for {target} is not followed by a code block")
            continue
        path = markdown.parent / target
        if not path.is_file():
            errors.append(f"{where}: {target} does not exist")
            continue
        actual = path.read_text(encoding="utf-8")
        if kind == "file" and text.rstrip("\n") != actual.rstrip("\n"):
            errors.append(f"{where}: block differs from {target}")
        if kind == "excerpt" and text.rstrip("\n") not in actual:
            errors.append(f"{where}: block is not an exact excerpt of {target}")
    return errors


def main(args: list[str]) -> int:
    roots = [Path(a) for a in args] or [Path("lessons")]
    skip = {".venv", "node_modules", "target", "practice"}
    files = []
    for root in roots:
        if root.is_dir():
            files.extend(p for p in sorted(root.rglob("*.md")) if not skip & set(p.parts))
        else:
            files.append(root)

    errors = [error for markdown in files for error in check(markdown)]
    checked = sum(1 for markdown in files for _ in blocks(markdown))
    for error in errors:
        print(error)
    print(f"checked {checked} annotated code blocks in {len(files)} files: {len(errors)} problems")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
