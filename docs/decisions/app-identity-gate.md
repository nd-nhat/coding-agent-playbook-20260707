# 決定記録: box を GitHub App identity で回して human-approval merge gate を機械強制する

**status**: Accepted・機構は実装済み（PR #169 / #170）だが **gate 自体は現状 revert 済み**（PAT fallback 経路との衝突。詳細「残差・未決」参照）。broker / marker toggle は温存し再有効化可能
**関連**: [../repo-settings.md](../repo-settings.md)（ruleset / gate 設計）/ [../setup.md](../setup.md)（有効化手順）/ [../../rules/box-personas.md](../../rules/box-personas.md)（identity 軸）

## 背景

box-primary model は sbx microVM 内で claude/codex を YOLO で回す。今は sbx proxy が **user の fine-grained PAT を注入**するため、box は **user 本人 (owner) として** push / PR する。ここに 2 つの問題がある。

- **P1（gate が機構化できない）**: [../repo-settings.md](../repo-settings.md) の「agent 自律 merge の gate 設計」原則 1 が示すとおり、GitHub は **PR author が自分の PR を approve できない**。author=agent=owner (PAT) だと `required_approving_review_count >= 1` が **満たせず詰む**ため、本 repo は `required_approving_review_count: 0` を選び、merge gate を **HOTL 判断（原則 6: 報告して停止・人間が merge）** と review thread resolution（agent 自身が resolve でき得る監査ステップ）で担保している。つまり「compromised/rogue box が自分で merge しない」が **機構ではなく規約**でしか守られていない。
- **P2（scale / key 露出）**: 「box に identity を持たせる」を素朴に読むと **人数分の App/PAT** になり、App private key を box に配ると高価値 secret が広く分散する（key 漏洩 = App 全 install repo への token 生成能力・無期限。token 漏洩 = 1 repo・≤1h より遥かに悪い）。

## 決定 1: box を GitHub App bot identity で回す（proxy substitution + host broker）

box が push / PR を **user PAT ではなく GitHub App bot** として行う。これで PR author が human owner ではなく bot になり、**human owner（別 identity）が approve できる** ようになる → 原則 1 の「詰む」が解け、`required_approving_review_count: 1` が **satisfiable かつ機械強制な gate** になる（決定 3）。

機構（**sbx proxy と戦わず、置換される token を App token にする**）:

- sbx proxy は stored `github` secret を box の github request に注入する（= 注入される token が PR author を決める）。**host は sbx secret の値を読めない**（`sbx secret ls` は masked、`get`/`show` は無い）が、**proxy の注入対象を差し替えることはできる**。
- **host broker**（`scripts/internal/app-token-broker.js`）が App private key を **host のみ**で保持し、repo-scoped installation token を mint（JWT → `POST /app/installations/{id}/access_tokens` に `repositories: [repo]`）して、`sbx secret set <box> github` で **per-box github secret を App token に live 更新**する（~50min refresh、1h 失効前）。owner/repo は origin remote から自動導出。
- **box は sentinel のまま**（private key も real token も持たない）。git/gh は無改修で author=bot になる。**案Z は box 内 git credential helper 不要**（置換は proxy がやる。`git-credential-github-app` 系のように box に key を置かない）。

これにより P2 も解消: **private key は host broker のみ**、box には短命 token すら入らない（sentinel だけ）。App は org/repo に install 1 回で、多数の box が同 installation から token を得る（人数分不要）。

## 決定 2: 有効化は sbx marker secret（per-box / global toggle）、config は appId/keyPath のみ

「どの box を App bot にするか」を **sbx marker secret の presence** で切り分ける（`scripts/dev.sh` / `dev.ps1` が判定）:

```bash
# この box だけ App bot 化 (global にするなら <box> の代わりに -g)
sbx secret set-custom <box> --host app-identity.invalid --env APP_IDENTITY_ENABLE --value 1
```

