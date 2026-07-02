---
name: box-session-resume
description: "Moves a Claude Code session that ran inside an sbx (Docker Sandboxes) box so it can be resumed elsewhere — on the host or in another box — as the SAME session via `claude --resume`. Auto-locates where the session currently lives, injects the transcript into the destination's ~/.claude/projects/<encoded>/ under the original UUID name, and prints the resume command. Environment-aware: on the host it runs the resume directly; inside a box (host-only work it cannot do itself) it delegates to the host via the host-bridge by writing a request that the user grants with /box-session-resume-grant. One entry point: paste the session_id, optionally name a destination box (omit = host on the host / the current box inside a box). Companion to box-session-context (reference-only). Replaces the old box-session-handoff. A leaf-layer skill per rules/skills.md wrapping scripts/internal/box-session-resume.sh. Use when the user wants to take over / continue / hand off / resume a box session, mentions box session 引き継ぎ / box 内 session の続きから / 別 box で続ける / 箱を跨いで引き継ぐ / resume in another box / take over box work / hand off box session."
---

# box-session-resume

sbx (Docker Sandboxes) の box 内で動いた Claude Code session を、**別の場所 (host または別 box) で同一 session として `claude --resume` 再開できる状態にする** skill。session の所在を自動特定し、dest の `~/.claude/projects/<encoded>/` に元 UUID 名で transcript を inject して resume コマンドを返す。

`/box-session-context` (参照専用) が「読んで要約して停止」なのに対し、本 skill は**作業継続**: dest で当該 session の続きから動かす。旧 `/box-session-handoff` (host 引き取り専用) を置換し、**入口 1 つで box→host / box→別 box / host→box を賄う**。`scripts/internal/box-session-resume.sh` を駆動する leaf 層 ([rules/skills.md](../../../rules/skills.md))。

## 2 つの実行モード (環境で自動分岐)

転送の実体は host でしか動かない (sbx で複数 box に到達する必要があるため)。本 skill は**起動環境を検出して**、host なら直接実行・box なら host へ委譲する (`codex-review`↔`a2a-review` と同じ環境ディスパッチ。[rules/skills.md](../../../rules/skills.md) の peer 委譲例外):

| 起動環境 (`$SANDBOX_VM_ID`) | モード | 動き |
|---|---|---|
| **host** (env 空) | host-direct | `scripts/internal/box-session-resume.sh` を直接実行して inject + resume コマンドを返す |
| **box** (env set) | box-delegate | host-bridge に resume 依頼を書き、user が host で `/box-session-resume-grant` を 1 回叩いて実行 → 答えを Monitor で auto-pickup |

box 内から sibling box には届かない (microVM 隔離・sbx 不在) ので、box では「自分で実行」せず host に委譲する。**human が host で `/box-session-resume-grant` を叩く 1 ステップが injection gate** (`/host-answer` と同じ非対称設計、下記 limitations)。

## なぜ resume できるか (機構)

dev box は host repo を**同じ絶対 path に bind-mount** する。そのため box 内・host の `~/.claude/projects/<encoded>/` の dir 名が一致し、transcript (`<session-uuid>.jsonl`) を dest の同じ project dir に元 UUID 名で置けば、`claude --resume <id>` が**同一 session として復元**する (context 注入ではなく真の resume)。

## host 側 lookup の境界と「見つからない時」の補完経路

workshop 教材として **host 側の探索は `~/.claude/projects/` 単一 profile を default** とする (受講者環境を assume せず、[CLAUDE.md](../../../CLAUDE.md) `## Workshop 前提` の境界遵守)。`CLAUDE_CONFIG_DIR` で multi-profile 切替 (`~/.claude-personal` 等) を運用していると、当該 session jsonl が default `~/.claude` の外にあって `box-session-resume.sh` が exit 3 (not found) を返すケースに当たる。

script に multi-profile 探索や env hook を埋め込まないのは、project に user-scope 個人運用の構造を持ち込まないため。代わりに **exit 3 が出た時の補完経路を agent 規律として持つ**:

1. agent (claude) は available-skills listing の中に **Claude Code session log を扱う user-scope helper** (session 探索・抽出系の汎用 helper) が見えていれば、それを呼んで target session jsonl の**絶対 path** を解決する
2. 解決した path から **encoded dir 名** を抽出 (path の親 dir basename = `-Users-...-coding-agent-playbook` 等の workshop dir 名)
3. **host の default profile に手動 cp**:
   ```bash
   mkdir -p "$HOME/.claude/projects/<encoded>" && cp <found-path> "$HOME/.claude/projects/<encoded>/<uuid>.jsonl"
   ```
4. `source=host` を**明示**して本 script を再叩き → 今度は default profile にあるので exit 0 + resume コマンドが出る (補完後の jsonl が box 側にも残っている場合、第 3 引数省略 = auto-detect では「host と box の両方にある」と判定されて exit 4 ambiguous になるため、`host` を明示する必要がある)

