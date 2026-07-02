# CLAUDE.md

講義用リポジトリ。全体像と運用モデルは [README.md](README.md) 参照。本ファイルは coding agent が作業する際の**高レベルの原則と開発フロー**を定め、詳細は `rules/` に委譲する（[rules/box-ops.md](rules/box-ops.md) / [rules/box-personas.md](rules/box-personas.md) / [rules/worktrees.md](rules/worktrees.md) / [rules/pr-followup.md](rules/pr-followup.md) / [rules/skills.md](rules/skills.md) / [rules/slides.md](rules/slides.md)）。

## Workshop 前提（project に設定を同梱し、host で動かす）

本リポジトリは **workshop 教材**。受講者の **個人 global 設定（user-level の `~/.claude` の MCP 登録・dotfiles・個人 settings 等）に依存しない**。必要な設定は **project 内にコミット**して、受講者が repo を clone するだけで揃うようにする。

**実行モデル（box-primary）**: 基本は **box（sbx = Docker Sandboxes）の中で claude / codex を動かす**（YOLO/隔離。中立 shell-docker base に両 agent を対等に同居させ相互レビュー）。microVM-per-agent の hypervisor 境界で、承認ゲートを外して並列で回す HOTL 運用が前提。host 権限が要る時だけ host に出る。box は**権限ティアごとに persona を分ける**（dev box=write / observe box=AWS read-only / host=deploy。混ぜない）→ [rules/box-personas.md](rules/box-personas.md)。

- **box の起動・secret 登録・並列・host escape hatch の手順は [rules/box-ops.md](rules/box-ops.md)**。要点: image を一度 build/load + secret 登録 → `sbx run claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit .` で bind-mount 起動（並列は `sbx create --name <box> ... --clone .`）。host に出るのは browser 確認 / docker 操作 / host 権限が要る時だけ。
- **project に置く（committed）**: `.mcp.json`（chrome-devtools MCP。host=headful / box=headless 自動切替）、`sbx/`（カスタム image + codex egress mixin）/ `scripts/`（host helper）/ `tools/`（開発ツール: a2a-review / parallel-dev）/ `.claude/skills/`（project 同梱の Claude skill: a2a-review / codex-review / pr-codex-ci / pr-ci / pr-review-respond / box-session-context / box-session-resume / box-session-resume-grant / host-ask / host-answer / host-fetch / host-fetch-grant / observe-session）/ `.claude/settings.json`（statusLine 等の共有設定）。個人差の出る設定は `.claude/settings.local.json`（local・非コミット）へ。
- **依存しない（user/host レベル）**: 受講者個人の global Claude 設定 / 個人 MCP 登録 / 個人 dotfiles / host 固有の手動セットアップ。

新しく何かを足すときは「受講者が repo を clone した状態だけで再現できるか」を必ず確認する。

## 開発フロー（box-primary の一周）

box の中で実装し、PR 作成後は codex review + CI を回して **merge-ready まで進める**（merge 自体はユーザー判断。デフォルトは報告して停止）。各ステップの詳細は委譲先の rule / skill を参照する（host 側の PR ライフサイクル運用の box-native・codex-only 縮約）。

| # | ステップ | 詳細 |
|---|---------|------|
| 0 | 環境準備（マシンに一度）: image build/load + sbx login + secret 登録 | [rules/box-ops.md](rules/box-ops.md) |
| 1 | box 起動: repo を mount した box に入る（YOLO） | [rules/box-ops.md](rules/box-ops.md) |
| 2 | 作業開始: worktree を切る（main checkout を汚さない） | [rules/worktrees.md](rules/worktrees.md) |
| 3 | 実装 + codex 相談: box 内なら `/a2a-review`、host なら `/codex-review` に codex の second opinion を投げる | [tools/a2a-review/README.md](tools/a2a-review/README.md) |
| 4 | PR → 後続へ自走: `gh pr create` 直後に orchestrator で codex review + CI check + **`/pr-review-respond` chain** を最終 merge-ready まで自走（local gate + remote gate の AND）。box session なら `/pr-codex-ci`（box-native、A2A 経由 cdx-pair）、host session なら `/pr-ci`（host-native、host codex CLI 直）。**transport だけ違い judgement の質は同等** | [rules/pr-followup.md](rules/pr-followup.md) / [rules/skills.md](rules/skills.md) |
| 5 | GitHub PR review 対応: orchestrator 内部 step 5 で chain 起動される `/pr-review-respond` が Copilot/qodo 等の bot review を確認 → 採否 → 修正/reply → resolve（**ローカル codex review とは別物**だが chain で連結） | [.claude/skills/pr-review-respond/SKILL.md](.claude/skills/pr-review-respond/SKILL.md) / [rules/pr-followup.md](rules/pr-followup.md) |
| 6 | merge: **全 review thread を resolve** 後にユーザー判断（デフォルトは報告して停止） | 下記「コミット / PR 運用」 / [docs/repo-settings.md](docs/repo-settings.md) |
| 7 | cleanup: CWD を main へ戻して `git worktree remove` | [rules/worktrees.md](rules/worktrees.md) |

