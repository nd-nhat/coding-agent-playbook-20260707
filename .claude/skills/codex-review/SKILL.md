---
name: codex-review
description: "Asks codex (OpenAI) for a fast second opinion on a file path, diff, or code instruction, and returns its findings as an issue list or LGTM. In a box session (SANDBOX_VM_ID set) automatically delegates to /a2a-review (A2A codex pair) — the caller does not need to detect the environment. In a host session calls the host codex CLI directly. Use when the user asks for a codex review or second opinion, mentions codex review / 別の目で見て / codex にレビューさせて, or when /pr-ci needs the codex step. A thin wrapper over `codex exec --skip-git-repo-check` on host, or /a2a-review on box (leaf-layer skill per rules/skills.md, not an orchestrator)."
---

# codex-review

host にインストールされた **codex (OpenAI) CLI を直接呼んで** PR diff / ファイル / コード片への第二意見を取る leaf skill ([rules/skills.md](../../../rules/skills.md))。`/a2a-review` の host 対称 — 役割 (codex 1 体の速い second opinion) と契約 (correctness / security / regression のみ採用 / nice-to-have skip) は同一で、**transport だけ違う** (A2A pair なし、host codex CLI を直接 exec)。

box-native の `/pr-codex-ci` フローに対し、host から PR を作って後処理する場合の codex 入口として `/pr-ci` から compose される。host claude が能動的に呼ぶ second opinion で、PR に post された他者 review への対応は別 skill `/pr-review-respond` (混同しない)。

## 前提

- **box session では自動的に `/a2a-review` に委譲** (step 1 参照)。呼び出し元は環境を意識せず本 skill を invoke してよい
- **host session では host `codex` CLI を直接呼ぶ**想定
- **`codex` CLI が host にインストール済み**: `which codex` で path が返ること。未インストールの場合は HOTL escalate (下記)
- **`codex login` 済み**: OpenAI subscription を OAuth login で認証してあること。未認証の場合は CLI が auth error で fail する
- **外部 AI にデータを送信する skill**: 起動時に明示的に警告する。実行前に「⚠️ 外部 AI (OpenAI Codex) にコード / diff を送信します」を表示する

## 使い方

引数 = レビュー対象。repo-root 相対のファイルパス / `diff` / 自由な指示文 (日本語可)。引数が空なら何をレビューするか先に聞く。

### 手順

1. **環境チェック**:
   - **box 環境 → `/a2a-review` に委譲して終了**: `printenv SANDBOX_VM_ID || true` を確認し、値があれば **`⚠️ 外部 AI (OpenAI Codex) にコード / diff を送信します` を 1 行表示してから `/a2a-review <引数>` を invoke してその結果をそのまま返す** (box の `codex` CLI は sbx/Dockerfile で install されているが auth context が host とは別で、host `codex login` 状態が box には伝わらないため host CLI を使わない。`/a2a-review` が box-native の同等 skill):
     > 「⚠️ 外部 AI (OpenAI Codex) にコード / diff を送信します」
     > 「box 内で動作中のため `/a2a-review` に委譲します。」
   - `which codex` で host に codex CLI があるか確認
   - 無ければ本 skill を停止し HOTL escalate:
     > 「host に `codex` CLI が見つかりません。`npm i -g @openai/codex` でインストールし `codex login` で OpenAI subscription を認証してから、`/codex-review` を再度叩いてください。あるいは box session に切り替えて `/a2a-review` (box-native の同等 skill) を使ってください (`bash scripts/dev.sh <NAME>` で起動)。」

2. **データ送信警告**: 「⚠️ 外部 AI (OpenAI Codex) にコード / diff を送信します」を 1 行表示する。

3. **指示文の組み立て** (下記「指示文の組み立て」参照)

