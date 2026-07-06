---
name: observe-session
description: "Sets up an AWS read-only observe box investigation session end-to-end: resolves the AWS profile/region, discovers the deployed target (CloudFormation stack + the live CloudWatch Logs log group actually referenced by the running ECS task definition, or the most recently active log group for non-ECS stacks), creates/updates the read-only IAM role via examples/observe/setup-role.sh, starts an obs-* box via scripts/dev.sh observe, injects a short-lived STS session via examples/observe/start-session.sh, and smoke-tests read access. Use when the user wants to investigate a deployed AWS environment's logs/errors from an observe box, or asks to set up AWS read-only log investigation (rules/box-personas.md US3). Hands off to examples/observe/runbook.md for the actual investigation — this skill only gets the box and credentials ready."
---

# observe-session

`rules/box-personas.md` US3 (AWS 可観測性の read-only 調査) のセットアップを 1 コマンドで完結させる leaf skill。既存の `examples/observe/setup-role.sh` / `examples/observe/start-session.sh` / `scripts/dev.sh observe` を束ね、「どの AWS profile/account か」「どの stack/log group が調査対象か」の発見を自動化する。

実際の調査ロジック (ログ解析コマンド等) は持たない。box とセッションの準備が終わったら [../../../examples/observe/runbook.md](../../../examples/observe/runbook.md) に引き継ぐ。

## 引数

`profile` / `region` / `log-group`（すべて省略可）。`log-group` を指定した場合、Step 3 (対象環境の発見) を skip して直接使う。

## 前提

- host 側の `aws` コマンドは常に `--profile` / `--region` を明示する（ambient な default profile に依存しない）
- `jq` が必要（`setup-role.sh` / `start-session.sh` 自体も要求する）
- Windows では各コマンドの `.ps1` 版 (`setup-role.ps1` / `start-session.ps1` / `scripts/dev.ps1`) を使う（[../../../examples/observe/runbook.md](../../../examples/observe/runbook.md) 参照）。以下は bash 例

## 手順

```text
Progress:
- [ ] Step 1: AWS profile 解決
- [ ] Step 2: 認証確認
- [ ] Step 3: 対象環境の発見
- [ ] Step 4: read-only role のセットアップ
- [ ] Step 5: observe box の起動
- [ ] Step 6: session 注入
- [ ] Step 7: smoke test
- [ ] Step 8: ユーザーへの引き継ぎ
```

### Step 1: AWS profile 解決

引数で `profile` が与えられていればそれを使う。無ければ `aws configure list-profiles` で一覧し、1 つしかなければそれを使う。複数あればユーザーに選ばせる。

### Step 2: 認証確認

```bash
aws sts get-caller-identity --profile <PROFILE> --region <REGION>
```

`region` が未確定なら `aws configure get region --profile <PROFILE>` から取得し、それも空ならユーザーに聞く。

認証が失敗する（SSO session expired 等）場合、**このスキルはブラウザ操作を代行できない**。停止して以下を提示する:

> SSO session が無効です。`aws sso login --profile <PROFILE>` を実行してログインしてから、本スキルを再度呼んでください。

### Step 3: 対象環境の発見（`log-group` 引数指定時は skip）

```bash
aws cloudformation list-stacks --profile <PROFILE> --region <REGION> \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
  --query 'StackSummaries[].StackName'
```

`CDKToolkit` は候補から除外する。0 件なら「対象環境が deploy されていません」と報告して停止。1 件ならそれを使う。複数あればユーザーに選ばせる。

選ばれたスタックについて、**「稼働中のタスク定義が実際に書き込んでいる log group」を特定する**（同一スタック内に複数世代の log group が残っていることがあり、`describe-log-groups` の名前一覧だけでは stale なものを掴みうる）。**以下のコマンドはすべて `--profile <PROFILE> --region <REGION>` を付けて実行する**:

1. `aws ecs list-clusters` / `aws ecs list-services --cluster <cluster>` でそのスタックのクラスタ・サービスを見つける（見つからなければ ECS ベースでないスタックとみなし、下記「ECS でない場合」へ）
2. `aws ecs describe-services --cluster <cluster> --services <service...>` で `desiredCount` / `runningCount`（0 なら「サービス停止中」と報告する）と現在の `taskDefinition` ARN を取得
3. `aws ecs describe-task-definition --task-definition <arn>` の `containerDefinitions[].logConfiguration.options."awslogs-group"` から実際の log group 名を得る
4. サービスが複数（api / mock 等）あれば、名前に `api` を含むものをデフォルト候補として提示しつつユーザーに確認する

