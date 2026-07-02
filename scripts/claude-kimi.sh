#!/usr/bin/env bash
# claude-kimi: Claude Code CLI を Moonshot (Kimi) の Anthropic 互換 endpoint で起動する
# fallback wrapper。Anthropic API 障害時に skill / MCP / 開発フローを保ったまま
# model backend だけ Kimi に差し替える。経路の全体像・box での使い方・注意点は
# docs/kimi-fallback.md 参照。
set -euo pipefail

if [ -z "${MOONSHOT_API_KEY:-}" ]; then
  echo "error: MOONSHOT_API_KEY が未設定です。" >&2
  echo "       https://platform.kimi.ai/console/api-keys で API key を発行し、" >&2
  echo "       MOONSHOT_API_KEY=<key> bash scripts/claude-kimi.sh のように渡してください。" >&2
  exit 1
fi

MODEL="${KIMI_MODEL:-kimi-k2.7-code}"

# 残存する Anthropic 認証を外す: ANTHROPIC_AUTH_TOKEN との競合を避け、
# Anthropic の credential (API key / OAuth token) を third-party endpoint へ送らせない。
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
# 他 provider の routing 選択が残っていると ANTHROPIC_BASE_URL が効かず Moonshot に切り替わらない。
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY

export ANTHROPIC_BASE_URL="${KIMI_ANTHROPIC_BASE_URL:-https://api.moonshot.ai/anthropic}"
export ANTHROPIC_AUTH_TOKEN="$MOONSHOT_API_KEY"
export ANTHROPIC_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"
# Moonshot 公式推奨 ( https://platform.kimi.ai/docs/guide/agent-support ):
# tool search は Kimi endpoint 非対応、auto-compact 窓は K2.7 の 256K context に合わせる。
export ENABLE_TOOL_SEARCH=false
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=262144

echo "claude-kimi: model backend = Moonshot $MODEL (コード/コンテキストは Anthropic でなく Moonshot に送信されます)" >&2
exec claude "$@"
