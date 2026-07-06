# CLAUDE.md

講義用リポジトリ。全体像と運用モデルは [README.md](README.md) 参照。本ファイルは coding agent が作業する際の**高レベルの原則と開発フロー**を定め、詳細は `rules/` に委譲する（[rules/box-ops.md](rules/box-ops.md) / [rules/box-personas.md](rules/box-personas.md) / [rules/worktrees.md](rules/worktrees.md) / [rules/commit-pr.md](rules/commit-pr.md) / [rules/stages.md](rules/stages.md) / [rules/pr-followup.md](rules/pr-followup.md) / [rules/skills.md](rules/skills.md) / [rules/slides.md](rules/slides.md) / [rules/chrome-devtools.md](rules/chrome-devtools.md)）。人間向け文書の置き場所は [docs/README.md](docs/README.md)（受講者 = `docs/guide/`、講師 = `docs/instructor/`、ADR = `docs/decisions/`）。

## Workshop 前提（project に設定を同梱し、host で動かす）

本リポジトリは **workshop 教材**。受講者の **個人 global 設定（user-level の `~/.claude` の MCP 登録・dotfiles・個人 settings 等）に依存しない**。必要な設定は **project 内にコミット**して、受講者が repo を clone するだけで揃うようにする。

**実行モデル（box-primary）**: 基本は **box（sbx = Docker Sandboxes）の中で claude / codex を動かす**（YOLO/隔離。中立 shell-docker base に両 agent を対等に同居させ相互レビュー）。microVM-per-agent の hypervisor 境界で、承認ゲートを外して並列で回す HOTL 運用が前提。host 権限が要る時だけ host に出る。box は**権限ティアごとに persona を分ける**（dev box=write / observe box=AWS read-only / host=deploy。混ぜない）→ [rules/box-personas.md](rules/box-personas.md)。

- **box の起動・secret 登録・並列・host escape hatch の手順は [rules/box-ops.md](rules/box-ops.md)**。要点: image を一度 build/load + secret 登録 → `sbx run claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit .` で bind-mount 起動（並列は `sbx create --name <box> ... --clone .`）。host に出るのは browser 確認 / docker 操作 / host 権限が要る時だけ。
- **project に置く（committed）**: `.mcp.json`（chrome-devtools MCP = host:headful / box:headless 自動切替、chrome-profile MCP = host のログイン済み専用 profile Chrome に接続。経路の使い分け・agent 規範は [rules/chrome-devtools.md](rules/chrome-devtools.md)、起動手順は [docs/guide/chrome-profile.md](docs/guide/chrome-profile.md)）、`sbx/`（カスタム image + codex egress mixin）/ `scripts/`（host helper）/ `tools/`（開発ツール: a2a-review / parallel-dev）/ `.claude/skills/`（project 同梱の Claude skill: a2a-review / codex-review / grilling / pr-codex-ci / pr-ci / pr-review-respond / box-session-context / box-session-resume / box-session-resume-grant / host-ask / host-answer / host-fetch / host-fetch-grant / observe-session）/ `.claude/settings.json`（statusLine 等の共有設定）。個人差の出る設定は `.claude/settings.local.json`（local・非コミット）へ。
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
| 6 | merge: **全 review thread を resolve** 後にユーザー判断（デフォルトは報告して停止） | [rules/commit-pr.md](rules/commit-pr.md) / [docs/instructor/repo-settings.md](docs/instructor/repo-settings.md) |
| 7 | cleanup: CWD を main へ戻して `git worktree remove` | [rules/worktrees.md](rules/worktrees.md) |

**注意**: step 4 の最終 merge-ready = **local gate（codex + CI clean）+ remote gate（全 thread resolved + 新規 bot review settle）の AND**。chain は orchestrator (`/pr-codex-ci` / `/pr-ci` どちらも) step 5 で `/pr-review-respond` を skill 内強制起動する形で実装されており（[rules/pr-followup.md](rules/pr-followup.md)）、step 4 → 5 は連続した後続工程で、中間で止めない（過去に「local gate clean」を merge-ready と誤読して停止し、後から届いた bot review を見落とした事故あり）。

