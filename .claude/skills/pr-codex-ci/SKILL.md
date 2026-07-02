---
name: pr-codex-ci
description: "Runs the post-PR pipeline: gets a codex (OpenAI) second-opinion review of the PR diff by composing the /a2a-review skill, applies a CI gate, and loops fixing codex findings and CI failures until the PR is review-clean and CI is green (or no CI configured). The box-native, codex-only post-PR follow-up (the in-box counterpart to host-side multi-AI review). Use after creating a PR, when the user asks to review a PR with codex and watch CI, or mentions PR review + CI / codex に PR を見せて / PR の後処理. Orchestrates /a2a-review + gh pr checks; the per-box codex reviewer (cdx-<NAME>) must already be running (auto-provisioned by dev.sh)."
---

# pr-codex-ci

PR 作成後の **codex review + CI gate** を回す box-native の後処理フロー。**codex 呼び出しは `/a2a-review` skill に委譲**（A2A の入口を 1 本に集約し、reviewer 到達性は `/a2a-review` 側に任せる）し、本 skill は **CI gate + 修正ループの orchestration に徹する**。box には他の AI CLI が無いため codex 1 体での second opinion。

## Autonomy（中間確認なしで発火・進行）

本 skill は **`gh pr create` 直後に確認を求めず invoke される**（[../../../rules/pr-followup.md](../../../rules/pr-followup.md) 「いつ発火するか」参照）。skill 起動後も「このまま続けますか？」「codex 指摘を採用しますか？」「再 push しますか？」等の**選択肢提示で停止しない**。採否は本 skill の判定基準（correctness / security / regression / 既存契約違反のみ採用）で自走決定する。

明示的に停止するのは以下のみ:
- **最終 merge-ready 報告**（local gate: codex 採用指摘ゼロ + CI green or 未設定 / remote gate: 全 thread resolved + 新規 review settle が AND で揃った状態）— user に状況を返して停止。merge 実行はユーザー判断（`gh pr merge` は明示指示時のみ）。**local gate clean だけで停止しない**（後続 step 5 で remote gate を確認する）
- **HOTL escalate**（自走不能事象）— reviewer 未到達 / CI 失敗が修正不能 / conflict 自動解決不能 / `/pr-review-respond` の採否判断不能・修正不能 等（`/pr-review-respond` 実行中の check terminal 化 hang は、caller が leaf 戻り待ちで blocked のため本 step 3 でなく `/pr-review-respond` の leaf-side 30 分 bound で escalate される）。**選択肢ではなく、何が起きたか + 必要な人間操作 + 再開コマンドを 1〜2 行で明示**して停止（メッセージ形は [../../../rules/pr-followup.md](../../../rules/pr-followup.md) 「自走不能時の HOTL escalate」参照）。「無言で詰む」「次どうしますか？を出す」は禁止

### 本 skill 起動前に reviewer health を手動 probe しない

reviewer 健康確認は **本 skill の step 1a (lease 確認) + step 2 (実 invoke 時の到達性確認) に一元化** されている。本 skill を invoke する**前**に agent が `ps aux | grep cdx` / `pgrep` 等で自 box 内のプロセスを覗いて「reviewer down」と判定するのは**規範違反**（[../../../rules/pr-followup.md](../../../rules/pr-followup.md) 「禁止する自己判断」参照）。cdx-`<NAME>` reviewer は**別 sbx microVM** で動くため自 box の PID namespace には**原理的に出ず**、`ps aux` は reviewer health の proxy として**そもそも成立しない**。`gh pr create` 直後に確認なしで本 skill を起動し、step 1a の lease 確認に reviewer 健康判定を委ねること。

## 前提

- 本 skill は **dev box (`bash scripts/dev.sh` 起動の bind-mount box) の中**で動く想定。dev.sh が起動時に cdx-`$SANDBOX_VM_ID` reviewer box を auto-provision + pair-serve を bg fork し、advertise URL を box の env (`$A2A_CODEX_URL`) に注入する (per-pair lifecycle)。`/a2a-review` は env を見て codex に到達する
- `/a2a-review` が reviewer 未到達 error を返したら本 skill は HOTL escalate で停止 (`/a2a-review` の HOTL メッセージをそのまま受け流す)
- `gh` が使える（box では proxy 認証）。CI は GitHub Actions（`gh pr checks`）を想定
- sandbox box (`bash scripts/dev.sh sandbox` 起動) では reviewer pair が存在しないため本 skill は使えない。`bash scripts/dev.sh attach` で既存 dev box に attach し直すか、`bash scripts/dev.sh` で新規 dev box を起動すること

## 引数
PR 番号。省略時は現在の branch の PR を `gh pr view --json number` で解決する。

## 手順（merge-ready まで loop）

1. **PR 解決**: 引数、無ければ `gh pr view --json number,baseRefName,headRefName` で PR 番号と base branch を得る。

