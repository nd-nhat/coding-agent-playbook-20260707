# PR Follow-up Flow（PR 作成後の codex review + CI）

PR を作成したら、ユーザーの確認を待たず **orchestrator skill** を回して codex review + CI gate を merge-ready まで進める規範。box-primary 運用で「PR を作る」を中間成果で止めず、後処理まで一気通貫にするためのもの。[CLAUDE.md](../CLAUDE.md) 「コミット / PR 運用」の PR 後続規範の詳細版。

orchestrator は実行環境で 2 系統:

- **box session** (`bash scripts/dev.sh` の dev box の中) → **`/pr-codex-ci`** (A2A 経由で cdx-`<NAME>` pair の codex を呼ぶ。`/a2a-review` leaf を compose)
- **host session** (dev box 起動なし、host claude が直接 PR を作成) → **`/pr-ci`** (host インストールの `codex` CLI を直接 exec。`/codex-review` leaf を compose)

両者は **transport だけ違い**、judgement の質 (codex 第二意見 + CI gate + bot review chain) は同等。CI gate + bot review chain (`/pr-review-respond` leaf compose) は両 orchestrator 共通。

## いつ発火するか

本 chain は **2 つの境界で確認を求めず自動発火**する（CLAUDE.md「コミット / PR 運用」の autonomy 規範の具体化）:

1. **編集 done の境界（pre-PR）**: 実装 / docs 編集が done になったら、ユーザーに「PR 化しますか？」と聞かず、そのまま worktree 内で `git add -A`（または明示 pathspec で対象ファイルを stage） → `git commit -m "<件名>"`（`-m` / `-F` 無しだと editor を開いて対話 hang する） → `git push -u origin <branch>`（`-u` 必須。新規 branch は upstream 未設定のため bare `git push` は `push.default=simple` 下で fail する） → **pre-PR sweep**（`/comment-sweep` で新規追加コメントを [rules/code-comments.md](code-comments.md) 規範で sweep し、違反があればユーザー承認後 Edit で修正して amend / 追加 commit → `git push` を 1 度だけ再実行。`/co-evolve-check` / `/extension-bloat-sweep` は project が TS/JS / Python の marker file を持つ場合のみ走り、それ以外では silent skip するので **default で 3 つとも並走させてよい**。本 main checkout は marker file が無いので後者 2 つは即 skip する）→ `gh pr create --base <base-branch> --title "<件名>" --body "<本文 + 末尾に CLAUDE.md「PR Body フッター」必須>"`（`--title` / `--body` 必須。省略すると対話 prompt で hang し PR Body フッターも欠落しうる。`--base` も明示しないと default branch に向き、stage worktree からの PR が `main` に向く等の事故になる。`--body` 本文末尾に CLAUDE.md「PR Body フッター」セクションの footer 形式を必ず含める）を連続実行する（worktree-first が前提。詳細 [worktrees.md](worktrees.md)。bare `git add` は pathspec 不在で何も stage しないため必ず `-A` または pathspec を渡す。main checkout で誤って編集してしまった場合は **(a)** main checkout の dirty 変更が**全て agent 自身の今回の作業のみ**であることを確認 → **(b)** `git stash push -u -- <修正対象 pathspec...>`（pathspec を渡す場合は `push` subcommand 必須。`git stash -u <pathspec>` の省略形は fail する。agent 作業以外が無いと確認できたら pathspec 無しで `git stash push -u` でも可） → **(c)** `git worktree add --relative-paths <worktree-path> -b <branch> <base-branch>`（`--relative-paths` + `<base-branch>` を明示。本リポは relative link 前提。`<base-branch>` 省略は現在の HEAD = main から分岐するため stage PR で base が崩れる） → **(d)** `git -C <worktree-path> stash pop` で worktree に移してから commit する。`git stash pop` は cwd 基準で展開されるため、`git -C <worktree-path>` で worktree を明示しないと main checkout に再度展開して汚す。user の WIP が main checkout に含まれていたら retreat せず HOTL escalate する。`git worktree add` 自体は未 commit 変更を移動しない）。
2. **PR 作成の境界（post-PR）**: `gh pr create` 直後に確認を求めず orchestrator を起動。**box session なら `/pr-codex-ci <PR番号>`、host session なら `/pr-ci <PR番号>`** (使い分けの判断軸は冒頭「orchestrator は実行環境で 2 系統」参照)。**どちらも内部 step 5 で `/pr-review-respond <PR番号>` を chain 起動**し、local gate (codex + CI clean) + remote gate (全 thread resolved + 新規 bot review settle) の両方が揃うまで自走する。**呼び出しは orchestrator → leaf の一方向**: orchestrator ([../.claude/skills/pr-codex-ci/SKILL.md](../.claude/skills/pr-codex-ci/SKILL.md) / [../.claude/skills/pr-ci/SKILL.md](../.claude/skills/pr-ci/SKILL.md)) の手順 5 が `/pr-review-respond` を呼び、`/pr-review-respond` ([../.claude/skills/pr-review-respond/SKILL.md](../.claude/skills/pr-review-respond/SKILL.md)) は処理後 structured result を返して終了する (orchestrator を呼び戻さない、cycle 禁止規範 [skills.md](skills.md))。`pushed_changes: true` の場合は orchestrator が手順 1 から再評価する責務。**「PR を作成した」も「local gate clean」も中間成果で止めない**。最終 merge-ready 報告 = local + remote 両 gate clean を満たした状態でのみ user に返す（過去に「codex + CI clean」を merge-ready と誤読して停止し、後から届いた bot review を見落とした事故あり）。

