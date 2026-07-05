# 決定記録: stage/* を orphan 凍結 checkpoint から main と履歴共有する stacked branch 連鎖へ移行する

**status**: Accepted・実装済み（2026-07-02 移行完了: 新 stage/01–08 を push 済み・main 側の scripts / docs / slides 追従も同日 merge。rollback 用に温存した `archive/stage-orphan/*` は、移行検証の完了と owner 判断により同日削除済み — checkpoint 内容は新 stage の app/ にハッシュ一致で引き継がれており、旧 orphan 時代の commit は当時の PR 参照経由で GitHub 上に残る）
**関連**: [../../rules/stages.md](../../rules/stages.md)/ [../../rules/worktrees.md](../../rules/worktrees.md) / [../instructor/README.md](../instructor/README.md) / [../instructor/stage-playbook.md](../instructor/stage-playbook.md)

## 背景

現行の `stage/*` は **orphan 系列**（main と履歴を共有しない）で、`.worktrees/<NN-slug>/` に worktree 展開して使う。受講者の作業も「stage worktree を開く → そこから作業 worktree を切る」で、**worktree / orphan / setup-worktrees.sh という教材固有の概念が受講者の必修**になっている。owner からの指摘（2026-07-02）: 実開発に存在しない「stage を開く」操作が主役に見え、普通の `git switch` ベースの方が扱いやすい。基盤（scripts/ 等）は講義中変わらず、**stage 間で差分が出るのは app のパスだけ**なので、履歴を共有させて branch switch で回す方が自然ではないか。

orphan 分離の元々の根拠は「stage に複製された基盤が凍結されて drift する（共有履歴が無いので merge でも直せない）」だった。しかし**履歴を共有させれば、基盤の変更は main → stage の merge で機械的に追従できる**ため、根拠が逆転する。orphan は drift を「複製しない」ことで防ぐ設計、stacked は drift を「merge で解消できる」ことで防ぐ設計であり、後者は受講者 UX（実開発と同じ操作）を買える。

## 決定 1: stage/* = main を base にした stacked branch 連鎖、app は `app/` 配下

```text
main ──► stage/01-blank ──► stage/02-onepager ──► … ──► stage/08-server-500-broken
         (main + app/ 空)    (+ app/one-pager.md)
```

- 各 stage は **main の全ツリー（講義基盤）+ `app/` 配下の project 本体**を持つ。基盤ファイルは全 stage で main と同一内容なので、**stage 間の `git switch` では（restack 済みかつ `.github/workflows/ci.yml` が stage 間で同一なら）app/ 以外は原則変わらない**（tooling は切り替え中も無傷。main ↔ stage の switch では stage 側にだけある `.github/workflows/ci.yml` が出入りする）
- **app を root でなく `app/` 配下に置く理由**: 現 orphan は app を root に持ち、main と `README.md` / `docs/` / `.gitignore` / `.github/` の 4 パスで衝突する。`app/` に隔離すれば衝突ゼロ（app の README / docs / .gitignore は `app/` 配下にネストする。nested `.gitignore` は git が解釈する）
- **app の CI**（現 stage の `.github/workflows/ci.yml`）は stage branch の root `.github/workflows/ci.yml` に置く（workflow は repo root 必須。main に同名ファイルは無いので main→stage merge で消えない）。trigger は **`push.branches: [stage/**]` に加えて `pull_request.branches: [stage/**]` を必ず持つ**（feat/... → stage/NN の PR は push filter に一致しないため、pull_request trigger が無いと PR フローの CI gate が空になる）。両方に `paths: [app/**]` フィルタ
- **受講者の操作は実開発と同じになる**: `git switch stage/NN` → `git switch -c feat/...` → 実装 → PR（base = stage/NN。stage/NN は「その時点の main の代役」）。worktree / orphan / setup-worktrees は必修から外れる

## 決定 2: 基盤の伝播は明示で叩く restack ヘルパー（常駐同期はしない）

`scripts/internal/restack-stages.sh` / `.ps1` を新設し、**main → stage/01 → 02 → … → 08 の cascade merge** を 1 コマンドで流す。基盤（root 側）と app（`app/`）はパスが素で重ならないため merge は自動解決する。CI 常駐の自動同期は入れない（明示で叩く。checkpoint の SHA をむやみに動かさない）— 現行 CLAUDE.md の「必要になったら restack ヘルパーとして足す」想定の実装。

