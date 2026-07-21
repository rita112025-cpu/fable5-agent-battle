#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${PORT:-7860}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:$PORT/health}"
STATE_DIR="${STATE_DIR:-.tmp}"
PID_FILE="$STATE_DIR/service-$PORT.pid"
TOKEN_FILE="$STATE_DIR/service-$PORT.start"
LOG_FILE="${LOG_FILE:-$STATE_DIR/service-$PORT.log}"
START_COMMAND="${START_COMMAND:-}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] 缺少必要工具: $1" >&2
    exit 2
  }
}
for cmd in curl lsof ps; do require "$cmd"; done

[[ -n "$START_COMMAND" ]] || {
  echo "[ERROR] 必須設定 START_COMMAND" >&2
  exit 2
}

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

process_token() {
  ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

listener_pids() {
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u
}

health_ok() {
  curl -sf --connect-timeout 1 --max-time 2 "$HEALTH_URL" >/dev/null 2>&1
}

stop_owned() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  for _ in {1..10}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  kill -9 "$pid" 2>/dev/null || true
}

if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  recorded="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    current="$(process_token "$pid")"
    if [[ -z "$recorded" || "$current" != "$recorded" ]]; then
      echo "[ERROR] PID 已被其他程序重用，拒絕自動終止: $pid" >&2
      exit 2
    fi
    if listener_pids | grep -qx "$pid" && health_ok; then
      echo "[OK] 服務已就緒，重用 PID $pid"
      exit 0
    fi
    stop_owned "$pid"
  fi
  rm -f "$PID_FILE" "$TOKEN_FILE"
fi

unknown="$(listener_pids || true)"
if [[ -n "$unknown" ]]; then
  echo "[ERROR] Port $PORT 被未知程序占用: $unknown" >&2
  exit 2
fi

: > "$LOG_FILE"
nohup bash -lc "exec $START_COMMAND" >> "$LOG_FILE" 2>&1 &
pid=$!
echo "$pid" > "$PID_FILE"

for _ in {1..20}; do
  token="$(process_token "$pid")"
  if [[ -n "$token" ]]; then
    echo "$token" > "$TOKEN_FILE"
    break
  fi
  sleep 0.1
done

deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE" "$TOKEN_FILE"
    echo "[ERROR] 服務程序提前結束" >&2
    exit 1
  fi
  if listener_pids | grep -qx "$pid" && health_ok; then
    echo "[OK] 服務已就緒，PID $pid"
    exit 0
  fi
  sleep 1
done

stop_owned "$pid"
rm -f "$PID_FILE" "$TOKEN_FILE"
echo "[ERROR] 服務 30 秒內未就緒" >&2
exit 1
