#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${PORT:-7860}"
STATE_DIR="${STATE_DIR:-.tmp}"
PID_FILE="$STATE_DIR/service-$PORT.pid"
TOKEN_FILE="$STATE_DIR/service-$PORT.start"

command -v ps >/dev/null 2>&1 || {
  echo "[ERROR] 缺少必要工具: ps" >&2
  exit 2
}

[[ -f "$PID_FILE" ]] || exit 0

pid="$(cat "$PID_FILE" 2>/dev/null || true)"
recorded="$(cat "$TOKEN_FILE" 2>/dev/null || true)"

if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] PID file 無效" >&2
  exit 2
fi

if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$PID_FILE" "$TOKEN_FILE"
  exit 0
fi

current="$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -z "$recorded" || "$current" != "$recorded" ]]; then
  echo "[ERROR] PID token 不符，拒絕終止未知程序: $pid" >&2
  exit 2
fi

kill "$pid" 2>/dev/null || true
for _ in {1..10}; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
rm -f "$PID_FILE" "$TOKEN_FILE"
exit 0
