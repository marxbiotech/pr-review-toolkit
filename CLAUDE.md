# CLAUDE.md

## allowed-tools 語法

`allowed-tools` frontmatter 中的 Bash 權限**必須使用 space 語法**，不使用 colon 語法：

- `Bash(git *)` — 正確
- `Bash(git:*)` — deprecated（legacy 語法，未來會被移除）

詳見 [Claude Code permissions 文檔](https://code.claude.com/docs/en/permissions)：
> "The legacy `:*` suffix syntax is equivalent to ` *` but is deprecated."

此規則同時適用於：
- YAML frontmatter `allowed-tools` 欄位
- `settings.json` 的 `permissions.allow` 陣列
- 文檔中的 JSON 設定範例
