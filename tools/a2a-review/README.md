# A2A code-review: codex を同一ソースの reviewer にする (decomposed multi-agent)

[docs/decisions/decomposed-multiagent-a2a.md](../../docs/decisions/decomposed-multiagent-a2a.md) の Stage 1 を「実開発で使える」形にした参照実装。**codex を別 box の A2A server に wrap し、claude が編集中の同一ソースツリーを bind-mount で codex に見せて**、A2A streaming でレビューを依頼する。codex は OAuth 転送ゼロ認証で、claude とは別 microVM で動く。

設計の核:

- **同一 live ソース**: codex box に claude の作業ツリーを direct mount し、codex が agentic に同じファイルを読む（コード片を message に貼らない）。
- **streaming で推論中が分かる**: server が `codex exec --json` の JSONL イベント（reasoning / command_execution / agent_message）を WORKING ステータスで逐次中継し、client は SSE でリアルタイム受信する。
- **固定 timeout を持たない**: server は idle timeout（進捗が途切れた時だけ hang 判定）なので、数時間級の自律レビューも進捗が流れる限り待てる。

> このディレクトリは codex A2A reviewer の**実装 + 学習用リファレンス**。**日常開発の入口は `/a2a-review` skill**（`.claude/skills/a2a-review/`、project 同梱）で、それが host helper `scripts/internal/a2a-review.sh`（dev.sh route subcommand と同型）を駆動する。`sbx/` `.mcp.json` は触らない。Stage 2/3（gemini/grok 追加・Agent Gateway 一本化）はこの形を**広げる**前提（[ADR](../../docs/decisions/decomposed-multiagent-a2a.md) `### 決定 (Accepted)` 参照）。

## 構成

```
tools/a2a-review/
  codex-a2a-server/       # codex --json を A2A server に wrap (codex box 内で起動)
    pyproject.toml        # a2a-sdk 1.1+ / starlette / uvicorn / sse-starlette
    server.py             # CodexReviewExecutor (JSONL イベント→WORKING 中継) + Starlette
  client-demo/            # A2A client (SSE streaming で進捗 + artifact 受信)
    pyproject.toml
    client.py
```

## 最短で動かす — `/a2a-review` skill（日常開発の入口）

claude は box の中で **`/a2a-review <対象>`** を叩くと codex の second opinion を呼べる（`.claude/skills/a2a-review/`、project 同梱なので clone するだけで使える）:

```text
/a2a-review tools/a2a-review/codex-a2a-server/server.py を correctness 観点で
```

skill は下回りの host helper `scripts/internal/a2a-review.sh ask "<指示>"` を駆動するだけ。reviewer pair (`cdx-<NAME>`) は **`bash scripts/dev.sh` / `bash scripts/dev.sh <NAME>` 起動時に dev.sh が auto-provision + pair-serve を bg fork する** ため、手動 setup / 別ターミナル serve は不要 (per-pair lifecycle、debate 2026-06-27 決定):

```bash
# host で一度だけ: openai OAuth secret 登録 (ADR spike #1)
sbx secret set -g openai --oauth

# 以降は dev.sh が pair の起動・破棄を auto で行う
bash scripts/dev.sh            # auto-named dev box + 対応 cdx-<NAME> pair reviewer が連動して起動・破棄
bash scripts/dev.sh foo        # 明示名 foo dev box + cdx-foo pair reviewer (idempotent attach-or-create)
```

box は main checkout root を bind-mount するので、`.worktrees/<NN>/` 配下の stage コードもそのパスで指示できる。並列で `bash scripts/dev.sh` を複数回叩く / 別 `<NAME>` を起動すると、各 pair が独立 port を持ち干渉しない (per-pair lifecycle)。

A2A server / Agent Card / JSON-RPC の中身を手で追う手順は次節。

## 手で動かす — A2A の中身を理解する

### 1. dev.sh による per-pair lifecycle (本番経路)

`bash scripts/dev.sh` (引数なし、auto-name) または `bash scripts/dev.sh <NAME>` (明示名、idempotent attach-or-create) を叩くと dev.sh が:

1. `cdx-<NAME>` reviewer box を `sbx create --name cdx-<NAME> codex -t coding-agent-playbook-sbx <作業ツリー絶対パス>` で作成 (direct mount)
2. `tools/a2a-review/codex-a2a-server/` と `tools/a2a-review/client-demo/` を `uv venv && uv pip install -e .` で install
3. `bash scripts/internal/a2a-review.sh pair-serve <NAME>` を **子プロセスとして bg fork** — pair-serve は内側で:
   - `sbx ports cdx-<NAME> --publish 9999` で host port を **kernel ephemeral で取得**
   - `sbx ports cdx-<NAME>` 出力から host port を読み返し
   - `A2A_ADVERTISE_URL=http://host.docker.internal:<host-port>` で server.py を foreground 起動
   - `sbx policy allow network --sandbox <NAME> "localhost:<host-port>"` で claude box の egress 許可
   - `.claude/tmp/cdx-serve-<NAME>.lease` に pid / port / boxes を JSON 書き込み (statusline / check-setup が読む)
