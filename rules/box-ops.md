# Box Ops（sbx box のライフサイクル）

box-primary 運用の実行基盤 = **sbx（Docker Sandboxes）の box の中で claude / codex を動かす**（YOLO/隔離、microVM-per-agent）。本 rule は box の環境準備・起動・並列・host escape hatch・後片付けの手順をまとめる。開発フロー全体は [CLAUDE.md](../CLAUDE.md)「開発フロー」、image/mixin の中身は [sbx/README.md](../sbx/README.md) 参照。

## 0. 環境準備（マシンに一度。全 project で再利用）

image はマシン単位で load すれば project 非依存で使い回せる:

```bash
sbx login                                              # 後続の sbx secret set / image pull 等で必須 (template load 自体はローカル tar なので不要)
docker build --load -t coding-agent-playbook-sbx sbx/ # claude/codex/uv/python を同梱した汎用箱 (--load: BUILDX_BUILDER non-default driver でも local image store に入れる)
docker save coding-agent-playbook-sbx -o cap-sbx.tar
sbx template load cap-sbx.tar                          # sbx は local image を共有せず pull するため load 必須
```

**secret 登録**（box の外で proxy 注入が原則。一部経路で token が box 内に provision される例外あり、security トレードオフは [sbx/README.md](../sbx/README.md)）:

- **claude**: サブスク並列は `claude setup-token` → `sbx secret set -g anthropic`（全 box 自動認証・推奨）。単発は箱内 `/login`。API key は `sbx secret set -g anthropic`
- **codex**: built-in claude agent の同居 box (codex 同梱) は OAuth proxy 注入が効かない (agent-gating) ため、host で `codex login` 済みの `~/.codex/auth.json` を box 内に転送（転送先 dir 事前作成 + `sbx cp` + 所有者変更の 3 ステップ、詳細は [sbx/README.md](../sbx/README.md) の「codex のサブスク認証」）。**built-in codex agent の専用 box (codex reviewer pair = `cdx-<NAME>`)** は `sbx secret set -g openai --oauth` で作成時に proxy 注入（token は box に入らない、auth.json 転送不要）

## 1. box 起動

```bash
# 単発 dev box (host worktree を bind-mount。auto-name + cdx-<NAME> reviewer pair auto-provision)
bash scripts/dev.sh

# 明示名 dev box (idempotent attach-or-create)
bash scripts/dev.sh <NAME>

# 並列 dev box (引数なしを別ターミナルで複数回、各 dev box が独立 cdx pair を持つ)
bash scripts/dev.sh
bash scripts/dev.sh
bash scripts/dev.sh ls [-q]                             # 一覧 + cdx 状態 (-q で name only)
bash scripts/dev.sh attach [<NAME|N>]                   # 再 attach (引数なしは picker)
bash scripts/dev.sh kill <NAME|N>                       # 停止 (cdx-<NAME> pair も同時破棄)
bash scripts/dev.sh prune [--yes] [--all]               # orphan cdx pair / stale lease / stale lock を一括 cleanup (引数なしは dry-run、--all で CDX=none な dev box 本体も対象。--all は sbx ls --json で status=running を skip (jq 必須、不在 / parse fail で fail-closed abort)、dev.sh shell attached や直接 sbx exec 中の box は誤削除されない。delete 直前に running を再 snapshot して scan→delete window の race も防ぐ)

# sandbox box (--clone .、cdx pair なし、PR 化前の ad-hoc 探索用)
bash scripts/dev.sh sandbox [<NAME>]
```

- 起動で `.mcp.json` / CLAUDE.md がロードされる（box は claude+codex 同居）
- **stage は branch なのでどの box でも `git switch stage/NN` で開ける**（stacked 連鎖: [docs/decisions/stage-stacked-branches.md](../docs/decisions/stage-stacked-branches.md)）。dev box (bind-mount) は host checkout を共有するため box 内の switch が host にも見える点に注意（agent は worktree を切る規約）
- **sandbox box (`--clone .`)** は clone に stage/* branch が含まれるためそのまま `git switch` できる。worktree 展開（git 管理外の `.worktrees/`）は clone に持ち込まれないが、必要なら box 内で `bash scripts/internal/setup-worktrees.sh` を実行する（並置比較用の道具）

## 2. host escape hatch（host に出るのは限られた用途）

基本は box の中。host 権限が要る時だけ host に出る:

1. 操作を見ながらのブラウザ確認（host で headful chrome-devtools）
2. docker 操作（並列起動の Traefik 等）
3. その他 host 権限が要るもの

box 内 dev server は `sbx ports <box> --publish <port>` で host に publish する（publish 直後に `127.0.0.1:<host port>->...` が出力される。後から再確認するには `sbx ports <box>`）。**user に案内する閲覧 URL は publish 出力の host port を使い `http://127.0.0.1:<host port>` と書く**（`--publish <port>` 単独形は host 側に ephemeral port が割当られうるため sandbox port をそのまま使わない。`localhost` にもしない — macOS は `localhost` を IPv6 `::1` に先に解決するが、sbx の IPv6 側 forward は接続が reset され「アクセスできない」になる。IPv4 側のみ正常）。

## 3. 後片付け

- dev box を消す: `bash scripts/dev.sh kill <NAME|N>` (cdx-`<NAME>` reviewer pair も同時破棄)。sandbox box は `sbx rm <box>`
- codex reviewer pair box (`cdx-<NAME>`) は dev box の TTY 終了時に dev.sh の trap で auto-teardown される (per-pair lifecycle、[setup.md](../docs/setup.md))。trap が走らずに残った orphan / stale lease / stale lock は **`bash scripts/dev.sh prune`** (dry-run で削除候補確認 → `--yes` で実行) で一括 cleanup する。stale sbx policy 系は `sbx policy ls` で確認して `sbx policy rm <id>`
