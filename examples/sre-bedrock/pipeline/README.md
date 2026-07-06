# pipeline: 500 alert → 無人 fix PR の配線設計

ADR [cloud-unattended-sre.md](../../../docs/decisions/cloud-unattended-sre.md) の **決定 3（アーキテクチャ・承認ゲート）と「安全」節（identity 分離）を、実装可能な設計に落とした** リファレンス。[spike/](../spike/) が「修正 identity が triage から直せるか」を実証したのを受け、その上に乗る **trigger 配線 + identity 境界** を固める（ADR 段階 2–3）。

本ディレクトリは main 側の横断リファレンス（認証/実行基盤の設計 + IAM 雛形 + repo 非依存の fixer entrypoint 参照実装）。**IaC 実体・Lambda triage 本体・題材 demo アプリ（仕込みバグ込み）は stage 系に置く**（[CLAUDE.md](../../../CLAUDE.md)「stage ブランチの規約」）。置き場所の内訳は下記「実装の置き場所」表。

## 全体配線（ADR 決定 3 を具体化）

```text
CloudWatch  (ALB/API GW 5XX alarm  or  Logs metric filter で ERROR/5xx)
   └─ Alarm ─ SNS ─ Lambda(triage)            ← 観測 identity（observe-identity-iam.json）
                      │ ① Logs Insights で該当ログ取得
                      │ ② actionable 判定（noise は agent を起こさず internal state に記録のみ。issue 化は観測の外＝下記「optional: issue layer」）
                      │ ③ 固定 schema に sanitize（生ログ/secret を載せない）
                      ▼ ④ s3://TRIAGE_HANDOFF_BUCKET/triage/<incident-id>.json に PUT（検証済みのみ）。観測の出力はここで終わり
   S3 event ─ EventBridge rule ─ StartBuild/RunTask   … 起動は infra（観測の credential でなく）。key は event 由来・override 無し
        ┌─────────────────────────┬─────────────────────────┐
        ▼ パターン A                ▼ パターン B          ← 修正 identity（fixer-identity-iam.json）
   CodeBuild / Fargate          AgentCore Runtime
   claude -p on Bedrock         Claude Agent SDK on Bedrock
        │ S3 から triage を GET（repo は clone）。AWS read はこれ以外不可（IAM Deny）
        └─ triage + repo → runbook(Skill) → 最小 fix → gh pr create（無人）
                      │ merge は人間（承認ゲート）
```

**観測 identity は fixer を直接起動しない**（`codebuild:StartBuild` を持たせない）。StartBuild は env/source override を運べるため、観測がそこに生ログ/secret を載せて fixer の GitHub egress 経由で抜く経路になりうる。よって起動は **S3 event → EventBridge rule → StartBuild/RunTask** という infra 側のトリガに分離し、fixer に渡るのは **event 由来の object key だけ**（override 経路なし）。triage 本文は ④ の **schema 検証を通った S3 オブジェクトとしてのみ** 渡る。fixer entrypoint も env override を読まず key の S3 オブジェクトだけを入力にする。これが ADR「dispatch 境界自体を sanitize gate にする」の具体化（env override で生データを密輸させない）。

## 2 つの identity（lethal trifecta を IAM で崩す）

ADR の拘束条件「観測（AWS read + 一方向 dispatch）と 修正（repo-write・AWS read なし）を別 identity に」を、2 つの least-privilege ポリシーで実装する。プレースホルダ（`REGION` / `ACCOUNT_ID` / `*_NAME` 等）は環境ごとに置換する。

| 関心事 | 観測 identity ([observe-identity-iam.json](observe-identity-iam.json)) | 修正 identity ([fixer-identity-iam.json](fixer-identity-iam.json)) |
|---|---|---|
| アプリ/incident ログ read | ✅ Logs Insights（app log group scope） | ❌ **明示 Deny**（`DenyIncidentAndAppDataRead`） |
| Bedrock 推論 | ❌ 明示 Deny | ✅ Anthropic model/profile に scope（global cross-region は 3 ARN） |
| GitHub 書き込み | ❌ ネットワーク egress 無し | ✅ Secrets Manager の repo-scoped token で `gh pr create` |
| triage handoff | ✅ S3 `triage/*` に PutObject（書くだけ） | ✅ S3 `triage/*` を GetObject（読むだけ） |
| 起動の向き | S3 PutObject で終わり（`StartBuild` は**持たない**）。起動は S3 event→EventBridge が担う | 起動されるだけ（観測を呼び返せない・event 由来 key のみ受ける） |
| 資格情報ブローカ | ❌ `sts:AssumeRole*` Deny | ❌ `sts:AssumeRole*` Deny |

