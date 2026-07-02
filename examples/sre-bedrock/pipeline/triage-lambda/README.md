# triage-lambda: 観測側 triage の参照実装

[pipeline/README.md](../README.md) の **観測 identity（Lambda）** の本体。CloudWatch 5xx alarm → SNS で起動し、
該当ログを Logs Insights で取り → **actionable 判定** → **sanitize 済み triage** を組み → DynamoDB で dedup →
**S3 に PUT**（観測の出力はここまで）。GitHub には一切触らない（identity 境界）。起動は別途
S3 event → EventBridge → fixer（[fixer-entrypoint.sh](../fixer-entrypoint.sh)）。

| file | 役割 |
|---|---|
| `triage_core.py` | 純ロジック（**boto3 非依存**）: schema 検証 / secret redact / dedup キー / actionable 判定 / size 上限。spike・fixer と等価に保つ |
| `handler.py` | Lambda handler: boto3（Logs Insights / S3 / DynamoDB）で `triage_core` を I/O で囲む |
| `test_triage_core.py` | unit test（stdlib `unittest`・**AWS 不要**）。`python3 -m unittest test_triage_core` |

## 設計上のポイント

- **観測は GitHub egress を持たない**。issue 作成・PR は一切しない（[pipeline/README.md](../README.md)「2 つの identity」「optional: issue layer」）。
- **sanitize は持ち出しを絞るが命令注入は無害化しない**。`evidence` は redact + 要約サイズに丸めるが、最終的な injection 耐性は「fixer に triage 以外を読ませない」設計で担保する。
- **dedup は S3 key でなく DynamoDB（signature キー）**。S3 object key は推測不能（`uuid4`）にして fixer 側の列挙・推測を塞ぐ。
- **schema は spike/triage.json・fixer-entrypoint.sh と等価**に保つ（drift すると修正 identity 側で弾かれる）。

## 検証済みの範囲（box）と残り（AWS）

- **box で検証済み**: `triage_core` の純ロジックを unit test（schema 弾き / secret redact / dedup slug / actionable 閾値 / size 上限）。
- **AWS 環境での結合が要る**: `handler.py` の Logs Insights query・S3 PutObject・DynamoDB 条件付き put、および IaC（IAM role は [observe-identity-iam.json](../observe-identity-iam.json)・dedup を使うなら `dynamodb:PutItem` + `dynamodb:DeleteItem`（claim release 用）+ DynamoDB Gateway endpoint を追加）。`_query_logs` の signature 抽出は**アプリ依存**なので実アプリに合わせて調整する（reference 実装）。

Linux Lambda runtime 専用なので Python のみ（PowerShell 対は持たない）。
