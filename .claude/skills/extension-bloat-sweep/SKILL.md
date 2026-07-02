---
name: extension-bloat-sweep
description: "Detects pre-PR diffs where agents extend existing implementations (file / function / signature) instead of splitting / extracting / replacing. Tier 1: (E1) large file appended (base ≥ 300 lines + added ≥ 50), (E2) signature complexity (param ≥ 4 or ≥ 3 optional), (E6) same function modified ≥ 2 commits in base..HEAD. Auto-detects TS/JS (`package.json`) / Python (`pyproject.toml`), silently skips otherwise. Outputs subtractive questions. Non-blocking. Complements `/co-evolve-check` on the orthogonal axis. Use before creating a PR (alongside `/comment-sweep` and `/co-evolve-check`), or when the user mentions リファクタした方が綺麗 / 既存実装に無理に詰め込む / 既存ファイル肥大 / 関数シグネチャ複雑化 / extension bloat."
---

# extension-bloat-sweep

「分割・抽出・置換した方が綺麗になるはずなのに、既存の file / 関数 / シグネチャに無理に詰め込んで肥大化させる」パターンを pre-PR diff から検出する leaf skill ([rules/skills.md](../../../rules/skills.md))。

`/co-evolve-check` は「旧版温存 (version 並走)」を検出する skill だが、本 skill は **直交軸の「既存実装の無理な拡張」** を検出する。両 skill は補完関係で重複しない。

検出のみで PR を block しない (non-blocking report-only)。LLM judge は subtractive 質問のみで、ideal form の全文 draft は禁止 (addition bias 再発防止)。

## いつ使うか

主発火点:
- `gh pr create` を実行する**前**に `/comment-sweep` + `/co-evolve-check` と並走で起動
- 既存 PR に追加 push する前
- 「リファクタした方が綺麗」「既存実装に無理に詰め込む」感覚があったとき

検出対象となる typical な agent シナリオ:
- 大型 file (既存 500 行) に新規 100 行を末尾追加して肥大化させる
- 既存関数のシグネチャに optional param を 3 つ重ねて param 数を 5 にする
- 同一関数を `base..HEAD` で 3 回触り続けて責務が肥大化する

検出されないケース (silent skip / low confidence):
- 言語自動推定不能な project (TS/JS/Python のいずれの marker file もない)
- 純粋な revert PR (base..HEAD 全 commit subject が `^Revert "`)
- `CLAUDE_SKILL_EXTENSION_BLOAT_DISABLE=1` 設定時
- 小規模 file への追加 (base < 300 行) や軽微な引数追加 (param 数 < 4)

## 引数

| 引数 | 説明 |
|------|------|
| `BASE_BRANCH` (位置引数、任意) | base ref を明示 (例: `main`, `develop`)。default は `origin/HEAD` → `main` の順で解決 |
| `--staged` | `git diff --cached` を見る (commit 前の index) |
| `--worktree` | `git diff HEAD` を見る (commit 前の tracked 未 commit 変更) |

引数なし: 現在 branch の `base..HEAD` を sweep。

## 手順

```text
Extension-bloat-sweep Progress:
- [ ] Step 1: project の言語推定 (TS/JS / Python / 推定不能)
- [ ] Step 1.5: 純粋 revert PR の auto-skip 判定
- [ ] Step 2: diff から E1/E2/E6 候補抽出
- [ ] Step 3: 各候補に subtractive 質問を生成
- [ ] Step 4: 構造化 finding を出力
```

実装は `scripts/extension_bloat_sweep.py` が SoT で、上記 Step を一括で行う。CLI:

```bash
python3 .claude/skills/extension-bloat-sweep/scripts/extension_bloat_sweep.py \
  [BASE_BRANCH] [--base BASE_BRANCH] [--staged | --worktree] [--json]
```

`--json` で JSON 出力。default は人間向け text 出力。

exit code:
- 0: 正常終了 (findings の有無に関わらず)
- 1: 引数エラー
- 2: git command 失敗
- 3: 言語推定不能 / 純粋 revert PR (silent skip)
- 6: その他のエラー

### 各 Step の意味

**Step 1: project の言語推定** — `package.json` (TS/JS) / `pyproject.toml` / `setup.py` / `setup.cfg` / `requirements.txt` / `Pipfile` (Python) のいずれかが repo root に必要。無ければ silent skip。`CLAUDE_SKILL_EXTENSION_BLOAT_DISABLE=1` でも silent skip。`CLAUDE_SKILL_EXTENSION_BLOAT_LANGUAGES=ts,py` で言語自動推定を csv 上書き。

**Step 1.5: revert PR auto-skip** — `git log --format=%s <base>..HEAD` の全 subject が `^Revert "` で始まる場合 silent skip。

**Step 2: E1/E2/E6 候補抽出**

- **E1: 既存大型ファイルへの大量追加** — 各変更ファイルについて: base 行数 ≥ `CLAUDE_SKILL_EXTENSION_BLOAT_FILE_LINES_THRESHOLD` (default 300) かつ `+` 行数 ≥ `CLAUDE_SKILL_EXTENSION_BLOAT_ADDED_LINES_THRESHOLD` (default 50) → 候補
- **E2: 関数シグネチャ複雑化** — 各変更ファイルの diff から関数定義行 (TS: `function` / `const ... = (`、Python: `def`) を抽出: base 側に既存の同名関数 + 新シグネチャの param 数 ≥ `CLAUDE_SKILL_EXTENSION_BLOAT_PARAM_THRESHOLD` (default 4) または optional 連続 ≥ 3 → 候補
- **E6: 同一ファイルの複数回 modify** — `git log --format='%H %s' <base>..HEAD` の各 commit の `git show <sha> --name-only` でファイル touch 確認: 同一ファイル ≥ `CLAUDE_SKILL_EXTENSION_BLOAT_MODIFY_COUNT_THRESHOLD` (default 2) commit で touched → 候補 (file 単位の low confidence 検出; 関数定義範囲への絞り込みは未実装)

