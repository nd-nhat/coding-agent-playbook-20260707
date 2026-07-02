# stage 別 実演ガイド（講義中に参照する台本）

各 stage checkpoint を「開いて → claude に何を頼み → どこを見せるか」を stage 単位でまとめた**実演台本**。講義中はこの doc を横に開き、下記の「claude への依頼例」をそのまま貼って進める運用を想定している。

- checkpoint がどう連鎖しているか（状態の設計意図）は [instructor.md](instructor.md)「ステージ (checkpoint 連鎖)」、開発フローそのものは [../CLAUDE.md](../CLAUDE.md) が単一ソース。本 doc はそれらを**フェーズ進行の手順**に落としたもので、規範の重複は避けてリンクで委譲する。
- スライドは**フェーズ**単位、stage は**状態**単位（8 点）で対応が 1:1 ではない（保守フェーズが broken/fixed の 2 点を持つため）。対応は各フェーズ見出しに併記する。

## 事前準備（毎回）

1. box に入る: `bash scripts/dev.sh`（[README](../README.md) §2）。以降の claude への依頼は**この box の中の claude** に投げる。
2. stage/* branch が手元にあるか確認: 無ければ `git fetch origin`（fork なら "Copy the main branch only" を外して全ブランチごと fork）。
3. 「今どの stage を開くか」は claude に **stage 名で伝える**（例: `stage/04-mvp`）。project 本体は stage の `app/` 配下にある。実装デモは **stage を base にした専用 worktree を切らせる**（agent は main checkout の branch を変えない規約 → [../rules/worktrees.md](../rules/worktrees.md)。受講者が自分の checkout で `git switch stage/04-mvp` して眺めるのは自由）。

> **受講者の default は「地続き」**: 前フェーズの自分の到達点（自分の branch / ツリー）のまま次フェーズへ進む — 実開発と同じ連続感で、stage を毎回開き直す必要はない。**stage は追いつき・やり直し用のセーブポイント**（各フェーズの正しい開始状態のスナップショット。実開発には存在しない教材装置）で、詰まった時・時間切れの時・実演を確実に再現したい時に `git switch stage/<NN-slug>`（例: `git switch stage/04-mvp`）で乗り移る。**例外は運用保守フェーズ（06〜08）**: 仕込まれたバグを扱うため stage 起点が必須。

---

## フェーズ1: 壁打ち（スライド `02`） — `stage/01-blank`

- **開始状態**: 空（root commit / ファイル 0 件）。
- **狙い**: アイデアを claude と壁打ちして **one-pager（企画書）** に落とすまでを見せる。起点プロンプトは実演時に口頭で与える（凍結しない）。
- **claude への依頼例**:
  > 新電力の新規顧客獲得ファネルを作りたい。市場連動プランの「高騰が怖い」という心理障壁を、本人のスマートメーター実データのバックテストで潰す、というアイデアを壁打ちしたい。制度面の裏付けも一緒に検証しながら app/one-pager.md にまとめて。
- **見どころ**: 事実確認（制度が実在するか）を含めた往復、前提の言語化。
- **到達点**: `app/one-pager.md` が書けた状態 = 次の `stage/02-onepager`。答え合わせは `git show stage/05-fixed:app/one-pager.md`（完成形の一例）。

## フェーズ2: 設計（スライド `03`） — `stage/02-onepager`

- **開始状態**: `app/one-pager.md` あり。
- **狙い**: one-pager から **設計書 `app/docs/design.md`**（フルスタック構成 + AWS/ECS 構成まで）を起こす。
- **claude への依頼例**:
  > この one-pager をもとに設計書 app/docs/design.md を書いて。monorepo 構成（web / api / mock / core / infra）、外部連携（協会 power-data / SMS / JEPX）のアダプタ境界、型共有の方針、AWS 上の構成（ECS Fargate / ALB / S3 / CloudFront）まで含めて。要所は /a2a-review で codex にも見てもらって。
- **見どころ**: 設計段階での codex second opinion（`/a2a-review`）、境界（外部 API を mock で差し替えられる seam）の設計。
- **到達点**: `app/docs/design.md` = 次の `stage/03-design`。

## フェーズ3: 実装（スライド `04`） — `stage/03-design`

- **開始状態**: 設計書あり・実装なし。
- **狙い**: 設計に沿って **動く MVP** を組む。monorepo（web / api / mock / core / infra）が立ち上がり、mock 経由で診断が通るところまで。
- **claude への依頼例**:
  > app/docs/design.md に沿って MVP を実装して。専用の worktree を切って、app/ 配下に web / api / mock / core / infra を作り、mock サーバ経由で診断フローが一通り動く状態まで。実装できたら PR にして /pr-codex-ci まで回して。
- **見どころ**: 設計 → 実装の落とし込み、PR 化して `/pr-codex-ci`（codex review + CI）まで自走する CLAUDE.md の開発フロー一周。
- **到達点**: 動く MVP = 次の `stage/04-mvp`。ローカル起動手順は各 stage の `app/README.md`「ローカル開発」。

## フェーズ4: 仕上げ / 並列 issue 処理（スライド `05`） — `stage/04-mvp`

- **開始状態**: 動く MVP。粗削りな点が残っている。
- **狙い**: 改善点を **issue 化 → 並列で潰す**。並列度 = box 数（① 手動ペタペタ）または agent 数（② ultracode）。手順の本体は [parallel.md](parallel.md)「大量 issue を並列で捌く」が単一ソース。
- **claude への依頼例（起票）**:
  > stage/04-mvp の MVP を見て、改善すべき点を issue として起票して。file が重ならない粒度で束ねて（並列で conflict しないように）。
- **claude への依頼例（並列処理 ①手動）**: box を issue ごとに立て、各 box の claude に:
  > stage/04-mvp の issue #93 を、専用の worktree を切って直し PR まで出して。
- **claude への依頼例（②ultracode / Claude Code harness 利用時のみ）**:
  > stage/04-mvp の #92 #93 #94 #95 #96 #97 を ultracode で並列に直して。
- **注意**: stage は default branch でないため fix PR で `Closes #N` は自動 close されない（手動 close）。同一ファイルを触る issue は並列 conflict する（[parallel.md](parallel.md) の警告参照）。
- **到達点**: issue を捌いて磨いた健全な MVP = 次の `stage/05-fixed`（保守フェーズの土台）。

## フェーズ5: 運用保守・バグ修正（スライド `06`）

健全な `stage/05-fixed` を土台に、**2 つのシナリオ**を持つ。片方は broken→fixed のペア（local 調査）、もう片方は broken 単体（cloud 無人 fixer）。

### シナリオ A: readings 契約ドリフト（local observe box 調査） — `stage/06-readings-drift-broken` → `stage/07-readings-drift-fixed`

- **開始状態（`stage/06-readings-drift-broken`）**: 上流 readings API がレスポンスを `data` オブジェクトで包む形に変わったのにアダプタが追従しておらず壊れている（`{ readings: [...] }` → `{ data: { readings: [...] } }` の契約ドリフト）。
- **狙い**: 「本番で診断が壊れた」を **read-only の observe box**（AWS ログを読むだけの persona）で調査 → 原因特定 → 直す、を実演する。persona の考え方は [../rules/box-personas.md](../rules/box-personas.md) US3、調査手順は [../examples/observe/runbook.md](../examples/observe/runbook.md)。
- **このシナリオだけ box の使い分けに注意**（「事前準備」の「依頼は dev box の claude に」の例外）: observe box は dev box とは別の persona で、**セットアップは host 側**（`/observe-session` が `scripts/dev.sh observe` + AWS 短命 cred 注入まで host で回し、別の `obs-*` box を立てる）。**調査は observe box の claude**、原因が分かった後の**修正 PR は dev box の claude**、と box を跨ぐ。dev box にそのまま貼ると observe box が作られず失敗する。
- **claude への依頼例（① host で observe box を用意）**: `/observe-session` は host 権限（`scripts/dev.sh observe` / `sbx` / AWS cred）を使うため **host の claude session** に投げる。dev box に入った元の**別ターミナルでこのリポジトリに `cd` して `claude` を起動**し、その host claude に:
  > /observe-session で stage/06-readings-drift-broken 相当のデプロイ先を調べる observe box を立てて。

  observe box への入場（`sbx run <obs-box>`）は TTY が要るので、host claude の案内に従って**受講者自身がターミナルで叩く**（この一手だけは人手）。
- **claude への依頼例（② observe box で調査）**:
  > 本番相当のログを読んで、readings 診断がどの層で壊れているか切り分けて（[../examples/observe/runbook.md](../examples/observe/runbook.md) の手順で）。
- **claude への依頼例（③ dev box で修正）**:
  > 調査で分かった readings レスポンスの契約ドリフトを stage/06-readings-drift-broken で直して PR にして。
- **答え合わせ（到達点 `stage/07-readings-drift-fixed`）**: 修正は 2 ファイルだけ — `app/packages/core/src/contracts.ts`（Zod 契約を `data` 包みに追従）と `app/apps/api/src/external.ts`（`.readings` → `.data.readings`）。実演で迷ったらこの diff を答えとして見せる。

### シナリオ B: サーバ 500 / null guard 漏れ（cloud 無人 SRE fixer） — `stage/08-server-500-broken`

- **開始状態（`stage/08-server-500-broken`）**: `/api/diagnose/summary` が `include` クエリ未指定時に `c.req.query('include')` が `undefined` になり `.includes('raw')` で throw → 未 catch で 500。`stage/07-readings-drift-fixed`（readings 修正済み）にさらに別バグを仕込んだ broken 単体。
- **狙い**: **cloud 常駐の無人 SRE fixer pipeline** が、エラーの triage を受けて自動で fix PR を出すところまでを見せる（決定 3「PR は無人・merge は人間」をそのまま教材にする）。設計と現状は [decisions/cloud-unattended-sre.md](decisions/cloud-unattended-sre.md)、実演教材は [../examples/sre-bedrock/README.md](../examples/sre-bedrock/README.md)。
- **現状で実機検証済みの範囲に注意**: spike が通過しているのは **実 deploy → S3 triage → fixer 起動（S3 event → EventBridge）→ fix PR 生成** の e2e（[ADR](decisions/cloud-unattended-sre.md)「残差・未決」）。**CloudWatch alarm → SNS → 観測 Lambda の full trigger 配線と Slack 承認通知はまだ未実装**なので、実演では「alarm が自動で全部を起こす」完全自動フローを待たせず、**triage handoff（S3）から先が無人で回る**部分を見せる。
- **見どころ**: `09-*` の frozen stage は作らず、生成された実 PR（[PR #159](https://github.com/kanka-jp/coding-agent-playbook/pull/159)）を実演時にその場で見せる。
- **claude への依頼例（手元で挙動を確かめたい場合）**:
  > stage/08-server-500-broken で /api/diagnose/summary を include なしで叩くと 500 になる。app.ts の該当ハンドラを読んで、なぜ 500 になるか説明して。
- **答え合わせ**: `c.req.query('include')` が `undefined` になりうる箇所の null guard（`?? ''` 等）漏れ。

---

## 早見表

| フェーズ | スライド | 追いつき用 stage（保守は必須起点） | claude に頼むこと（要約） | 到達点 |
|---|---|---|---|---|
| 壁打ち | 02 | `stage/01-blank` | アイデアを壁打ち → one-pager | `02-onepager` |
| 設計 | 03 | `stage/02-onepager` | one-pager → `app/docs/design.md` | `03-design` |
| 実装 | 04 | `stage/03-design` | 設計 → 動く MVP → PR | `04-mvp` |
| 仕上げ（並列 issue） | 05 | `stage/04-mvp` | issue 化 → 並列で潰す | `05-fixed` |
| 保守 A（local 調査） | 06 | `stage/06-readings-drift-broken` → `stage/07-readings-drift-fixed` | observe box で調査 → readings 契約追従 | `stage/07-readings-drift-fixed` |
| 保守 B（cloud 無人） | 06 | `stage/08-server-500-broken` | 500 の原因説明（fix は無人 pipeline / PR #159） | （frozen stage 無し） |

各 stage の実データ（one-pager / design / MVP コード）は `git switch stage/<NN-slug>` の `app/` 配下（または `git show stage/<NN-slug>:app/<path>`）で読める。困ったら box の claude に「今開いている stage の状態を説明して」と聞くのが早い。
