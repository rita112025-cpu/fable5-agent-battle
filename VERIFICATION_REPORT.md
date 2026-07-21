# FABLE5 v4.1 驗證報告

## 已完成(結構)

- 主流程、實作、專案規則與 Agent 裁決分離;CORE 降為維護與稽核文件
- 新增 `scripts/fable.sh` 引導式唯一入口(check/init/test/verify/
  cleanup/status/resume/bisect,--verbose 漸進揭露)
- `/battle` 改為編排 LLM 步驟並委派機械步驟給 fable.sh
- CORE 新增互動設計原則;docs/INTERACTION.md 記錄設計依據與盲測標準

## 沙盒行為驗證(本次實機執行於臨時 Git 專案)

- [x] 首次執行:缺 lsof / 缺 START_COMMAND → 精準阻擋,訊息含
      需要處理/系統未執行/重試方式,exit 2
- [x] check 全過後指出下一步(init 或 resume)
- [x] init:原子 ID(20260719-01→-02)、A/B worktree 鎖同 base commit
- [x] 上一場證據未封存 → 下一場 init 被 clean-tree 規則阻擋
- [x] test:真實啟動/停止服務兩輪(共用 Port)、health 200、
      acceptance 通過;patch 同時收到「修改既有檔」與「新增檔」
- [x] verify:12 檔證據包/JSON 合法性/禁區違規(偽造動到 scripts/
      的 patch 被抓到並阻擋)
- [x] cleanup:worktree 移除、Port 釋放、final-state 快照、封存指引
- [x] resume:三種中斷點(提案前/實作後/測試後)各自指向正確下一步
- [x] Port 被未知程序占用:阻擋且不誤殺;--verbose 顯示細節
- [x] `bash -n` 全部腳本 PASS(見 SYNTAX_CHECK.txt)

## 尚未執行(不得描述為已通過)

- [ ] Gate 1–5 於目標真實專案(真實 START_COMMAND、真實依賴)
- [ ] Bisect 實機(good/bad/skip 與 Ctrl+C reset)於目標專案
- [ ] Judge 實機裁決品質
- [ ] 新手盲測:未讀 CORE 者僅憑 `bash scripts/fable.sh` 完成一場
      沙盒 Battle(v4.1 的最終完成標準,見 docs/INTERACTION.md)
