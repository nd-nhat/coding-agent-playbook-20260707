---
name: comment-sweep
argument-hint: "[--staged | --worktree | BASE_BRANCH]"
description: "Reviews newly added code comments in a git diff against rules/code-comments.md. Detects identifier paraphrase, WHAT/HOW explanation of next code, comparison comments ('既存の X と異なり'), change history references (Copilot 指摘 / issue ID prefix / 'added for' / 'fixes URL'), 3+ line blocks compressible to a 1-line WHY, and duplicate sentences within a block. Default scans the diff between the PR base and HEAD for PR readiness. '--staged' scans the index, '--worktree' scans tracked uncommitted changes, BASE_BRANCH (any positional arg) overrides the base ref. Auto-skips when base..HEAD contains only revert commits (subjects all start with 'Revert \"'). Use BEFORE 'gh pr create', or when the user mentions コメントチェック / コメント sweep / comment review / 余計なコメント / コメント不適切."
---

# comment-sweep

PR / staged / worktree diff の **新規追加コメント行**を [rules/code-comments.md](../../../rules/code-comments.md) の規範に照らして判定し、違反箇所を報告して修正まで導く leaf skill ([rules/skills.md](../../../rules/skills.md))。`/pr-codex-ci` の前段として走らせると、codex review が低レベル指摘 (コメント余計) に時間を使わなくなる。

## いつ使うか

- **PR 作成前 (推奨)**: `gh pr create` の**前**。実装直後・テスト直後等、push 前に sweep を通す
- **既存 PR への追加 push 前**: review 対応や bug fix の差分にも適用 (commit 後・push 前に default モードで)
- **ユーザーから「コメント不適切」「余計なコメント」等の指摘を受けた直後**: 全変更ファイルに対し再 sweep
- **PR を作らない一時的な変更でも**: commit 前に `--staged` または `--worktree` モードで動かしてよい

## 引数モード

| 引数 | 対象 diff | 用途 |
|------|----------|------|
| (なし) | `git diff origin/<HEAD-branch>...HEAD` (HEAD-branch は `origin/HEAD` の symbolic-ref から決定。後述) | PR 作成前の最終 sweep |
| `BASE_BRANCH` (`--` で始まらない任意 1 引数) | `git diff origin/<BASE_BRANCH>...HEAD` | base を明示する場合 (リモート tracking ref を使う) |
| `--staged` | `git diff --cached` (index) | commit 前 sweep |
| `--worktree` | `git diff HEAD` (tracked かつ uncommitted。**untracked は含まない**) | 未 commit の tracked 変更を全部含めたい時 |

複数指定不可。フラグでなく数字でもない任意の 1 引数は `BASE_BRANCH` として扱う。`--worktree` で untracked な新規ファイルも対象にしたい場合は事前に `git add -N <path>` で intent-to-add してから呼ぶ。

## 手順

```text
Sweep Progress:
- [ ] Step 1: モード判定と diff 取得
- [ ] Step 1.5: Lightweight-PR diff の検出 (default / BASE_BRANCH モードのみ)
- [ ] Step 2: 追加コメント行の抽出とブロック化
- [ ] Step 3: 各ブロックを規範で判定
- [ ] Step 4: 違反テーブルをユーザーに提示
- [ ] Step 5: ユーザー承認後 Edit で修正
- [ ] Step 6: 再 sweep で残違反ゼロを確認
```

### Step 1: モード判定と diff 取得

引数を解釈してモードを決定。default モード (引数なし) の base は **`origin/HEAD` (デフォルトブランチ)** を使う。feature branch の upstream を base にすると `git diff origin/feat/x...HEAD` が空になり sweep が false-negative で通ってしまうため、必ず `origin/HEAD` 由来で決定する。

```bash
git symbolic-ref refs/remotes/origin/HEAD --short
```

これが `origin/main` 等を返したら、その branch を base として `...` (triple-dot) diff を取る:

```bash
git diff origin/main...HEAD
```