4. claude box `<NAME>` を `sbx run --name <NAME>` で起動 (foreground、user の TTY に attach)
5. user が TTY を抜けると `sbx run` が return し、dev.sh の trap が:
   - bg pair-serve 子プロセスを kill (foreground server も止まる)
   - `bash scripts/internal/a2a-review.sh pair-teardown <NAME>` を call → `cdx-<NAME>` box 削除 + lease 削除

並列で `bash scripts/dev.sh` を複数回 (それぞれ別の auto-name)、もしくは `bash scripts/dev.sh foo` と `bash scripts/dev.sh bar` を起動した場合、`cdx-foo` と `cdx-bar` (および対応 auto-name の cdx pair) が独立 port を持ち干渉しない (per-pair lifecycle、debate 2026-06-27 決定)。

> direct mount は rw だが、A2A server の codex は `-s read-only` 強制でファイルを**読むだけ**（書き込まない）。

### 2. 内部の仕組み (debug / 学習用に手で動かす)

pair-serve の中身を手動で再現したい場合 (a2a-review.sh の動作確認等):

```bash
# pair-setup 相当: cdx-foo box を作成 + install
sbx create --name cdx-foo codex -t coding-agent-playbook-sbx /absolute/path/to/checkout
sbx exec cdx-foo sh -lc 'cd tools/a2a-review/codex-a2a-server && uv venv && uv pip install -e .'
sbx exec cdx-foo sh -lc 'cd tools/a2a-review/client-demo && uv venv && uv pip install -e .'

# pair-serve 相当: publish + policy + server 起動
sbx ports cdx-foo --publish 9999          # 127.0.0.1:<ephemeral>->9999/tcp が出る
sbx ports cdx-foo                          # ephemeral port を確認
sbx policy allow network --sandbox foo "localhost:<ephemeral>"
sbx exec cdx-foo sh -lc 'cd tools/a2a-review/codex-a2a-server && A2A_ADVERTISE_URL=http://host.docker.internal:<ephemeral> .venv/bin/python server.py'

# 別ターミナルから client を投げる (box foo の中から)
sbx exec foo sh -lc 'bash scripts/internal/a2a-review.sh ask "tools/a2a-review/codex-a2a-server/server.py を correctness bug 観点でレビューして"'

# 後片付け
sbx rm -f cdx-foo
sbx policy ls   # 必要なら sbx policy rm <id> で stale policy 掃除
```

> box image には Python 3.14 + `uv` が bake 済み（`python3 -m venv` は ensurepip 不在のため不可、`uv venv` を使う）。a2a-sdk が `a2a.compat.v0_3` で `sse-starlette` を import するため pyproject に明示。

codex がレビュー対象を相対パスで読むルート（CWD）は、既定で **server.py の位置から導出した repo root**。別ツリーを読ませたいときだけ `A2A_REVIEW_WORKDIR=<絶対パス>` で上書きする。`Uvicorn running on http://0.0.0.0:9999` が出れば起動完了（listen は `0.0.0.0`、Agent Card の advertise は `A2A_ADVERTISE_URL` で指定）。

実機実証済みの挙動: codex が agentic に複数回（`nl` / `rg` / `python` で SDK 検証）ファイルを読みながら進捗を逐次配信し、具体的な指摘を添えて `TASK_STATE_COMPLETED`。

## 設計上の重要な点（per-pair lifecycle）

