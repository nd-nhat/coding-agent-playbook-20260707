---
name: pr-ci
description: "Runs the post-PR pipeline: gets a codex (OpenAI) second-opinion review of the PR diff, applies a CI gate, and loops fixing codex findings and CI failures until the PR is review-clean and CI is green (or no CI configured). In a box session (SANDBOX_VM_ID set) automatically delegates to /pr-codex-ci (box-native, A2A codex pair) — the caller does not need to detect the environment. In a host session uses /codex-review (host codex CLI direct). Use after creating a PR, when the user asks to review a PR with codex and watch CI, or mentions PR review + CI / PR の後処理. Orchestrates /codex-review (or /pr-codex-ci on box) + gh pr checks + /pr-review-respond."
---

# pr-ci

PR 作成後の **codex review + CI gate** を回す後処理フロー。**box session (SANDBOX_VM_ID 設定あり) では自動的に `/pr-codex-ci` に委譲**し、host session では host の `codex` CLI 直で動く。判定の質はどちらも同等 (codex 1 体の second opinion + CI + bot review chain で最終 merge-ready まで進める)。

**呼び出し元は環境を意識せず本 skill を invoke してよい** — step 0 の自動委譲が環境差を吸収する:

## Autonomy (中間確認なしで発火・進行)

本 skill は **`gh pr create` 直後に確認を求めず invoke される** ([../../../rules/pr-followup.md](../../../rules/pr-followup.md) 「いつ発火するか」参照)。skill 起動後も「このまま続けますか？」「codex 指摘を採用しますか？」「再 push しますか？」等の**選択肢提示で停止しない**。採否は本 skill の判定基準 (correctness / security / regression / 既存契約違反のみ採用) で自走決定する。

明示的に停止するのは以下のみ:
- **最終 merge-ready 報告** (local gate: codex 採用指摘ゼロ + CI green or 未設定 / remote gate: 全 thread resolved + 新規 review settle が AND で揃った状態) — user に状況を返して停止。merge 実行はユーザー判断 (`gh pr merge` は明示指示時のみ)。**local gate clean だけで停止しない** (後続 step 5 で remote gate を確認する)
- **HOTL escalate** (自走不能事象) — codex CLI 未到達 / CI 失敗が修正不能 / conflict 自動解決不能 / `/pr-review-respond` の採否判断不能・修正不能 等 (`/pr-review-respond` 実行中の check terminal 化 hang は、caller が leaf 戻り待ちで blocked のため本 step 3 でなく `/pr-review-respond` の leaf-side 30 分 bound で escalate される)。**選択肢ではなく、何が起きたか + 必要な人間操作 + 再開コマンドを 1〜2 行で明示**して停止 (メッセージ形は [../../../rules/pr-followup.md](../../../rules/pr-followup.md) 「自走不能時の HOTL escalate」参照)。「無言で詰む」「次どうしますか？を出す」は禁止

## 前提

- **box session では step 0 が自動検出して `/pr-codex-ci` に委譲** (下記手順参照)。呼び出し元は判断不要
- **host session では host `codex` CLI を使う**: 未インストール / 未認証なら `/codex-review` が step 2 で HOTL escalate する
- `gh` が使える。CI は GitHub Actions (`gh pr checks`) を想定
- 環境セットアップ詳細は [tools/a2a-review/README.md](../../../tools/a2a-review/README.md) (codex 設定) 参照

## 引数

PR 番号。省略時は現在の branch の PR を `gh pr view --json number` で解決する。

## 手順 (merge-ready まで loop)

0. **box 環境チェック → `/pr-codex-ci` に委譲して終了**: `printenv SANDBOX_VM_ID || true` を確認し、値があれば **本 skill のそれ以降の手順を実行せず `/pr-codex-ci <PR番号>` を invoke してその結果をそのまま返す** (box では `/codex-review` → host codex CLI が使えないため、box-native の `/pr-codex-ci` に転送する。以降の手順 1〜5 は実行しない):
   > 「box 内で動作中のため `/pr-codex-ci` に委譲します。」

1. **PR 解決**: **引数の有無に関わらず必ず** `gh pr view <PR番号> --json number,baseRefName,headRefName,headRefOid` を実行して PR 番号 + base / head 名 + head SHA を取得する (引数省略時は `<PR番号>` も省略すれば current branch から解決される)。引数があっても次 step で `<base>` placeholder を使うため、base/head の解決を skip しない。

