# 決定記録: cloud 常駐の無人 SRE 自動化（CloudWatch → agent → PR）の実行基盤と認証

**ステータス: Accepted（2026-07-01）** — 実行基盤（Amazon Bedrock）・認証（AWS IAM）・2 パターン（`claude -p` / Agent SDK）の設計を確定し、両パターンとも最小 e2e（実 deploy → S3 triage → fixer 起動 → fix PR 生成）の実機 spike を通過した（パターン A: [https://github.com/kanka-jp/coding-agent-playbook/pull/151](https://github.com/kanka-jp/coding-agent-playbook/pull/151) 〜 [https://github.com/kanka-jp/coding-agent-playbook/pull/154](https://github.com/kanka-jp/coding-agent-playbook/pull/154)、パターン B: [https://github.com/kanka-jp/coding-agent-playbook/pull/156](https://github.com/kanka-jp/coding-agent-playbook/pull/156) 〜 [https://github.com/kanka-jp/coding-agent-playbook/pull/159](https://github.com/kanka-jp/coding-agent-playbook/pull/159)）。CloudWatch alarm 経由の full trigger 配線と Slack 承認通知は未実装のまま残る（詳細は「残差・未決」参照）。

## 背景: 「運用保守」には別軸の 2 つがある

運用保守・バグ修正フェーズには、混同してはいけない 2 つの実行モデルがある。

| | local 調査（既存） | **cloud 常駐（本記録）** |
|---|---|---|
| 起点 | **人間**が手元で起こす | **CloudWatch イベント**（5xx alarm 等）が起こす |
| 実行場所 | 手元の sbx observe box | **AWS 上に常駐**（Fargate / AgentCore Runtime） |
| 人間の位置 | keyboard にいる（HOTL） | keyboard にいない（HOTU） |
| 役割 | read-only で原因を**調べる** | 一次対応として triage → **fix PR まで自走** |
| 規約 | [box-personas.md](../../rules/box-personas.md) US3 / [examples/observe](../../examples/observe/runbook.md) | 本記録 |

両者は**補完**（local = 人が深掘り / cloud = 無人で一次対応）であって競合ではない。[box-personas.md](../../rules/box-personas.md) の observe box は **local の HOTL 調査道具**であり、本記録の cloud 常駐パターンを縛るものではない。本記録は cloud 側の実行基盤と認証だけを決める。

## 決定 1: 実行系は Bedrock 上の `claude -p` と Agent SDK（`ant` / Managed Agents は採らない）

cloud で agentic に「調査 → 修正 → PR」を回す候補は 3 つ。

| 候補 | Bedrock(AWS 内完結)で動くか | 判定 |
|---|---|---|
| Anthropic **Managed Agents**（`ant beta:sessions`） | **不可**。Anthropic Platform 専用機能で、Bedrock は素のモデル推論しか出さない（Bedrock 側「Managed Agents」は別系統で Anthropic のものではない） | **除外** |
| **`claude -p`**（Claude Code headless） | 可（`CLAUDE_CODE_USE_BEDROCK=1`） | **採用 = パターン A** |
| **Claude Agent SDK**（自前プロセスで agent loop） | 可。Skills / subagents / MCP もそのまま動き、AgentCore Runtime に載る | **採用 = パターン B** |

`ant`（Managed Agents）を採らないのは、本パターンの第一要件が **AWS 内完結・IAM 課金**だから。Managed Agents は Anthropic Platform の従量 API key を要求し、この要件と両立しない。両パターンを併設して比較できるようにする（A = shell パイプ的に軽い / B = custom tool・承認ゲートをコードで握る）。

## 決定 2: 認証/課金は Bedrock（IAM）。subscription は使わない

| 認証 | 本パターンでの可否 | 理由 |
|---|---|---|
| subscription OAuth（`claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN`） | **不可** | Consumer ToS §3.7 が「自動・非人間手段でのアクセスは API key 経由を除き禁止」。Anthropic Help Center も「shared production automation は Platform の API key を使え」と明示。subscription は "ordinary, individual usage" 限定で、cloud 常駐の無人基盤はこれに当たらない |
| Anthropic Platform API key（`sk-ant-api03-`） | 可だが採らない | AWS 外課金。AWS 内完結の要件から外れる |
| **Amazon Bedrock（AWS IAM）** | **採用** | AWS アカウント内で IAM 課金（Anthropic への外部 key を持たない）。`CLAUDE_CODE_USE_BEDROCK=1` + `AWS_REGION` + `ANTHROPIC_MODEL`=Bedrock inference profile id。**VPC 内に閉じたい場合は別途** `bedrock-runtime` の Interface VPC Endpoint(PrivateLink) を併用する（IAM 認証だけでは経路は regional service endpoint で VPC 内通信にはならない） |

**subscription の正しい置き場所は local 側**（[box-personas.md](../../rules/box-personas.md) の dev box / observe box で人間が対話的に回す経路）。cloud 常駐の無人パイプラインに subscription token を焼くのは ToS 違反かつ enforcement 実績（server 利用トークンの遮断）があるため採らない。

> 補足（本決定の根拠ではない・参考）: subscription を採らない判断は **§3.7（自動化禁止）に基づく**もので、課金プールの扱い（2026-06-15 の「`claude -p` / Agent SDK を subscription プールから分離」変更とその保留）とは**独立**。課金側がどう転んでも本決定は変わらない。

## 決定 3: アーキテクチャと承認ゲート

```text
CloudWatch (ALB/API GW 5XX alarm  or  Logs metric filter ERROR/5xx)
   └─► Alarm ─► SNS ─► Lambda(trigger + triage) … 観測 identity（AWS read + S3 PutObject のみ・外部 egress なし）
                          │  該当ログを Logs Insights で取得 → actionable 判定 → triage を sanitize
                          ▼ actionable のみ、sanitized triage を handoff（AWS read はここで終わり）
        ┌────────────────────────────┬────────────────────────────┐
        ▼ パターン A                   ▼ パターン B            … 修正 identity（repo-write / AWS read なし）
   Fargate / CodeBuild            AgentCore Runtime
   claude -p on Bedrock           Claude Agent SDK on Bedrock
        └─► triage 結果 + repo 調査 → runbook(Skill) → fix → open PR ◄─┘
                          │
              PR は無人で開く ／ merge は人間（承認ゲート）
```

**承認ゲート**: PR 作成までは無人、**merge は人間**。これは playbook の「merge はユーザー判断・デフォルトは報告して停止」（[CLAUDE.md](../../CLAUDE.md)）と一致する。

**identity 境界（決定・拘束条件）**: ログ / AWS の read は **Lambda の triage 段（観測 identity）でのみ**行う。観測 identity の権限は **AWS read + sanitized triage を S3 に PutObject するだけ**に絞り、**fixer の起動権限 (`codebuild:StartBuild` / `RunTask` 等) も GitHub を含む外部 egress も持たせない**。fixer の起動は観測 identity から独立した **S3 event → EventBridge rule** という infra 側のトリガに分離し、fixer に渡るのは **event 由来の object key だけ**とする（実装は [examples/sre-bedrock/pipeline/README.md](../../examples/sre-bedrock/pipeline/README.md) 参照）。これは **dispatch の payload 自体が間接 exfil チャネルになり得る**ことへの対策でもある: 観測側が `StartBuild` の env override / message body にログ由来データを自由に載せられると、fixer の GitHub egress 経由で抜けて trifecta が復活するため、そもそも観測に起動権限を持たせず override 経路自体を無くす。**handoff する triage** (S3 object) は固定 schema・allowlist・サイズ制限・raw log/secret 禁止に拘束し、S3 PutObject という書き込み専用の境界自体を sanitize gate とする。パターン A/B の fixer は **sanitized な triage 結果 (event 由来 key を GetObject) + repo だけ**を入力に取り、**AWS read を持たない別 identity**とする。単一 identity（単一 Fargate/AgentCore role）に CloudWatch read と GitHub write を同居させてはならない（破ると本 ADR が避ける lethal trifecta が成立する。下記「安全」参照）。

## 安全: lethal trifecta は cloud でも崩す

[box-personas.md](../../rules/box-personas.md) P5 の原則（private data + untrusted content + external comms の同時成立を避ける）は cloud でも生きる。無人 agent が **untrusted なログ本文** と **repo write / GitHub egress** を 1 つの identity に同居させると trifecta が成立し、悪意あるログ本文を起点に PR 経由で exfil されうる。崩し方（identity 分離は**拘束条件**＝決定 3、残りは補強）:

- **観測（AWS read + S3 PutObject のみ・fixer 起動権限も GitHub/外部 egress も無し）と 修正（repo-scoped・AWS read を持たない）を別 identity に分離**する。fixer の起動は観測 identity からでなく infra 側の S3 event → EventBridge に分離する（決定 3）。
- 修正側には **生ログでなく構造化された triage 結果**だけを渡す。handoff（dispatch payload）は **固定 schema・allowlist・サイズ制限**で sanitize し、raw log / secret / 自由 override を載せない（この handoff 境界が間接 exfil チャネル化するのを防ぐ）。
- PR を出す identity は **対象 repo に scope 絞り・短命**（[parallel-hotl-execution.md](parallel-hotl-execution.md) の PAT scope 原則と同じ）。
- **merge は人間ゲート**（決定 3）。

read/write の分離は Bedrock 側でなく **IAM と GitHub token scope** で強制する（tool 層に依存しない、box-personas P4 と同じ思想）。

## 残差・未決

- **最小 e2e は通過、full 配線は後続**: パターン A（Fargate/CodeBuild での `claude -p` on Bedrock）/ B（AgentCore Runtime での Agent SDK）とも、S3 triage → fixer 起動 → fix PR 生成までの実デプロイ検証は完了した。CloudWatch alarm → SNS → 観測 Lambda の full 配線（README「実装の置き場所」表の「次段」項目）と approval gate の Slack 連携は未着手で、stage 系 demo アプリ側での実装時に対応する。
- **修正品質の限界**: LLM は応急処置 PR は得意だが root cause 特定は弱く、postmortem も「読みやすい 80%」に留まる傾向。人間 merge gate を前提とし、自律で merge しない。
- **コスト**: Bedrock 従量（IAM 課金）。triage 段で actionable 判定し、noise では agent を起こさず記録に留める（**GitHub issue 化するなら観測の外**で。観測 identity に GitHub egress を持たせると lethal trifecta が復活する。dedup の source of truth は GitHub でなく internal state。詳細は [examples/sre-bedrock/pipeline/README.md](../../examples/sre-bedrock/pipeline/README.md)「optional: issue layer」）ことで起動回数を抑える。
- **デモアプリ実体の配置**: パイプライン実体と仕込みバグは demo アプリ（stage 系）側に置く。本記録は main 側の横断決定（認証/実行基盤）のみを担い、stage の project コードには踏み込まない（[CLAUDE.md](../../CLAUDE.md)「stage ブランチの規約」）。

## Sources

- [Build an SRE incident response agent with Claude Managed Agents — Claude Cookbook](https://platform.claude.com/cookbook/managed-agents-sre-incident-responder)
- [Run Claude Code programmatically (headless) — Claude Code Docs](https://code.claude.com/docs/en/headless)
- [Running Claude Agent SDK with Skills on Amazon Bedrock — AWS Builder Center](https://builder.aws.com/content/3AC38DtkrFlNL0p076gVNPzSHuw/running-claude-agent-sdk-with-skills-on-amazon-bedrock)
- [Legal and compliance — Claude Code Docs](https://code.claude.com/docs/en/legal-and-compliance)
- [Use the Claude Agent SDK with your Claude plan — Claude Help Center](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
- [Claude Credit Overhaul 2026: Anthropic Pauses the June 15 Change — digitalapplied.com](https://www.digitalapplied.com/blog/anthropic-claude-credit-overhaul-june-15-2026)