**要点**: 「untrusted なログ本文を読む権限」と「GitHub に書く権限」が**同一 identity に同居しない**。観測は読めるが外に出せず、修正は外に出せるが incident を読めない（明示 Deny）。fixer の `secretsmanager:GetSecretValue` は **自分の GitHub token だけ**で、incident/app データ read ではない（boundary を侵さない）。

## handoff = sanitize gate（schema は spike と共有）

Lambda triage が S3 に書く JSON は [spike/triage.json](../spike/triage.json) と同じ固定 schema（`schema_version` / `incident.signature` 必須・未知 top-level キー拒否・size 上限・`no_raw_logs` / `no_secrets`）。spike harness ([spike/run-spike.sh](../spike/run-spike.sh)) が既に同じ検証を実装しているので、**Lambda 側の検証は spike の検証ロジックと等価に保つ**（drift させない）。検証を通らない triage は dispatch しない（actionable でも壊れた triage は捨てる）。

**fixer は自分の incident の triage 1 件だけを読む**: fixer role の `s3:GetObject` は `triage/*` prefix だが、`s3:ListBucket` を**明示 Deny**してバケット列挙を封じる（`DenyTriageBucketEnumeration`）。これで fixer は **event で渡された key を GET できるだけ**で、他 incident の sanitized triage を列挙・読取りできない。`<incident-id>` は**推測不能な値**（UUID 等）にして key 推測も塞ぐ。さらに厳密にするなら、起動側が当該 object の **pre-signed GET URL** を渡して fixer role から `s3:GetObject` を外す（fixer に S3 read 権限を一切持たせない）構成が取れる。

## optional: issue layer（tracking / dedup 用・主経路ではない）

PR が既に human-review gate なので、**ゲート目的では issue は不要**（直 PR が gate。auto-remediation の業界 consensus も「PR が natural review surface」）。issue は **dedup の anchor / 通知 / 人間向け tracking** の value-add として*任意で*足せる。足す場合の制約（崩すと lethal trifecta が復活する。GitHub issue コメント injection → private exfil の実例あり）:

- **観測 identity に issue を作らせない**（= GitHub egress を持たせない）。issue 作成は **fixer 側、または GitHub-issue-write だけの薄い intake identity**（AWS read なし・入力は sanitized triage object/key のみ）に置く。`StartBuild` を観測から外したのと同じ理由。
- **issue 本文・コメントを agent の入力にしない**。sanitize gate は raw log/secret/payload の持ち出しは絞るが**命令注入は無害化しない**（`evidence` 等の自由文字列はそのまま prompt に入る）。fixer の primary input は **S3 の sanitized triage に固定**し、issue を読むなら triage から再構成した機械生成本文だけにする。
- **dedup の source of truth は GitHub でなく AWS 内 state**（DynamoDB を `service+signature+resource` 等の signature キーで条件付き put）。条件付き put は observe Lambda が行う（AWS 内書き込みで GitHub egress ではないので observe 境界を破らない）。**この path を有効化する場合は観測 role に `dynamodb:PutItem` + `dynamodb:DeleteItem`（dedup table ARN scope。handoff 失敗時の claim release に Delete が要る）を足し、no-egress なら DynamoDB Gateway VPC endpoint も併設する** — 現 [observe-identity-iam.json](observe-identity-iam.json) と上記 endpoint 一覧は actionable 主経路の最小権限で **DynamoDB を含まない（意図的）**ので、有効化時に追加が要る。issue-as-dedup は comment 編集 / label 操作など外部 mutable state を制御面に入れて再現性と境界を弱めるため避ける。

実装はこの設計段では決め切らない（主経路を直 PR に保ち、必要になったら上記制約付きで足す）。

## パターン A / B（A から作る）

- **パターン A（先に作る）**: CodeBuild/Fargate で spike とほぼ同形の `claude -p` を回す。`CLAUDE_CODE_USE_BEDROCK=1` + fixer role の IAM 認証で、`--safe-mode --permission-mode acceptEdits --tools Edit Read Grep --strict-mcp-config`（spike で検証済みの起動形）に `gh pr create` を足すだけ。参照実装 = [fixer-entrypoint.sh](fixer-entrypoint.sh)（triage を path/S3 から読み → fix branch → `claude -p` → PR。`DRY_RUN=1` で PR 手前まで・`BACKEND=anthropic` で直 key 検証）。Linux の CodeBuild/Fargate 専用なので sh のみ（`.ps1` 対は持たない＝[CLAUDE.md](../../../CLAUDE.md) の ephemeral/限定環境 artifact）。
- **パターン B（後で比較）**: AgentCore Runtime で Claude Agent SDK。custom tool・承認ゲートをコードで握れる。Skills/subagents/MCP もそのまま。A と併設して「shell パイプ的に軽い A / 制御を握る B」を比較する（ADR 決定 1）。

