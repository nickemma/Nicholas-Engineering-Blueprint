#!/usr/bin/env bash
set -euo pipefail
cd "${1:-.}"
uv sync --locked
uv run --locked python -m unittest discover -s tests -v
