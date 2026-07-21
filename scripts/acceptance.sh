#!/usr/bin/env bash
set -uo pipefail

SUITE="${1:-smoke}"
case "$SUITE" in
  smoke|full) ;;
  *) echo "用法: $0 [smoke|full]" >&2; exit 2 ;;
esac

BASE_URL="${BASE_URL:-http://127.0.0.1:${PORT:-7860}}"
HEALTH_URL="${HEALTH_URL:-$BASE_URL/health}"
JSON_OUT="${JSON_OUT:-acceptance-result.json}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-5}"
PROJECT_ACCEPTANCE_SCRIPT="${PROJECT_ACCEPTANCE_SCRIPT:-}"
STARTED=$SECONDS
FAIL=0
TOOL_ERROR=0
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

write_fallback_json() {
  local out="$1" status="$2" error="$3"
  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  printf '{"suite":"%s","execution_status":"%s","failed":1,"checks":[],"error":"%s"}\n' \
    "$SUITE" "$status" "$error" > "$out" 2>/dev/null || true
}

for cmd in curl python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    write_fallback_json "$JSON_OUT" "infrastructure_error" "missing_$cmd"
    echo "[ERROR] 缺少必要工具: $cmd" >&2
    exit 2
  fi
done

record() {
  local name="${1//$'\t'/ }" status="$2" detail="${3//$'\t'/ }"
  name="${name//$'\n'/ }"
  detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$name" "$status" "$detail" >> "$TMP"
}

check_http() {
  local name="$1" expected="$2" url="$3" actual
  actual="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$CHECK_TIMEOUT" "$url" 2>/dev/null)" \
    || actual="ERR"
  if [[ "$actual" == "$expected" ]]; then
    record "$name" pass "http=$actual"
  else
    record "$name" fail "expected=$expected actual=$actual"
    FAIL=1
  fi
}

check_http "health" 200 "$HEALTH_URL"

if [[ -n "$PROJECT_ACCEPTANCE_SCRIPT" ]]; then
  if [[ ! -x "$PROJECT_ACCEPTANCE_SCRIPT" ]]; then
    record "project_acceptance" error "script_not_executable"
    TOOL_ERROR=1
  elif "$PROJECT_ACCEPTANCE_SCRIPT" "$SUITE"; then
    record "project_acceptance" pass ""
  else
    rc=$?
    if [[ "$rc" -eq 1 ]]; then
      record "project_acceptance" fail "exit=1"
      FAIL=1
    else
      record "project_acceptance" error "exit=$rc"
      TOOL_ERROR=1
    fi
  fi
fi

ELAPSED=$((SECONDS - STARTED))
if [[ "$SUITE" == "smoke" && "$ELAPSED" -gt 60 ]]; then
  record "smoke_time_limit" error "elapsed=${ELAPSED}s"
  TOOL_ERROR=1
fi

mkdir -p "$(dirname "$JSON_OUT")" 2>/dev/null || {
  write_fallback_json "${TMPDIR:-/tmp}/fable-acceptance-error.json" \
    "infrastructure_error" "json_parent_unwritable"
  exit 2
}

if ! python3 - "$TMP" "$JSON_OUT" "$SUITE" "$ELAPSED" "$FAIL" "$TOOL_ERROR" <<'PY'
import csv, datetime, json, subprocess, sys
src, out, suite, elapsed, failed, tool_error = sys.argv[1:]
checks = []
with open(src, encoding="utf-8") as f:
    for row in csv.reader(f, delimiter="\t"):
        name, status, detail = (row + ["", "", ""])[:3]
        checks.append({"name": name, "status": status, "detail": detail})

def git(*args):
    p = subprocess.run(["git", *args], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None

data = {
    "suite": suite,
    "execution_status": "infrastructure_error" if int(tool_error) else "completed",
    "failed": int(failed) or int(tool_error),
    "elapsed_seconds": int(elapsed),
    "commit": git("rev-parse", "--short", "HEAD"),
    "timestamp": datetime.datetime.now().astimezone().isoformat(),
    "checks": checks,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY
then
  write_fallback_json "${TMPDIR:-/tmp}/fable-acceptance-error.json" \
    "infrastructure_error" "json_write_failed"
  exit 2
fi

[[ "$TOOL_ERROR" -eq 0 ]] || exit 2
exit "$FAIL"
