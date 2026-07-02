---
name: co-evolve-check
description: "Detects retention bias in pre-PR diffs where agents add new versions (interface/class/function wrappers like `FooV2` / `getUserNew`) alongside the old ones, when (a) all callers of the old symbol are touched in the same PR and (b) no public consumer markers exist (no public `package.json` exports / no PyPI metadata / no `openapi.yaml` / `*.proto` / `*.graphql` references / no `@deprecated` annotations). Auto-detects language (TS/JS via `package.json`, Python via `pyproject.toml` / `requirements.txt`) and silently skips when detection fails (project-agnostic, requires nothing from the host project). Outputs structured findings with subtractive questions (\"なぜ旧版を残したか?\"). Non-blocking, report-only. Use when about to create a PR (alongside `/comment-sweep`), or when the user mentions リファクタ後の旧版残置 / 後方互換 shim / 同時更新可能 / co-evolution / dead code from version parallelism / internal API retention bias."
---

# co-evolve-check

「公開 API でないのに後方互換性を保とうとする」パターンを pre-PR diff から検出する leaf skill ([rules/skills.md](../../../rules/skills.md))。「外部消費者がある = 現状形保持の正当な理由」の**逆ケース** (= 外部消費者なし = 同時更新可能) を機械的に判定する。

`/comment-sweep` と同様、PR 作成前の sweep として動作する。検出のみで PR を block しない (non-blocking report-only)。

## いつ使うか

主発火点:
- `gh pr create` を実行する**前**に `/comment-sweep` と並走で起動
- 既存 PR に追加 push する前
- 「リファクタした」「重複削除した」「型を整理した」等の作業終盤

検出対象となる typical な agent シナリオ:
- TypeScript の `interface User` と `interface UserV2` / `UserOld` / `LegacyUser` を並走させる
- Python の `class Foo` と `class FooV2` を並走させる
- 関数の wrapper 並走 (`getUser` + `getUserNew` / `getUserV2`)
- 同一 PR で旧版を消せる場面 (= 全 caller が touched + 外部消費者なし) なのに旧版を温存

検出されないケース (silent skip / low confidence):
- 公開 API (`package.json` の public exports / PyPI metadata / `*.proto` / `openapi.yaml` 等から参照される symbol)
- `@deprecated` / `Deprecation:` annotation で意図的な段階廃止プロセス中
- 旧 symbol の caller の 1 つでも同 PR で touched されていない場合 (= 外部消費者の可能性)
- 言語自動推定不能な project (TS/JS/Python のいずれの marker file もない)
- 純粋な revert PR (base..HEAD 全 commit subject が `^Revert "`)

## 引数

| 引数 | 説明 |
|------|------|
| `BASE_BRANCH` (位置引数、任意) | base ref を明示 (例: `main`, `develop`)。default は `origin/HEAD` → `main` の順で解決 |
| `--staged` | `git diff --cached` を見る (commit 前の index) |
| `--worktree` | `git diff HEAD` を見る (commit 前の tracked 未 commit 変更) |

引数なし: 現在 branch の `base..HEAD` を sweep。

## 手順

```text
Co-evolve-check Progress:
- [ ] Step 1: project の言語推定 (TS/JS / Python / 推定不能)
- [ ] Step 1.5: 純粋 revert PR の auto-skip 判定
- [ ] Step 2: diff から候補 symbol 抽出 (X1 + X2)
- [ ] Step 3: 各候補について caller を grep して co-evolution scope を判定
- [ ] Step 4: public marker を推定 (FP 除外)
- [ ] Step 5: 構造化 finding を出力
```

実装は `scripts/co_evolve_check.py` が SoT で、上記 Step を一括で行う。CLI:

```bash
python3 .claude/skills/co-evolve-check/scripts/co_evolve_check.py \
  [BASE_BRANCH] [--base BASE_BRANCH] [--staged | --worktree] [--json]
```

