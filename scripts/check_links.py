#!/usr/bin/env python3
"""Check that every relative link in the repository's markdown resolves.

For each link [text](target) or image ![alt](target) outside code blocks,
where target is a relative path (not http:, mailto: and so on):
- the file or folder must exist;
- a #fragment must match a heading in the target markdown file (GitHub's
  rules: lowercase, punctuation dropped, spaces to hyphens, -1, -2 for repeats).

Usage: python3 scripts/check_links.py [FILE.md ...]
With no files, every tracked .md file is checked, except site/ and the templates.
"""

import re
import subprocess
import sys
from functools import cache
from pathlib import Path
from urllib.parse import unquote

LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
EXTERNAL = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
SKIP_DIRS = ("site/", "node_modules/", "scripts/templates/")  # templates hold placeholder links


def prose_lines(path: Path):
    """Yield (line number, text) for lines outside fenced code blocks."""
    fence = None
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        m = FENCE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        yield n, line


def slug(text: str) -> str:
    text = re.sub(r"<[^>]+>", "", text)  # inline HTML
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)  # links keep their text
    text = text.replace("`", "").lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


@cache
def anchors(path: Path) -> frozenset[str]:
    seen: dict[str, int] = {}
    out = set()
    for _, line in prose_lines(path):
        m = HEADING.match(line)
        if not m:
            continue
        s = slug(m.group(2))
        n = seen.get(s, 0)
        seen[s] = n + 1
        out.add(s if n == 0 else f"{s}-{n}")
    for _, line in prose_lines(path):  # explicit <a id="..."> / name anchors
        out.update(re.findall(r'<a\s+(?:id|name)="([^"]+)"', line))
    return frozenset(out)


def strip_code_spans(line: str) -> str:
    return re.sub(r"(`+)(?:(?!\1).)+\1", "", line)


def check(path: Path) -> list[str]:
    problems = []
    for n, line in prose_lines(path):
        for m in LINK.finditer(strip_code_spans(line)):
            target = m.group(1)
            if EXTERNAL.match(target) or target.startswith("//"):
                continue
            file_part, _, fragment = target.partition("#")
            file_part = unquote(file_part)
            dest = (path.parent / file_part).resolve() if file_part else path.resolve()
            if not dest.exists():
                problems.append(f"{path}:{n}: {target}: no such file")
                continue
            if fragment and dest.is_file() and dest.suffix == ".md":
                if unquote(fragment).lower() not in anchors(dest):
                    problems.append(f"{path}:{n}: {target}: no heading #{fragment} in {dest.name}")
    return problems


def tracked_markdown() -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    return [Path(p) for p in sorted(set(out)) if not p.startswith(SKIP_DIRS) and Path(p).is_file()]


def main(args: list[str]) -> int:
    files = [Path(a) for a in args] or tracked_markdown()
    problems = [p for f in files for p in check(f)]
    for p in problems:
        print(p)
    print(f"{len(files)} files, {len(problems)} broken links")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
