# 並列開発と発展的な使い方

[README](../README.md) §2 の基本パターン (`bash scripts/dev.sh` で 1 個の bind-mount dev box に入る) から外れる使い方:

- box の中の shell に入る (claude を経由しない)
- 複数 dev box を並列で立てる (本番作業を並列に進める / pair reviewer 連動)
- sandbox box (`--clone .` 隔離) で ad-hoc 探索 (`/pr-codex-ci` は使えない)
- dev server を名前で見分ける (Traefik 経由)

## box の中の shell に入る (claude を経由しない)

別ターミナルで `bash scripts/dev.sh ls` で名前を確認し、対象の box に shell で入る:

```bash
bash scripts/dev.sh ls                     # dev box 一覧 (#, NAME, CDX 状態)
bash scripts/dev.sh shell <NAME>           # その box の対話 bash に入る (NAME 必須)
# Windows: powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 shell <NAME>
```

claude セッションと**並走可能** (`exit` / `Ctrl+D` で shell だけ抜けても claude / box は生きたまま)。`sbx exec -it <box> bash` の薄い wrapper。stage worktree の展開（並置比較用）や debugging で `setup-worktrees.sh` を直接叩きたい時、または下の sandbox box にも shell で入りたい時 (`bash scripts/dev.sh shell <生成された名前>`) に使う。

## 並列で複数 dev box を立てる (本番作業 / pair reviewer 連動)

`scripts/dev.sh` を**引数なし**で複数回叩くと、毎回別の auto-named (`<basename>-<hex6>`、例: `coding-agent-playbook-7a3f29`) dev box が立ち、それぞれ独立した `cdx-<NAME>` reviewer pair を持つ (port も独立 dynamic ephemeral)。並列で `/pr-codex-ci` を回せる。

dev box の `<NAME>` は予約 prefix `cdx-*` (reviewer pair) と `sbx-*` (sandbox auto-name) を使えない (`dev.sh` は validation で reject する)。下記 sandbox の用途と namespace 分離するため。

```bash
bash scripts/dev.sh                        # 別ターミナルで複数回叩くと別々の dev box + cdx pair が立つ
bash scripts/dev.sh ls                     # 立っている dev box を一覧
bash scripts/dev.sh attach <N>             # ls の N 番目に再 attach
# Windows: powershell -ExecutionPolicy Bypass -File scripts/dev.ps1
```

明示名で立てたい場合 (`task-a` / `task-b` 等の意図を名前に込めたい場合) は引数を渡す:

```bash
bash scripts/dev.sh task-a                 # 明示名で idempotent attach-or-create
bash scripts/dev.sh task-b
```

dev box を停止するときは `bash scripts/dev.sh kill <NAME|N>` (cdx-`<NAME>` reviewer pair も同時に破棄)。auto-teardown が走らずに orphan reviewer pair / stale lease / stale lock が残った場合は **`bash scripts/dev.sh prune`** (引数なしで dry-run、`--yes` で実行) が一括 cleanup する (個別に `sbx rm -f cdx-<NAME>` + `rm .claude/tmp/cdx-*` を叩く代わり)。**`--all` flag** で「CDX=none な dev box 本体」(`ls` に出るが cdx pair を持たない蓄積した box) も candidate に追加 (Docker `image prune --all` 類比)。安全 guard 3 段: (1) cdx pair 持ち は別経路で扱う、(2) active dev lock 持ち は in-flight 起動として除外、(3) `sbx ls --json` で `status=running` の box は除外 (`dev.sh shell` 経由 / 直接 `sbx exec` 中等で lock を持たない attach も保護、`skipped (running, --all mode)` section で別表示)。さらに delete 直前に running を**再 snapshot** して scan→delete window の race も防ぐ。**fail-closed**: bash 版は `jq` 必須 + `sbx ls --json` 取得/parse 失敗で `--all` を refuse して exit (degrade して filter なしで誤削除するより安全側)、PowerShell 版は built-in `ConvertFrom-Json` で同じ fail-closed 規範。一覧の name だけ取りたい時は **`ls -q`** (Docker `docker ps -aq` 互換、`xargs` 等で advanced 用途に open)。

## 大量 issue を並列で捌く（運用保守フェーズ）

初期実装（MVP）の後は、改善点を **issue 化 → 並列で潰す** フェーズに入る。issue の**出どころ**と**処理(dispatch)**がそれぞれ「手動 / ultracode」の2通りある。

### 入力 issue の出どころ（いずれも coding agent が `gh issue create` する）
起票そのものは人が `gh` を手打ちするより **claude に頼んで作る**のが通常（box から起票するには PAT に `Issues: Read and write` が要る。[docs/setup.md](setup.md)。無いと `Resource not accessible by personal access token (createIssue)`）。違いは「**何を**起票するか」の source:
- **人主導（狙い撃ち・少数）**: 人が「ここを直したいので issue にして」と指示 → agent が起票。
- **ultracode 発見（網羅・大量）**: 対象（例 stage の MVP）を次元別 finder agent で fan-out → adversarial verify → dedup した**検証済み backlog** を agent が起票（`ultracode` キーワードで Workflow にオプトイン）。

