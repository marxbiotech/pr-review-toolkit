# Deploy to Environment

使用此命令會在當前分支的 PR 上自動留言 `/deploy <env>` 來觸發部署。

## 前置條件

- 已安裝 GitHub CLI (`gh`) 並完成認證
- 當前目錄為 git repository
- 當前分支已有對應的 PR

## 使用方式

```
/deploy-pr <environment>
```

## 可用環境

| 環境 | 簡寫 |
|------|------|
| staging | staging |
| dev-brian | brian |
| dev-ray | ray |
| dev-reckie | reckie |
| dev-suki | suki |
| dev-xin | xin |
| preview | preview |
| snowiou | snowiou |

## 執行

```bash
./scripts/deploy-pr.sh "$ARGUMENTS"
```
