# /battle [battle_id] [任務描述]

輸出契約:每一步只回答三件事——下一步做什麼、需要什麼、完成後會發生什麼。
機械步驟一律委派 `scripts/fable.sh`,只讀其摘要與 JSON,不把細節灌進上下文。
能由命令查出的,不問使用者;只詢問系統查不到的資訊。

1. `bash scripts/fable.sh check` — 未過:轉述「需要處理」清單後結束,不往下走
2. 無 battle_id 時:`bash scripts/fable.sh init "<任務>"` 取得 BATTLE_ID 與兩個 worktree
3. 【提案】engineer-a、engineer-b 只收任務+CLAUDE.md,提案在回覆中輸出;
   orchestrator 寫入 `battles/<id>/proposal-a.md`、`proposal-b.md`(agent 不寫檔)
4. 【交叉審查】固定一輪 → `critique-a.md`、`critique-b.md`
5. 【實作】A、B 各自只修改 `.worktrees/<id>-a|b`,不得 commit、不得動
   CLAUDE.md / CORE / scripts/ / .claude/
6. `bash scripts/fable.sh test <id>` — A 失敗仍測 B;結果只看 RESULT 行與 JSON
7. `bash scripts/fable.sh verify <id>` — 未過:依提示補齊;無法補齊則直接進 8,
   由 Judge 判 INSUFFICIENT_EVIDENCE
8. 【裁決】Judge 只呼叫一次,讀 `battles/<id>/` 全部證據 → `judgment.md`
9. 人類確認 → 套用獲勝 patch → `bash scripts/acceptance.sh full`
10. `bash scripts/fable.sh cleanup <id>` → 依提示封存 commit,git status 乾淨才結束

每步向使用者輸出:目前階段([n/5])、已完成/未完成、需要的資訊、下一步。
中斷後重新進入:先 `bash scripts/fable.sh resume`,依其指示從正確階段續跑。
