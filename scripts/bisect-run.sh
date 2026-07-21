#!/usr/bin/env bash
set -Eeuo pipefail

GOOD="${1:?用法: $0 <good> [bad] [functional|startup]}"
BAD="${2:-HEAD}"
TARGET="${3:-functional}"
case "$TARGET" in functional|startup) ;; *)
  echo "[ERROR] target 必須是 functional 或 startup" >&2
  exit 2
esac

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "[ERROR] 不在 Git repo" >&2
  exit 2
}
cd "$PROJECT_DIR"

[[ -z "$(git status --porcelain)" ]] || {
  echo "[ERROR] 工作區不乾淨" >&2
  exit 2
}

if git rev-parse --verify -q BISECT_HEAD >/dev/null; then
  echo "[ERROR] 已存在進行中的 git bisect" >&2
  exit 2
fi

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fable-bisect.XXXXXX")"
HARNESS="$RUN_DIR/harness"
mkdir -p "$HARNESS"
cp scripts/{acceptance,start-test-env,stop-test-env,prepare-test-deps,bisect-test}.sh "$HARNESS/"

BISECT_STARTED=0
cleanup() {
  if [[ "$BISECT_STARTED" -eq 1 ]]; then
    git -C "$PROJECT_DIR" bisect reset >/dev/null 2>&1 || true
  fi
  [[ "${KEEP_RUN_DIR:-0}" == "1" ]] || rm -rf "$RUN_DIR"
}
trap cleanup EXIT INT TERM HUP

git bisect start
BISECT_STARTED=1
git bisect bad "$BAD"
git bisect good "$GOOD"
git bisect run env \
  BISECT_TARGET="$TARGET" \
  FABLE_RUN_DIR="$RUN_DIR" \
  bash "$HARNESS/bisect-test.sh" "$PROJECT_DIR" "$HARNESS"