### ① 手動ペタペタ（人がディスパッチ）
issue ごとに box を立て、issue 番号を貼って自走させる、を**繰り返す**:

```bash
bash scripts/dev.sh                     # auto-named dev box を起動（issue ごとに繰り返す＝並列度=box 数）
# box の claude に（対象 checkpoint を明示し、専用 worktree を切らせる）:
> <対象 stage>（例 stage/04-mvp）の issue #93 を、専用の worktree を切って直し PR まで出して
```

claude は worktree→実装→PR→`/pr-codex-ci`→`/pr-review-respond` まで自走する（[CLAUDE.md](../CLAUDE.md)「開発フロー」の chain）。HOTL は statusLine の session id → host から transcript で監視。**素朴で確実だが、issue が多いと「立てて貼る」の繰り返しが手間**（→②へ）。

**①が repo 標準（clone だけで再現できる並列手順）**。②は下記のとおり Claude Code harness 利用時の発展形。

> ⚠️ **①②共通の注意（stage を対象に並列するとき）**
> - **worktree 隔離**: dev box は同じ host checkout（`.git` / `.worktrees/`）を bind-mount で共有する。共有 stage worktree（`.worktrees/<NN>/`）を直接編集させず、**issue ごとに別ブランチ＋別 worktree** を切らせる（box 間で worktree 名が衝突しないよう一意に）。
> - **Closes が効かない**: `stage/*` は default branch でないため、これらの fix PR では **`Closes #N` の自動 close が効かない**（[GitHub 仕様](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue)）。issue は手動 close／本文で参照する。
> - 対象 checkpoint 名は実ブランチと `docs/instructor.md` の checkpoint 表に合わせる。

### ② ultracode で並列処理（発展 / Claude Code harness 利用時のみ）

> ⚠️ **これは repo 同梱の機能ではない**。`ultracode` / `Workflow`（multi-agent orchestration）/ `isolation: 'worktree'` は **Claude Code harness が提供する機能**であって、本リポの script・skill ではない（clone しただけでは存在しない）。repo 標準の並列手順は①。②は Claude Code の中で回す時だけ使える。

issue 一覧を渡すと **issue ごとに agent を fan-out** して並列に fix→PR を回せる（①の「box を立てて貼る」繰り返しが 1 コマンドに畳める）:

```text
> <対象 stage>（例 stage/04-mvp）の #92 #93 #94 #95 #96 #97 を ultracode で並列に直して
```

各 agent は `isolation: 'worktree'` で独立に fix（上記「worktree 隔離」を harness が自動で満たす形）。**収束（各 worktree の結果を1つにまとめる）も harness／人間側のオーケストレーションで行う**（repo に自動統合の機構は無い）。規模と conflict 次第で:
- issue ごとに PR → 逐次 review/merge（本番 GitHub フローに近い。上記のとおり stage PR では `Closes` は効かない）
- 1 本の checkpoint（例 stage/05-fixed）に統合 → 1 PR（デモが簡潔）

> ⚠️ **同一ファイルを触る issue は並列で conflict する**。file 独立な issue を選んで並列度を上げる／逐次 merge・conflict 解消を組み込む、のどちらかを設計する（issue を切る段階で「file が重ならない粒度」に束ねておくと並列が楽）。

## sandbox box (`--clone .` 隔離 / ad-hoc 探索 / `/pr-codex-ci` は使えない)

host から完全に切り離した throwaway box を立てたい場合 (A 案 / B 案の探索、リスクの高いコマンドの検証等) は `dev.sh sandbox` を使う。host checkout を mount しない private copy として起動するため、host のファイルを取り合う race は構造的に存在しない (parallel-safe)。

```bash
bash scripts/dev.sh sandbox                # 引数なし: sbx-<basename>-<hex6> で毎回 fresh --clone
bash scripts/dev.sh sandbox <NAME>         # 明示名で sandbox を create/attach
# Windows: powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 sandbox [<NAME>]
```

sandbox box は **`sbx-` prefix** で命名され、dev box の namespace (prefix なし) と完全分離する。明示名で `bash scripts/dev.sh sandbox <NAME>` を呼ぶ場合、`<NAME>` に `cdx-*` を含めることはできず、`sbx-*` は**既存 box ならば reattach、未存在ならば create** (auto-name 後の reattach 経路と、受講者が `sbx-task-a` 等の自前 prefix で sandbox を立てる経路の両方を保つため)。これにより `bash scripts/dev.sh <NAME>` がうっかり sandbox に attach する事故を構造的に防ぐ。`bash scripts/dev.sh ls` には sandbox box は出ない (dev box discovery が `sbx-*` を除外)。`sbx ls` で全 box を確認、`sbx rm -f <NAME>` で破棄する。