横断: HOTL 監視（statusLine の session id → host から transcript） / 並列（box ごとに 1 セッション） / cross-platform（`.sh`+`.ps1` 対） / **box↔host 双方向 context bridge**（`/box-session-context` = host→box の transcript pull、`/box-session-resume` = session_id を貼るだけで host / 別 box に inject して `claude --resume` 再開（host 起動は直接実行・box 起動は host-bridge 経由で `/box-session-resume-grant` に委譲）、`/host-ask` ↔ `/host-answer` = box→host の能動 ask、`/host-fetch` ↔ `/host-fetch-grant` = box egress が塞がれた URL の host 代理取得（SSRF-safe core + user gate、`sbx policy allow` はせず単発取得）、`.claude/host-bridge/` を bind mount 経由で両見え。bridge の配管 = 共有 `scripts/internal/host-bridge.sh`）→ 各 rule（[rules/pr-followup.md](rules/pr-followup.md) / [rules/box-ops.md](rules/box-ops.md) / 下記）。

（`stage/*` は dev flow ではなく講義の checkpoint 機構 → [rules/stages.md](rules/stages.md)）

skill は**抽象度のレイヤー**で構成する（上＝抽象 / 下＝具体）: **フロー層（本セクション）→ orchestrator skill（例 `/pr-codex-ci`）→ leaf skill（例 `/a2a-review`）→ scripts/tools**。orchestrator が leaf を compose し、CI check 等の操作系も orchestrator が回す具体化要素。粒度・合成ルール・各 skill のレイヤーは [rules/skills.md](rules/skills.md) 参照。

## 構成の前提

- **main ブランチ = 講義進行用**（README / CLAUDE.md / rules/ / scripts/ / stages/ / slides/）。project 本体のコードは持たない
- **`sbx/` = playbook 全体の実行環境のカスタム image + codex egress mixin**（Docker Sandboxes）。built-in claude agent + image（claude/codex 同梱）+ codex mixin で、claude / codex を YOLO / auto-mode でも安全に同居させて回すための microVM 基盤で、main に置く土台。stage は base からの fork なので、分岐元の main に最初から存在させる（詳細は [sbx/README.md](sbx/README.md)）
- **`stage/*` ブランチ = project 本体の checkpoint**。main を base にした stacked 連鎖（main → stage/01 → … → 末尾）で、project 本体は各 stage の **`app/` 配下**に置く。`git switch stage/NN` で開ける（規約は [rules/stages.md](rules/stages.md)、設計は [docs/decisions/stage-stacked-branches.md](docs/decisions/stage-stacked-branches.md)。stage は dev flow ではなく**講義の checkpoint 機構**）

## 作業場所のルール

- 講義資料（README / CLAUDE.md / rules/ / scripts/ / slides/）や `sbx/` の変更は作業用 worktree で行う（[rules/commit-pr.md](rules/commit-pr.md)）。project（demo アプリ）本体の実装は **stage branch を base にした branch → PR** で行う。**agent は main checkout の branch を変えない規約**のため、stage 作業も worktree を切って行う（受講者は自分の checkout で `git switch` してよい — [docs/decisions/stage-stacked-branches.md](docs/decisions/stage-stacked-branches.md)）。
- worktree の切り方・片付けは [rules/worktrees.md](rules/worktrees.md)、stage の規約は [rules/stages.md](rules/stages.md) 参照。

## コミット / PR 運用

**変更は PR 経由**（main へ直接 commit / push しない）。実装 done → commit → push → pre-PR sweep → `gh pr create` → orchestrator（box session = `/pr-codex-ci` / host session = `/pr-ci`）→ merge-ready 報告、までを**中間確認なしで一気通貫**で進める（停止点は merge・HOTL escalate・user 明示指定のみ。merge 実行はユーザー判断）。自走不能事象は黙って止まらず **HOTL escalate**（何が起きたか + 必要な人間の操作 + 再開コマンドを明示）。詳細手順（stash 退避 / gh フラグの hang 回避 / escalate 文例 / thread resolve 要件）は **[rules/commit-pr.md](rules/commit-pr.md)**。

