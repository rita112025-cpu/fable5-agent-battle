#!/usr/bin/env bash
# FABLE5 引導式入口(唯一使用者入口)
#
# 原則:能由命令查出的,不問人;能由程式執行的,不叫人手動做。
# 使用者只需處理當前步驟,不必先讀 CORE_WORKFLOW.md。
#
# 用法:
#   bash scripts/fable.sh                 # 狀態感知引導(預設)
#   bash scripts/fable.sh check           # [1/5] 前置檢查
#   bash scripts/fable.sh init "<任務>"   # [2/5] 建立 Battle 與候選 worktree
#   bash scripts/fable.sh test <id>       # [4/5] 候選測試(A 敗仍測 B)
#   bash scripts/fable.sh verify <id>     # [5/5] 裁決前證據檢查
#   bash scripts/fable.sh cleanup <id>    # 收尾:worktree/PID/final-state
#   bash scripts/fable.sh status          # 系統狀態總覽
#   bash scripts/fable.sh resume          # 偵測未完成 Battle 並指出下一步
#   bash scripts/fable.sh bisect <good> [bad] [functional|startup]
#   加 --verbose 顯示實際命令、路徑與 exit code(漸進揭露)
#
# exit: 0=成功  1=功能失敗  2=環境/輸入錯誤
set -uo pipefail

# ── 定位與共用 ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

VERBOSE="${FABLE_VERBOSE:-0}"
ARGS=()
for a in "$@"; do
  case "$a" in
    --verbose|--debug) VERBOSE=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]:-}"

PORT="${PORT:-7860}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:$PORT/health}"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
no()   { printf '  ✗ %s\n' "$*"; }
vlog() { [[ "$VERBOSE" == "1" ]] && printf '    · %s\n' "$*"; return 0; }

# 可行動錯誤區塊:狀態/原因/需要處理/重試方式/未執行事項
FIX_ITEMS=()
SKIP_ITEMS=()
fail_and_exit() {
  local stage="$1" retry="$2"
  say ""
  say "需要處理:"
  local i; for i in "${FIX_ITEMS[@]}"; do say "  - $i"; done
  if [[ "${#SKIP_ITEMS[@]}" -gt 0 ]]; then
    say ""
    say "系統未執行(問題修好前不會做):"
    for i in "${SKIP_ITEMS[@]}"; do say "  - $i"; done
  fi
  say ""
  say "處理完成後執行:"
  say "  $retry"
  exit 2
}

json_get() { # json_get <file> <key>
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        print(json.load(f).get(sys.argv[2], ""))
except Exception:
    pass
PY
}

json_valid() { python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }

port_pids() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u | tr '\n' ' '; }

battle_dir() { printf 'battles/%s' "$1"; }
wt_a() { printf '.worktrees/%s-a' "$1"; }
wt_b() { printf '.worktrees/%s-b' "$1"; }