- host は secret の**値**を読めないが `sbx secret ls` で **presence（scope / env 名）** は読めるので、値でなく **presence で feature-toggle** する（scope が `(global)` か box 名かで per-box / global を切り分け、env 名は exact match、box 名は case-sensitive）。
- この方式を選ぶ理由: **手動 `dev.sh` でも Claude 経由でも動く**（`.claude/settings.local.json` の env は Claude 経由起動でしか入らない穴がある）／ **per-box で永続**（set once、再 attach でも残る）／ **workshop の secret 操作感に一致**（github/openai/anthropic と同じ）／ live 反映。
- **config file（`.claude/app-broker.local.json`、gitignore）は appId + keyPath の供給のみ**（enable 判定はしない）。owner/repo は自動導出、intervalSec は default。marker あり + config/node 不在は warning skip、marker 無し = 現行 global PAT（clone-and-go / fork 無改修）。
- **disable → PAT 復帰**: teardown（dev.sh の trap / dev.ps1 の finally）で broker が set した per-box github secret を除去し、marker を外した再起動で期限切れ App token が残って 401 になるのを防ぐ。

## 決定 3: gate は `required_approving_review_count` 0→1（opt-in・canonical 限定）、原則 1 と整合

> ⚠️ **本決定は現状 revert 済み**（下記「残差・未決」参照）。以下は design 意図の記述であり、本 repo の現在の ruleset は `required_approving_review_count: 0`（PAT default）に戻っている。App identity を再有効化する際の参照として保存する。

App identity を有効にした canonical repo でのみ、ruleset の `required_approving_review_count` を **0 → 1** にする（`bypass_actors` は空のまま。GitHub の新 ruleset は admin にも適用され、空 bypass = 全員に強制）。author=bot なので human 1 人の approve で満たせる。**box は自分の bot PR を approve できない**（GitHub は author の自己 approve を禁ずる）ため、**human が approve するまで merge gate を満たせず、box 単独では merge できない**（human approve 後は App token でも merge API を叩けるので「merge を human が実行することまで」を強制するわけではない — 強制されるのは approve が human 由来であること）。

**原則 1 との整合**: 原則 1 の「human approval を gate にしない」は **author=agent=owner (PAT) 前提の『詰む』回避**であって、「human approval は gate にできない」という普遍則ではない。box を App bot 化すると author ≠ human owner になり、human approval が **satisfiable な gate** になる。しかも本 repo の**実 default は既に HOTL-merge**（原則 6: box は報告して停止、merge は人間）なので、本決定は **その HOTL を機構強制に格上げ**するハードニングであり、原則 1-4 と対立せず補完する。

**trade-off（明示）**: 本 gate は原則 3 の「`--auto` による agent 自律 merge」とは **逆の posture**。box は implement → push → CI → review 対応 → merge-ready まで自走するが、**merge には human approval が必須**（box は自分の bot PR を approve できず、単独では gate を満たせない）。「box が緑になったら自律 merge」より「compromised box が human approval 無しに merge を通せない」を優先する canonical repo 向けの opt-in で、autonomous-merge を要る場合は本 gate を有効にしない。

## 決定 4: App 権限は最小、two-tier（canonical=App / fork=PAT）

- **App 権限**（原則 3/4 の token 最小化と同型・既存 PAT ([../setup.md](../setup.md)) と揃える）: Repository permissions = `Contents: RW`（push）+ `Pull requests: RW`（PR 操作）+ `Issues: RW`（review backlog の `gh issue create`）+ `Actions: Read`（`gh pr checks` の rollup / `gh run view --log` の CI 失敗診断）+ `Commit statuses: Read`（`Metadata: Read` は自動）。**`Workflows` を付けない**（compromised box に `.github/workflows/**` 改変 = required check の no-op 化を許さない。原則 3）。**`Administration` を付けない**（ruleset 自体の改変を許さない。原則 4）。install は canonical repo のみ。
- **two-tier**（design 意図。現状は下記「残差・未決」のとおり canonical repo も revert 中で PAT default + `required_approving_review_count: 0`）:
  - **canonical repo（App identity 再有効化時）** = App identity（broker-minted token）+ ruleset 機械強制 gate（require 1 approval / bypass 空）。
  - **fork / その他 / 現状の canonical repo** = clone-and-go / PAT / 規約 gate（HOTL）。App も key も broker も marker も無し。fork は org/repo ruleset 非継承なので強制されない。