4. **実行**: stdin redirect 経由で長文プロンプトを渡す。**一時ファイルは fresh clone で `.claude/tmp/` が存在しない可能性があるため `mkdir -p` を先に行い、また並列 invoke 衝突を避けるため一意名 (session id 短縮形 / PID 等の suffix) を付ける**:
   ```bash
   mkdir -p .claude/tmp
   # PROMPT_FILE=.claude/tmp/codex-review-prompt-<unique-suffix>.md として Write
   # codex exec の PROMPT positional は `-` (stdin) を明示 (公式 CLI ref: `string | -` 形式)
   codex exec --skip-git-repo-check -s read-only - < "$PROMPT_FILE"
   ```
   reasoning effort を上げたい場合 (任務が複雑な PR diff 等) は `-c 'model_reasoning_effort="high"'` を付与 (`-s read-only` と `-` は必ず保持):
   ```bash
   codex -c 'model_reasoning_effort="high"' exec --skip-git-repo-check -s read-only - < "$PROMPT_FILE"
   ```
   `-s read-only` は **必須**: PR review は本質的に read-only な役割で、codex に workspace 書き込み権限を持たせない (review 中に codex が誤って host のファイルを編集・実行する経路を構造的に塞ぐ。`/a2a-review` 側も同じ sandbox 制約を持つ)。`-` (positional PROMPT placeholder) は codex CLI が stdin から prompt を読むことを明示する公式 ref 準拠形 (省略しても現状動くが contract 整合のため必須)。`--cd` は不要 (current cwd を codex が読む)。一時 prompt ファイルは実行後に削除する。

5. **CLI が auth / network error で fail** した場合は本 skill を停止し HOTL escalate (黙って止まらない / 選択肢を出さない):
   > 「codex CLI が `<エラー要旨>` で fail しました。recovery 候補:
   > - auth エラーなら `codex login` で再認証
   > - network エラーなら接続確認後に `/codex-review` を再度叩く
   > - 切り替え案: box session で `/a2a-review` を使う (`bash scripts/dev.sh <NAME>` で起動)」

6. 下記「結果提示」

**指示文の組み立て**: 引数を 1 つの review 指示文にする。codex は cwd の repo を自分で読むので、**パス/diff を指示で渡す**:

- ファイル: `tools/a2a-review/codex-a2a-server/server.py を correctness / edge-case 観点でレビューして`
- diff: `git diff origin/main...HEAD を correctness / security / regression 観点でレビュー`
- worktree: `git -C .worktrees/<NN>/ diff HEAD をレビューして` のように `-C` でツリーを明示

PR diff review 用の標準プロンプト (`/pr-ci` から呼ばれる時はこれを使う):

```text
以下の PR diff を correctness / security / regression / 既存契約違反の観点でレビューしてください。

base: <base-ref> (例: origin/main)
diff: `git diff <base-ref>...HEAD` の出力

採否方針:
- 採用すべき: 明確な correctness bug / security 脆弱性 / regression / 既存契約 (型・テスト・仕様) 違反
- 採用しない: nice-to-have の改善提案 / 将来拡張 / refactor 推奨 / コメント追加推奨 (addition bias 回避)

LGTM の場合はその旨を 1 行で返す。指摘がある場合は file:line + severity (correctness / security / regression / contract) + 修正案を箇条書きで返す。
```

**結果提示**: codex の最終 artifact (指摘 or LGTM) を要約してユーザーに返す。codex の指摘は **second opinion** であり、採否は claude / ユーザーが判断する (AI 1 体の指摘を独立根拠にしない)。`## Codex (OpenAI)` 見出しで結果を表示する。

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| `which codex` が空 | `npm i -g @openai/codex` でインストール後、`codex login` で認証 |
| `codex login` 未実施 / 期限切れ | host で `codex login` を実行 |
| network error (proxy 配下等) | host 側 network 設定確認。socks/http proxy 経由なら `HTTPS_PROXY` env が codex に伝わるか確認 |
| 指摘が広範すぎる (nice-to-have が大量) | 指示文に「nice-to-have skip」「correctness / security / regression のみ」を明示 (上記標準プロンプト参照)。reasoning effort を `--xhigh` に上げると逆に detailed すぎることもあるので、PR review 用途は `high` 程度で十分 |
| box 内で本 skill を invoke した | step 1 が自動検出して `/a2a-review` に委譲するため特段の対処不要。委譲後に reviewer 未到達 error が出たら `/a2a-review` のトラブルシューティングに従う |
| 結果に tool-use ナレーション (思考過程) が混ざる | codex は stream 出力に reasoning trace を含むことがある。表示時に最終 artifact だけ抽出する |
