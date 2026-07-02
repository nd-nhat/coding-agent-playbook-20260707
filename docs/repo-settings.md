# GitHub リポジトリ設定（ruleset）

この repo の merge gate は GitHub の **ruleset**（Settings → Rules → Rulesets）で強制している。**全 review thread を resolve しないと main に merge できない**のが主目的。agent を YOLO/自律で回す前提なので、**誤 merge をどう機械的に防ぎ、かつ「頼んだら自律 merge」をどう両立するか**の設計根拠を下記「agent 自律 merge の gate 設計」にまとめる。

## 有効な ruleset（default branch = main）

| ルール | 値 | 意味 |
|--------|----|------|
| `pull_request` | 必須 | main への変更は PR（pull request）経由を要求する |
| └ `required_review_thread_resolution` | `true` | **PR の review thread を全て resolve するまで merge できない**（本設定の主目的） |
| └ `dismiss_stale_reviews_on_push` | `true` | 新しい push で既存の review approval を dismiss する |
| └ `required_approving_review_count` | `0` | approval 数は要求しない。owner 主導の repo のため、品質はローカル codex review + thread resolution（audit step）+ HOTL 判断（下記「前提と現状」参照。thread resolution 自体は agent の手が届くため単独の hard gate ではない）で担保する。App identity gate を試験的に `0→1` にした際、PAT fallback（marker 無し box / host session 発 PR）が gate を満たせなくなる残差が実運用で判明したため `1→0` に revert 済み（詳細は下記「App identity による human-approval gate」） |
| `non_fast_forward` | 禁止 | main への force-push を禁止 |
| `deletion` | 禁止 | main の削除を禁止 |

`enforcement: active` で全員に適用（bypass なし）。

なお `pull_request` rule は「変更を PR 経由にする」ものであり、**直接 push の全面禁止（`Restrict updates` rule）は本 ruleset には含めていない**。「main へ直接 push しない」は [../CLAUDE.md](../CLAUDE.md)「コミット / PR 運用」の運用規範で担保する（force-push・削除は上表の `non_fast_forward` / `deletion` で機械的に禁止）。

## 前提（plan 要件）

ruleset / branch protection は、**private repo では GitHub Team/Pro plan が必要**（public repo なら無料）。本 repo は private のため、org を有料 plan にして有効化している。plan を持たない private repo では ruleset API が `403 Upgrade to GitHub Pro or make this repository public` を返す。

## 確認・変更方法

- **Web UI**: Settings → Rules → Rulesets → 「main」
- **CLI**（`gh` が repo を自動解決する `{owner}/{repo}` placeholder を使う）:

```bash
# 一覧
gh api repos/{owner}/{repo}/rulesets
# 中身（<id> は一覧の id）
gh api repos/{owner}/{repo}/rulesets/<id>
```

更新は同 id に `PUT repos/{owner}/{repo}/rulesets/<id>` で ruleset 全体を渡す（部分更新でなく全体置換のため、既存 rule を保持したうえで変更する）。

## workflow 規範との関係

GitHub 側の強制（本 ruleset）と対に、開発フロー側でも **「review を全て対応・resolve してから merge する」** を [../CLAUDE.md](../CLAUDE.md)「コミット / PR 運用」で定義している。ruleset は機械的 gate、規範は agent / 人間の運用指針で、二重に担保する。

## agent 自律 merge の gate 設計（誤 merge 防止と自律 merge の両立）

agent を YOLO/自律で回すと「**勝手に merge してほしくない**」と「**頼んだら自律で merge してほしい**」が同時に要る。両立の鍵は **gate を agent の手の届かない server 側（ruleset）に置き、agent が自力で満たせる条件（CI status check）だけを merge 条件にする** こと。以下は GitHub 公式 docs で確認した挙動に基づく設計根拠（出典は各項末尾）。

### 原則 1: 自己 approve は不可能 → human approval を gate にしない

