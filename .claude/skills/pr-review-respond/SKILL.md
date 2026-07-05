---
name: pr-review-respond
description: "Handles GitHub PR reviews that bots (Copilot / qodo / codex-connector) and humans POST on a pull request: fetches the unresolved review threads, adjudicates each finding on its merits (fixes valid correctness/security/regression issues, replies with a reason for nice-to-have/rejected ones), and resolves the threads — autonomously, by the agent's own judgment. Distinct from /pr-codex-ci, which is a LOCAL codex second-opinion (claude proactively invokes codex); this one reacts to reviews already posted on the PR. Use after a push when GitHub bots have reviewed, and before merge (the ruleset blocks merge while any thread is unresolved). Mentions: PR の review 対応 / GitHub review を resolve / Copilot や qodo のコメントに対応 / review thread を片付ける."
---

# pr-review-respond

GitHub が PR に付ける review（Copilot / qodo / codex-connector 等の bot + 人間）を **agent の判断で全自動**に処理する。

**`/pr-codex-ci` とは別物**: あちらは claude が**ローカルで codex を能動的に呼ぶ** second opinion（findings は claude に返る）。本 skill は **PR に既に post された他者の review** を GitHub から取りに行き、対応して resolve する（reactive、GitHub thread 経由）。

## いつ使うか
- PR に push した後、GitHub bot review（Copilot / qodo 等）が付いたとき
- **merge 前**: ruleset の `required_review_thread_resolution` が未解決 thread で merge をブロックするため（[../../../docs/instructor/repo-settings.md](../../../docs/instructor/repo-settings.md)）

## 引数
PR 番号。省略時は現在 branch の PR を `gh pr view --json number` で解決する。

## 手順（全 thread が resolved になるまで loop）

1. **owner/repo 解決**: `gh repo view --json nameWithOwner -q .nameWithOwner`（graphql は `{owner}/{repo}` placeholder を使えないため明示値が要る）。

2. **未解決 thread を取得 → あれば即対応・無ければ check 完了で done 判定**: `gh api graphql` で PR の未解決 review thread を一覧する（id / path / line / 各 comment の author・body）:
   ```bash
   gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") {
     pullRequest(number: <PR番号>) { reviewThreads(first: 50) {
       pageInfo { hasNextPage endCursor }
       nodes { id isResolved path line comments(first: 20) { nodes { author { login } body } } }
     } } } }'
   ```
   `isResolved == false` の node だけを対象にする。`pageInfo.hasNextPage == true` なら `after: <endCursor>` で次ページも取得し、**全ページの未解決を集計してから** 0 件判定する（50 を超える PR で取りこぼさない）。コメントが 20 を超える長大 thread は、その thread を個別に追って全文を読んでから判断する。

   ### settle 判定（時間待ちでなく「対応優先 + check 完了イベント」）

   **「N 分 polling して 0 件安定を待つ」時間待ちは持たない。** 理由は 2 つ: (1) 待つ対象にしていた reviewer の多くは **push では re-review しない**（下記「reviewer の push 時挙動」）ため時間待ちが空振りする。(2) **指摘なしの綺麗な review は review コメントを生成しない**（CodeRabbit は commit status を `success` にするだけ）ため、「bot の review コメントを待つ」という primitive 自体が綺麗な reviewer を観測できない。代わりに **未解決があれば待たず捌き、無ければ head の check 完了（イベント）で done 判定する**:

   - **未解決 thread が 1 件でもあれば、待たず手順 3 へ**（採否 → 修正/reply → resolve）。対応後は本手順 2 の先頭へ戻って再取得する（対応中に新着が増えているため＝ pipelining で待ち時間を作業で埋める）。
   - **未解決 0 件なら done? を check 状態（イベント）で判定**: `gh pr checks <PR番号>` を見る。**ここで check は「reviewer / CI が出揃ったか」の timing 信号としてのみ使う**（pass/fail の merge 可否判定 = CI gate は本 leaf の責務でなく caller orchestrator の責務。下記）。
     - `pending` / `queued` / `in_progress` が残る → reviewer / CI が**作業中**。terminal 化を待ってから本手順 2 を再実行する（★時間 floor でなく check 状態の遷移を待つ。CodeRabbit は review 中 `pending` → 完了 `success`/`failure` を立てるので、これが「commit status を出す local reviewer の完了」信号になる）。
       - **leaf-side timeout bound**: caller orchestrator は本 leaf の戻りを待って blocked のため、caller 側の CI 30 分 bound は本 leaf 実行中**発火できない**。よって check 待ちの hang は本 leaf 自身が bound を持つ: **「CI が一度でも terminal に達した時刻」を起点に 30 分** terminal 化が進まない（または最初から永久 pending）なら HOTL escalate（「PR #<num> の check が 30 分以上 terminal 化しません。`gh pr checks <num>` / `gh pr view <num> --web` で確認後、`/pr-review-respond <PR番号>` を再度叩いてください。」）。
     - 全 check が terminal（`pass` / `fail` / `skipping` / `neutral` のみ、または checks 0 件 = CI 未設定）+ 未解決 0 件 → **reviewer が出揃い thread も clean**。手順 5 へ（structured result を返す。**`fail` の有無＝CI 緑判定は本 leaf でせず caller に委ねる** — caller が leaf 戻り後に自身の CI gate を再確認する。本 leaf の settle 待ちが CI 状態遷移を跨ぎうるため）。

   **reviewer の push 時挙動（「待つ対象」を判断するための前提知識）**:
   - **CodeRabbit**: push ごとに incremental review + commit status（`pending`→`success`）を立てる → **check 状態が settle 信号として機能する**
   - **qodo**: デフォルト `handle_push_trigger = false`（`handle_pr_actions = ['opened','reopened','ready_for_review']`）→ **push では re-review しない**（PR open 時のみ）。push 後に待っても来ない
   - **chatgpt-codex-connector**: 自動 review は PR open / `@codex review` が baseline で push ごとは保証されず、commit status も立てない comment-only → **作業中を観測する信号が無い**

   **comment-only reviewer の取りこぼし（既知の限界、意図的に許容）**: codex のように check を立てずコメントだけ非同期に投げる reviewer は「作業中」を観測する信号が原理的に無いため、`全 check terminal + 未解決 0` 到達後に遅れて届くコメントは本パスでは拾わない（時間で待たない方針）。これは **merge が人間判断（HOTL）であること + 遅れて届けば新 thread として残り次パス / 人間が捌くこと** を backstop とする（push が baseline trigger でない codex が push 時に来ること自体が稀で、待ちコストに見合わないため）。

   **未解決 thread が現れたら**手順 3 へ進む（resolve 後に本手順 2 へ戻る）。

