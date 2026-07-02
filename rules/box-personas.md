# box persona と権限ティア

coding agent を **権限ティアごとに別 box / 別 identity に分離**して回すための規約。
通常開発（write）・AWS 可観測性の調査（read-only）・deploy（host privileged）を**混ぜない**。
全体の実行モデルは [box-ops.md](box-ops.md)、PR ライフサイクルは [pr-followup.md](pr-followup.md) 参照。

## なぜ分けるか（原則）

業界の SRE/agent セキュリティ実践（AWS DevOps Agent の read-first・Agent Space per environment、
PagerDuty の Review/Autonomous ゲート、WorkOS の agent identity 分離、CoSAI の JIT 権限、
Simon Willison の lethal trifecta、Grafana MCP の opt-in read-only）に共通する原則を、本 playbook に写す。

- **P1 read-first / write-gated**: 調査(read)は自走、修正・再 deploy(write/remediation)は人間承認。
- **P2 persona ごとに別 identity・別 credential**: 1 つの広域資格を使い回さない／ユーザー資格を借用しない。
- **P3 standing 権限を持たせない**: 短命・task-scoped・即失効。長期 full-access key の直焼きはアンチパターン（blast radius）。
- **P4 read-only の境界は権限層(IAM)で作る**: tool 層(CLI/MCP)に依存しない。read-only は IAM ロールで強制する。
- **P5 観測データ(ログ本文)は untrusted**: lethal trifecta（private data + untrusted content + external comms）の
  同時成立を避ける。観測 persona は private data(AWS read) と untrusted content(ログ) を持つので、
  **external comms を AWS API endpoint のみに絞って** trifecta を崩す（狙い）。ただし sbx の現行機能では
  この絞り込みは構造的に実現できないと確認済み（下記「既知の制約」参照）。当面の実効境界は **P4 の IAM** が担う。

## persona マトリクス

| persona | 実行場所 | repo | git | AWS cred | network | 役割 |
|---|---|---|---|---|---|---|
| **dev box** | sbx microVM | bind-mount (write) | push/PR | なし | github + codex pair + MCP | 通常開発・実装・codex review・PR |
| **observe box** | sbx microVM | **clone copy**（`dev.sh observe` = `--clone .`。host checkout を mount せず host repo を汚さない＝read-only 相当・push しない。committed runbook を含む） | なし | read-only・短命 session・スコープ済 | **AWS read API endpoint のみ**（CDN 不可、狙い。sbx の現行機能では構造的に未達、下記「既知の制約」参照） | AWS 可観測性の調査（ログ/状態を読む、agent が能動的に `aws` コマンドを叩く） |
| **host** | host | working tree | — | write/deploy | full | deploy/destroy・headful browser 確認・bridge 応答 |

**不変条件**:
- write/deploy の AWS cred は **host だけ**。observe box は **read-only cred だけ**。dev box は **AWS cred ゼロ**。
- observe box の cred は **host が mint した短命 session を実行時注入**し、box 内では `AssumeRole` しない
  （IAM で `sts:AssumeRole` を明示 Deny。credential broker 化を防ぐ。P3）。
- **アプリ閲覧（CDN/ブラウザ）は observe box でやらない**（CDN を許可すると `https://<cdn>/<path>` で
  観測データを exfil できる＝trifecta 復活。P5）。閲覧は AWS cred 非保持側（host か dev box の headless chrome）で行う。
  現状はこれを network 側で強制できていないため運用規律として徹底する（下記「既知の制約」参照）。

### 既知の制約: identity/network 分離が sbx の現行機能では実現できない

`cmd_observe`（`scripts/dev.sh`）は dev box と**同一の image (`sbx/Dockerfile`) / 同一の `claude` agent**
で起動するため、github/anthropic/openai の secrets proxy も dev box と同様に注入される（P2 の「別
identity」が未達）。`sbx secret set [-g | SANDBOX] <service>` は sandbox 名を指定した個別 scope を
サポートするが、これで P2 が解決するわけではない: (1) observe box も built-in `claude` agent を起動する
ため anthropic secret は observe にも必要で、github/openai だけを固定名 dev box に scope しても
anthropic は global のまま残り observe に注入され続ける、(2) codex reviewer は dev box ではなく別
sandbox `cdx-<NAME>` を使い、`scripts/dev.sh` は `sbx secret ls -g` に **global** の openai 登録が
あるときだけ `cdx-<NAME>` を auto-provision する（`scripts/dev.sh:1217`）ため、openai を dev box だけに
scope すると global 登録が消えて `/a2a-review` / `/pr-codex-ci` の reviewer 経路が壊れる。したがって
sandbox-scoped secret は「observe box だけを個別 identity に分離する」という目的には使えない仕組みで、
採用しても P2 は未達のまま残る。`shell`（AI agent 無しの素の対話 shell）への agent 切り替えなら secrets
注入自体は避けられるが、それは observe persona の「agent が能動的に `aws` コマンドで調査する」という
役割を失わせるため採らない。