**注意**: step 4 の最終 merge-ready = **local gate（codex + CI clean）+ remote gate（全 thread resolved + 新規 bot review settle）の AND**。chain は orchestrator (`/pr-codex-ci` / `/pr-ci` どちらも) step 5 で `/pr-review-respond` を skill 内強制起動する形で実装されており（[rules/pr-followup.md](rules/pr-followup.md)）、step 4 → 5 は連続した後続工程で、中間で止めない（過去に「local gate clean」を merge-ready と誤読して停止し、後から届いた bot review を見落とした事故あり）。

横断: HOTL 監視（statusLine の session id → host から transcript） / 並列（box ごとに 1 セッション） / cross-platform（`.sh`+`.ps1` 対） / **box↔host 双方向 context bridge**（`/box-session-context` = host→box の transcript pull、`/box-session-resume` = session_id を貼るだけで host / 別 box に inject して `claude --resume` 再開（host 起動は直接実行・box 起動は host-bridge 経由で `/box-session-resume-grant` に委譲）、`/host-ask` ↔ `/host-answer` = box→host の能動 ask、`/host-fetch` ↔ `/host-fetch-grant` = box egress が塞がれた URL の host 代理取得（SSRF-safe core + user gate、`sbx policy allow` はせず単発取得）、`.claude/host-bridge/` を bind mount 経由で両見え。bridge の配管 = 共有 `scripts/internal/host-bridge.sh`）→ 各 rule（[rules/pr-followup.md](rules/pr-followup.md) / [rules/box-ops.md](rules/box-ops.md) / 下記）。

（`stage/*` は dev flow ではなく講義の checkpoint 機構。下記「stage ブランチの規約」参照）

skill は**抽象度のレイヤー**で構成する（上＝抽象 / 下＝具体）: **フロー層（本セクション）→ orchestrator skill（例 `/pr-codex-ci`）→ leaf skill（例 `/a2a-review`）→ scripts/tools**。orchestrator が leaf を compose し、CI check 等の操作系も orchestrator が回す具体化要素。粒度・合成ルール・各 skill のレイヤーは [rules/skills.md](rules/skills.md) 参照。

## 構成の前提

- **main ブランチ = 講義進行用**（README / CLAUDE.md / rules/ / scripts/ / stages/ / slides/）。project 本体のコードは持たない
- **`sbx/` = playbook 全体の実行環境のカスタム image + codex egress mixin**（Docker Sandboxes）。built-in claude agent + image（claude/codex 同梱）+ codex mixin で、claude / codex を YOLO / auto-mode でも安全に同居させて回すための microVM 基盤で、main に置く土台。stage は base からの fork なので、分岐元の main に最初から存在させる（詳細は [sbx/README.md](sbx/README.md)）
- **`stage/*` ブランチ = project 本体の checkpoint**。main を base にした stacked 連鎖（main → stage/01 → … → 08）で、project 本体は各 stage の **`app/` 配下**に置く。`git switch stage/NN` で開ける（規約は下記「stage ブランチの規約」、設計は [docs/decisions/stage-stacked-branches.md](docs/decisions/stage-stacked-branches.md)。stage は dev flow ではなく**講義の checkpoint 機構**）

## 作業場所のルール

- 講義資料（README / CLAUDE.md / rules/ / scripts/ / slides/）や `sbx/` の変更は作業用 worktree で行う（下記「コミット / PR 運用」）。project（demo アプリ）本体の実装は **stage branch を base にした branch → PR** で行う。**agent は main checkout の branch を変えない規約**のため、stage 作業も worktree を切って行う（受講者は自分の checkout で `git switch` してよい — [docs/decisions/stage-stacked-branches.md](docs/decisions/stage-stacked-branches.md)）。
- worktree の切り方・片付けは [rules/worktrees.md](rules/worktrees.md)、stage の規約は下記「stage ブランチの規約」参照。

