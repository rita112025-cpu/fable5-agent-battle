#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${1:-$PWD}"
FABLE_ENV_FILE="${FABLE_ENV_FILE:-${TMPDIR:-/tmp}/fable-env-$$.sh}"
CACHE_ROOT="${FABLE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/fable5}"

cd "$PROJECT_DIR"
mkdir -p "$(dirname "$FABLE_ENV_FILE")" "$CACHE_ROOT"
: > "$FABLE_ENV_FILE"

if [[ -f package-lock.json ]]; then
  command -v npm >/dev/null 2>&1 || {
    echo "[ERROR] 缺少 npm" >&2
    exit 2
  }
  npm ci --silent || exit 2
fi

if [[ -f requirements.txt ]]; then
  command -v python3 >/dev/null 2>&1 || {
    echo "[ERROR] 缺少 python3" >&2
    exit 2
  }
  project_key="$(python3 - "$PROJECT_DIR" <<'PY'
import hashlib, os, sys
print(hashlib.sha256(os.path.realpath(sys.argv[1]).encode()).hexdigest()[:12])
PY
)"
  dep_hash="$(python3 - requirements.txt <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"
  venv="$CACHE_ROOT/venvs/${project_key}-${dep_hash}"
  if [[ ! -x "$venv/bin/python" ]]; then
    python3 -m venv "$venv" || exit 2
    "$venv/bin/python" -m pip install -q -r requirements.txt || exit 2
  fi
  printf 'export PATH=%q:$PATH\n' "$venv/bin" >> "$FABLE_ENV_FILE"
fi

echo "$FABLE_ENV_FILE"
