# GitHub リポジトリ設定（ruleset）

この repo の merge gate は GitHub の **ruleset**（Settings → Rules → Rulesets）で強制している。**全 review thread を resolve しないと main に merge できない**のが主目的。agent を YOLO/自律で回す前提なので、**誤 merge をどう機械的に防ぎ、かつ「頼んだら自律 merge」をどう両立するか**の設計根拠（誤 merge 防止と自律 merge の両立、原則 1–4）は [../decisions/merge-gate-design.md](../decisions/merge-gate-design.md) 参照。

## 有効な ruleset（default branch = main）

| ルール | 値 | 意味 |
|--------|----|------|
| `pull_request` | 必須 | main への変更は PR（pull request）経由を要求する |
| └ `required_review_thread_resolution` | `true` | **PR の review thread を全て resolve するまで merge できない**（本設定の主目的） |
| └ `dismiss_stale_reviews_on_push` | `true` | 新しい push で既存の review approval を dismiss する |
| └ `required_approving_review_count` | `0` | approval 数は要求しない。owner 主導の repo のため、品質はローカル codex review + thread resolution（audit step）+ HOTL 判断（[../decisions/merge-gate-design.md](../decisions/merge-gate-design.md)「前提と現状」参照。thread resolution 自体は agent の手が届くため単独の hard gate ではない）で担保する。App identity gate を試験的に `0→1` にした際、PAT fallback（marker 無し box / host session 発 PR）が gate を満たせなくなる残差が実運用で判明したため `1→0` に revert 済み（詳細は [../decisions/merge-gate-design.md](../decisions/merge-gate-design.md)「App identity による human-approval gate」） |
| `non_fast_forward` | 禁止 | main への force-push を禁止 |
| `deletion` | 禁止 | main の削除を禁止 |

`enforcement: active` で全員に適用（bypass なし）。

なお `pull_request` rule は「変更を PR 経由にする」ものであり、**直接 push の全面禁止（`Restrict updates` rule）は本 ruleset には含めていない**。「main へ直接 push しない」は [../../CLAUDE.md](../../CLAUDE.md)「コミット / PR 運用」の運用規範で担保する（force-push・削除は上表の `non_fast_forward` / `deletion` で機械的に禁止）。

## 前提（plan 要件）

ruleset / branch protection は、**private repo では GitHub Team/Pro plan が必要**（public repo なら無料）。本 repo は private のため、org を有料 plan にして有効化している。plan を持たない private repo では ruleset API が `403 Upgrade to GitHub Pro or make this repository public` を返す。

## 確認・変更方法

- **Web UI**: Settings → Rules → Rulesets → 「main」
- **CLI**（`gh` が repo を自動解決する `{owner}/{repo}` placeholder を使う）:

```bash
# 一覧
gh api repos/{owner}/{repo}/rulesets
# 中身（<id> は一覧の id）
gh api repos/{owner}/{repo}/rulesets/<id>
```

更新は同 id に `PUT repos/{owner}/{repo}/rulesets/<id>` で ruleset 全体を渡す（部分更新でなく全体置換のため、既存 rule を保持したうえで変更する）。

## workflow 規範との関係

GitHub 側の強制（本 ruleset）と対に、開発フロー側でも **「review を全て対応・resolve してから merge する」** を [../../CLAUDE.md](../../CLAUDE.md)「コミット / PR 運用」で定義している。ruleset は機械的 gate、規範は agent / 人間の運用指針で、二重に担保する。