**Step 3: subtractive 質問生成**

| ID | subtractive 質問 |
|---|---|
| E1 | この追加分は別 file に切り出せないか? base file が既に `<N>` 行あり、本 PR で `<M>` 行追加されている。責務が異なる部分は新規 file に分離することを検討 |
| E2 | 関数 `<func>` の引数を object 化 (`{ option1, option2, ... }`) するか、責務で関数分割できないか? 現在 param 数 `<N>` (optional 連続 `<M>`) |
| E6 | 関数 `<func>` を `<N>` 回 modify している。責務肥大の兆候。分割を検討 |

**Step 4: 構造化 finding 出力** — 各 finding:

```text
Extension bloat opportunity: <E1: 既存大型ファイル末尾追加 | E2: 関数シグネチャ複雑化 | E6: 同一関数の複数回 modify>
Evidence: <file:line range>
Base state: <base file 行数 / 関数 param 数 / commit touch 回数>
Diff impact: <追加行数 / 新 param 数 / modify 回数>
Subtractive question: <分割・抽出・置換の提案>
Suggested next action: <具体的検証ステップ — LLM の全文 draft ではない>
Confidence: high (閾値超過 + 明確な肥大化シグナル) / medium / low
```

最後に summary 1 行:

```text
✅ extension-bloat-sweep: <N findings> (<high> high / <medium> medium / <low> low confidence)
```

findings 0 件なら `✅ extension-bloat-sweep: no extension-bloat opportunities found`。

## 出力例

```text
Extension bloat opportunity: E1: 既存大型ファイル末尾追加
Evidence: src/handlers/user.ts (+131 / -0 (net +131))
Base state: base file is 520 lines
Diff impact: net growth +131 lines (+25% of base)
Subtractive question: この追加分は別 file に切り出せないか? base file が既に 520 行あり、本 PR で net +131 行 (131 added, 0 deleted) 増加している。責務が異なる部分は新規 file に分離することを検討。
Suggested next action: 追加した行が独立した責務 (例: 新機能・新領域) なら、新 file に切り出して既存 file の re-export / import 経由で繋ぐ形を検討する。
Confidence: high

✅ extension-bloat-sweep: 1 finding (1 high / 0 medium / 0 low confidence)
```

## 環境変数 (任意 toggle)

project 側に必須要求しない。default で動作する。

| 環境変数 | 説明 | default |
|---------|------|---------|
| `CLAUDE_SKILL_EXTENSION_BLOAT_DISABLE` | `1` で skill を silent disable | (未設定) |
| `CLAUDE_SKILL_EXTENSION_BLOAT_LANGUAGES` | 言語自動推定を csv で上書き (例: `ts,py`) | 自動推定 |
| `CLAUDE_SKILL_EXTENSION_BLOAT_FILE_LINES_THRESHOLD` | E1 の base file 行数閾値 | `300` |
| `CLAUDE_SKILL_EXTENSION_BLOAT_ADDED_LINES_THRESHOLD` | E1 の追加行数閾値 | `50` |
| `CLAUDE_SKILL_EXTENSION_BLOAT_PARAM_THRESHOLD` | E2 の param 数閾値 | `4` |
| `CLAUDE_SKILL_EXTENSION_BLOAT_MODIFY_COUNT_THRESHOLD` | E6 の commit touch 回数閾値 | `2` |

## co-evolve-check との関係

| 軸 | co-evolve-check | extension-bloat-sweep |
|---|---|---|
| 検出対象 | 旧版残置 (version 並走) | 既存実装の無理な拡張 |
| nudge | 「旧版削除して統一できないか?」 | 「分割・抽出・置換で綺麗にできないか?」 |
| 検出シグナル | suffix 並走 / 関数 wrapper / caller co-evolution | file 肥大 / param 数 / 関数 modify 反復 |

両者は直交軸で補完関係。pre-PR sweep として `/comment-sweep` + `/co-evolve-check` + 本 skill を並走で起動する運用を想定。

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| 言語推定が誤判定する | `CLAUDE_SKILL_EXTENSION_BLOAT_LANGUAGES=ts,py` で上書き |
| 閾値が project に合わない | `CLAUDE_SKILL_EXTENSION_BLOAT_FILE_LINES_THRESHOLD` 等で project 別調整 |
| 大量 finding が出る | 閾値を上げる、または `CLAUDE_SKILL_EXTENSION_BLOAT_DISABLE=1` で silent disable |
| E6 で AST 解析が effective でない | fallback で「ファイル単位の 2+ commit touch」を low confidence で報告 |
| revert PR で偽 finding | Step 1.5 の auto-skip が機能していない可能性。`git log --format=%s <base>..HEAD` で subject を確認 |
| 新規ファイルが対象になる | E1 は「base に存在する大型 file」のみ対象。新規 file への分割は推奨方向なので silent skip が正しい挙動 |
| 本 workshop repo で動かない | repo root に `package.json` / `pyproject.toml` 等が無いため Step 1 で silent skip するのが正しい挙動 (stage worktree の demo app は marker file を持つので、そちらでは検出が走る) |