agent はこの 4 段を自走する。受講者環境では該当 user-scope helper を持たないため step 1 で no-op になり、default のまま exit 3 で終わる (= 個人運用の補完経路は受講者に影響を与えない graceful degradation)。

## 使い分け

| 用途 | skill | 挙動 |
|---|---|---|
| **box 内 session を参照したい** | [`/box-session-context`](../box-session-context/SKILL.md) | transcript を読んで概要を要約し**停止** |
| **box 内 session の続きをやりたい** (host で / 別 box で) | **`/box-session-resume`** (本 skill) | dest の project dir に inject → `claude --resume` を提示 |

## 引数

`<session_id> [<dest>] [<source>]`:

- `session_id`: UUID 形式または**先頭 8+ hex 短縮形**
- `dest` (省略可): **host 起動なら省略=host**、**box 起動なら省略=その box 自身** (`$SANDBOX_VM_ID`)。box 名を渡せばその box、`host` を渡せば host
- `source` (省略可): transcript の現在地。省略時は host + running claude box を自動特定。複数 location 該当時のみ明示

---

## 手順 A: host-direct (host で起動)

1. **状態確認**: `sbx ls` で対象 box が running か確認。dest が停止中の box 名なら `sbx run --name <dest>` を案内
2. **実行** (cwd は repo root):
   - Unix / macOS / Git Bash: `bash scripts/internal/box-session-resume.sh <session_id> [<dest>] [<source>]`
   - Windows PowerShell: `powershell -ExecutionPolicy Bypass -File scripts/internal/box-session-resume.ps1 <session_id> [<dest>] [<source>]`
3. script が source を自動特定 → dest の `~/.claude/projects/<encoded>/<uuid>.jsonl` に inject → stdout に resume コマンドを出力 (exit code: 1=arg / 3=not found / 4=ambiguous / 6=sbx 失敗)
4. **dest で resume**: 出力された `claude --resume <uuid>` を dest で叩く (dest の main claude が別 session を握っていれば一旦 exit、または `/resume` picker から選ぶ)

> human がこの script を**自分で叩く必要はない**。host claude session で `/box-session-resume <args>` を打てば、本 skill (claude) が上記 script を実行する。`scripts/internal/` は実装で、入口は本 skill。

---

## 手順 B: box-delegate (box の中で起動)

box では転送を自分で実行できないため、host への依頼を書いて待つ (`/host-ask` と同じ bridge 機構):

1. **自 box 名取得**: `printenv SANDBOX_VM_ID` → `<box-name>`。空なら「box 内で起動してください」と escalate して停止
2. **dest 既定の解決**: 引数 `dest` 省略時は `<box-name>` (= この box 自身。「ここで続ける」) を dest とする。明示時はその値 (box 名 / `host`)
3. **bridge dir を絶対 path で解決**: bridge は host と box が同一絶対 path に bind-mount する **main checkout root** 直下に置く必要がある (gitignore も host grant の read もそこ前提)。cwd 相対だと worktree / subdir 起動で `<cwd>/.claude/host-bridge` に書かれ host が拾えず gitignore も外れる。cwd でなく git common dir の親から解決する (staging root / cdx lease と同じ root):
   ```bash
   REPO_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
   BRIDGE="$REPO_ROOT/.claude/host-bridge"
   mkdir -p "$BRIDGE"
   ```
   以降のすべての bridge file 操作 (ls / rm / Write / Monitor の cat) は **この `$BRIDGE` 絶対 path** を使う (下記の `.claude/host-bridge/` は `$BRIDGE/` に読み替える)。**transport script も cwd 相対でなく `$REPO_ROOT/scripts/internal/host-bridge.sh` で絶対 path 呼び出しする** (本 skill は worktree / subdir から起動されうるため。cwd 相対だと script が見つからず regression する)
4. **次 seq 算出**: 共有 transport を使う (采番の anchored glob / octal-safe / cross-platform 規約は script に集約):
   ```bash
   SEQ=$(bash "$REPO_ROOT/scripts/internal/host-bridge.sh" next-seq "$BRIDGE" "resume-req-<box-name>")
   ```
   無ければ `001`、有れば +1 のゼロ埋め 3 桁が返る
5. **stale ans/sentinel を予防削除 → req を Write**: transport の `prep-req` が bridge dir mkdir + 自 seq の stale ans/done の `rm -f` (遺物無しは no-op) をまとめて行う:
   ```bash
   bash "$REPO_ROOT/scripts/internal/host-bridge.sh" prep-req "$BRIDGE" "$BRIDGE"/resume-ans-<box-name>-$SEQ.md
   ```
   続けて `$BRIDGE/resume-req-<box-name>-<seq>.md` を下記 format で Write
