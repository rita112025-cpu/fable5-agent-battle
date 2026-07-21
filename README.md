# FABLE5 Agent Battle(v4.1 引導式)

使用者只需要一個命令:

```bash
bash scripts/fable.sh
```

系統會自動檢查環境、告訴你缺什麼、給可複製的修正方式,
並在每一步指出下一步。你不需要先讀任何文件。

- 中斷後續跑:`bash scripts/fable.sh resume`
- 看狀態:`bash scripts/fable.sh status`
- 技術細節:任何子指令加 `--verbose`
- 在 Claude Code 中,LLM 步驟(提案/審查/實作/裁決)由 `/battle` 編排,
  機械步驟同樣委派 fable.sh

## 文件定位

- `CORE_WORKFLOW.md`:系統實作與稽核依據(維護者文件,使用者不必讀)
- `docs/INTERACTION.md`:互動設計原則與盲測標準
- `scripts/`:全部實作;`CLAUDE.md`:專案限制;`.claude/agents/`:角色規則

## 狀態

結構、Bash 語法與 fable.sh 引導行為已在沙盒驗證(見
VERIFICATION_REPORT.md);目標專案的 Gate 1–5 與新手盲測仍須實機執行。