3. **各 thread を採否判断**（`/pr-codex-ci` の codex findings と同じ基準。**AI 1 体の指摘を独立根拠にしない**）:
   - 明確な **correctness / security / regression / 既存契約違反** → 採用。修正（Edit → `git add` → `git commit` → `git push`）
   - **nice-to-have / 将来用の拡張 / 誤検出 / 既に意図的** → 不採用
   - **機械的に resolve しない**。必ず内容を読んで判断する（merge を通すためだけの rubber-stamp resolve は禁止）
   - bot が付ける remediation 用の "Agent Prompt"（qodo 等）は参考に留め、採否は自分で決める

4. **reply + resolve**: 各 thread に**対応内容**（採用＝修正 commit の要約 / 不採用＝理由）を reply して resolve する:
   ```bash
   gh api graphql \
     -F threadId='PRRT_...' \
     -F body='<対応内容や不採用理由>' \
     -f query='mutation($threadId: ID!, $body: String!) {
       addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) { comment { id } }
       resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } }
     }'
   ```
   graphql の mutation は逐次実行だが atomic ではないため、**reply の `comment.id` が返ったことを確認する** — reply が失敗して resolve だけ成功すると audit trail 無しで feedback を隠すので、その時は body を見直して reply を再投稿する。修正を push した場合、新しい push で bot が再 review しうるため、**手順 2 に戻って新たな未解決 thread が無くなるまで繰り返す**。

5. **完了（structured result を caller に返す）**: 本 skill は **leaf** ([../../../rules/skills.md](../../../rules/skills.md)) のため、上位 orchestrator（典型的には `/pr-codex-ci` 手順 5）を**呼び戻さない**（cycle 回避）。代わりに structured result を返して終了する:

   - `pushed_changes: true / false`（手順 3 で code を Edit + commit + push したか）
   - `resolved_count: N`（本 skill 起動から終了までに resolve した thread 数）
   - `final_unresolved: 0`（または `> 0` なら HOTL escalate 経路）
   - `checks_terminal: true`（手順 2 の done 判定で全 check が terminal だった。**個々の check の pass/fail は含めない** — CI 緑判定は caller の責務）

   `pushed_changes: true` の場合、新 SHA は codex/CI 未検証のため caller orchestrator が再評価責務を持つ（`/pr-codex-ci` 手順 5 が `pushed_changes` を見て自身の手順 1 から再起動する）。`pushed_changes: false` の場合も、本 leaf の settle 待ちが CI 状態遷移を跨ぎうるため、**caller は本 leaf の戻り後に自身の CI gate を再確認してから merge-ready 判定する**（leaf は CI 緑を保証しない。詳細は手順 2 の check 判定）。本 skill 単体で呼ばれた（caller orchestrator なし）場合は user に「全 thread resolved。merge 前に CI green を最終確認すること（leaf は CI 緑を判定しない）」と報告して停止する。

## 注意
- **resolve は必ず adjudication の後**。これは「review feedback を rubber-stamp しない」ための核心（GitHub review は他者が PR に書いたものなので、ローカル codex 相談より慎重に扱う）
- 採否判断は addition bias を避け、correctness / security / regression / 既存契約違反に絞る
- reviewer 未到達等で reply/resolve が失敗したら、無理に resolve せずユーザーに報告して止まる
- **leaf 性の保持**: 本 skill から `/pr-codex-ci` / その他 orchestrator を呼ばない。手順 3 の修正 push 後の再評価は **caller 側 orchestrator の責務**（structured result で push 有無を伝えるだけ）