incomplete_battles() { # 有 context.json 但無 judgment.md 的 battle
  local d
  for d in battles/*/; do
    [[ -f "$d/context.json" && ! -f "$d/judgment.md" ]] || continue
    basename "$d"
  done 2>/dev/null
}

# ── [1/5] 前置檢查 ────────────────────────────────────────────
cmd_check() {
  say "[1/5] 前置檢查"
  FIX_ITEMS=(); SKIP_ITEMS=("未建立 Battle" "未建立 worktree" "未啟動任何服務" "未終止任何程序")
  local pass=1 c

  for c in git curl lsof ps python3; do
    if command -v "$c" >/dev/null 2>&1; then
      vlog "工具 $c: $(command -v "$c")"
    else
      no "缺少必要工具: $c"
      FIX_ITEMS+=("安裝 $c(Ubuntu: sudo apt install $c)")
      pass=0
    fi
  done
  [[ "$pass" -eq 1 ]] && ok "必要工具齊備(git curl lsof ps python3)"

  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    ok "位於 Git repo:$(git rev-parse --show-toplevel)"
  else
    no "不在 Git repo 內"
    FIX_ITEMS+=("在專案根目錄執行,或先 git init 並完成第一個 commit")
    pass=0
  fi

  if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
    ok "Git 工作區乾淨"
  else
    no "Git 工作區不乾淨"
    FIX_ITEMS+=("commit 或 stash 目前變更;上一場 Battle 證據請先封存 commit")
    pass=0
  fi

  if git rev-parse --verify -q BISECT_HEAD >/dev/null 2>&1; then
    no "存在進行中的 git bisect session"
    FIX_ITEMS+=("執行 git bisect reset")
    pass=0
  else
    ok "無進行中的 bisect session"
  fi

  if [[ -n "${START_COMMAND:-}" ]]; then
    ok "START_COMMAND 已設定"
    vlog "START_COMMAND=$START_COMMAND"
  else
    no "缺少 START_COMMAND(服務啟動指令)"
    FIX_ITEMS+=('設定啟動指令,例如: export START_COMMAND="npm run start"')
    pass=0
  fi
  vlog "PORT=$PORT  HEALTH_URL=$HEALTH_URL"

  local occupied=""
  if ! command -v lsof >/dev/null 2>&1; then
    no "無法檢查 Port $PORT(缺 lsof)"
    pass=0
  elif occupied="$(port_pids)"; [[ -n "$occupied" ]]; then
    local own_pid=""
    [[ -f ".tmp/service-$PORT.pid" ]] && own_pid="$(cat ".tmp/service-$PORT.pid" 2>/dev/null)"
    if [[ -n "$own_pid" && " $occupied" == *" $own_pid "* ]]; then
      ok "Port $PORT 由本系統既有服務占用(PID $own_pid,start 會重用)"
    else
      no "Port $PORT 被未知程序占用:PID $occupied"
      FIX_ITEMS+=("停止 PID $occupied,或改用其他 Port(export PORT=<另一個>)。FABLE5 不會自動終止未知程序")
      pass=0
    fi
  else
    ok "Port $PORT 未被占用"
  fi

  local s bad_syntax=0
  for s in "$SCRIPT_DIR"/*.sh; do
    if ! bash -n "$s" 2>/dev/null; then
      no "腳本語法錯誤: $s"
      FIX_ITEMS+=("修正 $s(bash -n 檢查)")
      bad_syntax=1; pass=0
    fi
  done
  [[ "$bad_syntax" -eq 0 ]] && ok "scripts/*.sh 語法全部通過"

  if [[ "$pass" -ne 1 ]]; then
    fail_and_exit "check" "bash scripts/fable.sh check"
  fi

  say ""
  say "前置檢查全部通過。"
  next_hint
  return 0
}

next_hint() {
  local pending; pending="$(incomplete_battles | tail -1)"
  say ""
  say "下一步:"
  if [[ -n "$pending" ]]; then
    say "  偵測到未完成 Battle:$pending"
    say "  執行: bash scripts/fable.sh resume"
  else
    say '  建立新 Battle: bash scripts/fable.sh init "<一句話任務描述>"'
    say "  (完成後系統會建立候選 worktree,並指示如何進入提案與實作)"
  fi
}

# ── [2/5] 建立 Battle ─────────────────────────────────────────
cmd_init() {
  local task="${1:-}"
  if [[ -z "$task" ]]; then
    FIX_ITEMS=('提供任務描述,例如: bash scripts/fable.sh init "修復 /api/history 回 404"')
    SKIP_ITEMS=("未建立任何目錄或 worktree")
    say "[2/5] 建立候選"
    no "缺少任務描述"
    fail_and_exit init 'bash scripts/fable.sh init "<任務描述>"'
  fi

  # 前置未過就不往下(靜默重跑 check 的關鍵項)
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]] \
     || git rev-parse --verify -q BISECT_HEAD >/dev/null 2>&1 \
     || ! git rev-parse HEAD >/dev/null 2>&1; then
    say "[2/5] 建立候選"
    no "前置條件未滿足"
    FIX_ITEMS=("先執行 bash scripts/fable.sh check,依提示處理")
    SKIP_ITEMS=("未建立 Battle 與 worktree")
    fail_and_exit init "bash scripts/fable.sh check"
  fi

  say "[2/5] 建立候選"
  mkdir -p battles .worktrees
  local day seq id
  day="$(date +%Y%m%d)"; seq=1
  until mkdir "battles/${day}-$(printf '%02d' "$seq")" 2>/dev/null; do
    seq=$((seq + 1))
    if [[ "$seq" -gt 99 ]]; then
      no "無法建立 Battle 目錄(當日已達 99 場?)"
      FIX_ITEMS=("檢查 battles/ 目錄狀態")
      SKIP_ITEMS=("未建立 worktree")
      fail_and_exit init "bash scripts/fable.sh init \"$task\""
    fi
  done
  id="${day}-$(printf '%02d' "$seq")"
  local dir; dir="$(battle_dir "$id")"
  local base branch
  base="$(git rev-parse HEAD)"
  branch="$(git rev-parse --abbrev-ref HEAD)"

  printf '%s\n' "$task" > "$dir/task.md"
  python3 - "$dir/context.json" "$id" "$base" "$branch" "$PORT" <<'PY'
import datetime, json, sys
out, bid, base, branch, port = sys.argv[1:]
json.dump({
  "battle_id": bid,
  "base_commit": base,
  "branch": branch,
  "port": int(port),
  "started_at": datetime.datetime.now().astimezone().isoformat(),
  "candidate_a_valid": None,
  "candidate_b_valid": None,
}, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  ok "Battle 目錄:$dir"
  ok "Base commit:${base:0:8}(A、B 鎖定同一 base)"

  local fail=0
  git worktree add --detach "$(wt_a "$id")" "$base" >/dev/null 2>&1 \
    && ok "Engineer A worktree:$(wt_a "$id")" || { no "A worktree 建立失敗"; fail=1; }
  git worktree add --detach "$(wt_b "$id")" "$base" >/dev/null 2>&1 \
    && ok "Engineer B worktree:$(wt_b "$id")" || { no "B worktree 建立失敗"; fail=1; }
  if [[ "$fail" -eq 1 ]]; then
    git worktree remove --force "$(wt_a "$id")" >/dev/null 2>&1 || true
    git worktree remove --force "$(wt_b "$id")" >/dev/null 2>&1 || true
    git worktree prune >/dev/null 2>&1 || true
    FIX_ITEMS=("檢查 .worktrees/ 殘留:git worktree list;必要時 git worktree prune")
    SKIP_ITEMS=("Battle 目錄已建立($dir),worktree 已回滾")
    fail_and_exit init "bash scripts/fable.sh init \"$task\""
  fi

  say ""
  say "完成後會發生什麼:"
  say "  [3/5] 提案與實作由 Claude Code 的 /battle 指令接手——"
  say "  A、B 各自提案(不寫檔)→ 一輪交叉審查 → 各自只在自己的"
  say "  worktree 內實作(不得 commit)。"
  say ""
  say "下一步:"
  say "  在 Claude Code 執行: /battle $id"
  say "  (實作完成後,/battle 會呼叫: bash scripts/fable.sh test $id)"
}

# ── [4/5] 候選測試 ────────────────────────────────────────────
cmd_test() {
  local id="${1:-}"
  local dir; dir="$(battle_dir "$id")"
  say "[4/5] 候選測試"
  if [[ -z "$id" || ! -f "$dir/context.json" ]]; then
    no "找不到 Battle:${id:-<未提供>}"
    FIX_ITEMS=("確認 ID:ls battles/;或先 bash scripts/fable.sh init")
    SKIP_ITEMS=("未執行任何測試")
    fail_and_exit test "bash scripts/fable.sh test <battle_id>"
  fi
  local base; base="$(json_get "$dir/context.json" base_commit)"
  local missing=0 w
  for w in "$(wt_a "$id")" "$(wt_b "$id")"; do
    [[ -d "$w" ]] || { no "worktree 不存在:$w"; missing=1; }
  done
  if [[ "$missing" -eq 1 ]]; then
    FIX_ITEMS=("worktree 已被清理或未建立;若要重測,重新 init 一場新 Battle")
    SKIP_ITEMS=("未執行任何測試")
    fail_and_exit test "bash scripts/fable.sh resume"
  fi

  say "  循序測試(共用 Port $PORT;A 失敗不會阻止 B)"
  local line_a line_b
  line_a="$(BASE_COMMIT="$base" bash "$SCRIPT_DIR/worktree-test.sh" "$(wt_a "$id")" "$dir" a 2>/dev/null | tail -1)"
  vlog "$line_a"
  line_b="$(BASE_COMMIT="$base" bash "$SCRIPT_DIR/worktree-test.sh" "$(wt_b "$id")" "$dir" b 2>/dev/null | tail -1)"
  vlog "$line_b"

  local t
  for t in a b; do
    local rj="$dir/result-$t.json"
    if [[ -f "$rj" ]] && json_valid "$rj"; then
      local es fl
      es="$(json_get "$rj" execution_status)"; fl="$(json_get "$rj" failed)"
      case "$es" in
        completed)
          if [[ "$fl" == "0" ]]; then ok "候選 ${t^^}:驗收通過"
          else no "候選 ${t^^}:驗收失敗(細節見 $rj 與 service-$t.log)"; fi ;;
        infrastructure_error)
          no "候選 ${t^^}:基礎設施錯誤($(json_get "$rj" error))——非候選之過,修好可重測" ;;
        *)  no "候選 ${t^^}:狀態 $es($(json_get "$rj" error))" ;;
      esac
      vlog "result: $rj"
    else
      no "候選 ${t^^}:缺少合法 result-$t.json"
    fi
  done

  say ""
  say "完成後會發生什麼:"
  say "  兩份 result JSON、patch 與 service log 已落在 $dir/,"
  say "  將作為 Judge 唯一的證據來源(AI 的文字不是證據)。"
  say ""
  say "下一步:"
  say "  bash scripts/fable.sh verify $id"
}

# ── [5/5] 裁決前證據檢查 ──────────────────────────────────────
cmd_verify() {
  local id="${1:-}"
  local dir; dir="$(battle_dir "$id")"
  say "[5/5] 裁決前證據檢查"
  if [[ -z "$id" || ! -d "$dir" ]]; then
    no "找不到 Battle:${id:-<未提供>}"
    FIX_ITEMS=("確認 ID:ls battles/")
    SKIP_ITEMS=("未進行任何裁決")
    fail_and_exit verify "bash scripts/fable.sh verify <battle_id>"
  fi

  FIX_ITEMS=(); SKIP_ITEMS=("Judge 尚未被呼叫" "未套用任何 patch")
  local pass=1 f
  for f in task.md context.json proposal-a.md proposal-b.md \
           critique-a.md critique-b.md patch-a.diff patch-b.diff \
           result-a.json result-b.json service-a.log service-b.log; do
    if [[ -f "$dir/$f" ]]; then vlog "有 $f"
    else no "缺少 $dir/$f"; FIX_ITEMS+=("補齊 $f(缺提案/審查→回 /battle;缺 result→fable.sh test $id)"); pass=0
    fi
  done
  [[ "$pass" -eq 1 ]] && ok "最小證據包 12 檔齊全"

  for f in context.json result-a.json result-b.json; do
    [[ -f "$dir/$f" ]] || continue
    if json_valid "$dir/$f"; then vlog "$f JSON 合法"
    else no "$f 不是合法 JSON"; FIX_ITEMS+=("重跑 fable.sh test $id 產生合法 $f"); pass=0
    fi
  done
  [[ "$pass" -eq 1 ]] && ok "JSON 全部合法"

  local t viol=0
  for t in a b; do
    [[ -s "$dir/patch-$t.diff" ]] || continue
    if grep -Eq '^diff --git a/(CLAUDE\.md|CORE_WORKFLOW\.md|scripts/|\.claude/)' "$dir/patch-$t.diff"; then
      no "候選 ${t^^} 動到禁止區域(CLAUDE.md / CORE / scripts/ / .claude/)"
      FIX_ITEMS+=("候選 ${t^^} 應判無效;由 /battle 在 context.json 標記後交 Judge")
      viol=1; pass=0
    fi
  done
  [[ "$viol" -eq 0 ]] && ok "無候選觸碰禁止區域"

  if [[ "$pass" -ne 1 ]]; then
    fail_and_exit verify "bash scripts/fable.sh verify $id"
  fi

  say ""
  say "完成後會發生什麼:"
  say "  Judge(在 Claude Code)讀取 $dir/ 全部證據,只呼叫一次,"
  say "  裁決寫入 judgment.md;證據不足時必須輸出 INSUFFICIENT_EVIDENCE。"
  say ""
  say "下一步:"
  say "  1) 在 Claude Code 續跑 /battle $id 的裁決步驟"
  say "  2) 人工確認裁決 → 套用獲勝 patch → full acceptance"
  say "  3) bash scripts/fable.sh cleanup $id"
}

# ── 收尾 ─────────────────────────────────────────────────────
cmd_cleanup() {
  local id="${1:-}"
  local dir; dir="$(battle_dir "$id")"
  say "收尾:$id"
  if [[ -z "$id" || ! -d "$dir" ]]; then
    no "找不到 Battle:${id:-<未提供>}"
    FIX_ITEMS=("確認 ID:ls battles/")
    SKIP_ITEMS=("未清理任何資源")
    fail_and_exit cleanup "bash scripts/fable.sh cleanup <battle_id>"
  fi

  STATE_DIR=".tmp" PORT="$PORT" bash "$SCRIPT_DIR/stop-test-env.sh" >/dev/null 2>&1 || true
  ok "主工作區測試服務已停止(若在跑)"

  local w
  for w in "$(wt_a "$id")" "$(wt_b "$id")"; do
    if [[ -d "$w" ]]; then
      git worktree remove --force "$w" >/dev/null 2>&1 && ok "移除 $w" \
        || no "無法移除 $w(git worktree list 檢查)"
    fi
  done
  git worktree prune >/dev/null 2>&1 || true

  bash tests/sandbox/final-state.sh "$dir/final-state.txt" >/dev/null 2>&1 || true
  ok "終態快照:$dir/final-state.txt"

  say ""
  if [[ -f "$dir/judgment.md" ]]; then
    ok "judgment.md 存在"
  else
    no "judgment.md 不存在——此場尚未裁決,清理不代表完成"
  fi
  say ""
  say "下一步(封存,勝敗都做):"
  say "  1) 檢查 $dir/ 無敏感資訊(token/個資)"
  say "  2) git add $dir && git commit -m 'battle $id: <裁決摘要>'"
  say "  3) git status 乾淨後,本場才算結束"
}

# ── 狀態與續跑 ───────────────────────────────────────────────
cmd_status() {
  say "FABLE5 狀態"
  [[ -z "$(git status --porcelain 2>/dev/null)" ]] \
    && ok "Git 工作區乾淨" || no "Git 工作區不乾淨"
  git rev-parse --verify -q BISECT_HEAD >/dev/null 2>&1 \
    && no "有進行中的 bisect session(git bisect reset 可解除)" \
    || ok "無 bisect session"
  local occ; occ="$(port_pids)"
  [[ -n "$occ" ]] && say "  · Port $PORT 占用中:PID $occ" || ok "Port $PORT 空閒"
  say "  · worktrees:"
  git worktree list 2>/dev/null | sed 's/^/      /'
  local pending; pending="$(incomplete_battles | tr '\n' ' ')"
  if [[ -n "${pending// /}" ]]; then
    say "  · 未完成 Battle:$pending"
    say ""
    say "下一步: bash scripts/fable.sh resume"
  else
    ok "沒有未完成的 Battle"
  fi
}

cmd_resume() {
  local id; id="$(incomplete_battles | tail -1)"
  if [[ -z "$id" ]]; then
    say "沒有未完成的 Battle。"
    say '下一步: bash scripts/fable.sh init "<任務描述>"'
    return 0
  fi
  local dir; dir="$(battle_dir "$id")"
  say "偵測到未完成 Battle:$id"
  say ""
  local have_wt=0 have_prop=0 have_res=0
  [[ -d "$(wt_a "$id")" && -d "$(wt_b "$id")" ]] && have_wt=1
  [[ -f "$dir/proposal-a.md" && -f "$dir/proposal-b.md" ]] && have_prop=1
  [[ -f "$dir/result-a.json" && -f "$dir/result-b.json" ]] && have_res=1

  say "已完成:"
  ok "[2/5] Battle 目錄與 context"
  [[ "$have_wt"  -eq 1 ]] && ok "[2/5] A、B worktree" || no "[2/5] worktree 缺失"
  [[ "$have_prop" -eq 1 ]] && ok "[3/5] 提案已存檔" || no "[3/5] 提案未完成"
  [[ "$have_res" -eq 1 ]] && ok "[4/5] 候選測試結果存在" || no "[4/5] 尚未測試"
  no "[5/5] 尚未裁決(無 judgment.md)"
  say ""
  say "繼續:"
  if [[ "$have_wt" -eq 0 ]]; then
    say "  worktree 已散失,證據保留於 $dir/。"
    say "  安全作法:封存本場後重新 init 一場新 Battle。"
  elif [[ "$have_res" -eq 1 ]]; then
    say "  bash scripts/fable.sh verify $id"
  elif [[ "$have_prop" -eq 1 ]]; then
    say "  在 Claude Code 續跑 /battle $id(實作 → 之後 fable.sh test $id)"
  else
    say "  在 Claude Code 執行 /battle $id(從提案開始)"
  fi
}

# ── bisect 引導 ──────────────────────────────────────────────
cmd_bisect() {
  local good="${1:-}"
  say "回歸定位(git bisect)"
  if [[ -z "$good" ]]; then
    no "缺少 good commit"
    FIX_ITEMS=("提供最後已知正常的 commit,例如: bash scripts/fable.sh bisect abc1234"
               "可加參數: bisect <good> [bad=HEAD] [functional|startup]")
    SKIP_ITEMS=("未啟動 bisect")
    fail_and_exit bisect "bash scripts/fable.sh bisect <good_commit>"
  fi
  if [[ -z "${START_COMMAND:-}" ]]; then
    no "缺少 START_COMMAND"
    FIX_ITEMS=('export START_COMMAND="<你的啟動指令>"')
    SKIP_ITEMS=("未啟動 bisect")
    fail_and_exit bisect "bash scripts/fable.sh bisect $good ${2:-} ${3:-}"
  fi
  say "  bisect 會逐一 checkout commit 測試;請在一般終端機執行本命令,"
  say "  不要在 Claude Code session 內執行(輸出會消耗上下文額度)。"
  vlog "exec bisect-run.sh $good ${2:-HEAD} ${3:-functional}"
  exec bash "$SCRIPT_DIR/bisect-run.sh" "$good" "${2:-HEAD}" "${3:-functional}"
}

# ── 預設:狀態感知引導 ────────────────────────────────────────
cmd_default() {
  say "FABLE5 — 系統會引導你,不需要先讀任何文件。"
  say ""
  local pending; pending="$(incomplete_battles | tail -1)"
  if [[ -n "$pending" ]]; then
    cmd_resume
  else
    cmd_check
  fi
}

case "${1:-}" in
  "")        cmd_default ;;
  check)     cmd_check ;;
  init)      shift; cmd_init "${1:-}" ;;
  test)      shift; cmd_test "${1:-}" ;;
  verify)    shift; cmd_verify "${1:-}" ;;
  cleanup)   shift; cmd_cleanup "${1:-}" ;;
  status)    cmd_status ;;
  resume)    cmd_resume ;;
  bisect)    shift; cmd_bisect "${1:-}" "${2:-}" "${3:-}" ;;
  help|-h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    no "未知指令: $1"
    say "可用: check / init / test / verify / cleanup / status / resume / bisect"
    exit 2 ;;
esac