「ユーザーが merge を判断する」以外の停止点は、**自走を継続できない事象**（reviewer 未到達 / CI 失敗の修正不能 / conflict 自動解決不能 等）の HOTL escalate のみ（下記「自走不能時の HOTL escalate」参照）。

### 禁止する確認文型（中間停止しない）

agent が以下のような選択肢提示・確認質問で停止するのは**規範違反**。これらが頭に浮かんだら、まず最善の選択肢を proceed-first で進める（global Autonomy / proceed-first）。

- 「PR 化しますか？ / PR にしますか？」
- 「次のステップはどうしますか？」
- 「このまま `/pr-codex-ci` (or `/pr-ci`) を回しますか？」
- 「① codex review を回す ② PR だけで止める ③ ...のどれにしますか？」
- 「このまま進めてよいですか？」
- 「commit + push してよいですか？」（PR 作成のための push は autonomy の範疇）
- 「box 起動しますか？」 (host session で動作中なら `/pr-ci` を回せばよく、box 起動は不要)

例外: ユーザーが明示的に「PR は作るな」「commit だけで止めて」等のスコープを宣言している場合はそれに従う。merge 実行（`gh pr merge`）はユーザー指示が無ければ実行しない（merge-ready 報告で停止が default）。

### 禁止する自己判断（orchestrator を skip しない）

orchestrator (`/pr-codex-ci` / `/pr-ci`) は **起動前に agent 側で reviewer 不在や CI 不在を判定して skip しない**。reviewer 健康確認は **orchestrator の preflight (lease 確認 / 実 invoke 時の到達性確認) に一元化** されているため、agent が手前で probe しても誤判定の温床になるだけで、正規の escalate 経路にも乗らない。「PR 作成 → 確認なしで orchestrator 起動」を必ず通すこと。

具体的に以下の path は規範違反として扱う:

- **自 box 内 `ps aux` (or `pgrep` 等) で reviewer process が無いから down と判定 → skip 提案**: cdx-`<NAME>` reviewer は**別 sbx microVM** で動くため、自 box の PID namespace には**原理的に出ない**（`(none found)` は当然の出力で reviewer 生死とは無関係）。reviewer の生死は **lease ファイル (`.claude/tmp/cdx-serve-<NAME>.lease`) + advertise URL への agent-card probe** でしか分からず、これは `/pr-codex-ci` step 1a + step 2 がやる。**`ps aux` を reviewer health の proxy として使うこと自体が誤り**
- **「reviewer 復旧 = session 失う」「軽微な変更だから不釣り合い」等の cost-asymmetry framing で skip を正当化**: skip の可否は orchestrator の preflight 結果 + HOTL escalate メッセージに基づいてのみ判定する。agent 側の cost 推測で自走 chain を短絡しない（motivated reasoning の温床）
- **`ls .github/workflows/` で CI workflow が無いから CI gate を skip と独断で判定**: CI gate の skip 可否は orchestrator step 3 (`gh pr checks` で実際の checks 0 件確認) が判定する。ファイル一覧の有無だけで決めない

