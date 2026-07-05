# docs/ — playbook の人間向け文書

repo root の `docs/` は **playbook（講義基盤）自身の文書**。product（demo アプリ）の設計 docs は stage ブランチの `app/docs/` にあり、ここには置かない（[../rules/stages.md](../rules/stages.md)）。agent 向けの規範は [../rules/](../rules/)、コンポーネント固有の説明は各ディレクトリの README（`sbx/` / `tools/*` / `examples/`）に置く。

## guide/ — 受講者向け how-to（困ったとき・発展的に使いたいとき）

| doc | 誰向け・いつ読む |
|---|---|
| [guide/setup.md](guide/setup.md) | 初回セットアップの詳細。PAT 権限根拠 / cdx pair reviewer 運用 / image・claude・codex の更新 |
| [guide/parallel.md](guide/parallel.md) | 並列開発と発展形。複数 dev box / sandbox box / box 内 shell / Traefik routing |
| [guide/kimi-fallback.md](guide/kimi-fallback.md) | Anthropic 障害時に claude CLI の backend を Kimi 互換 API に差し替える fallback |
| [guide/headful-bridge.md](guide/headful-bridge.md) | box の claude から host の見える Chrome を CDP で操作する opt-in ブリッジ |
| [guide/chrome-profile.md](guide/chrome-profile.md) | host のログイン済み専用 profile Chrome を chrome-profile MCP で操作する |

## instructor/ — 講義運営者向け（受講者は読まなくてよい）

| doc | 誰向け・いつ読む |
|---|---|
| [instructor/README.md](instructor/README.md) | 講義運営の手順。新 stage 作成 / restack / スライド配信 / checkpoint 連鎖の設計意図 |
| [instructor/stage-playbook.md](instructor/stage-playbook.md) | 講義中に横に開く実演台本。stage ごとの依頼プロンプト例と見どころ |
| [instructor/repo-settings.md](instructor/repo-settings.md) | GitHub ruleset（merge gate）の現行設定値と確認・変更方法 |

## decisions/ — ADR（なぜそう決めたかの記録。追記のみ）

| doc | 決定 |
|---|---|
| [decisions/stage-stacked-branches.md](decisions/stage-stacked-branches.md) | stage/* を orphan から main 履歴共有の stacked 連鎖へ移行 |
| [decisions/merge-gate-design.md](decisions/merge-gate-design.md) | agent 自律 merge の merge gate 設計（誤 merge 防止と自律 merge の両立） |
| [decisions/app-identity-gate.md](decisions/app-identity-gate.md) | box を GitHub App identity で回す human-approval gate（現状 revert 済み） |
| [decisions/devcontainer-sandbox.md](decisions/devcontainer-sandbox.md) | devcontainer サンドボックスを main の土台に置く |
| [decisions/parallel-hotl-execution.md](decisions/parallel-hotl-execution.md) | 安全に並列化した coding agent / HOTL の実行基盤 |
| [decisions/decomposed-multiagent-a2a.md](decisions/decomposed-multiagent-a2a.md) | decomposed multi-agent（1 agent 1 box + native auth + A2A coordination） |
| [decisions/cloud-unattended-sre.md](decisions/cloud-unattended-sre.md) | cloud 常駐の無人 SRE 自動化（CloudWatch → agent → PR）の実行基盤と認証 |
