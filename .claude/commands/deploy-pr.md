# Deploy to Environment

在當前分支的 PR 上留言 `/deploy <env>` 觸發部署。

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
./scripts/deploy-pr.sh $ARGUMENTS
```