「agent が自分で判断して skip → user に『そのまま / 走らせる / 中断』の選択肢を出して停止」フローは、上述「禁止する確認文型」の `① ... ② ...` 系と**同じ規範違反**として扱う（form あるいは内容で偽装した中間停止）。

例外: orchestrator 自身が出した HOTL escalate メッセージ（preflight で lease 不在を検出した等、下記「自走不能時の HOTL escalate」の形）に従って停止するのは正規経路。escalate メッセージ自身は agent ではなく skill 出力なので、agent の自己判断による skip とは区別する。

## 自走不能時の HOTL escalate

orchestrator chain (`/pr-codex-ci` / `/pr-ci`) で**自走を継続できない事象**に当たった場合、agent は選択肢を提示するのではなく、**何が起きたか + 人間に必要な操作 + 再開コマンド**を 1〜2 行で明示して停止する。「無言で詰む」「次は何しますか？を出す」は禁止。

代表ケースと escalate メッセージ例:

| 事象 | escalate メッセージの形 |
|------|------------------------|
| box 内で `/a2a-review` が cdx-`<NAME>` pair に到達不能 | 「`/a2a-review` が cdx-`<box-name>` reviewer に到達できません。recovery 順序: (1) box の terminal で Ctrl-D / `exit` で claude を抜け dev.sh trap で cdx-pair + lock を cleanup → (2) host で `bash scripts/dev.sh <box-name>` を再起動 (新 lock + pair-serve 再 fork) → (3) `/pr-codex-ci <PR番号>` を再度叩く。box hang で exit 不能なら host で `sbx rm -f <box-name>` → (2) (state 失われます)。原因確認は host の `.claude/tmp/cdx-serve-<box-name>.log` (pair-serve 出力) を参照。」 (`<box-name>` は box 内 `echo $SANDBOX_VM_ID` の literal で置換) |
| host で `cdx-<NAME>` pair が auto-provision されていない | 「cdx-`<box-name>` reviewer box が未作成です。openai secret 未登録の可能性: host で `sbx secret set -g openai --oauth` を実行してから、box 内 dev.sh を Ctrl-D / `exit` で抜け、host で `bash scripts/dev.sh <box-name>` を再起動 (dev.sh が pair-setup + pair-serve を実行) してください。再開は `/pr-codex-ci <PR番号>` を再度叩いてください。」 (`<box-name>` は box 内 `echo $SANDBOX_VM_ID` の literal で置換) |
| host で `/codex-review` が host codex CLI 未インストール / 未認証 | 「host に `codex` CLI が見つからない or `codex login` 未済。recovery: (1) `npm i -g @openai/codex` でインストール → (2) `codex login` で OpenAI subscription を認証 → (3) `/pr-ci <PR番号>` を再度叩く。あるいは box session に切り替えて `/pr-codex-ci` (box-native) を使う (`bash scripts/dev.sh <NAME>` で起動)。」 |
| CI が同じ run で繰り返し失敗（修正後も同症状） | 「CI の <check 名> が修正後も同じ理由 (<要旨>) で失敗します。手動確認が必要です。失敗 log: <URL>。」 |
| CI run が 30 分以上 status 変化なし（`pending` のまま、または `in_progress` のまま step ログ更新なし） | 「CI run `<id>` が `<経過分>` `<pending or in_progress>` のまま進捗しません。manual approval / queue hang / runner shortage / 実行 hang の可能性。`gh run view <id> --web` で手動確認してください。原因解消後、orchestrator (`/pr-codex-ci` or `/pr-ci`) を再度叩いてください。」 |
| conflict 自動解決不能 | 「`<base>` への rebase で <ファイル> に conflict。自動解決を試みましたが意味的判断が必要です。`.worktrees/<branch>/` で手動解決後、orchestrator (`/pr-codex-ci` or `/pr-ci`) を再度叩いてください。」 |

## フロー（orchestrator が行うこと）

box-native `/pr-codex-ci` skill ([.claude/skills/pr-codex-ci/SKILL.md](../.claude/skills/pr-codex-ci/SKILL.md)) / host-native `/pr-ci` skill ([.claude/skills/pr-ci/SKILL.md](../.claude/skills/pr-ci/SKILL.md)) が以下を最終 merge-ready まで loop する（**最終 merge-ready = local gate + remote gate の AND**）:

1. **local: codex review** — leaf に委譲。**box の `/pr-codex-ci`** は `/a2a-review` (別 sbx microVM の cdx-pair codex に A2A 経由で送る) を、**host の `/pr-ci`** は `/codex-review` (host インストールの `codex` CLI を直接 exec する) を呼ぶ。どちらも codex の second opinion を取る役割は同じで、transport だけ違う。
2. **local: CI gate** — `gh pr checks` で CI を確認（GitHub Actions 想定）。
3. **local 修正ループ** — 採用すべき codex 指摘 / CI 失敗があれば修正 → push → 再評価。これらが clean になったら **local gate clean**（ここで停止しない、step 4 へ）。
4. **remote: GitHub bot review gate** — leaf `/pr-review-respond` を compose して invoke。`/pr-review-respond` は bot review (Copilot / chatgpt-codex-connector / qodo 等) を fetch → 採否 → reply + resolve → structured result (`pushed_changes` / `resolved_count` / `final_unresolved` / `checks_terminal`) を返す。**`pushed_changes: true` なら新 head として step 1 から再評価** / **`pushed_changes: false` + `final_unresolved: 0` なら、戻り後に CI gate を再確認して green を確認のうえ remote gate clean** → 最終 merge-ready 報告（leaf は CI 緑を判定しないため caller が再確認する）。

両 orchestrator とも codex 1 体での local review (workshop の box には他の AI CLI が無いため codex-only、host にも他 CLI を要求せず codex のみで揃える方針)。**`/pr-review-respond` は orchestrator を呼び戻さない leaf** ([skills.md](skills.md))、上位 orchestrator が両者を compose する形（cycle 回避）。

## 前提

**box session で `/pr-codex-ci` を使う場合**:
- **cdx-`<NAME>` pair reviewer が dev.sh で auto-provision 済み**: `bash scripts/dev.sh` (auto-name) または `bash scripts/dev.sh <NAME>` (明示名) を起動すると dev.sh が対の cdx-`<NAME>` reviewer box を auto-provision + pair-serve を bg fork する (claude box TTY 終了時に trap で auto teardown する per-pair lifecycle、debate 2026-06-27 決定)。手動で serve を立てる必要はない。openai secret 未登録 / setup 失敗時は fail-open (claude box は起動するが /a2a-review は使えない) で、`/pr-codex-ci` → `/a2a-review` が「dev.sh を再起動せよ」と案内して止まる（graceful degrade）。
- `gh` が使える（box では proxy 認証）。
- codex box・openai OAuth secret のセットアップは [tools/a2a-review/README.md](../tools/a2a-review/README.md) 参照。

**host session で `/pr-ci` を使う場合**:
- **host に `codex` CLI 入りかつ `codex login` 済み**: `npm i -g @openai/codex` でインストール → `codex login` で OpenAI subscription を認証。box と同じ codex CLI を host にも入れる構図 (workshop の codex 設定は box / host で対称、ユーザーは use 状況で選ぶ)。
- `gh` が host で使える (`gh auth login` 済み)。
- box は起動不要 (host claude が `/pr-ci` で完結する)。box 起動なしで PR を作って host で `/pr-ci` を回せば codex 第二意見 + CI gate + bot review chain を all-in で進められる。

## デフォルトはマージせず報告して停止（責務境界）

**責務境界の整理**:

- **orchestrator SKILL (`/pr-codex-ci` / `/pr-ci`) は** local gate (codex review + CI) を回し、local gate clean になったら **skill 内 step 5 で leaf `/pr-review-respond` を 1 段下として invoke** して remote gate (全 thread resolved + 新規 bot review settle) まで進める。**最終 merge-ready 報告 = local + remote 両 gate clean** を満たした時点で skill 終了する（merge 実行は user 判断、自動 merge しない）。
- **`/pr-review-respond` SKILL は leaf として** GitHub bot review thread の取得 → 採否判断 → reply + resolve の実 logic を担い、**structured result (`pushed_changes` / `resolved_count` / `final_unresolved` / `checks_terminal`) を caller に返して終了**する（cycle 回避のため orchestrator を呼び戻さない、[skills.md](skills.md)）。code 変更 push 後の codex/CI 再評価は caller orchestrator (`/pr-codex-ci` or `/pr-ci`) が `pushed_changes: true` を見て自身の step 1 から再起動する責務。
- **chain 全体の停止点は**:
    - local + remote 両 gate clean = orchestrator の最終 merge-ready 報告
    - 自走不能事象 = 「自走不能時の HOTL escalate」セクションの形で停止（`/pr-review-respond` の採否判断不能・修正不能、および check が terminal 化しない CI hang も含む）