network 側も同様に構造的な制約がある: `sbx` のローカル network policy はホスト全体に効く baseline 許可
（github / AI provider API 等）を sandbox 単位で削除できず、`sbx policy deny "**"` は同一 sandbox の
allow も道連れでブロックするため（実機確認済み）、observe box を「AWS のみ到達可能」に絞り込む carve-out
が構造的に組めない（P5 が未達）。仮に sbx が将来 sandbox 単位の deny-with-carve-out をサポートしても、
observe box は built-in `claude` agent として動く以上 Anthropic の model endpoint への到達が必須で、
AWS のみへの carve-out は agent 自体を機能不能にする。P5 を真に達成するには sbx 機能の追加だけでは足りず、
AWS 内で完結する model endpoint や non-agent workflow への architecture 変更が要る。

実効している境界は **P4 の IAM（read-only ロール）のみ**。これは現時点で受容する既知の制約とする
（sbx が box 種別単位の secret scope や sandbox 単位の deny-with-carve-out をサポートすれば再検討する）。
追跡: [https://github.com/kanka-jp/coding-agent-playbook/issues/161](https://github.com/kanka-jp/coding-agent-playbook/issues/161)

### 補足: github author identity は別軸で分離できる

上記「既知の制約」は **sbx secret 注入 identity**（anthropic/openai/github credential の box 種別分離）の話。**dev box の github "author" identity**（push / PR を誰の名前で行うか）は別軸で、host broker + sbx proxy の token 置換により **GitHub App bot** に分離できる（canonical repo で opt-in、author=bot は自己 approve 不可なので compromised box が human approval 無しに merge を通せない machine gate 化。P2「ユーザー資格を借用しない」の github 側実現）。host は sbx secret の値を読めないが presence で toggle する仕組みで、上記 secret scope 制約とは独立に成立する。設計: [../docs/decisions/app-identity-gate.md](../docs/decisions/app-identity-gate.md)、手順: [../docs/setup.md](../docs/setup.md)「github を App identity 化する」。

## CLI 既定・MCP 任意

read-only の境界は IAM が作る（P4）ので、CloudWatch MCP 等は**必須でない**。observe box では **`aws` CLI を既定**とする
（最小・clone で再現できる）。MCP は「作り込み済み観測ツール(anomaly/analyze)が欲しい」「多サービス統一面が要る」時だけの
任意オプション（MCP tool 面自体が prompt-injection surface を増やすため最小では入れない）。
具体コマンドは [../examples/observe/runbook.md](../examples/observe/runbook.md)、read-only IAM は
[../examples/observe/readonly-iam-policy.json](../examples/observe/readonly-iam-policy.json) を参照。

## ユーザーストーリー

### US1 通常開発（dev box）※本体
dev box で worktree → 実装 → `/a2a-review` → `gh pr create` → `/pr-codex-ci` → merge-ready。
AWS cred はこの経路に出てこない。大半の作業はここ。

### US2 host 側で使うケース（privileged / 人手）
- **deploy**: host で `npm run deploy`（write cred は host のみ）→ 出力 URL を控える（**非 commit**・口頭/非公開メモで提示）。
  後始末は `cdk destroy`（NAT/ALB/Fargate の課金停止）。
- **headful 確認**: host Chrome で deploy 済み URL を目視 / box からは cdp-bridge（[headful-bridge.md](../docs/headful-bridge.md)）か、
  CDN を `sbx policy allow` 後に dev box の headless chrome-devtools MCP で閲覧（dev box は AWS cred 非保持なので trifecta 不成立）。
- **bridge**: box が host しか見えない事実を `/host-ask` → host が `/host-answer`。

### US3 AWS 調査（observe box）※運用保守フェーズの実環境版
deploy 済み環境で異常（例: 診断が 502）→ observe box を起こし、host が mint した read-only session で
`aws logs filter-log-events` 等から `external_call{kind:upstream,path:...}` を読む → 構造化ログがそのまま切り分け材料 → 原因特定。
**read=observe box で自走 / 修正=dev box(write) / 再 deploy=host(privileged)** の read-first・write-gated 3 段（P1）。
既定は **Review 相当**（人間が修正/再 deploy を承認）。Autonomous な自動修正は扱わない（教材の安全側）。

## 公開リポ制約

実 URL / account ID / ARN / log group 実名は **commit しない**（[../README.md](../README.md) / 公開リポ前提）。
committed なのは placeholder 入りテンプレと runbook だけ。実値は実行時に env/file 注入し、ランタイムメモは
gitignore 済みの `.claude/tmp/` に置く。
