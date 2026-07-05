# Kimi fallback (Claude Code の backend を Kimi 互換 API に差し替える)

Anthropic 側の障害 (API / 認証) で講義・開発が止まらないよう、**Claude Code CLI を [Moonshot AI の Kimi](https://platform.kimi.ai/) の Anthropic 互換 API で動かす** fallback を用意している。claude CLI・skill・`.mcp.json`・CLAUDE.md の開発フローは**そのまま生き**、差し替わるのは model backend だけ。

なお本 fallback は claude CLI が動くことが前提 (endpoint の差し替え)。CLI 自体が起動不能な障害は対象外。

## 平時の準備 (これだけやっておく)

1. [Moonshot AI Open Platform](https://platform.kimi.ai/console/api-keys) で API key を発行する (従量課金または Kimi membership。障害が起きてから発行しようとすると Anthropic と無関係に混雑しがち)
2. **box 用: key を sbx custom secret に登録する** (実 key は sbx store = OS keychain に入り、box には固定 placeholder しか渡らない):

```bash
sbx secret set-custom -g --host api.moonshot.ai --placeholder sbx-playbook-kimi-moonshot --value <MOONSHOT_API_KEY>
```

   `--value` は shell history に残るため、実行後に履歴から消す。登録しただけでは何も切り替わらない (下記 marker を立てるまで box は通常どおり Anthropic で動く)
3. host wrapper の疎通確認を 1 回だけ:

```bash
MOONSHOT_API_KEY=<key> bash scripts/claude-kimi.sh -p "1+1="
# Windows: $env:MOONSHOT_API_KEY="<key>"; powershell -ExecutionPolicy Bypass -File scripts/claude-kimi.ps1 -p "1+1="
```

## 障害時: box を Kimi backend で立ち上げる (推奨)

marker secret を立てると、以後 `dev.sh` / `dev.ps1` が作る**新規 box** (dev / sandbox / observe) は claude が Kimi backend (`kimi-k2.7-code`) で起動する:

```bash
# marker ON (全 box に適用。特定 box だけ試すなら -g の代わりに <box名>)
sbx secret set-custom -g --host playbook-kimi.invalid --env PLAYBOOK_KIMI_ENABLE --placeholder playbook-kimi-enable --value 1

# 以後は普段どおり
bash scripts/dev.sh
```

仕組みと注意:

- marker 検出時に `sbx/playbook-kit-kimi/spec.yaml` (mixin kit) が box 作成に追加され、`api.moonshot.ai` への egress と Kimi 向け env (`ANTHROPIC_BASE_URL` / model 系) が box に入る。`ANTHROPIC_AUTH_TOKEN` に入るのは固定 placeholder で、**proxy が `api.moonshot.ai` 宛 request 中でのみ実 key に置換**する (実 key は box に入らない — github secret と同じ構造)
- **既存 box には効かない** (kit / env は box 作成時に注入)。既存 box を切り替えるには `bash scripts/dev.sh kill <NAME>` → 再作成
- key 未登録のまま marker を立てると dev.sh が fail-closed で abort し、登録コマンドを案内する
- codex 側 (cdx pair / `/a2a-review` / `/pr-codex-ci`) は Anthropic 障害と無関係に動くため、PR 後続フローはそのまま使える
- コード / コンテキストの送信先が Anthropic から **Moonshot に変わる**。取り扱いに注意が要る作業は障害復旧まで見送る判断も含めて選ぶ

復旧したら marker を外す (以後の新規 box は Anthropic に戻る。key の custom secret は置換対象が `api.moonshot.ai` 宛だけなので残しておいてよい):

```bash
sbx secret rm -g --placeholder playbook-kimi-enable -f
# per-box で立てた marker は -g の代わりに <box名> を指定して外す
sbx secret rm <box名> --placeholder playbook-kimi-enable -f
```

## host session で使う (wrapper)

box を使わない host session は wrapper で起動する:

```bash
MOONSHOT_API_KEY=<key> bash scripts/claude-kimi.sh
```

wrapper は Moonshot 公式の [agent 連携ガイド](https://platform.kimi.ai/docs/guide/agent-support) どおりに `ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic` / `ANTHROPIC_AUTH_TOKEN` / model 系 env を設定し、残存する Anthropic credential (`ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN`) と他 provider の routing selector (`CLAUDE_CODE_USE_BEDROCK` / `VERTEX` / `FOUNDRY`) を外してから `claude` を exec する。model は `KIMI_MODEL` で上書き可 (既定 `kimi-k2.7-code`)。

- **host では YOLO (`--dangerously-skip-permissions`) を付けない**。本 repo の YOLO 前提は box の hypervisor 境界 ([sbx/README.md](../../sbx/README.md)) であって model の信頼性ではない。host では承認プロンプト付きの通常運用で回す