`--json` で JSON 出力 (機械可読、CI 連携用)。default は人間向け text 出力。

exit code:
- 0: 正常終了 (findings の有無に関わらず)
- 1: 引数エラー
- 2: git command 失敗
- 3: 言語推定不能 / 純粋 revert PR (silent skip)
- 6: その他のエラー

### 各 Step の意味

**Step 1: project の言語推定** — repo root で marker file を確認:

- `package.json` 存在 → TypeScript / JavaScript 対象
- `pyproject.toml` / `setup.py` / `setup.cfg` / `requirements.txt` / `requirements*.txt` / `Pipfile` のいずれか → Python 対象
- どれも無い → silent skip

`CLAUDE_SKILL_CO_EVOLVE_CHECK_DISABLE=1` が設定されていれば silent skip。

`CLAUDE_SKILL_CO_EVOLVE_CHECK_LANGUAGES=ts,py` が設定されていれば言語自動推定を上書き (csv 形式)。

**Step 1.5: revert PR auto-skip** — `git log --format=%s <base>..HEAD` の subject が全て `^Revert "` で始まる場合は silent skip。

**Step 2: diff から候補 symbol 抽出** — `git diff <base>...HEAD` (引数なし時)、`git diff --cached` (`--staged`)、`git diff HEAD` (`--worktree`) で diff を取得。`+` 行から以下を抽出:

- **X1: 型・interface 並走** — TS の `interface (\w+)` / `type (\w+) = ...` の追加 + 同一 module 内に version suffix/prefix の対 (`Foo` + `FooV2`、`(V\d+|Old|New|Legacy|Compat|Deprecated)` 命名 regex)。Python の `class (\w+)` 同型。
- **X2: 関数 wrapper 並走** — TS の `function (\w+)` / `const (\w+) = (async)? \(` / `export function (\w+)` の追加 + 既存の同 base name + suffix (`getUser` + `getUserNew` / `getUserV2`)。Python の `def (\w+)` + `_new` / `_v\d+` / `_old` / `_legacy` suffix。

候補 symbol を `(old_symbol, new_symbol, file:line)` の組として記録。

**Step 3: caller 解析と co-evolution scope 判定** — 各候補 `(old, new)` について `grep -rn "<old_symbol>"` で全 reference を抽出し、各 reference の touched 状態を `git diff` の touched line と照合:

- 全 reference が同 PR で touched + public marker なし → `Co-evolution scope: confirmed` (`Confidence: high`)
- 1 件でも未 touched → `Co-evolution scope: uncertain (1+ reference not touched)` (`Confidence: low`)
- reference 0 件 → `Co-evolution scope: confirmed (no callers)` (`Confidence: medium`、旧版が完全に dead code)

**Step 4: public marker 推定 (FP 回避)** — old_symbol が以下にマッチする場合は `Public marker: detected: <kind>` を記録:

- TS: `package.json` の `"private": true` でない + `"exports"` / `"main"` / `"types"` に old_symbol を含む module 宣言、または `export` 付き + `tsconfig.json` の `declaration: true` / `.d.ts` 経由公開
- Python: `pyproject.toml` `[project]` section 存在 (PyPI publish 想定) / `__all__` に含まれる / `_` prefix なしの public symbol
- Cross-language: `openapi.yaml` / `swagger.yaml` / `*.proto` / `*.graphql` / `schema.json` から old_symbol 参照、`@deprecated` / `Deprecation:` annotation

**Step 5: 構造化 finding を出力** — 各 finding は以下の形式:

