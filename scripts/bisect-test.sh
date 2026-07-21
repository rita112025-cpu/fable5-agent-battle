#!/usr/bin/env bash
set -uo pipefail

PROJECT_DIR="${1:?缺少 project dir}"
HARNESS="${2:?缺少 harness dir}"
TARGET="${BISECT_TARGET:-functional}"
BASE_DIR="${FABLE_RUN_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/fable-bisect-test.XXXXXX")}"
STATE_DIR="$BASE_DIR/state"
ENV_FILE="$BASE_DIR/env.sh"
LOG_FILE="$BASE_DIR/service.log"
JSON_OUT="$BASE_DIR/result.json"

mkdir -p "$STATE_DIR"
cleanup() {
  STATE_DIR="$STATE_DIR" PORT="${PORT:-7860}" \
    bash "$HARNESS/stop-test-env.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM HUP

cd "$PROJECT_DIR" || exit 125
cleanup

if ! FABLE_ENV_FILE="$ENV_FILE" \
     bash "$HARNESS/prepare-test-deps.sh" "$PROJECT_DIR" >/dev/null; then
  echo "[SKIP] 依賴準備失敗"
  exit 125
fi
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

if ! STATE_DIR="$STATE_DIR" LOG_FILE="$LOG_FILE" \
     bash "$HARNESS/start-test-env.sh" >/dev/null 2>&1; then
  if [[ "$TARGET" == "startup" ]]; then exit 1; fi
  echo "[SKIP] 服務無法啟動"
  exit 125
fi

if JSON_OUT="$JSON_OUT" \
   bash "$HARNESS/acceptance.sh" smoke >/dev/null 2>&1; then
  exit 0
fi
rc=$?
case "$rc" in
  1) exit 1 ;;
  *) exit 125 ;;
esac