`origin/HEAD` が未設定で symbolic-ref が失敗する場合は `BASE_BRANCH` 引数を要求してユーザーに案内する (`git remote set-head origin -a` で再設定可能)。`--staged` / `--worktree` / `BASE_BRANCH` の場合はこの計算をスキップして対応コマンドを直接実行する。`BASE_BRANCH` 引数モードでは `git diff origin/<BASE_BRANCH>...HEAD` を実行する (ローカル branch 名でなくリモート tracking ref を使う)。

### Step 1.5: Lightweight-PR diff の検出 (auto-skip)

`default` / `BASE_BRANCH` モードのみ実行 (`--staged` / `--worktree` は HEAD に commit が無いケースがあるため対象外、通常通り Step 2 へ進む)。

新規追加コメントが構造的に存在しない diff は auto-skip する。判定は共有 helper に委譲する:

```bash
python3 -I .claude/skills/_shared/pr-skip-policy.py --base <base-ref> --head HEAD --json
```

`<base-ref>` は **Step 1 で `git diff <base-ref>...HEAD` に使った base ref そのもの** (default は `origin/main` 等、`BASE_BRANCH` モードは `origin/<BASE_BRANCH>`)。**`origin/` は二重に付けない**。head は本 skill が未 push のローカル commit を含むため `HEAD`。

出力 JSON の `profile` で分岐する:

- `pure-revert` → 以下を出力して終了 (revert diff の `+` 行は復元コメントのみで再 sweep 対象外):

  ```text
  ✅ Revert-only diff (skipped)
  ```

- `tiny-json-hotfix` → 以下を出力して終了 (`.claude/` 配下の単一 JSON scalar 値置換等で新規追加コメント行ゼロ):

  ```text
  ✅ Lightweight PR (tiny-json-hotfix, skipped)
  ```

- `none` → Step 2 へ進む

helper が exit code 0 以外 (git 失敗等の判定不能) を返した場合も通常フローに倒し Step 2 へ進む。

### Step 2: 追加コメント行の抽出とブロック化

**生成ファイルの除外（抽出前、bun があれば）**: 自動生成ファイルはコメントも生成物でレビュー対象にならないため、ファイルごと sweep から除外する。bun が PATH 上にあれば、呼び出しモードに対応する検出 CLI を実行し、出力 JSON の `generated[].path` を以降の抽出対象から外す:

| モード | コマンド |
|--------|---------|
| default / `BASE_BRANCH` | `bun --config=/dev/null .claude/skills/_shared/detect-generated-local.ts --range <base-ref>...HEAD` |
| `--staged` | `bun --config=/dev/null .claude/skills/_shared/detect-generated-local.ts --staged` |
| `--worktree` | `bun --config=/dev/null .claude/skills/_shared/detect-generated-local.ts --worktree` |

bun が無ければこのステップを skip し、すべての変更ファイルを抽出対象に含める (生成ファイルがあっても false-positive で違反検出するだけで、ユーザー承認段階で除外できる)。除外したファイルは Step 4 で件数と一覧を注記する（黙って消さない）。

diff 出力から `^\+(?!\+\+)` で始まる行のうち、**変更ファイルの拡張子に応じた**コメント prefix にマッチするものを抽出する。拡張子ごとに有効な prefix は以下:

| 拡張子 | 有効なコメント prefix |
|--------|---------------------|
| `.go` / `.rs` / `.ts` / `.tsx` / `.js` / `.jsx` / `.mjs` / `.cjs` / `.c` / `.h` / `.cpp` / `.hpp` / `.java` / `.swift` / `.kt` / `.scala` / `.dart` | `^\+\s*//` / `^\+\s*/\*` 〜 `\*/` / `^\+\s*\*` (block 継続) |
| `.py` / `.rb` / `.sh` / `.bash` / `.zsh` / `.yml` / `.yaml` / `.toml` / `.nix` / `Makefile` / `.mk` / `Dockerfile` | `^\+\s*#` (line) |
| `.md` / `.markdown` / `.html` / `.htm` / `.xml` / `.svg` / `.vue` | `^\+\s*<!--` 〜 `-->` (block) のみ |
| `.sql` | `^\+\s*--` (line) / `^\+\s*/\*` 〜 `\*/` (block) |
| `.ex` / `.exs` | `^\+\s*#` (line) |
| `.erl` | `^\+\s*%` (line) |

