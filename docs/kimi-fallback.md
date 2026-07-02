# Kimi fallback (Claude Code の backend を Kimi 互換 API に差し替える)

Anthropic 側の障害 (API / 認証) で講義・開発が止まらないよう、**Claude Code CLI を [Moonshot AI の Kimi](https://platform.kimi.ai/) の Anthropic 互換 API で動かす** fallback を用意している。claude CLI・skill・`.mcp.json`・CLAUDE.md の開発フローは**そのまま生き**、差し替わるのは model backend だけ。

なお本 fallback は claude CLI が動くことが前提 (endpoint の差し替え)。CLI 自体が起動不能な障害は対象外。

## 平時の準備 (これだけやっておく)

1. [Moonshot AI Open Platform](https://platform.kimi.ai/console/api-keys) で API key を発行して手元に控える (従量課金または Kimi membership。障害が起きてから発行しようとすると Anthropic と無関係に混雑しがち)
2. 1 回だけ疎通確認しておく:

```bash
MOONSHOT_API_KEY=<key> bash scripts/claude-kimi.sh -p "1+1="
# Windows: $env:MOONSHOT_API_KEY="<key>"; powershell -ExecutionPolicy Bypass -File scripts/claude-kimi.ps1 -p "1+1="
```

## host で使う

```bash
MOONSHOT_API_KEY=<key> bash scripts/claude-kimi.sh
```

wrapper は Moonshot 公式の [agent 連携ガイド](https://platform.kimi.ai/docs/guide/agent-support) どおりに `ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic` / `ANTHROPIC_AUTH_TOKEN` / model 系 env を設定し、残存する Anthropic credential (`ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN`) を外してから `claude` を exec する。model は `KIMI_MODEL` で上書き可 (既定 `kimi-k2.7-code`)。

注意:

- **host では YOLO (`--dangerously-skip-permissions`) を付けない**。本 repo の YOLO 前提は box の hypervisor 境界 ([sbx/README.md](../sbx/README.md)) であって model の信頼性ではない。host では承認プロンプト付きの通常運用で回す
- コード / コンテキストの送信先が Anthropic から **Moonshot に変わる**。取り扱いに注意が要る作業は障害復旧まで見送る判断も含めて選ぶ
- codex 側 (`/a2a-review` / `/pr-codex-ci` / `/pr-ci` の codex step) は Anthropic 障害と無関係に動く。落ちているのが claude 側だけなら PR 後続フローはそのまま使える

## box で使う (任意)

box は egress default-deny のため、host で Moonshot への egress を開けてから box 内で wrapper を叩く:

```bash
# host: 対象 box だけに Moonshot egress を許可 (rule id が出力されるので控える)
sbx policy allow network --sandbox <box名> api.moonshot.ai:443

# box 内: key は対話 shell で export して起動 (bind-mount 上のファイルに key を書かない)
export MOONSHOT_API_KEY=<key>
bash scripts/claude-kimi.sh --dangerously-skip-permissions
```

復旧後は host で `sbx policy rm network --sandbox <box名> --id <rule-id>` で egress を閉じる (id を控え損ねたら `sbx policy ls` で確認)。

box の built-in claude agent (`dev.sh` 起動時に自動で立つ claude) は anthropic secret proxy 前提のため、この経路では差し替えない。box での Kimi 利用は「box shell からの手動起動」に限り、手数を減らしたいなら host 運用への切り替えを推奨する。

## 復旧後

Anthropic が復旧したら通常運用 (`bash scripts/dev.sh` の box-primary) に戻し、開けた egress rule を閉じる。Kimi backend で作りかけた PR は通常の PR フロー ([rules/pr-followup.md](../rules/pr-followup.md)) にそのまま乗る (backend が何であれ PR / CI / review の gate は同一)。