2. **codex review (`/codex-review` に委譲)**: **手順 1 で取得した PR の head SHA を対象に** diff をレビューさせる (current local HEAD ではない。任意 worktree から `/pr-ci <PR番号>` を呼んだとき local HEAD が PR head と乖離する correctness 事故を防ぐ)。`gh pr diff <PR番号>` を使うか、`git fetch origin <headRefName>` 後に `origin/<base>...origin/<headRefName>` 形で diff を取る:
   ```text
   /codex-review gh pr diff <PR番号> の出力を correctness / security / regression 観点でレビュー
   ```
   または:
   ```text
   /codex-review git diff origin/<base>...origin/<head> を correctness / security / regression 観点でレビュー
   ```
   **local `HEAD` を直接渡さない** (PR head と乖離した別 ref を review する事故になる)。`/codex-review` が host `codex exec --skip-git-repo-check -s read-only` で codex に投げて結果を返す。**codex の指摘は second opinion** であり採否は自分で判断する (AI 1 体の指摘を独立根拠にしない。nice-to-have / 将来用の拡張提案は採用せず、明確な correctness / security / regression / 既存契約違反のみ修正対象)。

   **`/codex-review` が host codex 未インストール / 未認証 / network error で停止した場合**は本 skill も停止し、`/codex-review` の HOTL escalate メッセージをそのまま受け流す。

3. **CI gate**: `gh pr checks <PR番号>` で状態を見る。
   - 進行中 (pending / in_progress) → 間隔を置いて再確認。push 直後は前 commit の stale な結果を掴みうるため、新しい run が始まってから判定する。**長時間 進捗なしの bound**: 同じ check が **30 分以上 status 変化なし** (`pending` のまま / `in_progress` のまま) なら manual approval 待ち / queue hang / runner shortage / 実行 hang を疑い HOTL escalate (無限ループ回避)。`pending` だけでなく **`in_progress` でも step ログが進まない hang** を同じ bound でカバーする。形: 「CI run `<id>` が `<経過分>` `<pending or in_progress>` のまま進捗しません。manual approval / queue hang / runner shortage / 実行 hang の可能性。`gh run view <id> --web` で手動確認してください。原因解消後、`/pr-ci <PR番号>` を再度叩いてください。」
   - 失敗 → 失敗した check の原因を特定。**run-id は単一に pin する**: 失敗 check の URL から直接取得するのが最確実 (1 run と 1:1)。`gh run list --commit <SHA> --json databaseId,name,conclusion` は同一 commit の複数 workflow / re-run で多数行を返すため、`conclusion == "failure"` + `name == <失敗 check 名>` で絞り込んでから 1 件選ぶ (絞り込まずに先頭を取ると wrong failure を inspect する)。pinned run-id を `gh run view <run-id> --log-failed` に渡す。引数なしの `gh run view` は対話 TUI で hang するため使わない。
   - checks 0 件 → push 直後は CI 未登録で一過性に 0 件になりうるため、少し待っても 0 件のままなら CI 未設定とみなして skip (一過性の 0 件を「CI 無し」と誤判定して merge-ready にしない)。

4. **判定とループ**:
   - **採用すべき codex 指摘あり、または CI 失敗** → 修正 (Edit) → `git status --short` で diff を確認 → `git add <修正対象ファイル...>` (pathspec を明示。bare `git add` は何も stage しない / `git add -A` は user の別目的の変更も混入させうるため、対象ファイルを 1 つずつ指定する) → `git commit -m "<件名>"` (`-m` / `-F` 必須。bare `git commit` は editor を開き対話 hang する) → `git push` → **手順 2 に戻る** (新 head で再評価)。前 round で却下した指摘は再採用しない。
     - **修正後も同じ指摘 / CI 失敗が続く / 修正不能** な場合は loop を止めて HOTL escalate (無限ループ回避)。「次どうしますか？」ではなく **何が起きたか + 必要な人間操作** を明示。例: 「CI の `<check 名>` が修正後も同じ理由 (`<要旨>`) で失敗します。手動確認が必要です。失敗 log: `<URL>`。」「conflict が `<file>` で自動解決不能。`.worktrees/<branch>/` で手動解決後、`/pr-ci <PR番号>` を再度叩いてください。」
   - **採用すべき codex 指摘が無く (LGTM / 残りは却下のみ)、CI green (or 未設定)** → **ここで停止せず手順 5 に進む** (local gate = codex + CI は通ったが、GitHub bot review gate が未確認のため最終 merge-ready 判定はまだ)。codex が非 LGTM でも残る指摘が nice-to-have / 却下のみなら local gate clean とする。

