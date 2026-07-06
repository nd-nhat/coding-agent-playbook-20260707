# spike: Bedrock 上の agent が triage から fix を導けるか

ADR [cloud-unattended-sre.md](../../../docs/decisions/cloud-unattended-sre.md) の核心仮説を、
**CloudWatch / Lambda / Fargate を一切作らずに**検証する。

> `claude -p`(on Bedrock) に「**sanitized triage**（観測段が渡す構造化診断）+ **壊れた repo**」だけを渡し、
> **既知の正解 fix に近い修正**を最小で導けるか。

## なぜこの形か

- **正解が分かっている題材**を使う: `stage/06-readings-drift-broken`（壊れ）と `stage/07-readings-drift-fixed`（直し）が
  既に存在する。06 のバグは upstream の契約ドリフト（readings API が `{data:{readings:[…]}}` で返すのに contract が
  `{readings:[…]}` を期待）で、07 がその fix。agent の出力を 07 と読み比べれば質を測れる。
- **ADR の identity 境界をそのまま再現**: agent に渡すのは triage（生ログ/secret なし）+ repo だけ。**AWS read を持たせない**
  （fixer = 修正 identity）。triage は固定 schema の sanitized handoff（[triage.json](triage.json)）。

## 前提（backend を選ぶ）

spike が測る「**agent が直せるか**」は backend（推論の課金/認証経路）に依らない。なので gate は
`BACKEND` env で 2 経路から選べる（既定 `bedrock`）:

| `BACKEND` | 要るもの | 位置づけ |
|---|---|---|
| `bedrock`（既定） | 下記「AWS 側の前提」(1〜5) | **本番 auth track**。cloud 常駐の HOTU は IAM role で model access を gate する Bedrock が正。AWS 資格情報で課金 |
| `anthropic` | `ANTHROPIC_API_KEY` + `claude` CLI（と triage 検証用 `python3`）だけ | **gate を AWS 承認待ちから decouple** する近道。新規 account の Bedrock quota=0（下記 2 の chicken-and-egg）に阻まれず、今すぐ核心仮説を検証できる。直 key 課金 |

`anthropic` 経路は ADR の identity 境界（model を IAM で gate）を再現しないが、spike はそもそも
境界の hard 保証を担わない（下記「境界の限界」）ので、**gate 判定の妥当性は変わらない**。Bedrock の
承認が降りたら `BACKEND=bedrock` で同じ harness を回し直し、本番経路でも裏取りする。

`anthropic` で既存の Bedrock 環境と混線しないよう harness が 2 点ガードする: (1) `ANTHROPIC_MODEL` は **直 ID**（`claude-opus-4-8` 等）が要る。Bedrock の inference profile ID（`global.anthropic.…` 等）が残っていると弾く。(2) **隔離した空 `CLAUDE_CONFIG_DIR`** で `claude` を起動し、user の `~/.claude/settings.json` の Bedrock 設定（`CLAUDE_CODE_USE_BEDROCK=1` 等）を読ませない（process env の unset だけでは settings env override で覆されうるため）。

### AWS 側の前提（`BACKEND=bedrock` の場合・実行者が用意）

実 invoke には Bedrock が要る。harness はこれが無くても scaffold 済みで、揃った瞬間に走る:

