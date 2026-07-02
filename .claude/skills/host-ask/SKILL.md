---
name: host-ask
description: "From inside an sbx box, write a structured request file under `.claude/host-bridge/` asking the host claude session to investigate something only visible from host (other compose projects, port occupiers, host fs outside the mount, host-local services unreachable from box). The mirror of `/box-session-context` (which is host-from-box): this is box-from-host. Use when the box agent realizes it needs host-side facts and cannot infer them from the bind-mounted workspace. After writing the ask, automatically picks up the answer via a Monitor (persistent, session-length watch — bypasses the 10-minute Bash run_in_background timeout cap so long HOTL response windows are handled) when the host writes it; falls back to Bash run_in_background or manual cat when Monitor is unavailable (Claude Code < 2.1.98 / Bedrock / Vertex / Foundry / DISABLE_TELEMETRY / CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) so the skill keeps minimum functionality across environments. Box-side monitor only; host-side answering remains user-triggered via `/host-answer` to keep a user gate against prompt-injection chains where a compromised box could request and auto-receive host secrets."
---

# host-ask

box 内 (sbx microVM) で動いている claude session が、box からは見えない host 側の事実 (他 compose project の状態 / host で listen 中の port の占有者 / mount 外の host filesystem / box の network 制限で到達不能な host-local service) を必要としたとき、`.claude/host-bridge/ask-<box-name>-<topic>-<seq>.md` に**構造化された問い合わせ**を Write し、user に「host で `/host-answer` を回して」と告知してから ans file の出現を background polling で auto-pickup する skill (box 側 monitor のみ。host 側 auto-pickup は injection chain 防止のため**意図的に持たない** — limitations 参照)。

`/box-session-context` (host が box の transcript を覗く) の**逆方向**として対をなす leaf skill (`box → host` の能動 ask)。両者は重複せず補完関係。

## 前提条件

- **box (sbx microVM) の中で実行** する skill。host 側で起動すると意味がない (ans 待ちのループが host 上で生じるだけ)
- **bind mount された cwd 配下** に `.claude/host-bridge/` を Write できる権限。`sbx run ... .` は cwd を box の `/workspace` (or 同等) に bind するため host 側からも同じパスで見える
- 対応する `/host-answer` skill が project に同梱されており、host 側 claude が起動済み or user がすぐ起動できること
- box 内で `$SANDBOX_VM_ID` env が set されていること (dev.sh / dev.sh sandbox で box を立てれば自動で set される、statusLine にも `[$SANDBOX_VM_ID]` として表示される)

## 発火 trigger (box agent が「これは host にしか分からない」と判断する例)

box agent は以下のような状況で本 skill を発火させる:

- **host の listen port の占有者を知りたい** (例: `:80` を誰が握っているか、box 内では `lsof` も `docker ps` も host process を見れない)
- **他 project の compose / container の素性を知りたい** (例: 既存 Traefik / nginx / redis 等が host で動いていて、相乗りすべきか別途立てるべきかの判断材料)
- **mount 外の host filesystem path の中身** (例: 別 project の `docker-compose.yml` の設定値、host の `~/.config/<tool>/` の存在確認)
- **host-local service への到達** (box の network 制限で到達できない `host.docker.internal` 経由の service 等)
- **host shell の env / dotfiles の状態** (受講者環境固有の事情で box 内挙動が説明できないとき)

「box 内で `cat` / `docker ps` / `lsof` 等で確認可能」なものは host 側に振らない (本 skill は host 越境の専用経路で、box 内で解決できる質問を回さない)。

## 使い方

引数 = `<topic> [<question>]`

- `<topic>`: 1 つの問題を表す slug。`[a-z0-9-]{1,32}` (例: `traefik-port` / `port80-owner` / `host-fs-layout` / `jal-compose-config`)。**1 topic = 1 問題のスレッド**で、follow-up clarification は同 topic 内で seq を進める。解決したら新 topic を切る
- `<question>` (省略可): 1-3 行の自然文で「欲しい事実」を summarize。省略時は ask file の `## 欲しい事実` セクションを空欄で起こし、box agent が会話 context から本文を埋める

## 手順