**Markdown ファイル (`.md` / `.markdown`) では `^\+\s*#` を「コメント」として扱わない** — `#` は heading 構文のため `# Usage` / `## Test plan` 等を violation に誤検出するリスクがある。Markdown は `<!-- -->` のみ対象。

判定対象から除外:

- shebang (`#!`)
- linter / formatter / type-check directive (`// eslint-disable-line`, `# noqa: ...`, `// biome-ignore *`, `// @ts-ignore`, `// @ts-expect-error`, `# type: ignore`, `// nolint`, `# pylint:`)
- license header / copyright block
- generated file marker (`@generated`)
- `rules/code-comments.md` 自身を編集中の場合、その規範記述内の例コメント (`// 悪い例` 等) は対象外

**ブロック化ルール**: 同一ファイル内で連続する追加コメント行 (空行を挟まない) を 1 ブロックとする。間に `+` 以外 (context 行や `-` 行) が挟まれたら別ブロック。

### Step 3: 各ブロックを規範で判定

[rules/code-comments.md](../../../rules/code-comments.md) の以下カテゴリで判定。**コメント prefix (`//` / `#` / `--` / `<!--` 等) を strip した本文に対してパターンマッチする** (language-agnostic)。該当する**最も重い違反 1 件**を採用:

| カテゴリ | 検出基準 (prefix 除去後の本文に対して) |
|----------|---------|
| `IDENTIFIER_PARAPHRASE` | 本文の主要名詞が直後 (または直前 doc 位置) の識別子と意味重複 (例: `UserSignupToken は signup 確認用トークンの永続化モデル`) |
| `NEXT_CODE_WHAT` | 本文が直後 1〜3 行のコードを WHAT/HOW で説明 (例: `重複チェック用の既存ユーザーを登録` の直後に `existingUser := testutil.AddTestUser(...)`) |
| `COMPARISON` | 「既存の X と異なり」「他の Y と違って」等の対比表現 |
| `CHANGE_HISTORY` | 以下「CHANGE_HISTORY のキーワード一覧」のいずれかを含む |
| `BLOCK_TOO_LONG` | 同一ブロックが**3 行以上**で、`code-comments.md` の 2 段判定 (命名で吸収できないか → WHY 1 行に圧縮できないか) を通すと**圧縮可能** (削っても情報損失なし)。3 行以上を即違反扱いにしない |
| `DUPLICATE_SENTENCE` | 同一ブロック内で同じ要旨の文が複数回現れる (cosine 類似でなく要旨ベースで判定) |
| `NO_VIOLATION` | `code-comments.md` の「書く価値がある WHY の例」(仕様外制約・トレードオフ理由・既知バグ回避・他箇所と挙動が異なる正当な理由) に該当 |

**CHANGE_HISTORY のキーワード一覧** (markdown table 内で regex の `|` が table separator と衝突するため別記):

- `Copilot 指摘`
- `[A-Z]{2,}-\d+:` (大文字 issue prefix + 連番、例: `DEV-1234:`)
- `added for`
- `\bremoved\b` (単語境界)
- `\bdeprecated\b` (単語境界)
- `fixes?\s+#?\d+` (例: `fixes 123`, `fix #456`)
- `fixes?\s+https?://\S+` (例: `fixes https://example.com/issues/789`)
- `修正履歴`
- `https?://\S+/(pull|issues)/\d+` (PR / issue URL)

判定にあたって周辺コードが必要なケース (`IDENTIFIER_PARAPHRASE`, `NEXT_CODE_WHAT`) は Read ツールでファイルの該当行を確認する。

### Step 4: 違反テーブルをユーザーに提示

結果は markdown 表形式で。違反ゼロなら「✅ Comment sweep clean」のみ報告して終了。Step 2 で生成ファイルを除外した場合は、表（または clean 報告）の後に「除外した生成ファイル: N 件（`path1`, `path2`, ...）」を 1 行で注記する。

