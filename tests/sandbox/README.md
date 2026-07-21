# Sandbox Gates

固定順序：

1. Gate 1：Start／Stop
2. Gate 2：Acceptance
3. Gate 3：Bisect
4. Gate 4：Worktree
5. Gate 5：Judge
6. Final State Check

前一 Gate 未通過，不進下一 Gate。

## Gate 1

- 第一次 start → 0
- 第二次 start → 0，PID 不變
- stop 連續兩次 → 0
- stale PID 安全處理
- 未知程序占 Port → 2，且程序仍存活
- readiness 失敗後無殘留

## Gate 2

- 正常 → 0 + 合法 JSON
- 功能失敗 → 1 + 合法 JSON
- 工具／環境錯誤 → 2 + 合法 JSON 或明確 fallback
- smoke >60 秒 → 2

## Gate 3

- 正確定位人工 bad commit
- 不可測 commit → 125
- Ctrl+C 後沒有 BISECT_HEAD
- Repo 無 log、PID、JSON 污染

## Gate 4

- A、B 同 base
- Patch 非空且 `git apply --check` 通過
- 新增文字與二進位檔可進 Patch
- A 失敗後 B 仍執行
- 清理後只剩主 worktree

## Gate 5

- PASS／FAIL、FAIL／PASS、PASS／PASS、FAIL／FAIL
- 缺 result JSON → INSUFFICIENT_EVIDENCE
- Judge 不修改程式

結果寫入 `tests/sandbox/results/`。