merge には GitHub ruleset の gate があり、**PR の review thread（Copilot/qodo 等）を全て resolve するまで merge できない**（`required_review_thread_resolution`。設定詳細は [docs/instructor/repo-settings.md](../docs/instructor/repo-settings.md)）。**orchestrator (`/pr-codex-ci` / `/pr-ci`) と `/pr-review-respond` は責務が異なる別 skill** — 前者は claude が能動的に呼ぶ codex second opinion (transport は box A2A or host CLI)、後者は PR に付いた他者 review の確認 → 採否 → resolve。責務分離は維持しつつ chain は orchestrator step 5 で skill 内強制起動する形を採る（規範ベースの chain だと「local gate clean = merge-ready」と読み違えて停止する事故が発生したため、skill 自身に chain 責務を持たせる）。

## なぜ hook でなく規範（CLAUDE.md + 本 rule + skill）か

PR 作成を検知して自動発火させる手段として PostToolUse hook もありうるが、本リポジトリでは **CLAUDE.md / 本 rule の規範で skill を呼ばせる形**を採る。規範を能動的な発火点として読み、agent が `/pr-codex-ci` を呼ぶ。hook 機構には依存しない（settings.json の hook 配線・hook script を増やさず、振る舞いを規範に集約して読みやすく保つ）。box は YOLO（承認ゲート無し）なので、規範に従って後続ステップへそのまま進む。

## HOTL 監視（host から box の作業を見る）

box の claude は statusLine の 1 行目に `[box名] <session-id>`（+ cdx pair の死活）、2 行目に `model · branch · context 使用率 · cost` を出す（[.claude/settings.json](../.claude/settings.json) + [scripts/internal/statusline.js](../scripts/internal/statusline.js)）。`<session-id>`（フル session id）が box 内 transcript のファイル名（`<id>.jsonl`）なので、host から:

```bash
sbx exec <box> sh -lc 'cat ~/.claude/projects/*/<id>.jsonl'
```

で box の claude が何をしているか（PR 作成・`/pr-codex-ci` の進行・codex 指摘への対応）を追える。ライブ追従は `tail -f`。

## 限界

- **`/pr-codex-ci` (box-native) は per-pair lifecycle 前提**: box 内利用は host 側 dev.sh が pair-serve を bg fork している必要がある。完全に box 内で完結はしない（OAuth の codex は別 box なので A2A 越し）。
- **`/pr-ci` (host-native) は host codex CLI 入りが前提**: workshop 受講者の host 環境セットアップに 1 ステップ追加 (`npm i -g @openai/codex` + `codex login`)。codex CLI 自体は box 側でも install されており、host で同じ CLI を使う構図。host に codex を入れたくない場合は box session で `/pr-codex-ci` を使う運用に倒せる (どちらか一方で完結する)。
- **規範であって強制ではない**: agent が規範に従う前提。YOLO + 明示規範で実質自動になるが、deterministic な hook 強制ではない。
- **完全な host 駆動の自動化**（box の外から PR を検知して全部回す）は Agent Gateway 構想（[docs/decisions/decomposed-multiagent-a2a.md](../docs/decisions/decomposed-multiagent-a2a.md)）の領域で、本フローは **session 内自走**に留める（box session / host session のいずれでも skill 起動が走らないと chain は始まらない）。

## 背景

host 側の個人運用には「PR 作成後に review + CI 監視へそのまま進む」規範があるが、それは個人 global 設定（dotfiles）に属し team・他環境では再現しない。本リポジトリは workshop 教材として project に同梱して clone するだけで揃える方針のため、同じ思想を **project-committed の規範（本 rule）+ project-scoped skill（box-native の `/pr-codex-ci` + host-native の `/pr-ci`）+ codex-only review (`/a2a-review` for box / `/codex-review` for host)** に移植した。host session で PR を作って box を起動せずそのまま `/pr-ci` で merge-ready まで進めたい (host claude が会話的タスクから PR を作ったときの典型) ユースケースに対応するため、box-native `/pr-codex-ci` の対称版として `/pr-ci` を追加している。