## 承認ゲートと egress 境界

- **承認ゲート**: PR 作成までは無人、**merge は人間**（ADR 決定 3 / [CLAUDE.md](../../../CLAUDE.md) の「merge はユーザー判断」と一致）。Slack 通知は補助で後続。
- **egress 境界（IAM でなくネットワークで強制）**: 観測 Lambda は **外部 egress 無し**（NAT/IGW ルートを持たせない subnet）。修正側だけ NAT 経由で `github.com` + Bedrock regional endpoint に出る。VPC 内に閉じたい場合は `bedrock-runtime` の Interface VPC Endpoint(PrivateLink) を併用（ADR 決定 2）。IAM の Deny は「権限」を、subnet ルートは「経路」を、二重で縛る。
- **no-egress 側に要る VPC endpoint（重要・忘れると無言で timeout）**: 観測 Lambda は NAT 無しなので、呼ぶ AWS API ごとに **VPC endpoint が要る** — **S3 Gateway endpoint**（triage PUT）+ **CloudWatch Logs Interface endpoint**（Logs Insights query / 自分の log 出力）。これらが無いと AWS API に到達できず timeout する（StartBuild は観測から外したので CodeBuild endpoint は不要）。修正側も VPC 内に閉じるなら **S3 Gateway**（triage GET）+ **Secrets Manager / CloudWatch Logs Interface** + **`bedrock-runtime` Interface(PrivateLink)** を併設し、`github.com` 向けだけ NAT を残す（Bedrock も PrivateLink にすれば外部 egress は github のみ）。

## 実装の置き場所

| 成果物 | 置き場所 |
|---|---|
| 配線設計 + IAM 雛形（本 dir） | main（横断リファレンス） |
| **fixer entrypoint 参照実装**（`fixer-entrypoint.sh`） | main（spike harness と同じく repo 非依存の tooling。env で parameterize） |
| **観測 triage Lambda 参照実装**（[`triage-lambda/`](triage-lambda/)） | main（純ロジックは boto3 非依存で unit test 付き。env で parameterize） |
| **A 最小 e2e の IaC**（[`infra/`](infra/) CDK: S3→EventBridge→CodeBuild fixer） | main（`cdk synth` まで box 検証可・deploy は host） |
| フル配線の IaC（CloudWatch alarm / SNS / 観測 Lambda 配線）+ Lambda triage の実 deploy・アプリ依存の log query 調整 | stage 系 demo アプリ（次段） |
| 題材アプリ（仕込みバグ込み） | stage 系（cloud 常駐 fixer 教材は `stage/08-server-500-broken`。`stage/06`→`07` の drift 系は local observe box 調査の教材） |

## build order（次の一手）

1. **A の最小 e2e**: [`infra/`](infra/) の CDK を host で deploy → S3 に triage を置き → CodeBuild で fixer の `claude -p`（直 key）を回し → PR が出るところまで（spike の延長。直 key なので Bedrock 承認待ち不要）。← 完了（IaC done、実 deploy で PR 生成まで確認済み）。
2. **triage 配線**: CloudWatch 5XX alarm → SNS → Lambda（Logs Insights → actionable 判定 → sanitize → S3 PUT）。起動は S3 event → EventBridge rule → StartBuild/RunTask を別に配線（観測に StartBuild を持たせない）。← 未着手。
3. **identity 締め**: 2 ポリシーを実 role に当て、観測が Bedrock/secret 不可・修正が incident read 不可を実機で確認。← 未着手。
4. **B を併設**して A と比較 → ADR 段階 4（教材化）。← 完了（AgentCore Runtime での実 deploy・fix PR 生成まで確認済み。教材化は `stage/08-server-500-broken` + 生成 PR で対応）。

ADR ([docs/decisions/cloud-unattended-sre.md](../../../docs/decisions/cloud-unattended-sre.md)) は 1・4 の完了を受けて `Accepted` に更新済み。2・3 は同 ADR「残差・未決」に引き続き記載する。