## 実機検証（sbx v0.34.0）

- **proxy override**: box が任意の Authorization を送っても proxy が stored secret で上書き（naive「box が自前 App token を送る」は不可）。
- **live 伝播**: running box のまま `sbx secret set` すると `api.github.com/user` が 200→401 に即変化（box 再作成不要）→ broker の無停止 refresh が成立。
- **end-to-end**: broker が mint した App token を注入した box で `/installation/repositories` が 200 + 当該 repo のみを返す = box が **App installation として認証**（PAT でない）ことを確認。
- **trap scope（PR #170）**: broker teardown の pid を local → global 化しないと、EXIT trap が `set -u` で unbound abort する（Docker で実証）。

## 却下した代替

- **naive「box が自前の App token を持って送る」**: proxy override で潰れる + box 内 git credential helper（`git-credential-github-app` 系）が private key をローカル要求し P2 悪化。
- **「host が PR 作成を App で代行、box は PAT で push」**: gate と key-in-box は解けるが PR 作成が host round-trip になり box 自律ループが分断。proxy substitution（決定 1）なら round-trip 不要で同じ安全性。
- **owner/repo を config file に持つ**: 残存 config が auto-derive を迂回して別 repo で mint するリスク → 削除し origin remote から自動導出（override は `--owner/--repo` / `APP_BROKER_*`）。

## 残差・未決

- **ruleset flip は実運用検証後に revert 済み**: 決定 3 の `required_approving_review_count` 0→1 は、実運用検証（throwaway box を App bot identity で起動 → App 発 test PR を作成 → host 側 human account で approve 成功を確認）の後に一度実施した。GitHub の self-approve 制限は「author と同一アカウントによる approve」を禁ずるものであり、author=bot・approver=human owner は元から別アカウントのため self-approve に該当しない（規約を迂回しているのではなく、そもそも制限の対象外であることを確認した）。しかし `bypass_actors` 空・`enforcement: active` のため gate は **repo 全体に一律適用**され、marker 無し box や host session が author=PAT（= repo owner 本人）で作る PR にも同じ approve 要件がかかることが判明した。owner が唯一の human account である本 repo では、PAT 発 PR は App bot からの approve を得る以外に gate を満たせなくなり（human 側の別アカウントが無い）、通常運用のたびに App bot approve の workaround を要求するのは実用的でなかった。App identity marker（全 box が常時 marker 有効で運用する体制）が整うまでは `required_approving_review_count: 0` + marker unset に revert し、PAT を default 運用に戻している。broker / marker toggle 自体は削除せず、再度 canonical 運用へ移行する際に再有効化する。
- **CI required status check 依存**: 原則 3 の「red では merge 不可」は PR-triggered CI が前提で、本 repo は現状 `workflow_dispatch` only（[../repo-settings.md](../repo-settings.md)「PR-triggered CI が要る」参照）。App gate（require approval）は CI gate とは独立に機能する。
- **installation token の 1h 失効**: broker の refresh に依存。broker が長時間 hang すると期限切れ → box が 401（`ghApi` に 30s timeout + 失敗時 short-retry で self-heal）。

## Sources

- [https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)（installation token を x-access-token で git 認証）
- [https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)（1h 失効）
- [https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews)（PR author は自分の PR を approve 不可）
- [https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)（ruleset の bypass actors / admin 適用）
- [https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)（最小権限）