```markdown
## Comment sweep 結果

| # | file:line | カテゴリ | 抜粋 | 提案 |
|---|-----------|---------|------|------|
| 1 | `app/foo.ts:42` | NEXT_CODE_WHAT | `// 重複チェック用の既存ユーザーを登録` | 削除 (直後コードが自明) |
| 2 | `pkg/bar.go:88-92` | BLOCK_TOO_LONG | `// 仕様上はここに到達しない: ...` (5 行) | WHY 1 行に圧縮 or 削除 |
| 3 | `app/baz.ts:15` | CHANGE_HISTORY | `// Copilot 指摘: ...` | 削除 (git log が SoT) |

合計 N 件 / WHY のみ残せる候補 M 件

修正に進みますか? (y で全件修正 / 番号指定で部分修正 / n で停止)
```

### Step 5: ユーザー承認後 Edit で修正

承認方針:

- `y` / 「お願いします」 / 「全部」 → 全件 Edit で修正
- 番号指定 (例: `1,3` / `1-2`) → 該当件のみ
- `n` / 「やめる」 → 修正せず終了 (違反は報告済み)

修正方針 (カテゴリ別):

- `IDENTIFIER_PARAPHRASE` / `NEXT_CODE_WHAT` / `COMPARISON` / `CHANGE_HISTORY`: コメント行を**削除**
- `BLOCK_TOO_LONG`: WHY のみ 1 行に圧縮。圧縮できないなら削除を提案 (`code-comments.md` の 2 段判定: 命名で吸収できないか → WHY 1 行に圧縮できないか)
- `DUPLICATE_SENTENCE`: 重複部分を削除して 1 文に集約

Edit ツールで old_string に違反コメントブロックを含むコンテキスト、new_string に修正後を渡す。1 ファイル複数違反は連続して Edit する。

**`--staged` モードでの注意**: Edit は working tree のみを書き換える。次の commit に修正を反映するため、Edit 完了後にユーザーが `git add <修正ファイル>` で**必ず restage** する (restage しないと Step 6 の `git diff --cached` 再 sweep が修正前のままで違反を再検出する)。skill は自動で `git add` を実行しない — ユーザーが対象パスを指定して staging することで意図しない他ファイルの混入を防ぐ。

### Step 6: 再 sweep で残違反ゼロを確認

修正後、**モードに応じた diff** で再 sweep を 1 回回す:

| モード | 再 sweep の比較対象 | 前提 |
|--------|---------------------|------|
| default / `BASE_BRANCH` | `git diff origin/<base>...HEAD` | 修正を **commit してから** 再 sweep (HEAD が動かないと working tree 修正が反映されない) |
| `--staged` | `git diff --cached` | Step 5 で **`git add` 済み** が前提 |
| `--worktree` | `git diff HEAD` | Edit で working tree 修正済みなのでそのまま反映される |

残違反がゼロになるまで Step 3〜5 を繰り返す (最大 3 回。それでも残るなら手動判断が必要としてユーザーに報告)。default / `BASE_BRANCH` モードで commit を挟むことで PR にも順次反映される (push は別途必要)。

## 違反パターンの具体例

### IDENTIFIER_PARAPHRASE (削除推奨)

```go
// 悪い例: 識別子名を日本語で言い換えただけ
// UserSignupToken は signup 確認用トークンの永続化モデル
type UserSignupToken struct { ... }

// 良い例: コメント削除
type UserSignupToken struct { ... }
```

### NEXT_CODE_WHAT (削除推奨)

```go
// 悪い例
// 重複チェック用の既存ユーザーを登録。
existingUser := testutil.AddTestUser(...)

// 良い例
existingUser := testutil.AddTestUser(...)
```

### CHANGE_HISTORY (削除推奨)

```typescript
// 悪い例
// Copilot 指摘: signup verify は user/token 作成と session 発行を同一 tx で行う設計上、
// session 発行失敗で users/signup_token 行が rollback される
function verifySignup() { ... }

