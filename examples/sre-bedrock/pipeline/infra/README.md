# infra: パターン A 最小 e2e の CDK（host で deploy）

[pipeline/README.md](../README.md) の build order step 1「A の最小 e2e」を実 AWS に立てる CDK (TypeScript)。

```
S3 に sanitized triage を PUT  ->  EventBridge(Object Created, prefix triage/)  ->  CodeBuild(fixer 識別子)
   fixer-entrypoint.sh を BACKEND=anthropic | bedrock で実行(triage + 壊れた repo -> claude -p -> PR)
```

CloudWatch alarm -> 観測 Lambda の自動配線（[triage-lambda/](../triage-lambda/)）はこの上に足す。本 stack は
**「fixer が実 AWS で動いて PR が出る」を最小コストで確かめる段**。

backend は context flag `-c backend=anthropic|bedrock` で切替できる（既定 anthropic）:
- **anthropic**（既定）: 直 Anthropic API key 経路。Bedrock model access が無い account でも動く。secret に key を投入する
- **bedrock**: AWS Bedrock 経由（本番経路）。Bedrock の Claude モデル access が account に降りていること。Anthropic key secret は作らず、fixer role に inference profile + foundation model への `bedrock:InvokeModel` を ALLOW する

## 検証済み / 未検証

- **box で検証済み**: `npm ci && npm run build && cdk synth`（CloudFormation 生成・型・construct エラー）。IAM Deny 3 本（`s3:ListBucket` / incident app-data read / `sts:AssumeRole*`）・secret の build phase 取得（`gh auth setup-git` で token を `.git/config` に残さない）・event 由来 key 上書きが template に出ることを確認。
- **host で実 AWS 検証済み**: `cdk deploy` → S3 triage PUT → EventBridge → CodeBuild 内で `fixer-entrypoint.sh`（`claude -p`）が実行 → 修正対象 repo に fix PR が出るところまで確認済み（anthropic / bedrock 両 backend）。CloudWatch alarm → 観測 Lambda の自動配線（[triage-lambda/](../triage-lambda/)）は本 stack の対象外で未検証のまま残る。

## 前提（host）

- Node 18+ / AWS CLI / AWS CDK（`npx cdk` でも可）。
- deploy 用 AWS 資格情報（CloudFormation/S3/CodeBuild/IAM/Events/Secrets を作れる権限）。**dev box には入れない**（persona: deploy は host）。
- 修正対象 repo に push + PR 作成できる **repo-scoped GitHub token**。
- backend=anthropic 時: 直 Anthropic API key（`sk-ant-...`）。
- backend=bedrock 時: Bedrock の対象 Claude モデルに account level の access が降りていること（AWS console → Bedrock → Model access）。

## 手順（host）

```bash
cd examples/sre-bedrock/pipeline/infra
npm ci
npm run build                      # tsc（cdk.json は bin/app.js を実行する）

# 初回のみ: account/region を bootstrap
npx cdk bootstrap

# deploy（targetRepo は必須。backend / anthropicModel / targetBranch / prBase は任意）
# 既定 backend=anthropic（直 key 経路）:
npx cdk deploy \
  -c targetRepo=<owner>/<repo> \
  -c targetBranch=stage/08-server-500-broken \
  -c prBase=stage/08-server-500-broken

# backend=bedrock（本番経路）。anthropicModel は inference profile id（既定 global.anthropic.claude-opus-4-6-v1）:
npx cdk deploy \
  -c backend=bedrock \
  -c targetRepo=<owner>/<repo> \
  -c targetBranch=stage/08-server-500-broken \
  -c prBase=stage/08-server-500-broken
```

deploy 後、**Secret に実値を投入**（IaC に焼かないので手で。論理名は出力の Secret ARN から）:

```bash
# backend=anthropic のときは AnthropicApiKey + FixerGithubToken の両方を投入
aws secretsmanager put-secret-value --secret-id <AnthropicApiKey の ARN> --secret-string 'sk-ant-...'
aws secretsmanager put-secret-value --secret-id <FixerGithubToken の ARN> --secret-string 'ghp_...'

# backend=bedrock のときは AnthropicApiKey は作られない（IAM で InvokeModel 許可）。GitHub token だけ投入
aws secretsmanager put-secret-value --secret-id <FixerGithubToken の ARN> --secret-string 'ghp_...'
```

### e2e を起こす

sanitized triage（`targetBranch=stage/08-server-500-broken` に対応する [../../spike/triage-server-500.json](../../spike/triage-server-500.json)）を S3 の `triage/` prefix に置くと、EventBridge が CodeBuild を起動する:

```bash
aws s3 cp ../../spike/triage-server-500.json "s3://<TriageBucket 名>/triage/$(uuidgen).json"
# CodeBuild が走り、修正対象 repo に fix PR が出る。ログ: CodeBuild console / CloudWatch Logs
```

### 片付け

```bash
npx cdk destroy
```

## CodeBuild 内の前提（buildspec が用意）

CodeBuild の standard image に対し buildspec が install phase で `@anthropic-ai/claude-code`（version 固定）と `gh`（無ければ pinned binary）を入れ、**build phase で** `aws secretsmanager get-secret-value` により `GH_TOKEN`（+ backend=anthropic 時は `ANTHROPIC_API_KEY`）を取得（install 中の未固定コードに secret を晒さない）、`gh auth setup-git` で token を `.git/config` に残さず認証して `fixer-entrypoint.sh` を env の `BACKEND`・`ANTHROPIC_MODEL`・`TRIAGE_S3_KEY`(event 由来) で実行する。fixer は **triage 1 件の GET と自分の secret 取得 + backend=bedrock 時は指定 inference profile/foundation model への InvokeModel のみ**（バケット列挙・incident ログ read・他 model 呼出は IAM Deny / 未許可）。

## 本番との差（この stack でやらないこと）

- CloudWatch alarm -> SNS -> 観測 Lambda の自動 triage 生成（手動 S3 PUT で代用）。
- 観測/修正の VPC 隔離・PrivateLink（[pipeline/README.md](../README.md)「egress 境界」）。
