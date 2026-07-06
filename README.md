# coding-agent-playbook

Coding agent (claude / codex) を使った開発の一連の流れを、実演を追いながら学ぶための講義用リポジトリ。

**`bash scripts/dev.sh` 1 行で workshop 用の隔離 box に入り、あとは claude に頼むと [CLAUDE.md](CLAUDE.md) の開発フロー (worktree → 実装 → PR → codex review + CI → review 対応 → merge) で自走する** のが最短経路。セキュリティモデルは microVM-per-agent の hypervisor 境界 ([Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) `sbx`) に依存し、承認ゲートを外した YOLO / auto-mode でも箱の壁を破られない (詳細は [sbx/README.md](sbx/README.md) 「なぜ sbx か」)。

---

## 1. 初回セットアップ (マシンに 1 回)

**要件**: host に `sbx` CLI **v0.31+** ([Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) — `sbx version` で確認、`--clone` mode が v0.31.0 で導入。ただし下記の**サブスク「1 box `/login` で全 box 自動 provision」は v0.34.0+** が前提。v0.33 以前は box ごとに `/login` するか API key 経路にする) + Docker、git **2.48+**。host session で claude を回すなら `claude` CLI ([Claude Code 公式 install 手順](https://claude.com/claude-code)) も（box 内 claude は image 同梱・サブスク認証は最初の box で `/login`）。

```bash
# 1-1. host 認証 (一度)
sbx login                                  # Docker アカウント認証

# 1-2. secret 登録 (box を立てる前に github / openai を登録 — 詳細・PAT 権限根拠: docs/guide/setup.md)
sbx secret set -g github                   # fine-grained PAT を貼る (発行手順は docs/guide/setup.md)
sbx secret set -g openai --oauth           # browser で ChatGPT 認証
# anthropic (claude) はサブスク (Pro/Max) なら secret 登録不要 — §2 で最初の box に入って /login すれば
#   以降の新規 box は自動 provision される (v0.34.0)。API 課金にするなら: sbx secret set -g anthropic (API key を貼る)
```

image build は **§2 の `bash scripts/dev.sh` 初回起動時に自動** (~5 分)。明示叩くなら `bash scripts/build-image.sh` (rebuild) / `bash scripts/check-setup.sh` (環境 doctor)。

Windows (PowerShell) は対応する `.ps1` (`powershell -ExecutionPolicy Bypass -File scripts/dev.ps1` 等)。

**詳細** (PAT scope と選定根拠 / API key 経路 / cdx-`<NAME>` pair reviewer の運用 / image / claude / codex の更新): [docs/guide/setup.md](docs/guide/setup.md)

---

## 2. box に入って開発する (毎セッション)

```bash
bash scripts/dev.sh                        # 新規 dev box を起動 (自動命名 / cdx-<NAME> reviewer pair も auto-provision / 初回 ~5 分の image build 含む)
# Windows: powershell -ExecutionPolicy Bypass -File scripts/dev.ps1
```

名前を覚える必要はない (生成後の名前は dev.sh が出力)。再 attach や複数 dev box の切り替えは subcommand で:

```bash
bash scripts/dev.sh ls                     # 既存 dev box 一覧 (#, NAME, CDX 状態)
bash scripts/dev.sh ls -q                  # name only (Docker `docker ps -aq` 互換、xargs friendly)
bash scripts/dev.sh attach                 # 0→start / 1→無条件 attach / 複数→番号で選ぶ picker
bash scripts/dev.sh attach <NAME|N>        # 直接 attach (N は ls 行番号)
bash scripts/dev.sh <NAME>                 # 明示名で idempotent attach-or-create
bash scripts/dev.sh kill <NAME|N>          # dev box を停止 (対の cdx-<NAME> reviewer pair も同時破棄)
bash scripts/dev.sh prune [--yes] [--all]  # orphan cdx pair / stale lease / stale lock を一括 cleanup (引数なしは dry-run、--all で CDX=none な dev box 本体も対象)
```

claude プロンプトに `stage/02-onepager で issue #N の foo 機能を作って` のように頼めば、§3 の PR フローで自走する (詳細は [CLAUDE.md](CLAUDE.md)、使い方は box の claude に「この project どう使う？」と聞いてもよい)。

発展形 (並列 box / box 内 shell / Traefik routing 等) は [docs/guide/parallel.md](docs/guide/parallel.md) 参照。

---

## 3. PR フロー (claude が自走、受講者は最後の merge 判断のみ)

| # | step | skill |
|---|------|-------|
| 1 | worktree を切る | (自動 / `git worktree add`) |
| 2 | 実装 + 要所で codex 相談 | `/a2a-review` |
| 3 | `gh pr create` で PR 化 | (gh CLI) |
| 4 | codex review + CI + GitHub bot review (Copilot / qodo 等) 対応まで自走 (box session なら `/pr-codex-ci`、host session なら `/pr-ci`。transport だけ違い judgement の質は同等) | `/pr-codex-ci` / `/pr-ci` |
| 5 | merge | **ユーザー判断** (`gh pr merge --squash --delete-branch` 等) |
| 6 | worktree cleanup | (自動 / `git worktree remove`) |

step 4 の「merge-ready」は **codex review + CI clean（local gate）と、全 review thread resolved + 新規 bot review settle（remote gate）の AND**（[docs/instructor/repo-settings.md](docs/instructor/repo-settings.md)）: `/pr-codex-ci` / `/pr-ci` は内部で GitHub bot review 対応 skill (`/pr-review-respond`) を自動 chain 起動する (受講者が別途呼ぶ手動 step ではない) ため、**全 thread を resolve するまで実 merge はできない**。詳細は [CLAUDE.md](CLAUDE.md) と [rules/pr-followup.md](rules/pr-followup.md)。

---

## 構成

main ブランチは**講義進行用**で、project 本体のコードは持たない。project の実体は `stage/*` ブランチ (main を base にした stacked 連鎖) の **`app/` 配下**にあり、`git switch stage/NN` で開く ([docs/decisions/stage-stacked-branches.md](docs/decisions/stage-stacked-branches.md))。

```text
coding-agent-playbook/   # main: 講義進行用 (CLAUDE.md / 解説 / scripts)
  sbx/                   # カスタム image (claude/codex/chrome) + codex egress mixin
  tools/                 # 開発ツール (host から駆動)
    a2a-review/          # codex を別 box の A2A reviewer にする (/a2a-review skill の実体)
    parallel-dev/        # 複数 box を名前で見分ける並列開発 (Traefik)
  .claude/skills/        # project 同梱の Claude skill
  slides/                # フェーズ単位の講義スライド (単一 HTML)
  scripts/               # 受講者が日常で叩く host script (dev / build-image / check-setup) — sandbox / shell / route は dev の subcommand
    internal/            # agent / skill / setup が裏で呼ぶ host script (受講者は直接触らない)
  docs/                  # playbook の人間向け文書 (index: docs/README.md)
    guide/               # 受講者向け how-to (setup / parallel / kimi-fallback / headful-bridge / chrome-profile)
    instructor/          # 講義運営者向け (運営手順 / 実演台本 / repo 設定)
    decisions/           # ADR (なぜそう決めたかの記録)
  rules/                 # 開発フロー規範 (box-ops / worktrees / pr-followup / skills / slides)
  examples/              # 運用保守フェーズの参照実装・検証 harness (恒久 tooling ではない — examples/README.md)
    observe/             # local(HOTL): read-only observe box で本番を調べる runbook + IAM
    sre-bedrock/         # cloud(HOTU): 無人 SRE fixer pipeline の ADR 検証 spike + 配線設計
  .worktrees/            # 作業用 worktree (git 管理外。stage の並置比較・並列作業で使う)
```

stage の連鎖は `stage/01-blank` (壁打ちの起点・app/ 空) → `stage/02-onepager` → … → 末尾 (現在は運用保守シナリオの stage 群まで)。worktree を切った場合も同一の `.git` を共有するため、どこで commit / fetch しても全体に即時反映される。

---

## 詳細リファレンス

| 領域 | 場所 |
|---|---|
| 初回セットアップ詳細 (PAT 権限 / cdx-`<NAME>` pair reviewer 運用 / 更新) | [docs/guide/setup.md](docs/guide/setup.md) |
| image / claude / codex の更新 (`scripts/build-image.sh` の rebuild 手順・cache 挙動) | [docs/guide/setup.md](docs/guide/setup.md#image--claude--codex-の更新-たまに) |
| 並列開発 (並列 dev box / sandbox box / shell / Traefik routing) | [docs/guide/parallel.md](docs/guide/parallel.md) |
| 開発フロー全体 (box-primary, PR ライフサイクル) | [CLAUDE.md](CLAUDE.md) |
| box / image / 認証 / 落とし穴 | [sbx/README.md](sbx/README.md) |
| Anthropic 障害時の Kimi fallback (claude の backend 差し替え) | [docs/guide/kimi-fallback.md](docs/guide/kimi-fallback.md) |
| codex A2A review の内部 | [tools/a2a-review/README.md](tools/a2a-review/README.md) / [.claude/skills/a2a-review/SKILL.md](.claude/skills/a2a-review/SKILL.md) |
| Traefik 構成詳細 | [tools/parallel-dev/box-routing/README.md](tools/parallel-dev/box-routing/README.md) |
| box ops 規範 | [rules/box-ops.md](rules/box-ops.md) |
| worktree 規範 | [rules/worktrees.md](rules/worktrees.md) |
| PR フロー規範 | [rules/pr-followup.md](rules/pr-followup.md) |
| スライド規範 | [rules/slides.md](rules/slides.md) |
| skill 階層 | [rules/skills.md](rules/skills.md) |
| HOTL 監視 (box の中を host から見る) | [.claude/skills/box-session-context/SKILL.md](.claude/skills/box-session-context/SKILL.md) |
| GitHub ruleset / merge gate | [docs/instructor/repo-settings.md](docs/instructor/repo-settings.md) / 設計根拠 [docs/decisions/merge-gate-design.md](docs/decisions/merge-gate-design.md) |
| docs 全体の index (誰向け・いつ読む) | [docs/README.md](docs/README.md) |
| 採用した設計判断 (ADR) | [docs/decisions/](docs/decisions/) |
| 運用保守フェーズの実演教材 (AWS 上の無人 SRE fixer pipeline、observe box での read-only 調査) | [examples/sre-bedrock/README.md](examples/sre-bedrock/README.md) / [examples/observe/runbook.md](examples/observe/runbook.md) |
| stage 別 実演ガイド (講義中に参照する台本 / 依頼プロンプト例) | [docs/instructor/stage-playbook.md](docs/instructor/stage-playbook.md) |
| 講義運営者向け (新 stage / スライド / ステージ checkpoint 連鎖) | [docs/instructor/README.md](docs/instructor/README.md) |