## コミット / PR 運用

- **変更は PR 経由で作成する**。worktree を切って実装 → push → PR 作成 → review / CI 確認 → merge（owner 主導の講義用 repo だが、変更とレビューを PR として残す）。main へ直接 commit / push しない。worktree の切り方は [rules/worktrees.md](rules/worktrees.md)（**`git checkout -b` で main checkout の branch を変えない**）。
- README / CLAUDE.md / rules/ / scripts/ / slides/ / `sbx/` 等の講義基盤の変更も PR 経由とする。stage（project 本体）の変更も対応する branch の PR で行う。
- 外部公開リポジトリのため、commit / push / PR body に実環境の識別子（実メール・実顧客名・実トークン等）を含めない。
- **実装 done から PR 後続まで、中間確認なしで一気通貫**: 編集が done になったら、以下の chain を **確認を待たず連続して** 進める（global Autonomy / proceed-first の本リポでの具体化）。「PR 化しますか？」「次どうしますか？」「`/pr-codex-ci` を回しますか？」「このまま進めますか？」等の**選択肢提示で停止しない**（merge と、自走不能事象の HOTL escalate、および user が明示的に指定した停止点だけが停止点。user が「commit だけで止めて」「push しないで」等を明示している場合はそれに従う）。
    1. **worktree 内**で実装が done なら `git add -A`（または明示 pathspec で対象ファイルを stage） → `git commit -m "<件名>"`（worktree-first が前提。詳細 [rules/worktrees.md](rules/worktrees.md)。bare `git add` は pathspec 不在で何も stage しないため必ず `-A` または pathspec を渡す。`git commit` は `-m` / `-F` 無しだと editor を開いて対話 hang する。main checkout で誤って編集してしまった場合は **(a)** main checkout の dirty 変更が**全て agent 自身の今回の作業のみ**であることを確認する（user の WIP が含まれていたら retreat せず HOTL escalate）→ **(b)** `git stash push -u -- <修正対象 pathspec...>`（pathspec を渡す場合は `push` subcommand 必須。`git stash -u <pathspec>` の省略形は "subcommand wasn't specified" で fail する。agent 作業以外が無いと確認できたら pathspec 無しで全体 `git stash push -u` でも可）→ **(c)** `git worktree add --relative-paths <worktree-path> -b <branch> <base-branch>`（**`--relative-paths` + `<base-branch>` を明示**。本リポは relative link 前提。git 2.48+。`<base-branch>` を省略すると現在の HEAD = main から分岐するため stage 向け作業で base が崩れる） → **(d)** `git -C <worktree-path> stash pop` で worktree に移してから commit する。`git stash pop` は cwd 基準で展開されるため、main checkout に再度展開して汚さないよう `git -C <worktree-path>` で worktree を明示する。`git worktree add` 自体は未 commit 変更を移動しない）
    2. `git push -u origin <branch>`
    2.5. **pre-PR sweep**: `/comment-sweep` で新規追加コメントを [rules/code-comments.md](rules/code-comments.md) 規範で sweep。違反があればユーザー承認後 Edit で修正して追加 commit → `git push` を 1 度だけ再実行。`/co-evolve-check` / `/extension-bloat-sweep` は TS/JS / Python の marker file を持つ project でのみ走る（main checkout は marker 無しで silent skip）。詳細は [rules/pr-followup.md](rules/pr-followup.md) step 1。
    3. `gh pr create --base <base-branch> --title "<件名>" --body "$(cat <<'EOF' ... EOF)"`（**`--title` / `--body` 必須**。省略すると editor / 対話 prompt が開き hang する。`--base` も明示（省略時は default branch が選ばれ、stage worktree の PR が `main` に向く等の事故になる。本リポでは stage の作業 branch からの PR は分岐元の checkpoint（`stage/NN`）を base にする）。issue 紐付きなら `Closes #N`、PR Body フッター必須）
    4. orchestrator を invoke: **box session なら** `/pr-codex-ci <PR番号>`（A2A 経由 codex + CI gate + bot review chain）、**host session なら** `/pr-ci <PR番号>`（host codex CLI 直 + CI gate + bot review chain）。どちらも内部 step 5 で `/pr-review-respond` chain を起動し、local gate + remote gate の両方が clean になるまで自走する
    5. orchestrator の最終 merge-ready 報告（local gate clean + 全 thread resolved + 新規 bot review settle）を受けて user に**最終報告して停止**。merge 実行はユーザー判断（明示的に指示された場合のみ `gh pr merge`）。
