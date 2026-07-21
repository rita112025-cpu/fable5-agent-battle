# FABLE5 Core Workflow

## 0. 互動設計原則

本文件是系統實作與稽核依據,不是使用者必讀的操作手冊。
使用者唯一入口是 `bash scripts/fable.sh`(及 Claude Code 的 `/battle`)。

第一階段的減法,是把文件拆開;第二階段的減法,是讓使用者不必閱讀那些文件。

- 所有可由系統判斷的條件,必須由腳本或 `/battle` 自動檢查,不得依賴使用者記憶
- 能由命令查出的,不問人;能由程式執行的,不叫人手動做
- 每個階段的輸出必須明確顯示:目前階段、已完成與未完成、需要使用者提供的資訊、下一步會執行什麼、失敗時的具體修正方式
- 採漸進揭露:預設只顯示當前一步;技術細節(exit code、RUN_DIR、路徑)以 `--verbose` 提供
- 使用者只需處理當前步驟,不必先理解完整流程

## 1. 範圍

本文件只定義：

1. 何時直接修、何時進入 Battle
2. Battle 固定執行順序
3. 腳本輸入、輸出與 exit code
4. 立即中止條件
5. 完成驗收標準

實作只存在於 `scripts/`，專案限制只存在於 `CLAUDE.md`，裁決規則只存在於 `judge.md`。

## 2. 直接修與 Battle

### 直接修

以下條件全部成立才可直接修：

- 預估只修改 1 個檔案
- 預估總變更少於 30 行
- 不修改函式簽名、API 路由、schema 或外部介面
- 已有測試覆蓋相關路徑
- 不涉及認證、權限、網路、部署、資料庫、金額計算或 Secret

修完後重新檢查實際 diff。超過門檻即停止直接修，改進 Battle。

### 必須 Battle

任一條件成立即進 Battle：

- 跨模組修改
- 根因不明
- 涉及架構或服務關係
- 涉及 API、路由或 schema
- 涉及部署、權限、認證、Port 或 Secret
- 涉及金額計算
- 可能造成資料遺失或重大回歸
- 存在兩種以上合理修法且取捨不明

## 3. Phase 0：前置條件

進入自動流程前必須確認：

- 啟動指令已知，並可由 `START_COMMAND` 執行
- 停止流程由 `scripts/stop-test-env.sh` 管理
- `HEALTH_URL` 可回傳 HTTP 2xx
- `PORT` 已確認
- 服務依賴已列明
- good commit 與 bad commit 已確認
- 主工作區乾淨
- 沒有既有 Git bisect session
- 測試 Port 沒有未知程序占用

任一條件未完成，立即中止。

## 4. Exit code 契約

### acceptance、start、stop、prepare

- `0`：成功或驗收通過
- `1`：功能失敗或服務無法就緒
- `2`：工具、環境、輸入或安全條件錯誤

### git bisect harness

- `0`：good
- `1`：bad
- `125`：skip／不可測

## 5. Battle 固定流程

1. 判斷是否符合直接修門檻
2. 確認主工作區乾淨
3. 建立 `battles/<id>/task.md` 與 `context.json`
4. Engineer A、B 分別進行提案
5. 固定一輪交叉審查
6. 從同一 base commit 建立 A、B worktree
7. A、B 只在各自 worktree 實作
8. 分別執行 `worktree-test.sh`
9. 產生 patch、result JSON 與 service log
10. A 失敗不得阻止 B 執行
11. Judge 最後只呼叫一次
12. 人工確認後才套用獲勝 patch
13. 執行 full acceptance 並清理所有暫存資源

## 6. 候選規則

- A、B 必須使用相同 base commit
- 提案階段不得寫入檔案
- 實作階段只能修改指定 worktree
- 候選不得自行 commit
- Patch 必須包含 staged、unstaged、新增檔與二進位檔
- Patch 必須通過 `git apply --check`
- 候選不得修改 `CLAUDE.md` 或核心測試腳本
- 基礎設施錯誤與功能失敗必須分開記錄

## 7. 最小證據包

每場 Battle 只要求：

- `task.md`
- `context.json`
- `proposal-a.md`
- `proposal-b.md`
- `critique-a.md`
- `critique-b.md`
- `patch-a.diff`
- `patch-b.diff`
- `result-a.json`
- `result-b.json`
- `service-a.log`
- `service-b.log`
- `judgment.md`

只有合併裁決時才增加 `merge-instructions.md`。

## 8. 腳本契約

### fable.sh(使用者入口)

輸入:子指令 `check|init|test|verify|cleanup|status|resume|bisect`,可加 `--verbose`
輸出:每步顯示 ✓/✗、需要處理、系統未執行、下一步命令
驗收:錯誤可行動;重複執行不覆蓋證據、不重複建 worktree、不誤殺程序;中斷後 `resume` 能指出正確階段

### acceptance.sh

輸入：`smoke|full`、`BASE_URL`、`HEALTH_URL`、可選 `PROJECT_ACCEPTANCE_SCRIPT`  
輸出：合法 JSON  
驗收：正確區分 0／1／2；smoke 超過 60 秒回 2

### start-test-env.sh

輸入：`START_COMMAND`、`PORT`、`HEALTH_URL`、`STATE_DIR`、`LOG_FILE`  
輸出：PID 狀態與 service log  
驗收：重複 start 重用同一健康程序；未知 Port 占用回 2 且不誤殺

### stop-test-env.sh

輸入：`PORT`、`STATE_DIR`  
輸出：停止結果  
驗收：只停止自己記錄且 start token 相符的 PID；重複 stop 回 0

### prepare-test-deps.sh

輸入：專案目錄與 `FABLE_ENV_FILE`  
輸出：可 source 的環境檔  
驗收：Python 依 dependency hash 隔離；Node 依 worktree 安裝

### bisect-run.sh／bisect-test.sh

輸入：good、bad、`functional|startup`  
輸出：Git bisect 結果  
驗收：任意結束路徑 reset；不可測回 125；輸出不污染 repo

### worktree-test.sh

輸入：worktree、battle 目錄、`a|b`  
輸出：patch、result JSON、service log  
驗收：永遠留下合法結果；單一候選失敗不阻止另一候選

## 9. 立即中止條件

- Phase 0 任一項未確認
- 主工作區不乾淨
- 已存在 Git bisect session
- 未知程序占用測試 Port
- 必要工具缺失
- 任一核心腳本回傳 exit 2
- Patch 為空、無法套用或候選自行 commit
- 缺少 A／B 任一 result JSON
- Judge 判定 `INSUFFICIENT_EVIDENCE`

## 10. 完成標準

- `bash -n scripts/*.sh` 全部通過
- Gate 1–5 全部通過
- Start／Stop 冪等且不誤殺
- Acceptance 正確區分 0／1／2
- Bisect 異常後必定 reset
- A、B Patch 可在乾淨 worktree 套用
- A 失敗不阻止 B
- Judge 只依證據裁決
- Cleanup 後 Git、Port、PID、worktree、RUN_DIR 全部乾淨

## 11. 凍結規則

Gate 1–5 全部通過前，不增加新功能。

允許的修改只有：

- 修正可重現錯誤
- 新增對應回歸測試
- 修正 cleanup
- 修正 exit code
- 修正非法或缺漏的證據輸出
