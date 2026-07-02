# Pattern B: AgentCore Runtime + Claude Agent SDK

[`examples/sre-bedrock/pipeline/README.md`](../README.md) でいう **パターン B**「AgentCore Runtime で Claude Agent SDK」の最小実装。Pattern A (`pipeline/infra/`, `pipeline/fixer-entrypoint.sh`) と並列で deploy できる独立 stack。

## Pattern A との関係

```
                       sanitized triage を S3 に PUT
                                    |
                                    v
                     EventBridge (Object Created, prefix triage/)
                                    |
                            ┌───────┴───────┐
                            ▼               ▼
                       Pattern A         Pattern B
                       CodeBuild         CodeBuild (bridge)
                       claude -p CLI     bridge.sh: triage + 関連 file 抜粋 →
                       (Edit/Read/Grep   InvokeAgentRuntime → patches を適用 →
                        on Bedrock)      git push + PR
                            │               │
                            └───────┬───────┘
                                    ▼
                              fix branch + PR
```

両 pattern は **同じ triage を独立に処理**できる (S3 bucket は別、PR_BASE / FIX_BRANCH を分離)。差分:

| | Pattern A | Pattern B (本 stack) |
|---|---|---|
| 推論ホスト | CodeBuild 上の `claude -p` CLI | AgentCore Runtime (Node 22 hosted) 上の Agent server |
| Bedrock 呼出 | claude CLI → `@anthropic-ai/sdk` 経由 | `@aws-sdk/client-bedrock-runtime` 直 (Messages API) |
| Tool 環境 | `claude -p --tools Edit Read Grep` (CLI 同梱) | bridge が input.files で repo 抜粋を渡し、agent は structured patches を返す |
| 識別子境界 | CodeBuild が Bedrock InvokeModel を直接持つ | bridge は `InvokeAgentRuntime` のみ、Bedrock InvokeModel は runtime 側 (= 推論を identity 分離) |
| custom tool / 承認ゲート | CLI flag (`--tools`/`--strict-mcp-config`) で限定 | agent server の handler で自由に設計可能 (本実装は最小 = JSON in/out) |
| 冪等 push + PR | `pipeline/fixer-entrypoint.sh` (PR-B で冪等化) | `bridge.sh` (同じ idempotent ロジックを移植) |

## 構成

```
agentcore/
├── agent/                  # AgentCore Runtime で動く Node 22 agent server
│   ├── package.json
│   └── server.js           # 0.0.0.0:8080 で /ping + /invocations
├── bridge.sh               # CodeBuild が走らせる bridge (S3 cp / clone / Runtime invoke / patches 適用 / push / PR)
├── infra/                  # CDK (TypeScript)
│   ├── bin/app.ts
│   ├── lib/agentcore-stack.ts
│   ├── package.json
│   ├── cdk.json
│   └── tsconfig.json
└── README.md
```

## 検証済み / 未検証

- **box で検証済み**: `npm ci && npm run build && cdk synth` (型 + CloudFormation template の整合)。
- **host で実 AWS 検証済み**: 実 deploy、AgentCore Runtime のコンテナ起動と /ping 200 健全性、S3 event → bridge → Runtime invoke → fix PR 到達まで確認済み。

## 前提 (host)

- Node 20+ / AWS CLI / AWS CDK (`npx aws-cdk` でも可)
- deploy 用 AWS 資格情報 (本 stack は CloudFormation / S3 / CodeBuild / IAM / Events / Secrets / Bedrock-AgentCore リソースを作る)
- Bedrock の Claude モデル access が account に降りていること (本実装の既定は `global.anthropic.claude-opus-4-6-v1`)
- 修正対象 repo に push + PR 作成できる **repo-scoped GitHub token**

## 手順 (host)

```bash
cd examples/sre-bedrock/pipeline/agentcore/infra
npm ci
npm run build

# 初回のみ
npx aws-cdk bootstrap

# deploy。targetRepo は必須。targetBranch は既定 stage/08-server-500-broken (本 pattern B の演習対象)。
npx aws-cdk deploy \
  -c targetRepo=<owner>/<repo> \
  -c targetBranch=stage/08-server-500-broken \
  -c prBase=stage/08-server-500-broken
```

deploy 後、**GitHub token を Secret に投入**:

```bash
aws secretsmanager put-secret-value \
  --secret-id <FixerGithubTokenSecretArn の値> \
  --secret-string 'ghp_...'
```

### e2e を起こす

[stage/08-server-500-broken 用 triage](../../spike/triage-server-500.json) を S3 に置くと、本 stack の bridge CodeBuild が動く:

```bash
aws s3 cp ../../spike/triage-server-500.json "s3://<TriageBucketName>/triage/$(uuidgen).json"
```

bridge は:
1. triage を S3 から取得 + validate
2. 修正対象 repo を clone (token は build phase で取得)
3. 修正候補 file (`apps/*/src/**` / `packages/*/src/**` の `.ts/.tsx/.js/.mjs`) を抜粋
4. `aws bedrock-agentcore invoke-agent-runtime` で AgentCore Runtime に `{triage, files}` を投げる
5. Runtime 側 (agent server) は Bedrock InvokeModel で Claude に推論させ、`{patches: [{path, newContent}], reasoning}` を返す
6. bridge が patches を適用 (path traversal ガード付き)
7. **PR-B (`pipeline/fixer-entrypoint.sh` 冪等化) と同じ logic** で idempotent push + PR (`sre-fix-pattern-b/<incident_id>`)

### 片付け

AWS keep が前提なので本 stack は keep のまま運用する想定。実験を畳むなら:

```bash
npx aws-cdk destroy
```

## 罠 / 未実装

- **AgentCore Runtime container は ARM64 前提**だが `fromCodeAsset(NODE_22)` は AWS-managed image を使うので Docker build は不要。ただし agent code 側で **Linux/ARM64 で動かない native module を入れない**こと (現状 `@aws-sdk/client-bedrock-runtime` のみで pure JS)。
- **AgentCore Runtime は session 単位で state を持つ**が、本実装は session を per-invocation 独立 (UUID) にして state を持たせていない。multi-turn 対話 / 承認ゲート / custom tool 等の Pattern B らしい機能はここでは出していない (= 最小 e2e のみ)。
- **agent input の token 上限**: triage + 抜粋 file を JSON 1 リクエストに詰めるので、repo 巨大化時は agent input が肥大化する。本実装は 50KB/file + `apps/`/`packages/` 限定で抑える。
- **structured patches の信頼性**: モデルが newContent をファイル全体で返すため、長大 file の場合は途中で truncation するリスクがある。max_tokens = 4096 で運用していて、十分でない場合は SSE streaming 化や patch 差分形式への変更が要る。

## 関連

- [`pipeline/README.md`](../README.md) (Pattern A/B 全体設計)
- [`pipeline/infra/`](../infra/) (Pattern A の CDK)
- [`pipeline/fixer-entrypoint.sh`](../fixer-entrypoint.sh) (Pattern A の bridge / 推論。本 stack の `bridge.sh` と並列)
- [`docs/decisions/cloud-unattended-sre.md`](../../../../docs/decisions/cloud-unattended-sre.md) (ADR)
