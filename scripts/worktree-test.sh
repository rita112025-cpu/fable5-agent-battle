#!/usr/bin/env bash
set -uo pipefail

WT="${1:?用法: $0 <worktree> <battle-dir> <a|b>}"
OUT="${2:?缺少 battle dir}"
TAG="${3:?缺少 tag}"
case "$TAG" in a|b) ;; *)
  echo "[ERROR] tag 必須是 a 或 b" >&2
  exit 2
esac

ROOT="$(pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WT="$(cd "$WT" 2>/dev/null && pwd)" || {
  printf '{"execution_status":"infrastructure_error","failed":1,"checks":[],"error":"worktree_missing"}\n' \
    > "$OUT/result-$TAG.json"
  echo "RESULT: $TAG infrastructure_error"
  exit 0
}

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fable-worktree-${TAG}.XXXXXX")"
STATE_DIR="$RUN_DIR/state"
ENV_FILE="$RUN_DIR/env.sh"
RESULT="$OUT/result-$TAG.json"
LOG="$OUT/service-$TAG.log"
PATCH="$OUT/patch-$TAG.diff"
BASE_COMMIT="${BASE_COMMIT:-$(git -C "$WT" rev-parse HEAD 2>/dev/null)}"

write_error() {
  local error="$1"
  python3 - "$RESULT" "$TAG" "$error" <<'PY'
import datetime, json, sys
out, tag, error = sys.argv[1:]
data = {
  "candidate": tag,
  "execution_status": "infrastructure_error",
  "failed": 1,
  "checks": [],
  "error": error,
  "timestamp": datetime.datetime.now().astimezone().isoformat()
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY
}

cleanup() {
  STATE_DIR="$STATE_DIR" PORT="${PORT:-7860}" \
    bash "$ROOT/scripts/stop-test-env.sh" >/dev/null 2>&1 || true
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT INT TERM HUP

if [[ "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" != "$BASE_COMMIT" ]]; then
  write_error "candidate_created_commit"
  echo "RESULT: $TAG invalid_candidate"
  exit 0
fi

git -C "$WT" add -A
git -C "$WT" diff --cached --check >/dev/null 2>&1 || {
  write_error "diff_check_failed"
  echo "RESULT: $TAG invalid_candidate"
  exit 0
}
git -C "$WT" diff --cached --binary --full-index HEAD > "$PATCH"
if [[ ! -s "$PATCH" ]]; then
  write_error "empty_patch"
  echo "RESULT: $TAG invalid_candidate"
  exit 0
fi

CHECK_WT="$RUN_DIR/check"
if ! git -C "$WT" worktree add --detach "$CHECK_WT" HEAD >/dev/null 2>&1; then
  write_error "patch_check_worktree_failed"
  echo "RESULT: $TAG infrastructure_error"
  exit 0
fi
if ! git -C "$CHECK_WT" apply --check "$PATCH" >/dev/null 2>&1; then
  git -C "$WT" worktree remove --force "$CHECK_WT" >/dev/null 2>&1 || true
  write_error "patch_not_applicable"
  echo "RESULT: $TAG invalid_candidate"
  exit 0
fi
git -C "$WT" worktree remove --force "$CHECK_WT" >/dev/null 2>&1 || true

if ! FABLE_ENV_FILE="$ENV_FILE" \
     bash "$ROOT/scripts/prepare-test-deps.sh" "$WT" >/dev/null 2>&1; then
  write_error "dependency_setup_failed"
  echo "RESULT: $TAG infrastructure_error"
  exit 0
fi
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

cd "$WT" || {
  write_error "worktree_cd_failed"
  echo "RESULT: $TAG infrastructure_error"
  exit 0
}

if ! STATE_DIR="$STATE_DIR" LOG_FILE="$LOG" \
     bash "$ROOT/scripts/start-test-env.sh" >/dev/null 2>&1; then
  write_error "startup_failed"
  echo "RESULT: $TAG startup_failed"
  exit 0
fi

if JSON_OUT="$RESULT" \
   bash "$ROOT/scripts/acceptance.sh" smoke >/dev/null 2>&1; then
  rc=0
else
  rc=$?
fi

echo "RESULT: $TAG exit=$rc"
exit 0
