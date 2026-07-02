---
name: box-session-context
description: "Pulls a Claude Code session transcript from inside an sbx (Docker Sandboxes) box and presents it as reference context on the host. Use when the host needs to inspect a session that ran inside a box — the typical case is HOTL monitoring where the statusLine of a box-internal session shows a session_id and the host wants to read that session's transcript. A thin wrapper over scripts/internal/box-session-context.sh (leaf-layer skill per rules/skills.md); fills the structural gap that the user-scope session-context skill only reads ~/.claude/projects/ on the host. Use when the user mentions box session, box transcript, HOTL transcript, sbx session, 箱の session, box の中の transcript."
---

# box-session-context

sbx (Docker Sandboxes) の box 内で動いた Claude Code session の transcript jsonl を host に取り出して context として参照する。本リポは **box-primary 運用** で box 内の session が host の `~/.claude/projects/` に現れず、user-scope `session-context` skill (host 専用) では読めない構造的な穴を埋める。CLAUDE.md `## 開発フロー` の「HOTL 監視 (statusLine の session id → host から transcript)」がまさに本 skill の用途。

`scripts/internal/box-session-context.sh` を呼ぶ薄い wrapper (leaf 層、[rules/skills.md](../../../rules/skills.md))。A2A のロジックは持たず、transcript 取り出し + 提示のみに集中する。

本 skill は**参照専用**。session の続きを host / 別 box で実行したい (真 resume) なら [`/box-session-resume`](../box-session-resume/SKILL.md) を使う。

## 前提条件

- **host で sbx が使える** (本 skill は host 専用、box の中からは使えない。box 内から自身の transcript を見たいなら通常の `session-context` 系で十分)
- 対象 box が存在し **running** 状態。停止中なら `sbx run --name <box>` で起動してから本 skill を呼ぶ (勝手に起動しない)
- 対象 box が **built-in claude agent** で起動された箱 (`sbx run claude ...` で立てたもの)。codex 等の他 agent の transcript は対象外

skill listing は箱の中の Claude にも本 skill を見せるため box 内起動の勘違いが起きうるが、wrapper script が `$SANDBOX_VM_ID` set 時に exit 5 で fail-fast する (引数組み立てに進む前に止まる)。box 内 Claude が exit 5 を受けたら user-scope `/session-context` に切り替えること。

## 使い方

引数 = `<session_id> [<box_name>]` (`box_name` は省略可、省略時は auto-detect)。

- `session_id`: UUID 形式 (`00000000-0000-0000-0000-000000000000`) または **先頭 8+ hex 短縮形** (`00000000` 等)。短縮形は box 内 transcript で部分一致 1 件確定する場合のみ採用。複数候補なら full UUID を要求する
- `box_name` (省略可): `sbx ls` の SANDBOX 列の名前 (例: `claude-coding-agent-playbook`)。**省略時は `sbx ls` で `agent==claude && status==running` を満たす box が exactly 1 個確定なら採用**、0 個 (= 起動中の claude box なし) / 複数 (= 並列実行で曖昧) なら明示要求 error で停止 (誤検出回避のため strict に 1 個ヒット要件)

### 手順

1. **box 状態確認**: `sbx ls` で対象 box が running か確認。停止中なら `sbx run --name <box_name>` を案内して停止する。box が 1 つしかない場合 (本リポでの典型) は引数省略で auto-detect 動作する
2. **実行** (host で、cwd は repo root):
   - Unix / macOS / Git Bash: `bash scripts/internal/box-session-context.sh <session_id> [<box_name>]`
   - Windows PowerShell: `powershell -ExecutionPolicy Bypass -File scripts/internal/box-session-context.ps1 <session_id> [<box_name>]`
3. script の内部処理:
   - `sbx exec <box_name> ls /home/agent/.claude/projects/*/<session_id>*.jsonl` で transcript path を検索
   - 0 件: exit 3 で終了 (案内: `sbx exec <box> ls /home/agent/.claude/projects/` で session 一覧を確認)
   - 複数件 (短縮形が複数 hit): exit 4 で終了 (full UUID 要求)
   - 1 件: `sbx cp <box_name>:<path> .claude/tmp/box-session-<short>.jsonl` で host にコピー
   - stdout に host 側の保存 path を 1 行出力
4. claude は出力された path を **Read** ツールで読み込み (大きい場合は `offset` / `limit` 使用)、jsonl 各行を JSON parse して以下を抽出して要約する:
   - session の開始 / 終了時刻 (line の `timestamp` から)
   - user message / assistant message の主要なやり取り
   - tool calls (どの tool を何回呼んだか)
   - 最終状態 (最後の assistant message)

### 結果提示

session の概要 (起動時刻 / 主なやり取りの要約 / 最終 assistant message) を user に返す。生 transcript は冗長なので、user が「全部見たい」と言わない限り要約形式にする。

## 注意

- transcript は **box 内 filesystem (`/home/agent/.claude/projects/`)** に置かれており、box が `sbx rm` で削除されると失われる。長期保存したい transcript は本 skill で host にコピーしておく
- copy 先 (`.claude/tmp/box-session-<short>.jsonl`) は git 管理外 (`.claude/tmp/` は `.gitignore` 想定の一時 dir) なので、session 切り替え後も `Read` で参照可能

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| `sbx: command not found` | docs/box-ops.md に従って Docker Sandboxes (sbx) を host にインストール |
| `box <box_name> not found` | `sbx ls` で正確な box 名を確認 |
| `box <box_name> is not running` | `sbx run --name <box_name>` で起動してから再実行 |
| `no running claude box found` (auto-detect 失敗) | running な claude agent box が無い。`sbx run claude ... .` で起動するか、`<box_name>` を明示的に指定する |
| `multiple running claude boxes (...). Specify <box_name> explicitly` (auto-detect 失敗) | 並列で複数 box を立てているケース。`sbx ls` で対象を確認し `<box_name>` を明示的に指定する |
| `transcript not found for session_id` | `sbx exec <box> ls /home/agent/.claude/projects/` で session 一覧を確認。session_id の typo か別 box の可能性 |
| `multiple transcripts match short session_id` | 8-hex 短縮形が複数 hit。full UUID を渡すか、`sbx exec <box> ls /home/agent/.claude/projects/*/` で正確な session_id を確認 |
| copy 後の jsonl が大きすぎて Read で全部読めない | Read の `offset` / `limit` で先頭/末尾を見る、または手順 4 の要約に絞る |