```text
Co-evolution opportunity: <X1: 型並走 | X2: 関数 wrapper 並走>
Evidence: <file:line> (old) + <file:line> (new)
Old symbol: <old_symbol>
New symbol: <new_symbol>
Callers of old symbol: <N references>
  - <file:line> [touched in this PR ✓ / not touched ✗]
  ...
Public marker: <none / detected: <kind>>
Co-evolution scope: <confirmed / uncertain (1+ reference not touched) / excluded (public marker)>
Subtractive question: なぜ <old_symbol> を残したか? 全 caller が同 PR 内で touched され、外部消費者がいない場合、旧版を削除して新版に統一できる。
Suggested next action: <具体的なステップ — 例: "src/types/user.ts:10 の `interface UserOld` を削除し、全 caller を `User` に置換する">
Confidence: <high (co-evolution scope confirmed) / medium / low>
```

最後に summary 1 行:

```text
✅ co-evolve-check: <N findings> (<high> high / <medium> medium / <low> low confidence)
```

findings 0 件なら `✅ co-evolve-check: no co-evolution opportunities found`。

## 出力例

```text
Co-evolution opportunity: X1: 型並走
Evidence: src/types/user.ts:10 (old) + src/types/user.ts:20 (new)
Old symbol: UserOld
New symbol: User
Callers of old symbol: 3 references
  - src/api/legacy.ts:5 [touched in this PR ✓]
  - src/handlers/old.ts:12 [touched in this PR ✓]
  - src/types/index.ts:3 [touched in this PR ✓]
Public marker: none (no export to package boundary; not referenced in openapi.yaml / *.proto / public docs)
Co-evolution scope: confirmed
Subtractive question: なぜ UserOld を残したか? 全 caller が同 PR 内で touched され、外部消費者がいない場合、UserOld を削除して User のみに統一できる。
Suggested next action: src/types/user.ts:10 の `interface UserOld` を削除し、src/api/legacy.ts:5 / src/handlers/old.ts:12 / src/types/index.ts:3 の参照を `User` に置換する。
Confidence: high

✅ co-evolve-check: 1 finding (1 high / 0 medium / 0 low confidence)
```

## 環境変数 (任意 toggle)

project 側に必須要求しない。default で動作する。

| 環境変数 | 説明 |
|---------|------|
| `CLAUDE_SKILL_CO_EVOLVE_CHECK_DISABLE` | `1` で skill を silent disable (特定 project で動作させたくない場合) |
| `CLAUDE_SKILL_CO_EVOLVE_CHECK_LANGUAGES` | 言語自動推定を csv で上書き (例: `ts,py`)。default は marker file から推定 |

## PR 作成 flow への統合

`/comment-sweep` と同型の pre-PR 発火点。[CLAUDE.md](../../../CLAUDE.md)「コミット / PR 運用」の autonomy 連鎖で `gh pr create` の**直前**に並走で起動する。`/extension-bloat-sweep` (直交軸: 既存実装の無理な拡張検出) と組み合わせて使うと sweep 範囲がカバーされる。

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| 言語推定が誤判定する | `CLAUDE_SKILL_CO_EVOLVE_CHECK_LANGUAGES=ts,py` で上書き |
| public API なのに finding が出る | public marker 推定が漏れている。`@deprecated` / `__all__` / `package.json exports` 等を確認 |
| 内部 symbol なのに `Public marker: detected` で除外される | false negative。具体ケースを issue 化して script の除外条件を狭める |
| `grep -rn` の reference 抽出が遅い | repo 規模に比例。`CLAUDE_SKILL_CO_EVOLVE_CHECK_DISABLE=1` で skill 自体を silent disable する選択肢 |
| 命名 regex が agent シナリオを取り逃がす | `(V\d+&#124;Old&#124;New&#124;Legacy&#124;Compat&#124;Deprecated)` 以外の suffix/prefix pattern を script 改修で追加 |
| revert PR で偽 finding が出る | Step 1.5 の auto-skip が機能していない可能性。`git log --format=%s <base>..HEAD` で subject を確認 |
| 本 workshop repo で動かない | repo root に `package.json` / `pyproject.toml` 等が無いため Step 1 で silent skip するのが正しい挙動 (stage worktree の demo app は marker file を持つので、そちらでは検出が走る) |