- 基盤 merge で stage の SHA は動くが、**`app/` の内容は import commit のまま凍結**なので「3 分クッキングの再現性」（checkpoint の app 挙動が不変）は保たれる

## 決定 3: worktree は「必修」から「道具」へ降格（廃止しない）

worktree が引き続き必要な場面は残る:

- **並列 issue フェーズ**: 複数 dev box が**同一 bind-mount checkout を共有**するため、単一 checkout の branch switch は box 間で衝突する。並列時は従来通り box ごとに worktree（または clone box）
- **instructor の並置比較**: broken / fixed（06/07）の同時展開、答え合わせ参照
- **agent 自身の開発フロー**（main checkout の branch を変えない規約）は従来通り worktree

## 移行手順（2026-07-02 実施済みの記録）

> 以下は実施当時の手順の記録。手順中の `archive/stage-orphan/*` は移行検証後に削除済みのため、この手順をそのまま再実行することはできない（再移行が必要になった場合は、当時の orphan commit を古い PR の参照から辿る）。

1. stage/01 から順に再構築: 前 stage（新系列。stage/01 のみ main）を base に branch → **`git rm -r --ignore-unmatch app/` で前 stage 由来の app/ を空にしてから**（`--ignore-unmatch` は app/ が無い stage/01 の初回で fail しないため）旧 orphan のツリーを `git read-tree --prefix=app/ -u archive/stage-orphan/NN` で import（tree-ish は archive 済み旧 orphan の branch ref、`-u` で worktree にも展開。掃除しないと前 stage の残骸が次 stage に混入する）→ `app/.github/workflows/ci.yml` を root へ移設し trigger を決定 1 の形に調整 → import commit 1 つ
2. **先に旧 `.worktrees/` の展開を `git worktree remove` で全て外す**（checked-out branch は rename できないため、この順序が必須）→ 旧 orphan 系列を `archive/stage-orphan/NN` に rename して温存（rollback 手段。origin にも push）
3. 新系列を `stage/*` として push（live ruleset は 2 本とも `~DEFAULT_BRANCH` のみ対象で stage/* に保護なし — 2026-07-02 に API で確認済み。置き換え push を阻むものは無い）
4. instructor 用に必要な分だけ worktree を再展開（旧展開の除去は手順 2 で実施済み）
5. 追従して書き換えるもの: CLAUDE.md「stage ブランチの規約」/ [../../rules/worktrees.md](../../rules/worktrees.md) / [../../rules/box-ops.md](../../rules/box-ops.md)（stage worktree 展開前提の記述）/ [../instructor/README.md](../instructor/README.md) / [../instructor/stage-playbook.md](../instructor/stage-playbook.md) / スライド 01（setup-worktrees 行の除去）・02–06（「開く stage」→ `git switch stage/NN`）/ `scripts/internal/new-stage.sh`・`.ps1`（orphan 起点をやめ前 stage から分岐）/ `scripts/internal/setup-worktrees.sh`・`.ps1`（受講者必修から外し instructor 向けに縮退 or 撤去）

## トレードオフ・残差

- **main の workflow が stage push で走るリスク**: 現状は `pages.yml` が `branches: [main]` ゲート済み・他は `workflow_dispatch` のみで安全。**今後 main に workflow を足すときは branch ゲートを必須とする**（この規範を [.github/workflows/README.md](../../.github/workflows/README.md) に追記する）
- **`Closes #N` の自動 close は引き続き効かない**（stage が default branch でないのは同じ）。仕上げフェーズの注意書きは現状のまま有効
- **stage の履歴に main の全履歴が乗る**: stage の `git log` が基盤 commit で埋まる。app の履歴だけ見たいときは `git log -- app/`
- **凍結性の弱化**: orphan は「触りようがない」凍結だったが、stacked は merge で SHA が動く。app/ 不変で実害はないが、「checkpoint = app/ の内容」と定義を明確化して運用する
- 受講者 fork の要件（全 branch を fork）は従来と同じ
