# stage ブランチの規約（講義の checkpoint 機構）

[CLAUDE.md](../CLAUDE.md)「stage ブランチ」から委譲される詳細規範。

`stage/*` は「講義中に『ここまで進んだ状態』を即座に開く」ための教材装置（3分クッキング方式）であり、開発フロー（box → worktree → PR → merge）とは**別軸**。**受講者の default は前フェーズの自分の到達点から地続きに進むこと**で、stage は追いつき・やり直しの**セーブポイント**（例外: 運用保守フェーズは仕込みバグが必要なため stage 起点が必須）。main を base にした **stacked 連鎖**（main → stage/01 → … → 末尾）で、project（demo アプリ）本体は各 stage の **`app/` 配下**に置く（設計と移行の経緯は [../docs/decisions/stage-stacked-branches.md](../docs/decisions/stage-stacked-branches.md)）。

- **checkpoint = `app/` の内容**。基盤（root 側）は main 由来で全 stage 同一のため、stage 間の `git switch` は原則 app/（と stage 側にだけある `.github/workflows/ci.yml`）しか触らない
- **`app/` は product repo の root 相当**（実開発で単独 repo にしたときの root にあたる）。中の配置は実モノレポ慣行に合わせる: `apps/`（デプロイ単位: web / api / mock）+ `packages/`（共有ライブラリ: core）+ `infra/`（CDK app、独立 workspace）+ `docs/`（design.md 等の横断設計）。**product の設計 docs は `app/docs/` 直下**に置く（repo root の `docs/` は playbook 用で別物。app/ の中では root docs 慣行がそのまま成立する）
- 新しい stage は必ず `scripts/internal/new-stage.sh` / `scripts/internal/new-stage.ps1` で作る（前 stage を base に分岐。base 省略時は連鎖末尾）。orphan では作らない
- **stage で編集してよいのは `app/` 配下だけ**。基盤（README / CLAUDE.md / rules/ / scripts/ / slides/ 等の root 側）を stage 上で直接編集しない — 基盤の変更は main への PR で行い、`scripts/internal/restack-stages.sh`（Windows: `.ps1`）の cascade merge（main → 01 → … → 末尾）で全 stage に伝播させる（明示で叩く。常駐同期はしない）
- stage の project ドキュメント（`app/README.md` 等）や**コード中のコメント**には **project（demo アプリ）の動かし方だけ**を書く。playbook の host 運用手順（box→host の閲覧経路 = `dev.sh route` / Traefik 等、main の `scripts/` 前提のコマンド）を `app/` 側に複製しない（点検は `*.md` に限定しない）。全 stage 共通の playbook 関心事は main 側に単一ソースで置き、restack で伝播させる
- 命名: ブランチは `stage/NN-<slug>`。worktree（並置比較・並列用に展開する場合）は `.worktrees/<NN-slug>/`、削除は `git worktree remove`（手動 rm は stale 登録が残る）。一括展開は `bash scripts/internal/setup-worktrees.sh`（instructor / 並列用の道具で、受講者の必修ではない）
- **app/ の checkpoint 内容は凍結**: 上流 stage の app/ を後から直して下流へ流す retroactive な伝播は原則しない（checkpoint を動く標的にして 3分クッキングの再現性を壊すため）。必要になったら restack と同様の cascade merge を明示で回す（stacked なので merge で流せる）
- 旧 orphan 系列は移行検証（全 stage の app/ 内容が旧 orphan とハッシュ一致することを確認）後に削除済み（2026-07-02。移行の経緯は [../docs/decisions/stage-stacked-branches.md](../docs/decisions/stage-stacked-branches.md)）
