# Code Comments

## 原則

編集するファイルの既存コメント慣習に従うこと。docstring があれば同様に書き、なければ追加しない。新規ファイルでは同ディレクトリの既存ファイルに従い、判断できなければコメントは書かない。

コメントは「なぜ（why）」のみ簡潔に。WHAT / HOW の説明は識別子名と型シグネチャに任せる。**WHY もコードから自明に読み取れるなら書かない**（「WHY を書け」ではなく「自明でない WHY のみ書け」が正しいルール）。識別子名・型・周辺コードから推測可能な「なぜ」は、コメントにしても情報量を増やさず、コードが変わったときに古びるだけの負債になる。

## 書かない具体的パターン

### 1. 識別子名を自然言語で言い換えるだけ

識別子が示す情報をそのまま日本語/英語に変換した「定義」コメントは書かない。読み手はコードを読めば同じ情報を得られる。

```go
// 悪い例: 識別子名を日本語で言い換えただけ
// UserSignupToken は signup 確認用トークンの永続化モデル
type UserSignupToken struct { ... }

// 良い例: コメント削除
type UserSignupToken struct { ... }
```

なお、識別子名から読み取れない WHY (例: 検証完了まで users INSERT を遅延する設計理由) は残す価値があり、後述「書く価値がある WHY の例」に該当する場合は削除せず WHY だけに整理する。

### 2. 他のコードとの比較・対比

「既存の X と異なり〜」「他の Y と違って〜」のような対比コメントは書かない。読み手は実際に X / Y を見て構造を理解するべきで、対比は WHAT / HOW の言い換えに過ぎない。さらに参照先のコードが将来変更されるとコメントだけが古くなって嘘になる。

```go
// 悪い例: 既存実装との対比で説明
// IssueSignupToken は既存の Email/Password update token (JWT) と異なり
// DB レコードを SoT とするため、JWT 署名/検証は行わず opaque token を発行する。
func IssueSignupToken(...) { ... }

// 良い例: 対比をやめ、独立した WHY を簡潔に
// DB レコードを SoT として、消費後即時 hard-delete で revoke を担保するため opaque token を発行
func IssueSignupToken(...) { ... }
```

### 3. 直後のコードが自明に語る処理説明

```go
// 悪い例
// 重複チェック用の既存ユーザーを登録。
existingUser := testutil.AddTestUser(...)

// 悪い例
// user_signup_tokens にレコードができている。
assertUserSignupTokenFound(...)

// 良い例: コメント削除
existingUser := testutil.AddTestUser(...)
assertUserSignupTokenFound(...)
```

### 4. 変更履歴コメント

`// removed`, `// deprecated`, `// added for issue X`, `// fixes https://example.com/org/repo/issues/123` 等の変更履歴は書かない。git log / PR 説明が SoT。

## 書く価値がある WHY の例

識別子名や型シグネチャからは読み取れない情報のみ書く。

- 仕様外の制約: `// gorm.DeletedAt を持たない: 持つと暗黙的に soft delete に切り替わり hashed_password を含む行が残存する`
- 一見冗長/非効率に見える処理の理由: `// constant-time compare で timing attack を防ぐ`
- 他箇所と挙動が異なる正当な理由: `// この path だけ暗号化前に一度 hash する: legacy V1 のキー長制限 (32 bytes) に収めるため` ※「何をするか」だけでなく「なぜそうするか」まで書くこと。理由が書けないならそれは HOW であって WHY ではない
- 既知バグ回避: `// https://example.com/issues/BUG-123: foo は nil を返すことがある`

## 言語別の注意

### Go の exported 識別子

Go の golint 慣習で「exported 識別子には doc コメントを付ける」とされるが、**プロジェクト内の同ディレクトリ・同種ファイル（同じ Model / Repository / Interactor 等）に doc コメントが無いなら、自分も書かない**。慣習に従うかどうかはエコシステム単位ではなくプロジェクト単位で判定する。

### Python docstring

ファイル内の既存関数に docstring が無いなら追加しない。一部の関数に docstring がある場合は、新規追加する関数にも docstring を付与してファイル内での一貫性を維持すること。

## 3 行以上のコメントブロックは要警戒

WHY が 3 行必要なケースは稀。「3 行書きたい」と思った時点で、書こうとしているのが WHAT / 構造説明 / 対比であることが多い。一度疑って、削減できないか確認すること。

3 行以上書きたくなったときは、削除を即決する前に以下の 2 段判定を必ず行う:

1. **命名で吸収できないか**: コメントが説明している内容を識別子名（関数名・型名・引数名・enum タグ等）に埋め込めば消えないか。例: `ToEntities` が strict 変換であることをコメントで説明するより、`ToEntitiesStrict` / `ToEntitiesLenient` に分けて命名で意図を表すほうが SoT が 1 つになる
2. **WHY だけに圧縮できないか**: WHAT / HOW を全部削った後に残る WHY が 1 行で書ければそれが正解。3 行残るならまだ削れていない

## 判定タイミング

「書く前」「書いた直後」「レビュー時」の 3 タイミングで判定する。ルールはあるが守られないのは判定タイミングが暗黙的なため。

### 書く前

新規にコメントを書こうとしたとき、本稿「書かない具体的パターン」のどれかに該当しないか確認する。該当するなら書かない。

### 書いた直後（commit 前 sweep）

commit 前・PR 作成前は `/comment-sweep` skill で新規追加コメントを sweep する。skill が自分が追加したコメント行を抽出し本稿の判定を 1 行ずつ適用する (詳細は [.claude/skills/comment-sweep/SKILL.md](../.claude/skills/comment-sweep/SKILL.md) 参照)。

### レビュー時（reviewer mode）

PR / コード片のレビューを依頼されたとき、過剰コメントは **top-priority nit として明示的に flag** する。具体的には:

- 識別子名の言い換え・WHAT 説明・対比・変更履歴コメントは「削除推奨」として個別に指摘する
- 3 行以上のコメントブロックは「命名で吸収できないか」を含めて代替案を提案する
- ただし指摘の総数は **inline で最大 5 件まで**。それを超える場合は「他に N 件、同種の過剰コメントあり」と summary に集約し inline を膨らませない（reviewer noise を避けるための上限。Cloudflare の AI review 運用に倣う: https://blog.cloudflare.com/ai-code-review/ ）
- 一方、本稿「書く価値がある WHY の例」に該当する既存コメントは flag しない。**reviewer mode では「コメントを増やすべき」方向の提案はしない** — 削減方向にのみ働く reviewer であること（「Python docstring」節の一貫性維持ルールは書き手側に適用される別ルールで、reviewer mode の対象外）

ユーザーから明示的に「コメント不要」「verbose にして」等の指示があった場合はそちらに従う。
