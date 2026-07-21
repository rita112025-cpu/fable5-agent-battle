#!/usr/bin/env bash
set -uo pipefail
OUT="${1:-tests/sandbox/results/final-state.txt}"
mkdir -p "$(dirname "$OUT")"
{
  echo "=== git status ==="
  git status --porcelain
  echo "=== worktrees ==="
  git worktree list
  echo "=== bisect state ==="
  git rev-parse --verify -q BISECT_HEAD || echo "no active bisect"
  echo "=== port ==="
  lsof -i :"${PORT:-7860}" || true
  echo "=== pid files ==="
  find .tmp -type f -name '*.pid' -print 2>/dev/null || true
} > "$OUT"