5. **GitHub bot review gate (leaf `/pr-review-respond` を compose)**: 手順 4 で local gate が clean になったら、**確認を待たず leaf skill `/pr-review-respond <PR番号>` を 1 段下として invoke** する ([../../../rules/skills.md](../../../rules/skills.md) の orchestrator → leaf 規則。本 skill = orchestrator、`/pr-review-respond` = leaf)。`/pr-review-respond` は GitHub に post された bot review (Copilot / chatgpt-codex-connector / qodo 等) を取りに行き、採否判断 → reply + resolve → **structured result を返して終了**する。`/pr-review-respond` 自身は本 skill を呼び戻さない (cycle 回避)。

   `/pr-review-respond` の返り値 (structured result) を見て本 skill が次の挙動を判断する:

   - **`pushed_changes: true`** (code 修正を commit/push した) → 新 head になったため**本 skill 手順 1 から再評価** (codex + CI を再評価 → 残れば手順 5 でまた `/pr-review-respond` を呼ぶ、の orchestrator loop)
   - **`pushed_changes: false` + 全 thread resolved + 新規 review settle** (reply/resolve のみで code 変更なし、かつ remote gate clean) → **手順 3 の CI gate を再確認**してから (`/pr-review-respond` は CI 緑を判定せず、その settle 待ちが CI 状態遷移を跨ぎうるため) **最終 merge-ready を報告して停止** (自動 merge はしない。merge は人間判断)。再確認で CI が失敗/退行していたら手順 4 の CI 失敗 path (修正 → 手順 1 から再評価) へ戻る
   - **HOTL escalate** (`/pr-review-respond` の採否判断不能 / 修正不能 等) → 本 skill も停止して escalate メッセージをそのまま受け流す

> **責務分離は維持しつつ orchestrator が leaf を compose する形で cycle を回避**: 「ローカルで codex を能動的に呼ぶ second opinion (本 skill = orchestrator)」と「PR に既に post された他者の review を取りに行って resolve する (`/pr-review-respond` = leaf)」は別の行為のため独立 skill のまま。orchestrator が leaf を呼び、leaf は structured result を返すだけで上を呼び戻さない ([../../../rules/skills.md](../../../rules/skills.md) の「呼び出しは上→下のみ、循環禁止」)。本 skill 最終 `merge-ready` 報告 = local gate (codex + CI clean) + remote gate (全 thread resolved + 新規 review settle) の AND 状態。**「local gate clean = merge-ready」と誤読して停止しない** (過去にこの誤読で「実装フェーズ完了」報告 → 数時間放置 → user が「bot review きてそう」と nudge して再開、という事故が発生した)。

## `/pr-codex-ci` との差分

`/pr-codex-ci` (box-native) と本 skill (host-native) は以下の点だけが異なる。**本 skill は step 0 の box 自動検出で `/pr-codex-ci` に委譲するため、呼び出し元はどちらを使うか意識しなくてよい**:

| 項目 | `/pr-codex-ci` | `/pr-ci` (本 skill、host 動作時) |
|---|---|---|
| 実行環境 | box (dev box 内) | host |
| reviewer preflight | あり (cdx-pair lease check) | なし (host codex CLI 未到達は `/codex-review` 側で escalate) |
| codex 第二意見 | `/a2a-review` (A2A 経由 cdx-pair) | `/codex-review` (host codex CLI 直) |
| CI gate | inline (手順 3 同) | inline (手順 3 同) |
| bot review chain | `/pr-review-respond` (同) | `/pr-review-respond` (同) |
| 最終判定 | local (codex + CI) + remote (bot review) AND | 同 |
| HOTL escalate 形式 | 同 | 同 |
| auto-merge | default off (ユーザー判断) | 同 |

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| `/codex-review` が host codex 未インストールで停止 | 案内に従い `npm i -g @openai/codex` + `codex login` を host で実行 |
| `/codex-review` が auth エラーで停止 | `codex login` で再認証 |
| CI が長時間 pending | `gh pr checks <PR番号>` を間隔を置いて再確認。run が hang していないか確認 |
| codex が広範な改善提案を返す | nice-to-have / 将来用は採用しない。correctness / security / regression のみに絞る (addition bias 回避) |
| PR が解決できない | 現在の branch が push 済みで PR があるか確認。無ければ先に PR を作成する |
| box 内で本 skill を invoke した | step 0 が自動検出して `/pr-codex-ci` に委譲するため特段の対処不要。委譲後に reviewer 未到達 error が出たら `/pr-codex-ci` のトラブルシューティングに従う |