// 良い例: WHY だけ残す or 削除
// 同一 tx で発行: 中途半端な行残存を防ぐため
function verifySignup() { ... }
```

### BLOCK_TOO_LONG (圧縮可能なケースのみ違反)

```go
// 悪い例 (5 行で WHY 1 行に圧縮できる)
// 仕様上はここに到達しない: logout endpoint は AuthMiddleware 配下で
// session_id Cookie の検証 (構文 + DB 存在 + 期限) を通った後に呼ばれるため、
// session ID 文字列は valid なはず。形だけ defensive に nil を返すが、
// AuthMiddleware を経由しないリファクタが入った時に sessions が掃除されない
// 経路に変質しないよう注意。
return nil

// 良い例 1: 削除 (到達不能なら error を返すべき。コメントではなくコードで表現)
return errors.New("unreachable: logout outside AuthMiddleware")

// 良い例 2: WHY 1 行 (削除できない場合)
// AuthMiddleware 配下でのみ呼ばれる前提のため不変条件として nil 返却
return nil
```

3 行以上でも `code-comments.md` の「書く価値がある WHY の例」に該当する場合 (例: 圧縮するとトレードオフの説明が失われる仕様外制約) は `NO_VIOLATION` として残す。

### DUPLICATE_SENTENCE (1 文に集約)

```go
// 悪い例 (同じ要旨を 3 回言い換え)
// password 変更で credentials が変わるため既存 session を全 invalidate する
// 盗まれた session が継続利用されないよう
// reset 完了後はすべてのデバイスから再ログインを要求する

// 良い例
// password 変更で既存 session を全 invalidate (盗難 session の継続利用防止)
```

### NO_VIOLATION (残す)

```go
// 仕様外制約: gorm.DeletedAt を持たない (持つと暗黙的に soft delete に切り替わり hashed_password を含む行が残存する)
type User struct { ... }

// timing attack 防止: constant-time compare
if subtle.ConstantTimeCompare(a, b) == 1 { ... }
```

## PR 作成 flow への統合

[CLAUDE.md](../../../CLAUDE.md)「コミット / PR 運用」の autonomy 連鎖で `gh pr create` の**直前**に default モードで呼ぶ。`/pr-codex-ci` 起動前に sweep を通すことで、codex review がコメント関連 nit に時間を使わずに本質的な指摘に集中できる。

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| `git symbolic-ref refs/remotes/origin/HEAD --short` が失敗 | `git remote set-head origin -a` で再設定。それでも失敗なら明示引数 (`BASE_BRANCH`) を要求 |
| diff が空 | base 指定ミス (feature branch upstream を渡していないか確認) または HEAD が base に追いついている。`git log --oneline <base>...HEAD` で範囲を確認 |
| 違反テーブルが大量 (>20 件) | レガシーファイルを含む大規模差分の可能性。base を見直すか、ファイル単位で分割実行 |
| 周辺コード読み込みが多くて遅い | 同じファイル複数違反はまとめて Read。LLM 判定は 1 ファイル単位でバッチ化 |
| 修正後に lint / formatter が走って再差分 | 再 sweep 時に新たな違反として誤検出しないよう、formatter 自動修正分は無視 (空白だけの diff は除外) |
| `rules/code-comments.md` 自身を編集中 | 規範記述の例コメント (`// 悪い例` 等) を違反としない (Step 2 の除外ルール) |
| `--worktree` モードで新規ファイルが拾われない | `git diff HEAD` は tracked のみ。事前に `git add -N <path>` で intent-to-add してから再実行 |
| bun が PATH 上にない | 生成ファイル検出ステップを skip して全ファイルを sweep 対象とする (本 skill の核機能は影響なし) |

## 根拠

判定基準は [rules/code-comments.md](../../../rules/code-comments.md) を SoT とし、本スキルは**判定タイミング** (PR 作成前 / commit 前) を強制する。LLM のコメント生成は context window 圧縮で CLAUDE.md 規範が薄れて再現性が落ちるため、**deterministic な発火点**として skill 化している。