- **egress allowlist が肝**: sbx box は default-deny egress。pair-serve が `sbx policy allow network --sandbox <NAME> "localhost:<port>"` で claude box に reviewer への経路を開ける（これが無いと box→box は "Blocked by network policy" で 403）。
- **allow ルールは pair-teardown 後も残る**: `sbx rm -f cdx-<NAME>` で box は消えるが、`sbx policy allow` の rule は残る（revoke しない）。スコープは `localhost:単一ポート` と狭いが、繰り返し dev.sh 起動 / 停止すると積み上がるので、定期的に `sbx policy ls` で確認して `sbx policy rm <id>` で掃除する。
- **server は dev.sh の子プロセス foreground で保持**: sbx は idle box を停止するため `nohup` detach は不可。pair-serve は dev.sh の bg fork として親 PID に紐づく (host 常駐 daemon / launchd / systemd 不要 = workshop premise と整合、PR #68/#70 で revert された方向との明示的な差異化)。
- **advertise URL は box 到達形**: client は Agent Card の `supportedInterfaces[].url` を POST 先にするため、`A2A_ADVERTISE_URL=http://host.docker.internal:<port>`（既定 `127.0.0.1:9999` だと client が自箱を叩く）。pair-serve が自動設定する。
- **NO_PROXY の bracket IPv6**: box の egress proxy 設定は `NO_PROXY` に `[::1]` を含み httpx が `Invalid port` でクラッシュする（curl は平気）。`client.py` が起動時に bracket entry を除去する。
- **同一ソース共有**: cdx-`<NAME>` reviewer box と claude `<NAME>` box は**同じ host パスを direct mount** するので、claude の編集が codex から見える。`--clone` box (no-arg `dev.sh`) は host checkout を mount しないため codex から不可視 (= pair reviewer の対象外、上述「並列で複数 box を立てる」section 参照)。
- **port 割当は dynamic ephemeral**: hash / registry を使わず `sbx ports --publish 9999` (hostport 省略 = kernel 選択) + 読み返し方式。`scripts/dev.sh route add` と同形で衝突確率 0%。

完全な **box→box 直結 + reviewer discovery**（host の publish すら介さない）は Stage 3（Agent Gateway, ADR）で扱う。上記は host の publish + egress 許可を介する Stage 1 の cross-box 形。

## 何が動くか（実機実証済み）

- ✅ **同一 live ソース参照** — codex box に作業ツリーを direct mount、codex が agentic に同じファイルを読む（command_execution 16 回）
- ✅ **転送ゼロ認証** — OAuth secret の proxy 注入で box にトークンを置かない（ADR spike #1）
- ✅ **streaming で推論中が分かる** — `codex exec --json` の JSONL イベントを WORKING で逐次配信、client が SSE でリアルタイム受信
- ✅ **固定 timeout を持たない** — idle timeout なので進捗が流れる限り待つ。`turn.completed` → `TASK_STATE_COMPLETED` + artifact
- ✅ **codex が実 reviewer として機能** — 同一ソースを読んで実 issue を指摘

## long-running / スケール（A2A 標準, Stage 2/3 で扱う）

[A2A streaming & async](https://a2a-protocol.org/latest/topics/streaming-and-async/) は long-running task に 3 パターンを定義し、`ClientConfig` が直接サポートする:

- **streaming (SSE)** — 本実装。接続を保つ間の進捗監視（公式の preferred）
- **polling (`tasks/get`)** — `ClientConfig(polling=True)`。持続接続できない client が task id で状態 poll
- **push notification (webhook)** — `ClientConfig(push_notification_config=...)`。分〜時間〜日級の very long-running

本実装は streaming + idle timeout で「数時間級でも進捗が流れる限り待つ」を満たす。SSE 接続維持の限界（proxy timeout / 接続断）を超える運用は polling / push notification に切り替える。

## まだ扱っていない（Stage 2/3）

- 複数 reviewer の Agent Card 発見・選択（gemini/grok を Agent Card 追加で増やす discovery 機構）
- box-to-box 直接通信（現状はクロス box を host が中継）。Stage 3 の Agent Gateway で集約
- 非 agent service の MCP 統合（ADR 決定 #3）
- rate-limit / retry / cancel の本番品質（cancel は no-op）

## 既知の限界

- **`sbx create` 時点での auto-start にはしない**（ADR Stage 2 の wiring 範囲）。`scripts/internal/a2a-review.sh` は review 時に未起動なら server を立ち上げる（box ライフタイムに 1 回）
- **wrapper の起動判定は liveness のみ**（Agent Card が応答すれば起動を skip）。`server.py` 自体を更新しても hot-reload されないため、更新後は box の server を再起動（手動 kill か box 再作成）する。レビュー**対象**コードは codex が毎回 live に読むため影響を受けない
- **codex の CWD 既定は server.py から導出した repo root**（`A2A_REVIEW_WORKDIR` で上書き可）
- **codex は `--skip-git-repo-check -s read-only --json` を強制**（書き込み副作用なし、review 専用）
- **cancel は no-op**（codex 実行は走り切る。A2A executor I/F は持つが本実装では happy path のみ）
- **host から叩く場合は `A2A_ADVERTISE_URL` の指定が必要**。Linux native Docker での `host.docker.internal` 502 注意は [../parallel-dev/box-routing/README.md](../parallel-dev/box-routing/README.md) と同様

## References

- [docs/decisions/decomposed-multiagent-a2a.md](../../docs/decisions/decomposed-multiagent-a2a.md)（Stage 1 を定義する ADR）
- [https://a2a-protocol.org/latest/topics/streaming-and-async/](https://a2a-protocol.org/latest/topics/streaming-and-async/)（streaming / polling / push の使い分け）
- [https://developers.openai.com/codex/noninteractive](https://developers.openai.com/codex/noninteractive)（codex exec --json の非対話イベントストリーム）
- [https://github.com/a2aproject/a2a-python](https://github.com/a2aproject/a2a-python)（v1.1.0, 2026-05-29）
- [https://github.com/a2aproject/a2a-samples/tree/main/samples/python/agents/helloworld](https://github.com/a2aproject/a2a-samples/tree/main/samples/python/agents/helloworld)（参考実装）