1. **自 box 名取得**: `printenv SANDBOX_VM_ID` で env を読み `<box-name>` とする (例: `coding-agent-playbook-4632ea`)。env が空 (= box 外で誤起動 / `$SANDBOX_VM_ID` 未 set の異常 box) なら自走を止めて user に「`SANDBOX_VM_ID` env が読めません。dev box 内で本 skill を起動してください」と escalate

2. **bridge dir を checkout root から解決**: bridge は host と box が同一絶対 path に bind-mount する **main checkout root** 直下に置く (host 側 `/host-answer` もそこを見る)。cwd 相対だと worktree / subdir 起動時に `<cwd>/.claude/host-bridge` に書かれ host が拾えず flow が hang するため、cwd でなく git common dir の親から解決する (`box-session-resume` と同じ理由)。以降の `.claude/host-bridge/` は `$BRIDGE/`、`scripts/internal/host-bridge.sh` は `$REPO_ROOT/scripts/internal/host-bridge.sh` に読み替える:
   ```bash
   REPO_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
   BRIDGE="$REPO_ROOT/.claude/host-bridge"
   ```

3. **次の seq 算出**: 共有 transport を使う (采番の anchored glob / octal-safe 加算 / cross-platform 規約は script に集約。prefix 衝突 = `port` glob が `port-80` を hit する罠の回避もここが担う):
   ```bash
   SEQ=$(bash "$REPO_ROOT/scripts/internal/host-bridge.sh" next-seq "$BRIDGE" "ask-<box-name>-<topic>")
   ```
   既存無しなら `001`、ありなら `+1` してゼロ埋め 3 桁が返る

4. **新 seq の stale ans / sentinel を予防削除 → ask file を Write**: 新規 ask の発火前に、自 seq に対応する `ans-...md` / `ans-...md.done` の遺物を削除する (lifecycle cleanup 漏れや seq 衝突で stale sentinel が残り、手順 5 の polling が起動直後に `[ -f ANS.done ]` を即座 true と判定して `cat` が旧 body を取り込む race の予防)。transport の `prep-req` が bridge dir の mkdir と stale ans/done の `rm -f` (遺物無しは no-op で冪等) をまとめて行う:
   ```bash
   bash "$REPO_ROOT/scripts/internal/host-bridge.sh" prep-req "$BRIDGE" "$BRIDGE"/ans-<box-name>-<topic>-$SEQ.md
   ```
   続けて `$BRIDGE/ask-<box-name>-<topic>-<seq>.md` に下記 format で書く