- **自走不能なら黙って止まらず HOTL escalate**: `/pr-codex-ci` → `/a2a-review` が reviewer 未到達（cdx-`<box-name>` pair が dev.sh の bg pair-serve で立っていない等）、CI が長時間 pending、codex 指摘が修正不能、conflict 自動解決不能、等で**自走を継続できない事象**が出たら、選択肢を提示するのではなく **何が起きたか + 人間に必要な操作 + 再開コマンドを明示して停止**する。例: 「`/a2a-review` が cdx-`<box-name>` reviewer に到達できません。recovery 順序: (1) box の terminal で Ctrl-D / `exit` で claude を抜け dev.sh trap で cleanup → (2) host で `bash scripts/dev.sh <box-name>` を再起動 → (3) `/pr-codex-ci <PR番号>` を再度叩く。box hang で exit 不能なら host で `sbx rm -f <box-name>` → (2) (state 失われます)。」 (escalate を出す前に box 内 `echo $SANDBOX_VM_ID` の値で `<box-name>` placeholder を literal 置換すること。host shell には `$SANDBOX_VM_ID` env が無く空展開で別 session に化ける。**active dev session の lock を握ったまま host で同名 dev.sh を呼ぶと active lock 検出で reject されるため、必ず先に box 内 dev.sh を exit させる**)
- **merge 前提として全 review thread を resolve**: Copilot/qodo 等の bot レビュー / 指摘コメントは、対応 + reply + thread resolve まで揃わないと merge できない（GitHub ruleset の `required_review_thread_resolution` で機械的に強制。詳細 [docs/repo-settings.md](docs/repo-settings.md)）。これは独立 skill `/pr-review-respond`（読む → 採否 → 修正/reply → resolve）が担当し、**orchestrator (`/pr-codex-ci` / `/pr-ci`) 内部 step 5 で chain 起動**される（規範ベースの chain だと「local gate clean = merge-ready」と誤読する事故が出たため、skill 内 chain で強制する形に集約）。orchestrator の **ローカル codex review（claude が能動的に呼ぶ second opinion）とは別物**で混同しない。merge はユーザー判断だが、その前提として全 thread の解決が必須。

## stage ブランチの規約（講義の checkpoint 機構）

`stage/*` は「講義中に『ここまで進んだ状態』を即座に開く」ための教材装置（3分クッキング方式）であり、上記の開発フロー（box → worktree → PR → merge）とは**別軸**。**受講者の default は前フェーズの自分の到達点から地続きに進むこと**で、stage は追いつき・やり直しの**セーブポイント**（例外: 運用保守フェーズは仕込みバグが必要なため stage 起点が必須）。main を base にした **stacked 連鎖**（main → stage/01 → … → 08）で、project（demo アプリ）本体は各 stage の **`app/` 配下**に置く（設計と移行の経緯は [docs/decisions/stage-stacked-branches.md](docs/decisions/stage-stacked-branches.md)）。