**ECS でない場合**（Lambda 等）: `aws logs describe-log-groups` でスタック名を含む log group を列挙し、候補それぞれに `aws logs describe-log-streams --log-group-name <candidate> --order-by LastEventTime --descending --max-items 1` を実行して最終書き込み時刻を比較し、最も新しいものをアクティブ候補としてユーザーに提示する。

### Step 4: read-only role のセットアップ

```bash
bash examples/observe/setup-role.sh \
  --profile <PROFILE> --region <REGION> --log-group <LOG_GROUP> [--stack-name <STACK>]
```

`--stack-name` は Step 3 でスタックを発見できた場合のみ付ける（`log-group` 引数指定で Step 3 を skip した場合は付けない。`setup-role.sh` は省略時に対応する CloudFormation read ステートメントを自動で外す）。冪等なので毎回実行してよい。出力される role ARN を控える。

### Step 5: observe box の起動

```bash
bash scripts/dev.sh observe
```

`obs-*` 命名で自動生成される。出力から box 名を拾う。既存の稼働中 `obs-*` box を再利用したいかユーザーに聞いてもよい（必須ではない）。

`dev.sh observe` は最終的に `sbx run --name <NAME> ...` で対話 attach しようとするため、対話端末を持たない agent 実行では `ERROR: inspect exec: context deadline exceeded` が出て attach 自体は失敗する。これは想定内で、box 自体は作成・起動済みになる（`sbx ls` で `<NAME>` が `running` になっていることを確認してから Step 6 へ進む）。

### Step 6: session 注入

```bash
bash examples/observe/start-session.sh \
  --profile <PROFILE> --region <REGION> \
  --role-arn <Step 4 の ARN> --box <Step 5 の box 名>
```

出力に session の有効期限 (expiry) が含まれる。

### Step 7: smoke test

```bash
sbx exec <box名> aws logs describe-log-streams \
  --region <REGION> --log-group-name <LOG_GROUP> --max-items 1
```

### Step 8: ユーザーへの引き継ぎ

**「box に入って claude に調査させる」最終ステップは対話端末 (TTY) が必要なため、本スキル実行者 (agent) からは実行できない。** 以下を提示して終了する:

- 実行コマンド: `sbx run <box名>`
- box 内で claude に投げる調査プロンプトの例（対象 log group 名を埋め込んだ具体的な一文。[../../../examples/observe/runbook.md](../../../examples/observe/runbook.md) の内容に沿う）
- session の有効期限と、失効時の再実行コマンド（Step 6 のコマンドをそのまま再掲）

## 安全上の注意

- observe box の read-only 境界は IAM が担う（network 側は既知の制約として [../../../rules/box-personas.md](../../../rules/box-personas.md) / [https://github.com/kanka-jp/coding-agent-playbook/issues/161](https://github.com/kanka-jp/coding-agent-playbook/issues/161) 参照。本スキルで新たに対処する必要はない）
- ログ本文は untrusted。本スキルは box 起動までが責務で、box 内でのログ内容に基づくコマンド生成・調査ロジックは [../../../examples/observe/runbook.md](../../../examples/observe/runbook.md) の管轄

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| Step 2 で SSO session expired | ユーザーに `aws sso login --profile <PROFILE>` を実行してもらってから再度スキルを呼ぶ |
| Step 3 で候補スタックが 0 件 | 対象環境が deploy されていない。deploy 手順は `examples/observe/runbook.md` 対象アプリの README を参照 |
| Step 3 で ECS サービスの `runningCount` が 0 | サービス停止中と報告し、ユーザーに起動意思を確認する（本スキルはサービスを起動しない） |
| `setup-role.sh` / `start-session.sh` が unresolved placeholder エラー | `--log-group` / `--stack-name` の値が正しいか（Step 3 の発見結果）を確認 |
| box 内 `sbx run` が対話端末なしで失敗する | Step 8 のコマンドはユーザー自身のターミナルで実行してもらう（agent は代行できない） |