5. **ans wait の Monitor を起動 (persistent)**: **primary path** として Monitor tool を `persistent: true` で起動し **done sentinel** の出現を polling、検出したら本体を cat する (box 側のみの auto-pickup、host 側は user-trigger のまま — security 根拠は下記 limitations 参照)。待受コマンド文字列は transport の `poll` が生成する (sentinel 出現→cat の順序・30 秒粒度・path の single-quote escape は script に集約):
   ```bash
   bash "$REPO_ROOT/scripts/internal/host-bridge.sh" poll "$BRIDGE"/ans-<box-name>-<topic>-$SEQ.md
   ```
   poll の出力 (single-quote literal で path を埋めた `until ... cat ...` 文字列) を **Monitor tool の `command` 引数の値としてそのまま渡す** (別の `"..."` の中にテキスト連結しない。tool 呼び出しの JSON string 値になるので引用の二重化は不要):
   ```text
   Monitor({
     command: "<poll の出力を command の値として渡す>",
     persistent: true,
     description: "ans wait for <box-name>/<topic>/<seq>"
   })
   ```
   **Monitor `persistent: true` を使う理由 (Bash `run_in_background` ではなく)**: Bash tool の `run_in_background` は `BASH_MAX_TIMEOUT_MS` (default 600000 = 10 分、env で上限変更可能だが hard cap あり) で kill される。host 側 user の `/host-answer` 応答時間は HOTL ワークフローで 10 分を超えうる (user が他作業中・並列 PR 監視中・席を外している等)。Monitor `persistent: true` は session-length watch (no timeout) で、command が exit するまで自然に持続する。**Monitor schema の「single event は Bash run_in_background 推奨」は数分以内に終わる short job 前提**で、本 use case (いつ来るか分からない event を待つ) には合わない。

   **Monitor が利用不能な環境での fallback path**: Monitor は Claude Code 2.1.98+ の機能で、以下の環境では使えない (公式 [Tools reference](https://code.claude.com/docs/en/tools-reference) 参照):
   - **Claude Code < 2.1.98** (古い CLI version)
   - **Bedrock / Vertex / Foundry** (代替モデルプロバイダ)
   - **`DISABLE_TELEMETRY=1` / `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`** (telemetry 経路で起動するため)

   これらの環境では fallback として:
   - **(a) Bash `run_in_background`**: 同じ command を `Bash({command: "until ... done; cat ANS", run_in_background: true})` で起動 (10 分 timeout cap あり、HOTL 応答が 10 分超えると無音で kill されるため次善策)。完了通知の取り込み: `BashOutput(bash_id="<task-id>")` または notification の `<output-file>` を `Read` で読む (Bash の stdout は file 経由なため Monitor と違って明示取得が必要)
   - **(b) manual cat (旧フロー)**: 手順 6 の告知メッセージに「ans が来たら知らせてください、`cat .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md` で取り込みます」を含める。HOTL handoff 2 段になるが、environment 制約下では最小機能を保証する経路

   どの path を採るかは、box agent が起動時に Monitor が使えるか probe するか、または環境を事前に把握して選ぶ (確実な runtime detection は現状 doc から指示できないため、Monitor 起動が tool error で失敗したら (a) → (b) の順に fallback)。

   **sentinel (`.md.done`) を polling 対象にする理由**: `/host-answer` が ans 本体を Write してから別 step で sentinel を touch する serialization で、sentinel 出現 = 本体完成済みを保証する (race-free)。ans 本体を直接 polling すると Write ツールの非 atomic な書き込み (truncate + sequential write) 途中で `[ -f ans...md ]` が true になり `cat` が half-written 状態を取り込む race window がある。`until [ -f X ]` は POSIX shell で動く (box image の bash / busybox いずれでも portable)。`sleep 30` interval で host 側 user の `/host-answer` 実行を 30 秒粒度で待つ。Monitor は sentinel 出現で 1 度だけ `cat` を実行して exit (stdout 全行が 200ms 内なら 1 notification にまとまる、small ans file は通常 1 event)

6. **user に告知して本筋作業に戻る**: 起動した path に応じて以下を分けて告知 (Bash fallback では 10 分 timeout の honesty を保つため Monitor とは別文言にする):

   **(primary / Monitor `persistent: true`) session-length auto-pickup**:
   ```text
   📤 host info request 書きました: .claude/host-bridge/ask-<box-name>-<topic>-<seq>.md

   host 側 claude で次を実行してください:
     /host-answer <box-name> <topic>

   ans が書かれたらこちらで自動 pickup します (Monitor persistent、session-length 待機、30 秒粒度の sentinel polling)。それまで他の作業を続けます。
   ```

   **(Bash fallback) 10 分以内 auto-pickup、超えたら manual に倒す**:
   ```text
   📤 host info request 書きました: .claude/host-bridge/ask-<box-name>-<topic>-<seq>.md

   host 側 claude で次を実行してください:
     /host-answer <box-name> <topic>

   ans が 10 分以内に書かれればこちらで auto-pickup します (Bash run_in_background、30 秒粒度の sentinel polling)。
   ⚠️ 10 分超過時は Bash の timeout (BASH_MAX_TIMEOUT_MS hard cap) で polling が無音 kill されます。10 分以内に届かない場合は ans 到着を知らせてください (manual cat に倒します)。
   ```

   **(manual cat fallback) Monitor / Bash background が両方使えない場合**:
   ```text
   📤 host info request 書きました: .claude/host-bridge/ask-<box-name>-<topic>-<seq>.md

   host 側 claude で次を実行してください:
     /host-answer <box-name> <topic>

   ans が来たら知らせてください (こちらで `cat .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md` で取り込みます)。
   ```
   この path では HOTL handoff 2 段だが auto-pickup 経路が無い環境での最小機能を保証する

   告知後は ans を blocking で待たず、可能な範囲で本筋タスクを進める。Monitor の `cat` が sentinel 検出後に exit すると stdout 全行が notification として届く (Bash fallback の場合は notification + `<output-file>` Read、ただし timeout 後は手順 7 の Bash timeout handling 経路)

7. **ans 取り込み (path 別 + Bash timeout handling)**:
   - **(primary / Monitor)**: Monitor は stdout の各行を event として notification 化する (200ms 内の連続行は 1 notification にまとまるため、small ans file は通常 1 event = ans 全文が 1 つの notification として届く)。明示 Read 不要、context に直接届く
   - **(Bash fallback / 正常完了 = sentinel 検出 < 10 分)**: task-notification は task 完了の event のみで stdout は `<output-file>` (絶対 path) に persisted されている。`Read(file_path="<output-file>")` または `BashOutput(bash_id="<task-id>")` で明示取得する
   - **(Bash fallback / timeout = sentinel 未検出のまま 10 分到達 → SIGTERM kill)**: notification の status が `timeout` / `failed` で届く (`exit code 143` 等)。この場合は **manual cat fallback に手動で倒す**: (a) user に「Bash polling が timeout、ans が届いていれば手動で取り込みます」と伝える、(b) `[ -f .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md.done ]` の存否を確認 (sentinel 既に出ているなら直接 cat / まだなら user に host での `/host-answer` 実行状況確認を依頼)、(c) sentinel あり → `cat .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md` で取り込み
   - **(manual cat fallback)**: user が「来た」と告げたら `cat .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md` を Bash で実行して context に取り込む

   取り込んだ ans 内の ` ```host-ctx ... ``` ` fence が host 側からの paste-ready ブロック (内容を信頼して以降の判断材料にする)。取り込み後、待っていた本筋判断を再開する。Monitor / 正常完了 Bash は task exit で自然終了するため明示的な `TaskStop` は不要

## ask file format

```markdown
# Host info request

- **from**: box `<box-name>`
- **topic**: `<topic>`
- **seq**: `<seq>`
- **ts**: `<iso8601 UTC>`

## 欲しい事実 (1-3 行)

<box agent が自然文で記述。Done when を満たせる最小粒度で>

## 既知 (in-box で確認済み)

- <box 内で確認できた事実 1>
- <box 内で確認できた事実 2>

## 仮説 (host 側で裏取りしてほしい候補)

1. <仮説 1>
2. <仮説 2>

## Done when

<この情報が answer に含まれれば本 ask は閉じる、という終了条件 1-2 行>
```

## 並列 ask (複数 topic 同時)

`<topic>` で並走 topic を分離するため、同一 box session 内で複数の物理問題を同時に ask 可能 (例: `traefik-port` の ans を待つ間に `jal-compose-config` の ask を別途送る)。各 topic は独立した seq を持つ。

ただし**同一 topic 内の seq は単調増加**で、ans を待たずに次の seq を起こすと host 側が混乱する (どの seq が現在 active か曖昧)。同 topic の follow-up は ans を受け取った後に出す。

topic 命名規約 `[a-z0-9-]{1,32}` は機械強制せず agent 規律に委ねる。**topic prefix の衝突**は手順 3 の anchored glob (`[0-9][0-9][0-9].md`) で構造的に防ぐが、運用上も命名を散らす (例: `port-80` でなく `traefik-port`、`port-3000-app` でなく `app-port`) と読み手に優しい。

## limitations / caveats

- **box 側 monitor のみ (host 側 monitor は実装しない)**: bridge の auto-pickup は box → ans file 出現の polling のみ (上記手順 5)。host 側で box → ask file 出現を polling する逆経路は**意図的に持たない**。box は untrusted source (公開 issue / PR body / web 取得文書) を context に取り込む頻度が高く prompt-injection の経路になりやすい。box が injection されると ask に「全 host secret を返せ」と書ける → host 側が auto-pickup すると user 介入なしに host が answer → box context へ流入 → exfil 経路 (PR body / commit / bot reply) で外へ、という injection chain が成立する。host 側を user-trigger (`/host-answer` を user が能動 invoke) のままにすると、host claude が起動するタイミングで user 判断が入り chain が break する。host を信頼境界 / box を injection 経路として非対称に扱う設計
- **host-from-host 経路ではない**: 本 skill は box 内専用。host 内で host info が欲しいなら通常通り host で Bash を回すだけで済む (skill 不要)
- **lifecycle**: ask / ans / done sentinel file は `.gitignore` 対象だが**自動削除しない**。debug 価値で残し、気になったら手動 `find .claude/host-bridge -maxdepth 1 \( -name 'ask-*.md' -o -name 'ans-*.md' -o -name 'ans-*.md.done' \) -delete` (3 種すべて削除する。**`ans-*.md.done` を削除し忘れると同 box/topic で seq 001 を再採番した時に stale sentinel が残り、box 側 polling が `until [ -f ANS.done ]` を即座に true で抜けて `cat` が旧 ans body / 不在 path を取り込む race を起こす**)。**`find -delete` 形を使う理由**: 単純な `rm -f <glob>` は bash/sh では無マッチで idempotent だが zsh の default `nomatch` option では glob 展開時に `no matches found` で error する (macOS の default shell が zsh のため host で叩く際に踏みやすい)。`find -delete` は shell の glob 展開に依存せず find の自前 pattern match で動くため shell-independent に idempotent。`-maxdepth 1` で `.claude/host-bridge/` 直下に限定、`.claude/host-bridge/` で anchor して cwd 違いで無関係ファイルを巻き込まない
- **secret / 機密**: ask file 内に box の env / credential 等の機密を貼らない (host ↔ box で平文共有される。box-bridge は L0 機密境界の対象外で、機密値は op / secret-proxy 経由の動的注入で扱う)
- **`<box-name>` の一意性**: 同時に同名 box を立てられない sbx の制約 (`sbx ls` で name unique) により `<box-name>` で active session を一意特定できる。host が複数 dev box (例: parallel dev) を抱えている場合、`<box-name>` の取り違えで ans が別 box 宛になるため、escalate メッセージに `<box-name>` の literal を必ず含める

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| `printenv SANDBOX_VM_ID` が空 | box 外で誤起動 / 異常 box の可能性。dev.sh / dev.sh sandbox で box を立て直すか、`<box-name>` を user paste で fallback |
| `.claude/host-bridge/` が存在しない | 手順 2 で `mkdir -p` するため通常は発生しない。permission denied なら bind mount の write 権を確認 |
| host 側 claude が `/host-answer` を持っていない | 本 PR が host にも反映されているか確認 (project skill は両側 clone 同梱の前提) |
| ans が来ない (Monitor notification が届かない) | (1) user が host で `/host-answer <box-name> <topic>` を実行したか確認 (host 側は user-trigger、自動では走らない)。(2) Monitor の生存を `TaskList` で確認。`until` ループが回り続けているなら ans file が未生成 = host 側未実行。(3) 待ち時間が長い場合は user に明示的に escalate して Monitor を kill (`TaskStop <task-id>`) |
| ans 本体は書かれたが sentinel (`.md.done`) が無い | `/host-answer` が旧版 (sentinel touch 未対応) で動いた可能性。host で `touch .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md.done` を手動実行するか、新版 `/host-answer` で再投入してもらう |
| ans 出現したのに `cat` が走らない | `[ -f X ]` は regular file のみ true。sentinel が symlink で来ている等の特殊ケースは `[ -e X ]` 形にして手動で再起動 (通常の `/host-answer` 経路では regular file が touch される) |
| Monitor notification を受けたが ans が context に入っていない | Monitor は stdout を直接 stream する設計のため通常は発生しない。万一 missed なら `TaskList` / `TaskOutput` で Monitor の output を確認 |
| Monitor が永久に exit しない (host が応答放棄) | `TaskStop <task-id>` で Monitor を kill。topic を放棄するなら ask file も `rm` してから次の作業へ |
| 同 topic で seq がぶつかった (並走で誤って ask を二重に起こした) | 古い方の ask を `rm` + 対応する Monitor を `TaskStop` してから seq を採り直す |
| `<box-name>` を間違えて ans が別 box 宛になった | ans file 名の `<box-name>` を訂正して新規 ans として box 側で `cat` する (Monitor は元の `<box-name>` で polling 中なので `TaskStop` して新 path で再起動) |
