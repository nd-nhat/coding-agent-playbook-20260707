# examples: 運用保守フェーズの参照実装・検証 harness

講義 5 フェーズの最後 **運用保守・バグ修正** で「動いた後の世界」を実演するための main 側リファレンス。
project 本体（`stage/*`）でも、受講者が日常的に叩く恒久 tooling（`scripts/`）でも、playbook を動かす開発ツール（`tools/`）でもない
**第 4 のカテゴリ**として分けている（[../CLAUDE.md](../CLAUDE.md)「構成の前提」/「stage ブランチの規約」）。

- `scripts/` = 受講者が毎回叩く恒久 tooling（`.sh`/`.ps1` ペア保守が義務）
- `tools/` = playbook 自体を動かす開発補助（a2a-review / parallel-dev）
- **`examples/` = 運用パターンを理解・検証するための具体物**（runbook / IAM 雛形 / ADR ゲート harness / 配線設計）

## 中身と lifecycle（保守期待が違うものを1階層に置いている）

| path | 何か | lifecycle |
|---|---|---|
| [observe/](observe/runbook.md) | **local(HOTL) パターン**。権限を絞った observe box から本番を read-only で調べる固定 runbook + read-only IAM 雛形 | **stable reference** — 運用の恒久手順 |
| [sre-bedrock/spike/](sre-bedrock/spike/README.md) | **ADR ゲート harness**。インフラ0で「agent は sanitized triage だけで直せるか」の核心仮説を検証 | **ephemeral** — 判断が済めば役目を終える（`.sh`/`.ps1` ペア免除。[../CLAUDE.md](../CLAUDE.md) cross-platform 要件の scoped 例外） |
| [sre-bedrock/pipeline/](sre-bedrock/pipeline/README.md) | **cloud(HOTU) パターン**。CloudWatch 5xx → triage → agent → 自動 fix PR の配線 + identity 境界設計、least-privilege IAM 雛形、fixer 参照実装 | **reference architecture**（fixer 経路は実 AWS 検証済み / CloudWatch 前段は未配線） |

背景の決定は ADR [../docs/decisions/cloud-unattended-sre.md](../docs/decisions/cloud-unattended-sre.md)。

## 運用保守フェーズでの位置づけ

運用保守・バグ修正フェーズは **local(HOTL) 調査** と **cloud(HOTU) 無人修正** の 2 軸を持ち、この 2 つが本 dir の
observe/ と sre-bedrock/ に対応する。**どの stage をどのシナリオで開くか**の対応（`06/07` = local observe 調査、
`08` = cloud fixer pipeline 実演）は講義運営の関心事なので [../docs/instructor.md](../docs/instructor.md)「ステージ」に
単一ソースで置く（ここでは重複させない）。本 dir 側の関心事＝**各 artifact が今どこまで動くか**は次の通り:

- **observe/** — 恒久 runbook。実演には調査対象の deploy 済み環境（CloudWatch にログが出ている状態）が要る。
- **sre-bedrock/spike/** — `BACKEND=anthropic`（直 key）なら AWS 承認待ちなしで live 実行できる ADR ゲート。既定の
  採点ペアは `stage/06-readings-drift-broken`（`TARGET_BRANCH`）→ `stage/07-readings-drift-fixed`（`ANSWER_BRANCH`）。Bedrock 実機は「本番 auth track」。
- **sre-bedrock/pipeline/** — fixer 経路（S3 triage → 起動 → fix PR）はパターン A/B とも実 AWS で検証済み。
  **CloudWatch alarm → SNS → 観測 Lambda の前段は未配線**なので、完全無人 e2e は設計 walkthrough として見せる。
