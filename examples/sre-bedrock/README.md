# cloud 常駐の無人 SRE 自動化（Bedrock）リファレンス

このディレクトリは、決定記録 [docs/decisions/cloud-unattended-sre.md](../../docs/decisions/cloud-unattended-sre.md) が定める
**cloud 常駐（HOTU）パターン** — CloudWatch 5xx → agent → 自動 fix PR — の自己完結リファレンス。

手元で人間が read-only 調査する **local（HOTL）パターン**は [examples/observe](../observe/runbook.md) と
[rules/box-personas.md](../../rules/box-personas.md) US3。両者は別軸で補完（local=人が深掘り / cloud=無人で一次対応）。

## 中身

| path | 役割 |
|---|---|
| [spike/](spike/) | ADR の核心仮説「**Bedrock 上の agent が sanitized triage から妥当な fix を導けるか**」を、インフラを作らず最小コストで検証する harness。ADR を `Proposed → Accepted` に進めるためのゲート |
| [pipeline/](pipeline/) | spike の上に乗る **trigger 配線 + identity 境界の設計**（CloudWatch 5xx → Lambda triage → fixer → PR）。観測/修正 2 つの least-privilege IAM 雛形と、dispatch を sanitize gate にする handoff 設計。最小 e2e の IaC・triage Lambda 参照実装・fixer entrypoint は本 dir に実体を持つ（詳細は [pipeline/README.md](pipeline/README.md)「実装の置き場所」）。フル配線 IaC と題材アプリ（仕込みバグ込み）のみ stage 系へ |

## 段階

ADR の「残差・未決」に沿った構築順:

1. **spike**（[spike/](spike/)）— 核心仮説の検証。← 通過済み（直 Anthropic key で初回 PASS）
2. **trigger 配線 + identity 設計**（[pipeline/](pipeline/)）— CloudWatch 5XX alarm → SNS → Lambda triage、観測/修正 identity の IAM 境界。← IaC・least-privilege IAM 雛形・triage Lambda 参照実装まで完了。CloudWatch alarm → SNS の full 配線は未着手
3. パターン A（Fargate / CodeBuild で `claude -p`）→ B（AgentCore Runtime で Agent SDK）を end-to-end ← 両パターンとも最小 e2e（S3 triage → fixer 起動 → fix PR 生成）の実 deploy 検証まで完了
4. 教材化（`stage/08-server-500-broken` への仕込みバグ + 生成された fix PR を実演） ← 完了。`slides/` の運用保守フェーズは未着手（人間が書く担当）

フル配線 IaC（CloudWatch alarm 実配線）と題材アプリ（仕込みバグ込み）は demo アプリ（stage 系）側に置く。
最小 e2e の IaC・triage Lambda 参照実装・fixer entrypoint は repo 非依存の tooling として本ディレクトリ
（main）に置く（詳細は [pipeline/README.md](pipeline/README.md)「実装の置き場所」。[CLAUDE.md](../../CLAUDE.md)
「stage ブランチの規約」）。
