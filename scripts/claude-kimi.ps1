# claude-kimi: launch the Claude Code CLI against Moonshot (Kimi)'s Anthropic-compatible
# endpoint. Fallback for Anthropic API outages: keeps skills / MCP / the dev flow and
# swaps only the model backend. See docs/kimi-fallback.md for the full picture and
# caveats. PowerShell pair of claude-kimi.sh.
$ErrorActionPreference = "Stop"

if (-not $env:MOONSHOT_API_KEY) {
  Write-Error "MOONSHOT_API_KEY is not set. Create an API key at https://platform.kimi.ai/console/api-keys and set `$env:MOONSHOT_API_KEY before running."
}

$model = if ($env:KIMI_MODEL) { $env:KIMI_MODEL } else { "kimi-k2.7-code" }

# Drop leftover Anthropic credentials: they conflict with ANTHROPIC_AUTH_TOKEN, and the
# Anthropic API key / OAuth token must not be sent to a third-party endpoint.
Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue
# A lingering provider selector would override ANTHROPIC_BASE_URL and keep routing away from Moonshot.
Remove-Item Env:CLAUDE_CODE_USE_BEDROCK -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_CODE_USE_VERTEX -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_CODE_USE_FOUNDRY -ErrorAction SilentlyContinue

$env:ANTHROPIC_BASE_URL = if ($env:KIMI_ANTHROPIC_BASE_URL) { $env:KIMI_ANTHROPIC_BASE_URL } else { "https://api.moonshot.ai/anthropic" }
$env:ANTHROPIC_AUTH_TOKEN = $env:MOONSHOT_API_KEY
$env:ANTHROPIC_MODEL = $model
$env:ANTHROPIC_DEFAULT_OPUS_MODEL = $model
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = $model
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $model
$env:CLAUDE_CODE_SUBAGENT_MODEL = $model
# Moonshot official recommendation ( https://platform.kimi.ai/docs/guide/agent-support ):
# tool search is unsupported on the Kimi endpoint; the auto-compact window matches
# K2.7's 256K context.
$env:ENABLE_TOOL_SEARCH = "false"
$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = "262144"

Write-Host "claude-kimi: model backend = Moonshot $model (code/context is sent to Moonshot, not Anthropic)"
& claude @args
exit $LASTEXITCODE
