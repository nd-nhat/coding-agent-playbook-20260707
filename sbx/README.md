# sbx カスタム image / kit

[Docker Sandboxes (`sbx`)](https://docs.docker.com/ai/sandboxes/) で coding agent を **microVM-per-agent の hypervisor 境界**の中で動かすための、playbook の実行基盤。安全に並列化した coding agent / HOTL (Human-On-The-Loop) 運用の土台。

中立な `shell-docker` base の image に **claude と codex を同居**させ、**built-in claude agent** で起動して箱の中で claude が codex を呼んで**相互レビュー**できる構成。採用に至った検証と方針は [docs/decisions/parallel-hotl-execution.md](../docs/decisions/parallel-hotl-execution.md)（Accepted）を参照。

## なぜ sbx か（hard boundary）

自作 firewall ベースのサンドボックス（旧 `.devcontainer/`、撤去済み）は defense-in-depth であって hard boundary ではない（箱内の `node` が root sudo / docker 権限を持ち、乗っ取られた agent が egress を破壊しうる）。承認ゲートを外して並列で回す HOTL では監視が薄くなるため soft boundary は構造的に不足する。sbx は microVM-per-agent の hypervisor 境界を中核とし、VM 内 root でも破れない hard boundary を持つ。

## なぜ built-in claude agent + codex mixin か

secret の proxy 注入（トークンを box に入れず host で auth header を注入）は **agent positional が Docker built-in agent に解決される時だけ** sbx が host 側で provisioning する。custom (`kind: sandbox`) agent では claude / codex とも secret の placeholder が登録されず proxy 注入が効かない（実機検証で確認）。なお **anthropic で proxy 注入の対象になるのは API key のみ**で、サブスク (Pro/Max) は proxy 注入ではなく箱内 `/login`、または `claude setup-token` を `sbx secret set` に登録して box に自動 provision させる経路 C で認証する（いずれもトークンは box 内に入る。後述「認証」）。そこで:

- **base image は中立な `shell-docker`**（`claude-code-docker` を base にすると claude が特権化する）。claude / codex / chrome を image に bake し、`-t` で渡す。
- **agent は built-in `claude`**（`sbx run claude`）。built-in agent だと sbx が secret を proxy 注入できる（**API key** は host で auth header を注入しトークンは box に入らない）。**サブスク (Pro/Max) は proxy 注入ではなく箱内 `/login` か setup-token の secret 登録（経路 C）で認証し、その OAuth トークンは box 内に保存される**（後述「認証」）。
- **codex は mixin（`playbook-kit/`）で egress だけ開け**、サブスク認証は **host の `~/.codex/auth.json` を box に転送**して codex に実トークンを直接渡す（後述「codex のサブスク認証」）。codex の proxy 注入は built-in codex agent 限定で claude box では効かないため。
- `shell-docker` は共通 base `shell` に **Docker Engine (DinD) を足した variant**。playbook は箱内 compose を使う（[ADR](../docs/decisions/parallel-hotl-execution.md) 受け入れ項目）ため `-docker` 系統が必要。DinD は sbx が `-docker` 系統に対し privileged microVM + block volume + dockerd 自動起動を用意するもので、**素の `shell` に手で docker を足しても付かない**。

## 前提

- host に `sbx` CLI（Docker Sandboxes）を導入し、`sbx login` で認証済みであること
- Docker が動いていること

## image をビルド + sbx へ load

```bash
docker build --load -t coding-agent-playbook-sbx sbx/   # --load: BUILDX_BUILDER non-default driver でも local image store に入れる
docker save coding-agent-playbook-sbx -o cap-sbx.tar    # sbx runtime に渡すため tar 化
sbx template load cap-sbx.tar                           # sbx の template store に取り込む
```

base は `docker/sandbox-templates:shell-docker`（中立 base・DinD 入り）。これに workshop 用ツール（fonts / headless Chromium）と chrome-devtools MCP 用の chrome-headless ラッパー + CDP 環境変数（`CDP_EXEC` / `CDP_HEADLESS`）、および **claude / codex を公式 standalone installer で対等に** bake する。install は build 時に host network で走るため egress allowlist の影響を受けず、box の runtime egress を tight に保てる。

box 内の claude は既定モデルを **Opus** にしてある（image に `ENV ANTHROPIC_MODEL=opus` を焼く）。`opus` alias は常に最新 Opus を指す。image 側に焼くので **host 側 claude には影響しない**（box-only）。`~/.claude/settings.json` の `model` field でなく env に焼くのは、built-in claude agent が起動時に settings.json を自前で書き直し焼いた `model` を落とすため（実機確認済み）。box には `--model` も他の `ANTHROPIC_MODEL` も渡らないので、この env が precedence 上唯一の権威として効く。箱内で `/model` を叩けば現 session は即座に切り替わる（`/model` は env より優先）が、box は基本使い捨て 1 session なので env 既定で実害は無い。

> ⚠️ **`sbx template load` は必須**。sbx の Docker daemon は host の local image store を共有せず registry から pull するため、`docker build` しただけの local image は box 作成時に `pull failed` になる（[Templates doc](https://docs.docker.com/ai/sandboxes/customize/templates/)）。Dockerfile を変更したら再 build → 再 save → 再 load する。

> ℹ️ **agent の version を上げたいだけのとき**（Dockerfile は不変で claude / codex を最新版に更新したい）は、installer の `RUN` 文字列が変わらず Docker が cache hit して**古い版に固定される**。`AGENT_CACHEBUST` ARG（installer レイヤーの直前に置いてある）の値を変えて build すると、その install レイヤーだけ cache を捨てて再取得する:
>
> ```bash
> docker build --load --build-arg AGENT_CACHEBUST=$(date +%s) -t coding-agent-playbook-sbx sbx/
> docker save coding-agent-playbook-sbx -o cap-sbx.tar && sbx template load cap-sbx.tar
> ```
>
> （`bash scripts/build-image.sh` / `scripts/build-image.ps1` でこの 2 行を 1 行に縮約できる）
>
> 上流の重い apt / Chromium レイヤーは ARG より前なので cache 再利用される（`--no-cache` 全再ビルドより速い）。

## 認証

### claude

claude には **3 経路**がある。サブスク (Pro/Max) を**複数 box / 並列**で回すなら **経路 C（setup-token、per-box 操作なしで全 box 自動認証）が推奨**。単発 box の手早い起動なら経路 B（箱内 `/login`）。トークンを box に入れたくない (最小化) なら経路 A（API key）。経路 B / C はトークンが box 内に入る。

#### 経路 A: API key（proxy 注入・トークンは box に入らない）

```bash
sbx secret set -g anthropic   # API key (sk-ant-...) を貼る
```

built-in claude agent が API key を proxy 注入する。secret は host keychain に保存され、box 内は sentinel 値のみ（`SBX_CRED_ANTHROPIC_MODE=apikey`、実トークンは box に入らない）。

#### 経路 B: サブスク (Pro/Max)（箱内 `/login`・トークンは box 内）

**`sbx secret set -g anthropic --oauth` の対話 OAuth フローは使えない**（`anthropic OAuth cannot be started from sbx secret set; sign in from inside the Claude sandbox` で拒否、v0.33.0 で確認）。サブスクを secret 登録して全 box 自動認証したい場合は `claude setup-token` のトークンを貼る経路 C を使う。単発 box は箱内で `/login` する:

```bash
sbx run <box>      # claude が起動したら /login (claude.ai OAuth、対話)
```

完了すると OAuth トークンは **box 内 `~/.claude/.credentials.json` に保存される**（codex の auth.json と同じく box 内に実トークンが置かれる）。経路 A と違い token-not-in-box の性質は無く、下記 codex と同じ security トレードオフが claude にも生じる。

#### 経路 C: サブスク + setup-token（secret 登録で全 box 自動認証・**複数 box / 並列で推奨**）

経路 B の `/login` は box ごとに対話が要る。複数 box を並列で回すなら、**サブスクの長期トークンを一度 secret に登録**しておけば、以降の新規 box は作成時に認証が自動で入る:

```bash
claude setup-token             # host で 1 回 (対話・ブラウザ)。長期トークン sk-ant-oat01-... が出る
sbx secret set -g anthropic    # 出たトークンを貼る (sbx は sk-ant-oat... を OAuth として登録する)
```

`sbx secret ls` が `anthropic (oauth configured)` を示せば登録完了。以降 `sbx create` / `sbx run` した box は **作成時に `~/.claude/.credentials.json` が自動生成**され、`/login` も cp も無しで claude が通る（実機確認: oauth secret 登録後の新規 box で `claude -p` が認証成功）。

- **per-box の操作ゼロ**: 経路 B の box ごと `/login` も、credentials の手動 cp も不要
- **トークンは box 内**: 自動生成される credentials は box の filesystem に入る（経路 B と同じ security トレードオフ）。box の access token は短命（~数時間）で refresh され、土台の長期 setup-token が secret（host keychain）側に残る
- サブスク維持（経路 A の API key と違い API 課金にならない）

> ⚠️ `sbx secret set -g anthropic` に貼るのは **setup-token (`sk-ant-oat01-...`)**。API key (`sk-ant-api...`) を貼ると経路 A（apikey mode・proxy 注入）になる。`--oauth` フラグは anthropic では使えない（経路 B 参照）。
> ⚠️ **未検証**: 多数 box での長時間並列における refresh token のローテーション挙動はストレステストしていない。setup-token は box ごとに独立 mint される想定だが、並列で 401 が出る場合は box ごとに別アカウントか経路 A（API key）にする。

### codex（サブスク、auth.json 転送）

codex の OAuth は claude box では proxy 注入されないため、host の実トークンを box に転送する:

```bash
# 1. host で codex にサブスクログイン (ブラウザ)。~/.codex/auth.json が実トークンを持つ
codex login

# 2. box 作成後、auth.json を box に転送して agent 所有にする
#    (kit は startup で .codex を作らないので、転送先 dir を先に用意する)
sbx exec <box> sudo install -d -o 1000 -g 1000 /home/agent/.codex
sbx cp ~/.codex/auth.json <box>:/home/agent/.codex/auth.json
sbx exec <box> sudo chown 1000:1000 /home/agent/.codex/auth.json
```

codex は転送した auth.json の実トークンで `chatgpt.com/backend-api/codex` に直接話し、`auth.openai.com` で自動 refresh する（mixin が両 host への egress を許可、serviceAuth は付けず proxy が auth header を触らないようにしている）。

> ⚠️ **並列 box の制約**: 同じ `auth.json` を複数 box に転送して並走させると、ある box の token refresh で OAuth provider が **refresh token を rotate** し、他 box / host 側の古い refresh token が invalid になって 401 になりうる。codex を安定して並列実行したい場合は box ごとに別アカウント、または下記の API key 経路にする。

> ⚠️ **security トレードオフ**: auth.json 転送は **codex の実トークン（refresh token 含む）を box の filesystem に置く**。sbx の secret-proxy 分離（secret を box に入れない）を一段緩めるため、乗っ取られた agent がトークンを読み出し/exfil しうる（→ ChatGPT サブスクアカウントへの持続的アクセス）。microVM の hard boundary 自体は不変。claude を**経路 A（API key）**にすれば claude のトークンは box に入らず、box 内の実トークンは codex の 1 つに最小化される（**サブスク経路 B（`/login`）/ C（setup-token）だと claude のトークンも box 内に入る**ため最小化は効かない）。疑わしい挙動時は box 内に置いた実トークンを rotate する: codex は host で ChatGPT を sign out / 再 login、claude をサブスク経路で使っていれば claude.ai でセッションを revoke し、**既存の各 box の `~/.claude/.credentials.json` を破棄（box を作り直す）する**（host secret の更新は今後 provision される box にしか効かず、既存 box に配られたトークンは別途無効化が要る。経路 C なら host で `claude setup-token` を再発行して古いトークンを provider 側で失効させたうえで secret を差し替える ※ 再発行で既存 box 分が一括失効するかは未検証）。課金を分離して安全側に倒すなら codex を OpenAI **API key** にする手もある（その場合は mixin に openai の `serviceDomains`/`serviceAuth` を足して `OPENAI_API_KEY` を proxy 注入する。auth.json 転送は不要になる）。

> ⚠️ global secret（`-g`）は **box 作成時に反映**される。set/変更したら box を作り直す。

## box-primary（基本: 箱の中で回す）

repo ルートで、built-in claude agent + image + codex mixin で起動する:

```bash
sbx run claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit .
```

- agent = built-in `claude`（YOLO `--dangerously-skip-permissions` は built-in claude の entrypoint に組込み済み）。claude が driver で codex を shell out して相互レビューする。
- codex を使う前に上記「codex のサブスク認証」の auth.json 転送を行う。
- `playbook-kit/` は codex egress を足す mixin。kit を変更したら box を作り直す（`sbx rm <name>`）。

## 並列（複数 box で別タスク）

複数 box を並走させるときは **`sbx create`（非対話で作成）→ `sbx run <name>`（attach）の 2 段階**で行う:

```bash
sbx create --name box1 claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit --clone .
sbx create --name box2 claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit --clone .
```

作成後、それぞれ別ターミナルで attach する:

```bash
sbx run box1
```

```bash
sbx run box2
```

- `--clone` = 箱内で repo を private clone（各 box が独立した作業コピーを持ち、並列で衝突しない）。各 box の commit は host 側の `sandbox-<name>` git remote から回収できる
- 同一 repo の `--clone` box は複数並存できる
- claude サブスクを並列で使うなら **経路 C（setup-token を secret 登録）が楽**: 各 box が作成時に credentials を自動取得するので box ごとの操作が要らない。経路 B（`/login`）を使う場合は box ごとに attach 後 login が要る（「認証」参照）
- codex を使う box ごとに auth.json 転送が要る

## HOTL 監視（host から箱を覗く）

箱内 agent を走らせたまま、host から介入せず状態だけ見る:

```bash
sbx ls                                    # 走行状況 / published ports
sbx exec box1 sh -c 'git -C /run/sandbox/source log --oneline -8'   # 進捗を read-only に覗く
```

箱内 dev server を host のブラウザで見る（escape hatch）:

```bash
sbx ports box1 --publish 3000
```

published された host `127.0.0.1:<port>` を host の Chrome で開く。`--clone` 時の repo は箱内 `/run/sandbox/source`。

複数 box の dev server を `web.box1.localhost` / `web.box2.localhost` のように**名前で見分ける**には、publish した host port を Traefik の file provider で振り分ける（port 番号を人が覚えなくて済む）。実動 config と手順は [../tools/parallel-dev/box-routing/](../tools/parallel-dev/box-routing/README.md) 参照。

## 落とし穴

- **`shell` agent への mismatch 警告は想定内**: `sbx create` / `sbx run claude` で `template "coding-agent-playbook-sbx" was built for the "shell" agent but you are using "claude"` が出るが正常。この template の flavor は base 由来の `shell-docker`（中立 base を意図的に選択。`sbx template ls` の FLAVOR 列で確認できる）で、それを built-in `claude` agent で起動するため、sbx の flavor↔agent 整合チェックに引っかかって一般的な注意文を出すだけ（実害の検知ではない）。box は claude agent で正常起動している（`sbx ls` の AGENT 列が `claude`）。警告が促す `sbx run -t ... shell` には**従わない**（shell agent で入ると claude が driver にならず、built-in claude agent 限定の secret proxy 注入も効かなくなる）。
- **コールド起動の transient**: `stopped` の box を `sbx exec` で叩き起こした直後は egress proxy / 箱内 Docker daemon が温まりきっておらず、最初の数秒は egress timeout や DinD コマンド失敗が出ることがある。温まった後は安定する（恒久的な失敗と区別すること）
- **egress allowlist**: 箱内 runtime は default-deny + allowlist（`api.anthropic.com` / `**.github.com` / `registry.npmjs.org` / `docker.io` 等は許可、それ以外は proxy が 403 で能動拒否）。codex 用の `chatgpt.com` / `auth.openai.com` は mixin の `network.allowedDomains` で開ける。build は host network で走るため installer の取得には影響しない
- **nested egress も遮断**: 箱内 Docker で起動した container の直接 egress も VM 境界で遮断され、allowlist を bypass できない
- **box 内に置かれる実トークン**: codex の auth.json（常に）と、claude をサブスク経路 B（`/login`）/ C（setup-token）で使う場合の `~/.claude/.credentials.json`。上述の security トレードオフ参照。これらは box の filesystem にあるため box を信頼できない入力に晒さない（claude を経路 A の API key にすれば claude 側は box 内に入らない）
