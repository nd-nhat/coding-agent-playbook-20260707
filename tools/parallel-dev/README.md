# 並列開発リファレンス（Traefik）

複数の branch / サービスを **同時に・port 番号を取り合わずに** 動かすための最小リファレンス。
共有の Traefik（リバースプロキシ）が `:80` を 1 つだけ公開し、**Host 名で振り分ける**。

## URL の規約

```
<service>.<repo>-<branch>.localhost
```

- 例: `web.coding-agent-playbook-stage-02.localhost` / `api.coding-agent-playbook-stage-02.localhost`
- **branch ごと**に名前空間が分かれるので、別 branch を並列に立てても URL が衝突しない
- 1 つの app に複数サービスがあれば **`web.` / `api.` でサブドメイン区切り**
- `*.localhost` は主要ブラウザが標準で loopback に解決するため **hosts 編集不要**（Mac / Windows / Linux 共通）

## 使い方

### 1. 共有プロキシを 1 回だけ起動

```bash
docker network create traefik-public   # 既にあればスキップ（エラーになるだけ）
docker compose -f tools/parallel-dev/proxy.compose.yml up -d
```

branch ごとに Traefik を立てると `:80` が衝突するため、proxy は 1 つだけ共有する。共有ネットワークは `traefik-public`。

> **既に shared Traefik（`traefik-public` を使うもの）が稼働している環境では、この手順 1 はスキップ**。
> 既存 proxy が `--providers.docker.network=traefik-public` で動いていれば、下の stack を起動するだけで routing される。

### 2. branch ごとに app スタックを起動

`STACK=<repo>-<branch>` を渡す（branch の `/` は `-` に置換）。`-p` も同じ値にして branch ごとに分離する。

```bash
STACK="$(basename "$(git rev-parse --show-toplevel)")-$(git rev-parse --abbrev-ref HEAD | tr '/' '-')"
STACK="$STACK" docker compose -p "$STACK" -f tools/parallel-dev/stack.compose.yml up -d
```

→ `http://web.$STACK.localhost` / `http://api.$STACK.localhost` をブラウザで開く。

別 worktree（別 branch）で同じ 2 コマンドを実行すれば、その branch 用の URL が増えるだけ（並列で衝突しない）。

### 片付け

```bash
STACK="<repo>-<branch>" docker compose -p "<repo>-<branch>" -f tools/parallel-dev/stack.compose.yml down   # その branch のスタック
docker compose -f tools/parallel-dev/proxy.compose.yml down                                               # 共有プロキシ（自分で起動した場合のみ）
```

> `:80` が他で使われている場合は `proxy.compose.yml` の `ports` を `8080:80` 等に変える（URL は `...localhost:8080`）。

## 自分のアプリに差し替える

`stack.compose.yml` の `traefik/whoami` を自分の build に置き換え、`server.port` を listen する port に合わせるだけ:

```yaml
  web:
    build: ./web
    networks: [traefik-public]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${STACK}-web.rule=Host(`web.${STACK}.localhost`)"
      - "traefik.http.services.${STACK}-web.loadbalancer.server.port=3000"
```

> DB 等の内部サービスは `traefik-public` に出さず、別途 internal network を足してそこに繋ぐ（公開は web/api だけ）。

## YOLO サンドボックスとの関係

- Traefik に渡す `docker.sock` は **ホスト側の通常 docker** を `:ro` で渡すだけで、sbx の box
  （microVM・独自 docker daemon）の **中ではない**。隔離境界は侵さない。
- box 内で動かすアプリを名前ルーティングしたい場合は、box の port を `sbx ports <box> --publish` で **host に出してから** host の Traefik に載せる。box 内 container は独自 docker daemon（microVM）の中なので、host の `traefik-public` ネットワークには直接は繋がらない。
- この docker provider（label）方式は host docker 上の container しか拾えず、host に publish しただけの box port は対象外。box port を名前ルーティングする実動 config は [box-routing/](box-routing/README.md)（file provider 方式）を使う。