1a. **reviewer preflight (chain 末尾でなく PR 直後に reviewer 不在を検出)**: per-NAME pair の lease (`.claude/tmp/cdx-serve-$SANDBOX_VM_ID.lease`) を確認する。**lease のパス解決は writer (`scripts/internal/a2a-review.sh` の pair-serve) と一致させる** — writer は `git rev-parse --path-format=absolute --git-common-dir` の親 (= main checkout root) に `cd` してから `.claude/tmp/cdx-serve-<NAME>.lease` を書くため、reader 側も `--show-toplevel` (worktree session で worktree root を返す) でなく **`--git-common-dir` の親**で解決する。**preflight は cheap な早期検出に徹し TCP probe は走らせない** (TCP readiness は次 step の `/a2a-review` 実 invoke 側で発覚させる役割分担)。
   **escalate を出す前に、box 内で `echo $SANDBOX_VM_ID` の値を取得し、メッセージ内の `<box-name>` placeholder を実 box 名 (リテラル) で置換すること** (host shell には `$SANDBOX_VM_ID` env が無いため、literal を貼らないと空展開で別 session に化ける)。
   - lease 不在 → HOTL escalate: 「per-NAME pair の lease (`.claude/tmp/cdx-serve-<box-name>.lease`) が見つかりません。host で `bash scripts/dev.sh <box-name>` を再起動してください (dev.sh が現 box 名で idempotent attach-or-create + pair-serve を bg fork します)。完了後、`/pr-codex-ci <PR番号>` を再度叩いてください。」
   - lease 存在 + `lease.claude_box != $SANDBOX_VM_ID` → HOTL escalate: 「lease は `<lease.claude_box>` 用で、現 box `<box-name>` と一致しません (古い lease が残存)。host で `bash scripts/dev.sh <box-name>` を再起動してください。」

2. **codex review（`/a2a-review` に委譲）**: PR の diff を対象に `/a2a-review` を invoke する:
   ```text
   /a2a-review origin/<base>...HEAD の diff を correctness / security / regression 観点でレビュー
   ```
   `/a2a-review` が `bash scripts/internal/a2a-review.sh ask` で codex に投げ (URL は `$A2A_CODEX_URL` から派生)、結果を返す。**codex の指摘は second opinion** であり採否は自分で判断する (AI 1 体の指摘を独立根拠にしない。nice-to-have / 将来用の拡張提案は採用せず、明確な correctness / security / regression / 既存契約違反のみ修正対象)。

   **`/a2a-review` が reviewer 未到達 error を返した場合**は本 skill を停止し HOTL escalate メッセージを 1〜2 行で明示する (黙って止まらない):
   > 「`/a2a-review` が cdx-`<box-name>` reviewer に到達できません。recovery は active lock が dev.sh 再起動を block するため**順序が重要**:
   > 1. box の terminal で **Ctrl-D / `exit`** で claude を抜け dev.sh を正常終了 (trap が cdx-pair + lock を cleanup)
   > 2. host で `bash scripts/dev.sh <box-name>` を再起動 (新 lock + pair-serve 再 fork)
   > 3. 起動後 `/pr-codex-ci <PR番号>` を再度叩いてください
   >
   > hang して exit 不能なら host で `sbx rm -f <box-name>` → step 2 (state 失われます)。`<box-name>` は box 内 `echo $SANDBOX_VM_ID` の literal で置換。」

3. **CI gate**: `gh pr checks <PR番号>` で状態を見る。
   - 進行中（pending / in_progress）→ 間隔を置いて再確認。push 直後は前 commit の stale な結果を掴みうるため、新しい run が始まってから判定する。**長時間 進捗なしの bound**: 同じ check が **30 分以上 status 変化なし**（`pending` のまま / `in_progress` のまま）なら manual approval 待ち / queue hang / runner shortage / 実行 hang を疑い HOTL escalate（無限ループ回避）。`pending` だけでなく **`in_progress` でも step ログが進まない hang** を同じ bound でカバーする。形: 「CI run `<id>` が `<経過分>` `<pending or in_progress>` のまま進捗しません。manual approval / queue hang / runner shortage / 実行 hang の可能性。`gh run view <id> --web` で手動確認してください。原因解消後、`/pr-codex-ci <PR番号>` を再度叩いてください。」
   - 失敗 → 失敗した check の原因を特定（run-id は失敗 check の URL か `gh run list --commit <SHA> --json databaseId` で取得し、`gh run view <run-id> --log-failed` で失敗 log を見る。引数なしの `gh run view` は対話 TUI で hang するため使わない）。
   - checks 0 件 → push 直後は CI 未登録で一過性に 0 件になりうるため、少し待っても 0 件のままなら CI 未設定とみなして skip（一過性の 0 件を「CI 無し」と誤判定して merge-ready にしない）。