> ⚠️ **migration note**: 2026-06-27 の本 refactor 前に作られた旧 `dev.sh` no-arg = clone 由来の box (`<basename>-<hex6>` 形式、prefix なし) は、現在の design では **dev box として discovery される** が、実態は clone box (host checkout を mount していない)。`bash scripts/dev.sh <旧clone名>` で attach すると bind-mount のフリで起動してしまい、`/a2a-review` が stale diff をレビューする原因になる。**clone box 由来の旧 box は `sbx rm -f <NAME>` で一旦破棄してから新 dev.sh を使うこと**。新 design では clone box は必ず `sbx-` prefix で命名される (`dev.sh sandbox` 経由) ため、prefix なしの box は今後 bind-mount dev box のみとなる。
>
> ⚠️ **既知の制約 (multi-checkout の cross-pollution)**: `bash scripts/dev.sh ls` / `prune` は `sbx ls` (host 全体の box 一覧) から予約 prefix を除外した結果を表示するため、**同マシン上で複数 clone / 別 project の checkout から dev.sh を起動した受講者には、別 checkout で作られた dev box / cdx pair も一覧に混ざる**。その状態で `dev.sh attach <N>` を叩くと、現 checkout の `cdx-<NAME>` を新規 provision したうえで別 checkout の box に attach し、`/a2a-review` が wrong tree を読むリスクがある。`prune --yes` も同様で、別 checkout の startup window 中の cdx pair を「現 checkout の lock が無いから orphan」と誤判定して削除する race がある (active dev lock check は **現 checkout の `.claude/tmp/` だけ**を見るため別 checkout の lock を知らない)。**workshop の通常運用 (1 マシン 1 checkout) では問題にならない**が、多 checkout 並用時は `sbx ls` で box 名を確認してから明示名で attach する / `prune --yes` の代わりに `prune` (dry-run) で出力を目視確認することを推奨。構造的解決 (project root ハッシュを box 名に含めて filter する設計改修) は別 issue で tracking ([#75](https://github.com/kanka-jp/coding-agent-playbook/issues/75))。
>
> ⚠️ **`/pr-codex-ci` (codex review) は sandbox box では機能しない**: `/a2a-review` は **host の checkout を bind-mount** して codex に見せる設計のため、sandbox box の中で書いた / pushed branch を codex は inspect できず、stale / empty diff に対し LGTM を返す可能性がある。workshop の merge-ready flow を回したい時は `bash scripts/dev.sh` (bind-mount dev box) を使う。sandbox は **PR 化前の ad-hoc 用途** に限定する。
>
> ℹ️ **sandbox box でも stage は `git switch stage/NN` でそのまま開ける**（stage は branch のため clone に含まれる — [decisions/stage-stacked-branches.md](decisions/stage-stacked-branches.md)）。worktree 展開（git 管理外の `.worktrees/`）だけは clone に持ち込まれないので、並置比較したい場合のみ box 内で `bash scripts/internal/setup-worktrees.sh` を実行する。

## dev server をブラウザで見る

**まず baseline（Traefik 不要・全員これで足りる）**: box の dev port を publish してそのまま開く。

```bash
sbx ports <box> --publish 3000:3000   # → http://127.0.0.1:3000
```

URL は `localhost` でなく **`127.0.0.1` を明示**する（macOS は `localhost` を IPv6 `::1` に先に解決するが、sbx の IPv6 側 forward は接続が reset され開けない。IPv4 側のみ正常）。

名前付き URL（`<name>.localhost`、既定 `web.<branch>.<repo>.localhost`）が欲しい時だけ、オプションで Traefik 層を使う:

```bash
# A) :80 が空いている → 自前 Traefik を一度起動して名前で見る
bash scripts/dev.sh route up
bash scripts/dev.sh route add <box>             # name 既定 = web.<branch>.<repo> → web.<branch>.<repo>.localhost
bash scripts/dev.sh route add <box> 8788 api.myapp  # name 明示 = hostname 全体（ドット区切り）→ api.myapp.localhost

# B) 既に共有 Traefik が :80 に居る（複数 project を 1 本で捌く定石）→ 自動検出して相乗り（自前は立てない）
bash scripts/dev.sh route add <box>             # :80 の共有 Traefik を自動検出（env 指定不要・up 不要）
bash scripts/dev.sh route detect                # 検出結果を確認
# Windows: powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 route <verb> <args>
```

相乗り（B）は `:80` の file-provider Traefik を自動検出して経路をそこへ出し入れする（`up`/`down` は no-op、既存 Traefik 設定は変更不要）。自動検出できない構成（config file 指定など）は `BOX_ROUTING_DYNAMIC_DIR` / `BOX_ROUTING_DYNAMIC_VOLUME` で供給先を明示。配線・Traefik 構成・モードの詳細・Linux ネイティブ Docker での 502 注意は [tools/parallel-dev/box-routing/README.md](../tools/parallel-dev/box-routing/README.md) 参照。

**名前で見る必要が無ければ Traefik も `dev.sh route` subcommand も不要**（baseline で十分）。「box に入る」と「dev server を名前で見る」は別の関心事で、後者はオプション層。

> 上記は**人がブラウザで見る**話。**agent に host の見える Chrome を CDP で操作させたい**（box session 維持のまま可視ブラウザを運転）なら別ツール [headful-bridge.md](headful-bridge.md)（`scripts/cdp-bridge.sh`）。攻撃面が増えるので opt-in + 使い捨て profile 限定（同 doc のセキュリティ節必読）。