- **checkpoint = `app/` の内容**。基盤（root 側）は main 由来で全 stage 同一のため、stage 間の `git switch` は原則 app/（と stage 側にだけある `.github/workflows/ci.yml`）しか触らない
- **`app/` は product repo の root 相当**（実開発で単独 repo にしたときの root にあたる）。中の配置は実モノレポ慣行に合わせる: `apps/`（デプロイ単位: web / api / mock）+ `packages/`（共有ライブラリ: core）+ `infra/`（CDK app、独立 workspace）+ `docs/`（design.md 等の横断設計）。**product の設計 docs は `app/docs/` 直下**に置く（repo root の `docs/` は playbook 用で別物。app/ の中では root docs 慣行がそのまま成立する）
- 新しい stage は必ず `scripts/internal/new-stage.sh` / `scripts/internal/new-stage.ps1` で作る（前 stage を base に分岐。base 省略時は連鎖末尾）。orphan では作らない
- **stage で編集してよいのは `app/` 配下だけ**。基盤（README / CLAUDE.md / rules/ / scripts/ / slides/ 等の root 側）を stage 上で直接編集しない — 基盤の変更は main への PR で行い、`scripts/internal/restack-stages.sh`（Windows: `.ps1`）の cascade merge（main → 01 → … → 末尾）で全 stage に伝播させる（明示で叩く。常駐同期はしない）
- stage の project ドキュメント（`app/README.md` 等）や**コード中のコメント**には **project（demo アプリ）の動かし方だけ**を書く。playbook の host 運用手順（box→host の閲覧経路 = `dev.sh route` / Traefik 等、main の `scripts/` 前提のコマンド）を `app/` 側に複製しない（点検は `*.md` に限定しない）。全 stage 共通の playbook 関心事は main 側に単一ソースで置き、restack で伝播させる
- 命名: ブランチは `stage/NN-<slug>`。worktree（並置比較・並列用に展開する場合）は `.worktrees/<NN-slug>/`、削除は `git worktree remove`（手動 rm は stale 登録が残る）。一括展開は `bash scripts/internal/setup-worktrees.sh`（instructor / 並列用の道具で、受講者の必修ではない）
- **app/ の checkpoint 内容は凍結**: 上流 stage の app/ を後から直して下流へ流す retroactive な伝播は原則しない（checkpoint を動く標的にして 3分クッキングの再現性を壊すため）。必要になったら restack と同様の cascade merge を明示で回す（stacked なので merge で流せる）
- 旧 orphan 系列は移行検証（全 stage の app/ 内容が旧 orphan とハッシュ一致することを確認）後に削除済み（2026-07-02。移行の経緯は [docs/decisions/stage-stacked-branches.md](docs/decisions/stage-stacked-branches.md)）

## cross-platform 要件

スクリプトは macOS / Linux / Git Bash (Windows) / Windows PowerShell 5.1 で動くこと:

- bash 版（`*.sh`）と PowerShell 版（`*.ps1`）を**対で保守**する。片方だけの変更で挙動差を作らない
- 例外として、全 OS 共通の単一実装が要るもの（例: statusLine の `scripts/internal/statusline.js`）は `node` 1 本で書く。`node` は claude CLI の動作前提なので host/box の全 OS に必ず居り、単一 committed コマンドで mac/linux/box/Windows（全 shell）を賄える。この場合は `.sh`/`.ps1` の対を持たない（持たないこと自体が正で、欠落ではない）
- もう一つの例外として、**使い捨ての検証用 artifact**（一度回して判断したら役目を終える ephemeral なもの。例: `examples/*/spike/` の ADR ゲート harness）は、回す環境を限定してよく（例: 資格情報を持つ mac/Linux host だけ）、その場合は pair を持たず単一 shell 実装（`*.sh` のみ等）でよい。受講者が日常的に叩く**恒久 tooling**（`scripts/` の `dev.sh` / `new-stage.sh` 等）には適用しない。pair を持たない選択をしたら artifact 側の README/コメントに「ephemeral ゆえ pair 不要（`node` 例外とは別の scoped 判断・欠落ではない）」と明記し、Windows からは Git Bash / WSL で `*.sh` を回す導線を案内する
- `*.sh` は LF 固定（`.gitattributes` で強制済み）
- `*.ps1` は ASCII only（Windows PowerShell 5.1 が BOM-less ファイルを ANSI として読むため）
- 前提バージョン: git **2.48+**（`git worktree add --relative-paths` を使用。worktree の `.git` が相対パスになり、sbx の box のように repo を別パスにマウントしても worktree の git が効く＝ box の中でも `git -C .worktrees/<NN>` が動く）

## スライド

講義スライドは**フェーズ単位**で main の `slides/<NN-slug>.html` に置く（壁打ち / 設計 / 実装 / 仕上げ(並列 issue 処理) / 運用保守・バグ修正。加えて概要の導入デッキ 00 と環境構築デッキ 01。スライドは状態でなくフェーズに対応するので stage の checkpoint 数とは一致しない。講義資料なので stage ブランチには入れない）。**構成・命名・スタイル・レイアウト機構・検証の規範は [rules/slides.md](rules/slides.md)**、運営手順（作る / 見る / 配信）は [docs/instructor.md](docs/instructor.md)「スライド」「ステージ (checkpoint 連鎖)」参照。

- フェーズデッキ（02–06）の中身は講師が所有し、agent が書くのは**講師の明示指示があるときだけ**。agent の常時担当は雛形 `slides/template.html` と共有 CSS / fit-scale JS の保守（詳細は [rules/slides.md](rules/slides.md)「中身の担当」）