6. **ans wait の Monitor を起動 (persistent)**: done sentinel を polling し検出したら本体を cat (box 側のみ auto-pickup)。待受コマンドは transport の `poll` が生成する (path を double-quote で囲むため checkout path に空白が含まれても壊れない):
   ```bash
   bash "$REPO_ROOT/scripts/internal/host-bridge.sh" poll "$BRIDGE"/resume-ans-<box-name>-$SEQ.md
   ```
   ```text
   Monitor({
     command: "<上の poll 出力をそのまま>",
     persistent: true,
     description: "resume ans wait for <box-name>/<seq>"
   })
   ```
   Monitor 不可環境 (Claude Code < 2.1.98 / Bedrock / Vertex / Foundry / DISABLE_TELEMETRY / CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) では `/host-ask` 手順 5 と同じ fallback (Bash `run_in_background` → manual cat)
7. **user に告知して停止待ち**:
   ```text
   📤 resume 依頼を書きました: <BRIDGE>/resume-req-<box-name>-<seq>.md
      session <session_id> を dest=<dest> で resume します。

   host 側 claude で次を実行してください (これが injection gate です):
     /box-session-resume-grant <box-name>

   実行されたらこちらで自動 pickup します (Monitor persistent)。
   ```
8. **ans 取り込み後**: Monitor が返した ans (`resume-result` fence) を読む。成功なら dest で resume する案内をする:
   - dest が**この box 自身**なら、この session 内で `/resume` を打ち当該 session を選ぶ (= box-c の claude がそのまま box-a の session に成り替わる)、または box-c の別 shell で `claude --resume <uuid>`
   - dest が**別 box / host** なら、その dest で `claude --resume <uuid>` (ans に出力されたコマンド)

### resume-req file format

```markdown
# Box session resume request

- **from**: box `<box-name>`
- **seq**: `<seq>`
- **ts**: `<iso8601 UTC>`
- **session_id**: `<session_id>`
- **dest**: `<dest>`
- **source**: `auto`   (省略 = 自動特定。明示する場合のみ box 名 / `host` を書く。`auto` は grant 側で「第 3 引数なし」に変換される — script は非空の第 3 引数を box 名扱いするため `auto` をそのまま渡すと失敗する)

## 意図 (1 行)

<なぜ dest で続けたいか>

## host で実行されるコマンド (grant が実行)

bash scripts/internal/box-session-resume.sh <session_id> <dest>   # source=auto は第 3 引数を付けない
```

## 注意

- **dest=host の真 resume は今の session に成り替わる**: 文脈を保ったまま取り込みたいだけなら resume せず `/box-session-context` で読む
- **source box が消える前に resume する**: transcript は box 内 fs にあり `sbx rm` で失われる
- **resume の成立条件 = source と dest が同じ repo mount path を共有すること**: encoded project dir 名は repo の絶対 path から導出され、本 skill は source の dir 名を dest に流用する (エンコード規則は再実装しない)。これが正しいのは host + `bash scripts/dev.sh` 系 dev box (同一絶対 path に bind-mount) のみ。次は encoded が食い違い転送成功でも `claude --resume` が見つけられない:
  - **clone box (`bash scripts/dev.sh sandbox`)**: 別 path の clone (`/run/sandbox/source` 等)
  - **Windows host**: host path が `C:\...`、box は Linux mount path
- **確実な resume 経路は同一 mount path を共有する dev box ↔ dev box / dev box ↔ host (mac/Linux)**

## limitations / caveats

- **box-delegate は box 側 monitor のみ・host 側は user-trigger** (`/box-session-resume-grant`)。`/host-ask`↔`/host-answer` と同じ非対称設計: box は untrusted source を取り込みやすく injection 経路になりうるため、host 側実行に human の能動 invoke を挟んで chain を break する。ただし grant は host fs を read するだけの `/host-answer` と違い**状態変更 (transcript を dest box に書く) を実行する**ので、grant 側で依頼内容 (session/dest/source) を表示してから実行する (human が異常を見て中断できる)
- **request file の lifecycle**: `resume-req-*` / `resume-ans-*` / `.done` は gitignore 対象だが自動削除しない。掃除は `find .claude/host-bridge -maxdepth 1 \( -name 'resume-req-*.md' -o -name 'resume-ans-*.md' -o -name 'resume-ans-*.md.done' \) -delete`

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| `sbx: command not found` (host) | docs/box-ops.md に従って sbx をインストール |
| script を box 内で直接叩いて `exit 5` | 本 skill を使えば box では自動で host-delegate される。raw script を box で叩かない。host shell なら `echo $SANDBOX_VM_ID` が空であること |
| box-delegate で ans が来ない | host で `/box-session-resume-grant <box-name>` を実行したか確認 (host は user-trigger)。`TaskList` で Monitor 生存確認。長引けば `TaskStop` |
| `transcript not found` (exit 3) | session_id typo か source box 停止。`sbx ls` / `ls $HOME/.claude/projects/*/` |
| `exists in multiple locations` (exit 4) | 同一 session が複数 location に存在 (relay 済み等)。`<source>` を明示 |
| dest で `claude --resume` が session を見つけない | dest が source と同じ mount path か確認 (clone box / Windows は上記「注意」) |
