# sbx カスタム image / kit

[Docker Sandboxes (`sbx`)](https://docs.docker.com/ai/sandboxes/) で coding agent を **microVM-per-agent の hypervisor 境界**の中で動かすための、playbook の実行基盤。安全に並列化した coding agent / HOTL (Human-On-The-Loop) 運用の土台。

中立な `shell-docker` base の image に **claude と codex を同居**させ、**built-in claude agent** で起動して箱の中で claude が codex を呼んで**相互レビュー**できる構成。採用に至った検証と方針は [docs/decisions/parallel-hotl-execution.md](../docs/decisions/parallel-hotl-execution.md)（Accepted）を参照。

## なぜ sbx か（hard boundary）

自作 firewall ベースのサンドボックス（旧 `.devcontainer/`、撤去済み）は defense-in-depth であって hard boundary ではない（箱内の `node` が root sudo / docker 権限を持ち、乗っ取られた agent が egress を破壊しうる）。承認ゲートを外して並列で回す HOTL では監視が薄くなるため soft boundary は構造的に不足する。sbx は microVM-per-agent の hypervisor 境界を中核とし、VM 内 root でも破れない hard boundary を持つ。

## なぜ built-in claude agent + codex mixin か

secret の proxy 注入（トークンを box に入れず host で auth header を注入）は **agent positional が Docker built-in agent に解決される時だけ** sbx が host 側で provisioning する。custom (`kind: sandbox`) agent では claude / codex とも secret の placeholder が登録されず proxy 注入が効かない（実機検証で確認）。なお **anthropic で proxy 注入の対象になるのは API key のみ**で、サブスク (Pro/Max) は proxy 注入ではなく **どれか 1 box で箱内 `/login`** して認証する。`/login` の OAuth token 応答を sbx の proxy が intercept して実トークンを host store に保持し、以降の新規 box には sentinel credentials が自動 provision される（v0.34.0 時点。実トークンは box に入らず sentinel のみ。後述「認証」）。そこで:

- **base image は中立な `shell-docker`**（`claude-code-docker` を base にすると claude が特権化する）。claude / codex / chrome を image に bake し、`-t` で渡す。
- **agent は built-in `claude`**（`sbx run claude`）。built-in agent だと sbx が secret を proxy 注入できる（**API key** は host で auth header を注入しトークンは box に入らない）。**サブスク (Pro/Max) は proxy 注入ではなく、初回にどれか 1 box で `/login` すれば以降の新規 box は sentinel credentials が自動 provision される**（v0.34.0 時点。実トークンは box に入らず sentinel のみ。後述「認証」）。
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

claude は **2 経路**（v0.34.0 時点）。**推奨はサブスク (Pro/Max)** — 初回にどれか 1 box で `/login` すれば、以降の新規 box は per-box 操作ゼロで自動認証される。サブスクを持たない / API 課金にしたいなら **API key**。**どちらも実トークンは box 内に入らない**（host store / host keychain が保持し、box には sentinel のみ）。

#### 推奨: サブスク (Pro/Max)（初回 1 box で `/login`・以降自動 provision・token-not-in-box）

複数 box を並列で回しても、サブスク認証は **最初の 1 回だけ**。どれか 1 box で `/login` すると、その OAuth token 応答（`platform.claude.com/v1/oauth/token`）を sbx の proxy が intercept して **実トークンを host 側 store に保持**し、box には sentinel 値の `~/.claude/.credentials.json` だけを残す。**以降 `sbx create` / `sbx run` した新規 box は作成時に sentinel credentials が自動 provision され、`/login` も cp も無しでサブスクとして通る**（refresh も proxy が sentinel を実トークンに差し替えて代行する）。

```bash
sbx run <box>      # claude が起動したら /login (claude.ai OAuth、対話。最初の 1 box だけ)
```

- **per-box の操作ゼロ**: 2 個目以降の box は `/login` も credentials の手動 cp も不要
- **token-not-in-box**: box にあるのは sentinel のみで、実トークンは host store が保持し proxy が API call 時に差し替える（下記 API key 経路と同じく box に実トークンが入らない。旧版が経路 B/C の欠点として書いていた「OAuth トークンが box 内に保存される」性質は v0.34.0 で解消）
- **host store は box より長命**: `/login` した box を含め box を全部消しても host store は残り、次に作る box に provision され続ける（login した box 自体の削除は他 box の provisioning に影響しない）
- サブスク維持（API key と違い API 課金にならない）

> ⚠️ **サブスクを使うなら anthropic を `sbx secret set` に登録しない**（v0.34.0）。`claude setup-token` (`sk-ant-oat01-...`) を貼っても **apikey 型の service secret として登録**され（`sbx secret ls` はマスク表示になる）、新規 box は `SBX_CRED_ANTHROPIC_MODE=apikey` + apiKeyHelper 注入になって proxy が x-api-key として注入するため、`claude -p` が「Invalid API key · Fix external API key」で失敗する。サブスクの全 box 自動認証は上記 `/login` seeding が担うので、secret 登録は不要（むしろ有害）。
>
> ℹ️ **旧手順から移行する場合**: 既に `sbx secret set -g anthropic` で setup-token / API key を登録済みなら、単に「登録しない」だけでは移行にならない（残った secret が新規 box を apikey mode に固定し続ける）。`/login` seeding に移る前に **`sbx secret rm -g anthropic` で削除してから box を作り直し**、最初の box で `/login` する。この rm は seeding 開始**前**に行うこと — 一度 `/login` seeding を回した後の rm は既存 box の認証を壊す（後述「落とし穴」）。

#### 代替: API key（proxy 注入・token-not-in-box）

```bash
sbx secret set -g anthropic   # API key (sk-ant-api...) を貼る
```

built-in claude agent が API key を proxy 注入する。secret は host keychain に保存され、box 内は sentinel 値のみ（`SBX_CRED_ANTHROPIC_MODE=apikey`、実トークンは box に入らない）。サブスクでなく API 課金にする / サブスクを持たない場合に使う。

> ℹ️ `sbx secret set --oauth` フラグは v0.34.0 では **openai 専用**（`sbx secret set --help` に "(openai/global only)" と明記）。anthropic には使えない（サブスクは上記 `/login` seeding で認証する）。

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

> ⚠️ **security トレードオフ**: auth.json 転送は **codex の実トークン（refresh token 含む）を box の filesystem に置く**。sbx の secret-proxy 分離（secret を box に入れない）を一段緩めるため、乗っ取られた agent がトークンを読み出し/exfil しうる（→ ChatGPT サブスクアカウントへの持続的アクセス）。microVM の hard boundary 自体は不変。**claude 側は API key・サブスク (`/login`) いずれも token-not-in-box（v0.34.0 時点。box には sentinel のみ、実トークンは host store / host keychain 側）なので、box の filesystem に置かれる実トークンは codex の auth.json ひとつに絞られる**。疑わしい挙動時は、codex を host で ChatGPT を sign out / 再 login して box 内 auth.json を rotate し box を作り直す。claude はサブスクなら claude.ai 側でセッションを revoke（box に実トークンが無いので box 側 credentials の破棄は不要）、API key なら key を rotate すれば足りる。課金を分離して安全側に倒すなら codex を OpenAI **API key** にする手もある（その場合は mixin に openai の `serviceDomains`/`serviceAuth` を足して `OPENAI_API_KEY` を proxy 注入する。auth.json 転送は不要になる）。

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
- claude サブスクを並列で使うなら **最初の 1 box で `/login` するだけ**（v0.34.0）: 以降の新規 box は作成時に sentinel credentials が自動 provision されるので、box ごとの login も cp も要らない（「認証」参照）
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
- **box 内に置かれる実トークン**: codex の auth.json（常に）。**claude は API key・サブスク (`/login`) いずれも token-not-in-box（v0.34.0 時点。box には sentinel のみ、実トークンは host store / host keychain 側）** なので、box の filesystem に置かれる実トークンは codex の auth.json ひとつ。上述の security トレードオフ参照。box を信頼できない入力に晒さない
- **`sbx secret rm -g anthropic` は OAuth store も一緒に消す（v0.34.0）**: `sbx secret rm --help` が "OAuth and/or API key" と明記するとおり、`/login` seeding で保持している既存の全 box 分の sentinel→実トークン マッピングを失わせ、**既存 box の認証が即時に切れる**（次の API call で 401 → box 内 claude が credentials を破棄して「Not logged in · Please run /login」になる）。復旧は box ごとに `/login` し直すか box を作り直す。サブスクを `/login` seeding で回している間は anthropic secret に触らない