4. **判定とループ**:
   - **採用すべき codex 指摘あり、または CI 失敗** → 修正（Edit）→ `git status --short` で diff を確認 → `git add <修正対象ファイル...>`（pathspec を明示。bare `git add` は何も stage しない / `git add -A` は user の別目的の変更も混入させうるため、対象ファイルを 1 つずつ指定する）→ `git commit -m "<件名>"`（`-m` / `-F` 必須。bare `git commit` は editor を開き対話 hang する）→ `git push` → **手順 2 に戻る**（新 head で再評価）。前 round で却下した指摘は再採用しない。
     - **修正後も同じ指摘 / CI 失敗が続く / 修正不能** な場合は loop を止めて HOTL escalate（無限ループ回避）。「次どうしますか？」ではなく **何が起きたか + 必要な人間操作** を明示。例: 「CI の `<check 名>` が修正後も同じ理由 (`<要旨>`) で失敗します。手動確認が必要です。失敗 log: `<URL>`。」「conflict が `<file>` で自動解決不能。`.worktrees/<branch>/` で手動解決後、`/pr-codex-ci <PR番号>` を再度叩いてください。」
   - **採用すべき codex 指摘が無く（LGTM / 残りは却下のみ）、CI green（or 未設定）** → **ここで停止せず手順 5 に進む**（local gate = codex + CI は通ったが、GitHub bot review gate が未確認のため最終 merge-ready 判定はまだ）。codex が非 LGTM でも残る指摘が nice-to-have / 却下のみなら local gate clean とする。

5. **GitHub bot review gate（leaf `/pr-review-respond` を compose）**: 手順 4 で local gate が clean になったら、**確認を待たず leaf skill `/pr-review-respond <PR番号>` を 1 段下として invoke** する（[../../../rules/skills.md](../../../rules/skills.md) の orchestrator → leaf 規則。本 skill = orchestrator、`/pr-review-respond` = leaf）。`/pr-review-respond` は GitHub に post された bot review (Copilot / chatgpt-codex-connector / qodo 等) を取りに行き、採否判断 → reply + resolve → **structured result を返して終了**する。`/pr-review-respond` 自身は本 skill を呼び戻さない（cycle 回避）。

   `/pr-review-respond` の返り値 (structured result) を見て本 skill が次の挙動を判断する:

   - **`pushed_changes: true`**（code 修正を commit/push した）→ 新 head になったため**本 skill 手順 1 から再評価**（codex + CI を再評価 → 残れば手順 5 でまた `/pr-review-respond` を呼ぶ、の orchestrator loop）
   - **`pushed_changes: false` + 全 thread resolved + 新規 review settle**（reply/resolve のみで code 変更なし、かつ remote gate clean）→ **手順 3 の CI gate を再確認**してから（`/pr-review-respond` は CI 緑を判定せず、その settle 待ちが CI 状態遷移を跨ぎうるため）**最終 merge-ready を報告して停止**（自動 merge はしない。merge は人間判断）。再確認で CI が失敗/退行していたら手順 4 の CI 失敗 path（修正 → 手順 1 から再評価）へ戻る
   - **HOTL escalate**（`/pr-review-respond` の採否判断不能 / 修正不能 等）→ 本 skill も停止して escalate メッセージをそのまま受け流す

> **責務分離は維持しつつ orchestrator が leaf を compose する形で cycle を回避**: 「ローカルで codex を能動的に呼ぶ second opinion（本 skill = orchestrator）」と「PR に既に post された他者の review を取りに行って resolve する（`/pr-review-respond` = leaf）」は別の行為のため独立 skill のまま。orchestrator が leaf を呼び、leaf は structured result を返すだけで上を呼び戻さない（[../../../rules/skills.md](../../../rules/skills.md) の「呼び出しは上→下のみ、循環禁止」）。本 skill 最終 `merge-ready` 報告 = local gate (codex + CI clean) + remote gate (全 thread resolved + 新規 review settle) の AND 状態。**「local gate clean = merge-ready」と誤読して停止しない**（過去にこの誤読で「実装フェーズ完了」報告 → 数時間放置 → user が「bot review きてそう」と nudge して再開、という事故が発生した）。

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| `/a2a-review` が reviewer 未到達で停止 | 案内に従い host で `bash scripts/dev.sh <box-name>` を再起動 (`<box-name>` は box 内 `echo $SANDBOX_VM_ID` の literal で置換、host shell では env が無く空展開する)。原因を追うときは host の `.claude/tmp/cdx-serve-<box-name>.log` (pair-serve 出力) を確認 |
| CI が長時間 pending | `gh pr checks <PR番号>` を間隔を置いて再確認。run が hang していないか確認 |
| codex が広範な改善提案を返す | nice-to-have / 将来用は採用しない。correctness / security / regression のみに絞る（addition bias 回避） |
| PR が解決できない | 現在の branch が push 済みで PR があるか確認。無ければ先に PR を作成する |
| sandbox box の中で動かしている | sandbox box (`bash scripts/dev.sh sandbox`) は host checkout を mount しないため reviewer が動作しない。`bash scripts/dev.sh attach` で既存 dev box に attach し直すか、`bash scripts/dev.sh` で新規 dev box を起動する |
