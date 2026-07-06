# Worktrees（作業用 worktree の切り方・片付け）

変更を加えるときは **編集前に `git worktree add` で作業用 worktree を切る**。本 rule は worktree の切り方・片付けと、なぜ `git checkout -b` が禁止かをまとめる。開発フロー全体は [CLAUDE.md](../CLAUDE.md)「開発フロー」、stage の規約（講義の checkpoint 機構）は [CLAUDE.md](../CLAUDE.md)「stage ブランチの規約」参照。

## なぜ `git checkout -b` ではなく `git worktree add` か

**`git checkout -b` で main checkout のブランチを変えてはいけない。** direct mount box では main checkout が host の working tree に直結しているため、`git checkout -b` するとユーザーの環境（host の作業ツリー）が変わってしまう。必ず worktree を切ってそこで作業する。

```bash
# NG: main checkout のブランチが変わる（host 環境を汚す）
git checkout -b fix/something

# OK: main はそのまま、worktree で作業
git worktree add .worktrees/fix-something -b fix/something
# ... 作業・commit・push ...
git worktree remove .worktrees/fix-something
```

## 切り方・片付け

- **切る**: `git worktree add .worktrees/<name> -b <branch> main`（base は通常 main）
- **片付け**: 作業後（merge 後）に `git worktree remove .worktrees/<name>`（手動 rm は stale 登録が残る）。CWD が worktree 内にある状態で remove すると壊れるので、**先に main repo へ `cd` してから** remove する
- worktree は `--relative-paths` 前提（git 2.48+）なので box 内でも `git -C .worktrees/<name>` が効く（[CLAUDE.md](../CLAUDE.md) の cross-platform 要件参照）

## project（demo アプリ）の実装は stage branch を base にした worktree で

- 講義資料（README / CLAUDE.md / rules/ / scripts/ / slides/）や `sbx/` の変更は本 rule の作業用 worktree で行う
- **project（demo アプリ）本体の実装は、対応する stage branch を base にした作業用 worktree**で行う（例: `git worktree add --relative-paths .worktrees/feat-x -b feat/x stage/04-mvp`）。agent は main checkout の branch を変えない規約のため `git switch stage/NN` を main checkout で行わない（**受講者が自分の checkout で switch するのは可** — [docs/decisions/stage-stacked-branches.md](../docs/decisions/stage-stacked-branches.md)）。project 本体は stage の `app/` 配下にある（規約は [CLAUDE.md](../CLAUDE.md)「stage ブランチの規約」）