GitHub では **PR の作成者アカウントは自分の PR を approve できない**（[create-pull-request: concepts-guidelines](https://github.com/peter-evans/create-pull-request/blob/main/docs/concepts-guidelines.md)）。agent が author の PR を、その agent（や同じ owner token）で approve することは原理的にできない。

つまり **PR author = agent 自身の token（PAT）だと「approval N 件必須」を merge 条件にした瞬間に agent 単独運用が構造的に詰む**。品質は **ローカル codex review（[../CLAUDE.md](../CLAUDE.md) Step 4）+ review thread resolution** で担保するのが base の設計であり、「人間 approval を必須 gate にする」方向と PAT ベースの agent 自律運用は両立しない。本 repo が `required_approving_review_count: 0` にしているのはこの帰結。下記「App identity による human-approval gate」で author を bot 化すればこの詰みを解消できるが、PAT fallback（marker 無し box）との併用時に別の詰みが生じたため現状は revert 済み（詳細は同節参照）。

### 原則 2: gate は client 側でなく server 側に置く（client 側は agent が回避する）

「誤 merge を防ぐ」を **agent 側の設定や行儀**で実現しようとすると、agent はそれを回避できてしまう:

| 防御 | 層 | なぜ弱い / 強いか |
|------|----|-----------------|
| `.claude/settings.json` で `Bash(gh pr merge*)` を deny | **client 側** | その session の Bash 呼び出ししか縛れない。agent は別コマンド名・`gh api` 直叩き・web UI 等で回避可能。「うっかり」抑止止まり |
| 「即時 merge は使わず `--auto` だけ」という運用ルール | **行儀（規範）** | agent が即時 `gh pr merge` に切り替えれば破れる。強制力なし |
| ruleset の **required status check** | **server 側** | merge を実行する経路（CLI / `gh api` / web UI）に依らず GitHub 本体が判定。red / 未完では merge API 自体が拒否される。**回避不能**（bypass actor を除く、原則 4） |

要するに **「CLI からできてしまうと回避される」のはその通りで、だからこそ防御を CLI（client）でなく ruleset（server）に置く**。server 側 gate は `gh pr merge` だろうが `gh api` だろうが同じ条件で弾くので、コマンドを縛る必要がそもそも無くなる（[available-rules-for-rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets): "all required status checks must pass before collaborators can merge changes into the branch"）。

### 原則 3: required status check を gate にし、auto-merge で自律化する

agent が**自力で満たせる**唯一の merge 条件は **CI status check（green にする）**。これを使って「誤 merge 防止」と「自律 merge」を両立する:

1. ruleset に **「Require status checks to pass」** を追加し、PR の CI を必須にする → **red / 未完では誰も merge できない**（誤 merge 防止）。
2. repo 設定で **「Allow auto-merge」を ON** にする（Settings → General → Pull Requests）。
3. agent は merge したい時に即時 `gh pr merge` ではなく **`gh pr merge --auto`** を使う → **全 gate が green になった瞬間に GitHub が自動 merge**する（自律 merge）。red の間は merge されない。

auto-merge は **「all required reviews are met and all required status checks have passed」** で発火する（[automatically-merging-a-pull-request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request)）。注意点:

- auto-merge が**即時 merge ではなく「予約」になる**には、branch protection / ruleset に **最低 1 つの requirement** が必要。requirement が無いと auto-merge は予約されず**その場で merge される**ため、required status check はこの意味でも前提（[enable-pull-request-automerge](https://github.com/peter-evans/enable-pull-request-automerge): "The pull request base must have a branch protection rule with at least one requirement enabled"）。
- auto-merge を有効化できるのは **write 権限保持者**、無効化できるのは **write 権限保持者と PR author**（[automatically-merging-a-pull-request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request)）。

**重要な前提（gate の供給元自体を守る）**: required status check が「agent の手の届かない gate」になるのは、**その check を生む workflow 定義（`.github/workflows/*.yml`）を agent が改変できない**場合に限る。もし agent が workflow を改変できると、**required job 名はそのままに中身を no-op に差し替え**、`pull_request` workflow は PR の merge branch に対して走るので改変後の workflow から required status を green にでき、`--auto` が通ってしまう。

ここで本 repo の token 設計が効く: fine-grained PAT で `.github/workflows/**` を作成・更新するには **`Contents: write` とは別に `Workflows: Read and write` 権限が必要**だが、[setup.md](setup.md) の agent token は `Workflows` を**付与していない**（Contents / Pull requests = write のみ）。そのため **agent は workflow file を改変できず**、この no-op 化経路は現状の token では塞がれている。逆に言えば、この保護は token 設計に依存するので、**agent token に `Workflows: write` を与える／workflow を更新できる別 credential を持たせる場合は、`.github/workflows/**` を別途保護する**（例: CODEOWNERS で人間 review 必須にする、ruleset の対象に含めて workflow 改変 PR だけ人手 gate を課す）ことが前提になる。

### 原則 4: bypass list を空にする + agent token を最小権限にする

ruleset は **bypass actor に挙げた user / team / GitHub App には適用されない**（[about-rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)）。ruleset が admin を bypass 扱いにしていると **admin 権限の token で red CI を force merge できてしまい**、原則 2〜3 の server 側 gate が無力化する。GitHub の新 ruleset は classic branch protection と違い **admin にも適用できる**。本 repo は既に **`enforcement: active` / bypass list 空（上記「有効な ruleset」末尾）** なので整合している。この状態を崩さない（bypass に誰も足さない）ことが第一の要。

**ただし bypass 空だけでは不十分** — ruleset 自体を書き換えられる token を agent に渡してはいけない。ruleset の更新・削除は **`Administration` write 権限**を要する（GitHub REST: update/delete repository ruleset）。agent が admin-capable な token で動いていると、bypass list に載っていなくても **merge 前に `gh api` で ruleset を削除・緩和してから merge** でき、gate を回避できる。したがって server 側強制が本当に成立するのは **agent token が最小権限（least-privilege）** のときに限る。本 repo の agent token は [setup.md](setup.md) の fine-grained PAT で **Contents / Pull requests = write、Actions / Commit statuses = read-only、`Administration` は未付与**。この「**`Administration` write を持たせない**」が原則 4 のもう半分で、これにより agent は ruleset を改変できず、bypass 空の gate が agent の手の届かない所に保たれる。

人間が「どうしても今すぐ red のまま merge したい」場合だけ、**ruleset を一時的に緩める / 自分を一時 bypass に足す**という**明示的な人間操作（= Administration 権限を持つ人間）**を要する非対称になる。これが狙い: うっかり即時 merge は server 側で物理的に塞がれ、強行 merge は意図的な人間操作を強制される。

人間が「どうしても今すぐ red のまま merge したい」場合だけ、**ruleset を一時的に緩める / 自分を一時 bypass に足す**という**明示的な人間操作**を要する非対称になる。これが狙い: うっかり即時 merge は server 側で物理的に塞がれ、強行 merge は意図的な人間操作を強制される。

### 前提と現状: PR-triggered CI が要る（本 repo は現状未充足）

原則 3 の required status check gate は **PR ごとに CI check が実際に走る**ことが前提。だが本 repo の CI workflow は現状 **`on: workflow_dispatch` only**（private repo の Actions 無料分消費を避けるため。[../.github/workflows/README.md](../.github/workflows/README.md)）で、**PR では自動実行されない**。そのため:

- 現状は required status check に指定できる「実在する PR check」が無く、この gate は**まだ有効化していない**。
- 有効化するには、まず [../.github/workflows/README.md](../.github/workflows/README.md) の手順で各 workflow の `on:` に `pull_request:` を足し、PR ごとに check が走る状態にする → そのうえで ruleset に「Require status checks to pass」を追加して当該 check 名を必須にする。
- それまでの間、merge gate は **review thread resolution + HOTL 判断（[../CLAUDE.md](../CLAUDE.md)「コミット / PR 運用」の運用規範）** で担保する。ただし **thread resolution は「agent の手の届かない server 側 barrier」ではない** — thread を resolve できるのは **PR opener または write 権限保持者**で、本 repo の agent は PR を開く張本人かつ **Pull requests: write**（[setup.md](setup.md)）を持つため、**bot コメントを agent 自身が resolve して gate を満たせてしまう**。つまり `required_review_thread_resolution` は機械的には merge をブロックするが、agent に対する強制力は無く、**監査可能な workflow ステップ（誰がどう対応したかが thread に残る）**として機能する。CI gate が未充足な現状、agent に対する実質的な抑止は **HOTL 判断**（agent はデフォルトで merge せず報告して停止し、merge 実行はユーザー判断。[../CLAUDE.md](../CLAUDE.md) Step 6）である点を明確にしておく。

### まとめ

- **誤 merge 防止 = server 側 ruleset（required status check + bypass 空）**。client 側の deny や運用ルールは回避されるので主防御にしない。
- **server 側強制が成立する前提は「agent token が最小権限」**: `Administration` write を持たせない（持つと ruleset 自体を改変して回避できる）。`.github/workflows/**` の改変には `Workflows: write` が要るが、本 repo の token はこれを未付与なので check の no-op 化経路は塞がれている（`Workflows: write` を与える場合は workflow 定義を CODEOWNERS 等で別途保護する）。
- **自律 merge = `gh pr merge --auto` + Allow auto-merge**。green になった瞬間だけ merge され、red では server 側で弾かれる。
- **human approval は gate にしない**（自己 approve 不可のため）。品質はローカル codex review + thread resolution で担保。
- 上記の required status check 部分は **PR-triggered CI の有効化が前提**で、本 repo では現状未充足。暫定の thread resolution は agent 自身が resolve でき得る監査ステップに過ぎず、現状の実質的抑止は **HOTL 判断**。

## App identity による human-approval gate（opt-in・canonical repo、現状 revert 済み）

原則 1 の「human approval を gate にしない」は **author=agent=owner (PAT) だと自己 approve 不可で詰む**ことから導いた。**box を GitHub App bot identity で回す**と author=bot になり、**human owner（別 identity）が approve できる** → 原則 1 の「詰む」が解け、`required_approving_review_count: 1` が **satisfiable かつ機械強制な gate** になる。設計・機構・実機検証は [decisions/app-identity-gate.md](decisions/app-identity-gate.md)、有効化手順は [setup.md](setup.md)「github を App identity 化する」参照。

- **gate 化の狙い**: App identity を有効にした canonical repo でのみ `required_approving_review_count` を **0 → 1**（`bypass_actors` は空のまま = 原則 4 のとおり admin 含め全員に強制）。author=bot なので **box は自分の bot PR を approve できず**（自己 approve は GitHub が禁ずる）、**human 1 人の approve が無いと merge gate を満たせない**（= box 単独 merge 不能。approve が human 由来であることが強制される）。
- **原則 1-4 と対立しない**: 本 repo の実 default は既に **HOTL-merge**（原則 6: box は報告して停止、merge は人間）。本 gate はその HOTL を **機構強制に格上げ**するハードニングで、compromised/rogue box が規約を破って self-merge する経路を server 側で塞ぐ。
- **trade-off**: 原則 3 の `--auto` 自律 merge とは **逆 posture**。box は merge-ready まで自走するが最終 merge は human approval 必須（self-merge 不能）。「緑になったら自律 merge」より「box が self-merge しない」を優先する時の opt-in で、autonomous-merge が要る場合は有効にしない。
- **実運用検証は完了**: `0→1` の flip 自体は App 発 PR を実運用で human approve できることを確認済み（[decisions/app-identity-gate.md](decisions/app-identity-gate.md) 「残差・未決」参照）。
- **PAT fallback 経路との衝突により revert 済み**: `required_approving_review_count: 1` は `bypass_actors` 空・`enforcement: active` のため **repo 全体に一律適用**され、author=bot の box 発 PR に限らず、marker 無し box や host session が author=PAT（= repo owner 本人）で作る PR にも同じ approve 要件がかかる。本 repo は human account が owner 1 名のみのため、owner 自身が author の PR は自己 approve 不可で **App bot からの approve を得る以外に gate を満たせなくなる**（human 側の他アカウントは無い。broker の private key で一時的に installation token を発行し `POST /repos/{owner}/{repo}/pulls/{num}/reviews`（`event: APPROVE`）を呼ぶ workaround は動作確認済みだが、通常の PAT 運用のたびにこれを要求するのは実用的でない）。box が App identity marker を有効にした状態でのみ運用する体制が整うまでは、`required_approving_review_count: 0` に戻し、marker も unset して PAT 運用をデフォルトに戻している。App identity gate 自体（broker / marker toggle）は削除せず、再有効化可能な状態で残す。