1. **Anthropic モデルの access を有効化**。Anthropic は AWS Marketplace 経由のため、公式 prerequisites は **AND 条件**で 3 つ要る ([公式 docs](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html))：
   - **(a) AWS Marketplace permissions**: setup identity に `aws-marketplace:Subscribe` / `aws-marketplace:Unsubscribe` / `aws-marketplace:ViewSubscriptions` (初回 invoke で背景の auto-subscription が走るため必要。完了後の runtime identity は invoke-only で OK)
   - **(b) 有効な支払い方法**: AWS Marketplace purchase の前提
   - **(c) Anthropic First Time Use (FTU) form の submit**: **account / org 単位で 1 回**だけ (commercial regions 横断、org の management account で submit すれば child accounts に継承。opt-in region は region ごとに再 submit が必要)。**UI**: Bedrock console → Model catalog → Anthropic モデル選択 → 初回 invoke / playground 起動時にフォームが出る。**CLI**: `aws bedrock put-use-case-for-model-access --form-data fileb://<path-to-json>` ([`PutUseCaseForModelAccess` API ref](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_PutUseCaseForModelAccess.html))。完全 programmatic な access enable では Step 1 [`ListFoundationModelAgreementOffers`](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_ListFoundationModelAgreementOffers.html) → Step 2 `PutUseCaseForModelAccess` (Anthropic のみ) → Step 3 [`CreateFoundationModelAgreement`](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_CreateFoundationModelAgreement.html) → Step 4 [`GetFoundationModelAvailability`](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_GetFoundationModelAvailability.html) の順 ([SDK/CLI 手順](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html#model-access-modify))。setup role は `AmazonBedrockFullAccess` policy が手早い
2. **Anthropic Claude モデルの token quota を申請**。新規 / 未利用 account では Anthropic 系の TPD/TPM が `0` または低い値で初期化されている場合があり (AWS 公式 [docs](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-runtime.html) では「new accounts might receive reduced quotas」と条件付き、実例として今回の検証 account では全 Anthropic Claude モデルが `Value: 0.0`)、Service Quotas console で確認して足りなければ Request quota increase する (使う inference profile の系統に合わせて、`global.*` profile なら `Global cross-Region model inference tokens per minute for Anthropic Claude <model>`、`<region>.*` profile なら `Cross-region model inference tokens per minute for ...` を申請する。on-demand TPM だけ上げても cross-region 経路は throttle されるため経路に対応する quota を申請する) ([bedrock quotas docs](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas.html))。**Cross-region / Global cross-region TPM (per-minute) は `Adjustable=True`** (on-demand TPM と TPD は `Adjustable=False` の場合があるが、Cross-region TPM の承認時に Support が TPM/TPD/on-demand TPM の 3 つを一括 offer する運用)。**Basic Support tier で submit 可**。新規 account は「priority will be given to customers who generate traffic that consumes their existing quota allocation」 ([quotas-runtime docs](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-runtime.html)) の chicken-and-egg があるため、申請文に**具体的 use case + 小さい token 量 + 短い実行**を明示する。Opus 4.x が `not available for this account` で弾かれる場合は AWS entitlement plane と Anthropic runtime 間の sync bug 既知 ([https://github.com/anthropics/claude-code/issues/51183](https://github.com/anthropics/claude-code/issues/51183))。まず Sonnet 系で申請を通し、Opus は後追いで再申請するのが現実的
3. **正しい inference profile ID を `ANTHROPIC_MODEL` に設定**。exact ID は account / region で異なるため、既定値（`us.anthropic.claude-opus-4-8`）が合わない場合は `aws bedrock list-inference-profiles` で確認して設定する。ap-northeast-1 なら `global.anthropic.claude-sonnet-4-6` / `jp.anthropic.claude-opus-4-8` 等
4. **AWS 資格情報**（実行環境に）。**runtime invoke 用**の IAM action は `bedrock:InvokeModel` / `bedrock:InvokeModelWithResponseStream` / `bedrock:ListInferenceProfiles` / `bedrock:GetInferenceProfile` (Converse / ConverseStream API もこの InvokeModel 系 action で許可される — `bedrock:Converse` / `bedrock:ConverseStream` という独立 IAM action は AWS Service Authorization Reference に存在しない。AWS 公式 [inference prerequisites](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-prereq.html) 参照。least-privilege ポリシーを作るなら全部入れる。欠けると起動時 / streaming で Deny される)。**setup 用 identity は別軸**で上記項目 1 (a) の Marketplace 権限 + `bedrock:PutUseCaseForModelAccess` 等が必要 (auto-subscription path のため)。setup 完了後の runtime identity は invoke-only で OK。**`global.*` cross-Region inference profile を使う場合**は least-privilege role で source-region inference profile + regional foundation model + regionless global foundation-model ARN の **3 つすべてに bedrock 認可**が必要で、加えて org SCPs は `unspecified` requested region を allow する必要がある (region 制限 SCP がある環境で詰まる)。fix の git/gh は box の proxy 認証で通る。
5. `claude` CLI と、triage の schema 検証用に `python3` が PATH にある

## 使い方

```bash
# 既定: BACKEND=bedrock, TARGET_BRANCH=stage/06-readings-drift-broken, ANSWER_BRANCH=stage/07-readings-drift-fixed, triage=triage.json
bash examples/sre-bedrock/spike/run-spike.sh

# region / model / 題材を変える場合（Bedrock）
AWS_REGION=us-west-2 ANTHROPIC_MODEL='us.anthropic.claude-opus-4-8-v1:0' \
  bash examples/sre-bedrock/spike/run-spike.sh

# ap-northeast-1 の典型（global cross-region inference profile）
AWS_REGION=ap-northeast-1 ANTHROPIC_MODEL='global.anthropic.claude-sonnet-4-6' \
  bash examples/sre-bedrock/spike/run-spike.sh

# 直 Anthropic key で gate だけ回す（AWS 承認待ちと decouple。ANTHROPIC_API_KEY を環境に用意）
BACKEND=anthropic bash examples/sre-bedrock/spike/run-spike.sh

# 直 key で model を変える（既定は claude-opus-4-8）
BACKEND=anthropic ANTHROPIC_MODEL=claude-sonnet-4-6 \
  bash examples/sre-bedrock/spike/run-spike.sh
```

> このスクリプトは **mac/Linux でローカルに 1 回回す使い捨ての検証 gate** のため **sh 版のみ**とし、`.ps1` 対は持たない。これは [CLAUDE.md](../../../CLAUDE.md) の `.sh`/`.ps1` pair 方針を**この ephemeral artifact には適用しない**という意図的な scoped 判断であり、CLAUDE.md の node 単一実装例外（恒久 tooling 向け）とは別物。Windows host で回す場合は Git Bash / WSL で上記 bash を実行する（PowerShell 5.1 直叩きの導線は持たない）。

## 何をするか

1. `TARGET_BRANCH`（壊れた stage）を **detached worktree** に展開（実 stage worktree は汚さない）
2. backend に応じて `claude -p` を起動し（`bedrock` は `CLAUDE_CODE_USE_BEDROCK=1` + AWS 資格情報 / `anthropic` は直 `ANTHROPIC_API_KEY`）、triage + repo だけを入力に最小 fix をさせる
   （`--tools Edit Read Grep` で利用可能ツールを限定 + `--strict-mcp-config` で MCP を読まない。AWS/network 系ツールを渡さない）
3. agent の `git diff` を出力
4. **答え合わせ**: 既知 fix（`TARGET..ANSWER` の diff）が触るファイルと、agent が触ったファイル/キー（`data.readings`）を突き合わせ
5. detached worktree を片付け

スコア（既知 fix ファイル網羅 / 最小性=余計な変更なし / fix キー検出）は **目安**。最終判定は人間が agent diff と既知 fix を読み比べる:

```bash
git diff stage/06-readings-drift-broken stage/07-readings-drift-fixed
```

triage は ADR の sanitized handoff 制約を harness 側でも enforce する（size 上限 / **JSON parse して top-level shape 検証**〔`schema_version`・`incident.signature` 必須・未知 top-level キー拒否〕/ secret マーカー拒否）。検証は `python3`（必須）で、full な JSON Schema validator ではない。

## 境界の限界（正直な注記）

この spike は ADR の identity 分離を **`--tools Edit Read Grep` + `--strict-mcp-config`（利用可能ツールを repo 編集系に限定し MCP を読まない）で近似**するに留まり、**hard boundary ではない**:

- `claude -p` の子プロセスは **Bedrock 推論用の AWS 資格情報を環境に持つ**（推論に必須なため）。tool は絞っても process env のクレデンシャル自体は残る。
- `Read` は **repo 内に path-scope されない**。

真に「repo + triage だけ」を保証するのは spike の役割ではなく、**本番パイプライン側**（ADR の観測/修正 identity 分離・mount/credential 分離・read を観測段に閉じる設計）が担う。spike はあくまで「agent が直せるか」の検証に絞る。

## spike とパイプライン本番の違い

本 spike は「agent が直せるか」だけを見る。本番（ADR 図）は上に **CloudWatch→SNS→Lambda triage の自動配線**、
**`gh pr create` + 人間 merge の承認ゲート**、**観測/修正 identity 分離**が乗る。spike が通れば、残りは配線。

## 判定の更新

spike が安定して妥当 fix を出せたら、ADR のステータスを `Proposed → Accepted` に更新する。
出せない（題材を変えても誤修正/過剰修正が続く）なら、triage の渡し方や allowedTools 範囲、モデル選定を ADR で見直す。