## stage ブランチ（講義の checkpoint 機構）

`stage/*` は講義 checkpoint（3分クッキング方式）で、開発フローとは**別軸**。project 本体は各 stage の **`app/` 配下**（`app/` = product repo root 相当。product docs は `app/docs/`）。**stage で編集してよいのは `app/` 配下だけ**で、基盤変更は main への PR + restack で伝播させる。詳細規約（new-stage / restack / 命名 / checkpoint 凍結）は **[rules/stages.md](rules/stages.md)**、設計は [docs/decisions/stage-stacked-branches.md](docs/decisions/stage-stacked-branches.md)。

## cross-platform 要件

スクリプトは macOS / Linux / Git Bash (Windows) / Windows PowerShell 5.1 で動くこと:

- bash 版（`*.sh`）と PowerShell 版（`*.ps1`）を**対で保守**する。片方だけの変更で挙動差を作らない
- 例外として、全 OS 共通の単一実装が要るもの（例: statusLine の `scripts/internal/statusline.js`）は `node` 1 本で書く。`node` は claude CLI の動作前提なので host/box の全 OS に必ず居り、単一 committed コマンドで mac/linux/box/Windows（全 shell）を賄える。この場合は `.sh`/`.ps1` の対を持たない（持たないこと自体が正で、欠落ではない）
- もう一つの例外として、**使い捨ての検証用 artifact**（一度回して判断したら役目を終える ephemeral なもの。例: `examples/*/spike/` の ADR ゲート harness）は、回す環境を限定してよく（例: 資格情報を持つ mac/Linux host だけ）、その場合は pair を持たず単一 shell 実装（`*.sh` のみ等）でよい。受講者が日常的に叩く**恒久 tooling**（`scripts/` の `dev.sh` / `new-stage.sh` 等）には適用しない。pair を持たない選択をしたら artifact 側の README/コメントに「ephemeral ゆえ pair 不要（`node` 例外とは別の scoped 判断・欠落ではない）」と明記し、Windows からは Git Bash / WSL で `*.sh` を回す導線を案内する
- `*.sh` は LF 固定（`.gitattributes` で強制済み）
- `*.ps1` は ASCII only（Windows PowerShell 5.1 が BOM-less ファイルを ANSI として読むため）
- 前提バージョン: git **2.48+**（`git worktree add --relative-paths` を使用。worktree の `.git` が相対パスになり、sbx の box のように repo を別パスにマウントしても worktree の git が効く＝ box の中でも `git -C .worktrees/<NN>` が動く）

## スライド

講義スライドは**フェーズ単位**で main の `slides/<NN-slug>.html` に置く（壁打ち / 設計 / 実装 / 並列開発 / 運用保守・バグ修正。加えて概要の導入デッキ 00 と環境構築デッキ 02。壁打ちのデモを見せてから環境構築に入る流れのため、壁打ち(01) を環境構築(02) の前に置く。スライドは状態でなくフェーズに対応するので stage の checkpoint 数とは一致しない。講義資料なので stage ブランチには入れない）。**構成・命名・スタイル・レイアウト機構・検証の規範は [rules/slides.md](rules/slides.md)**、運営手順（作る / 見る / 配信）は [docs/instructor/README.md](docs/instructor/README.md)「スライド」「ステージ (checkpoint 連鎖)」参照。

- フェーズデッキ（`01-brainstorm` と 03–06）の中身は講師が所有し、agent が書くのは**講師の明示指示があるときだけ**。agent の常時担当は雛形 `slides/template.html` と共有 CSS / fit-scale JS の保守（詳細は [rules/slides.md](rules/slides.md)「中身の担当」）
