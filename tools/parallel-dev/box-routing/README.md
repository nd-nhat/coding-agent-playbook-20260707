# box ルーティング（sbx box → host → Traefik）

> このディレクトリの publish + 経路生成を自動化したのが `scripts/dev.sh route` subcommand（`up` / `add <box> [port] [name]` / `rm <name>` / `ls` / `down` / `detect`、Windows は `scripts/dev.ps1 route`）。以下は**何が起きているか**のリファレンス。

sbx box の中で動かす dev server を、host から **Host 名で振り分ける**ための最小リファレンス。
親ディレクトリの [../README.md](../README.md) は host docker 上の compose stack（docker provider / label）を
対象にするが、box 内 dev server は **microVM の独自 docker daemon の中**で動き host の `traefik-public`
network に直結できないため、docker provider では拾えない。そこで box の port を host に publish し、
Traefik の **file provider** で振り分ける。

## 前提

- **Docker Desktop（macOS / Windows）を想定**。`sbx ports --publish` は host の `127.0.0.1:<port>`（loopback）に出すため、container から到達するのに `host.docker.internal` を使う。Docker Desktop はこれを host の loopback に解決する。
- **Linux ネイティブ Docker Engine の注意**: `host.docker.internal:host-gateway` は bridge gateway IP（例 `172.17.0.1`）に解決され、`127.0.0.1` のみで listen する publish 先には届かず **502** になる。Linux では publish を全 interface に出す（`sbx ports <box> --publish 0.0.0.0:18001:3000`。`sbx ports` は `[[HOST_IP:]HOST_PORT:]SANDBOX_PORT` 形式で HOST_IP を取れる）と、bridge gateway IP 経由で届くようになる。または proxy を `network_mode: host` で起動して dynamic config の url を `http://127.0.0.1:<port>` にする。
- **`:80` は親 proxy と共用不可**: この proxy は親 `../proxy.compose.yml`（docker provider）と同じ `:80` を bind する。両者は別シナリオ（docker provider stack か box publish port か）の **代替**で、同時起動はできない。box port をルーティングするときは親 proxy を止めてこちらを使う（または `ports` を `8088:80` 等に変える）。

## URL の規約

```
<name>.localhost
```

- `<name>` は hostname 全体を表すドット区切りの DNS ラベル列。`scripts/dev.sh route add <box>` の既定は **`web.<branch>.<repo>`**（現 checkout 由来の web preview）→ `web.<branch>.<repo>.localhost`
- web 以外の service を公開する場合は先頭ラベルで表現する（例: `route add <box> 8788 api.myapp` → `api.myapp.localhost`。service 種別の prefix は固定しない）
- branch / repo で名前空間が分かれるので、複数 box / 複数 stage を並列に立てても URL が衝突しない
- `*.localhost` は主要ブラウザが標準で loopback に解決するため hosts 編集不要

## 使い方

以下の §2 / §3 は **このディレクトリを cwd として**実行する（親 README は repo ルート基準のフルパスだが、本手順は相対パス前提）:

```bash
cd tools/parallel-dev/box-routing
```

### 1. box の port を host に publish

```bash
sbx ports <box> --publish 18001:3000   # box の web(3000) を host:18001 に出す
```

### 2. dynamic config を置く

`boxes.example.yml` を `dynamic/` にコピーし、box 名と publish した host port に書き換える:

```bash
cp boxes.example.yml dynamic/box1.yml
# dynamic/box1.yml の Host(...) と host.docker.internal:<port> を編集
```

box を増やすときは router + service のペアを足す（または box ごとに 1 ファイル）。

### 3. プロキシを起動

```bash
docker compose -f proxy.compose.yml up -d
```

→ dynamic config の `Host(...)` に書いた hostname（例 `http://web.box1.localhost`）をブラウザで開く。`dynamic/` は watch されているので、
publish と dynamic config の追加だけで box を増やせる（プロキシ再起動不要）。

### 片付け

```bash
docker compose -f proxy.compose.yml down
sbx ports <box> --unpublish 18001:3000
```

## モード（baseline / 自前 Traefik / 既存の共有 Traefik に相乗り）

ルーティングは**オプション層**で、3 通りある。`scripts/dev.sh route` subcommand は後者2つを扱う。

1. **baseline（Traefik なし）**: 名前付き URL が要らないなら Traefik は不要。`sbx ports <box> --publish <port>:<port>` で `http://127.0.0.1:<port>` を直接開く（`localhost` は macOS 等で IPv6 `::1` に先に解決され sbx の IPv6 forward が reset して開けないことがある）。**最も単純で全員が使える**。
2. **自前 Traefik（既定・`dev.sh route up`）**: `:80` が空いていて名前付き URL が欲しい場合。本ディレクトリの proxy を立て、`<name>.localhost` で見る。
3. **既存の共有 Traefik に相乗り（自動検出）**: ホストに既に Traefik が `:80` で居る場合（複数 project を 1 本で捌くのが定石）。`:80` は 1 本しか bind できないので自前は立てず、**その Traefik の file provider 供給先へ経路を出し入れ**する。`dev.sh route` が **:80 の file-provider Traefik を自動検出**するので env 指定なしで使える:

   ```bash
   bash scripts/dev.sh route add <box>   # :80 の共有 Traefik を自動検出して相乗り（up 不要）
   bash scripts/dev.sh route detect      # 検出結果（供給先 volume/dir）を確認
   ```

   検出: `docker ps` で `:80` を publish する image 名に `traefik` を含む container を探し、CLI 引数 `--providers.file.directory=<dir>` と、その dir を destination に持つ mount（named volume / bind source）を引く。**config file で file provider を設定した Traefik 等、自動検出できない構成**は env で供給先を明示:

   ```bash
   BOX_ROUTING_DYNAMIC_DIR=<dir>    bash scripts/dev.sh route add <box>   # bind dir watch
   BOX_ROUTING_DYNAMIC_VOLUME=<vol> bash scripts/dev.sh route add <box>   # named volume watch
   ```

   相乗り時は `up`/`down` が no-op（共有 Traefik は管理しない）、`add`/`rm`/`ls` だけが供給先を操作（共有 Traefik 側の設定変更は不要）。複数 project で供給先を共有するため `<name>` はグローバルに一意に（既定 `web.<branch>.<repo>` は repo を含み衝突しにくい）。`rm` は `# box` marker 付き（本 subcommand 由来）のみ削除し手書き config を誤って消さない。

## 親リファレンスとの使い分け

| | [../](../README.md)（docker provider） | 本ディレクトリ（file provider） |
|---|---|---|
| ルーティング対象 | host docker 上の compose stack（label で自動検出） | sbx box が host に publish した loopback port |
| port | container port を Traefik が docker network 経由で参照 | `sbx ports --publish` の host port を `host.docker.internal` 経由で参照 |
| 用途 | host で直接立てる並列 dev | box-primary（YOLO 隔離）で立てる並列 dev |
