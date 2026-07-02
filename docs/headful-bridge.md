# headful CDP bridge（box から host の見える Chrome を操作する）

box の中の claude（chrome-devtools MCP）から、**host の見える Chrome** を CDP で操作するための opt-in ブリッジ。session を box に維持したまま、独立した可視ブラウザを agent に運転させたいとき用。

通常の box session では chrome-devtools MCP は **box 内の headless Chromium** を動かす（`.mcp.json` の `CDP_HEADLESS` 切替）。本ブリッジはそれと別に、**host 側の headful Chrome** に橋渡しする。

## いつ使うか / 使わないか

- 使う: 「host 画面に見えるブラウザを agent に操作させたい」「人がブラウザの様子を見ながら HOTL したい」
- 使わない: スクショ確認や DOM 取得だけなら **box の headless（既定）** で十分。ブリッジは攻撃面を増やすので必要時のみ。

## ⚠️ セキュリティ（必読）

CDP は**そのブラウザの全権**を与える: 任意ページへ navigate / DOM 読取 / **任意 JS 実行** / **cookie・localStorage・ログイン session の読取** / ダウンロード。

> **最大の危険**: 実 Chrome プロファイルに繋ぐと、box（microVM 隔離）の agent が Gmail / GitHub / AWS 等の**ログイン済み session を実質乗っ取れる**。box-primary の隔離前提が壊れる。

本ブリッジはこれを設計で防ぐ:

| 対策 | 内容 |
|---|---|
| **使い捨て profile（既定）** | host 側は既定で実 profile と別の throwaway `--user-data-dir` を `up` ごとに作り `down` で消す。既知の実ブラウザ profile root（Chrome / Beta / Canary / Chromium / Edge / Brave、symlink も解決して比較）を指す指定は**拒否**する。ただしこの guard は safety net で網羅は不可能なため、`CDP_PROFILE_DIR` を**明示する場合は実 profile を渡さない責任が user 側にある**（明示 dir は auto 削除もされない）。使い捨て profile は creds の無い空ブラウザだが、**box headless と「同等」ではない**（下の注意を参照） |
| **port preflight** | `up` 時に `localhost:<port>` が**既に CDP を喋っていたら中止**する。別プロセス（実 profile の Chrome かも）が port を占有している状態で policy allow すると、使い捨てでない既存ブラウザを box に晒すため |
| **loopback 限定** | host Chrome は `127.0.0.1`、box relay も `127.0.0.1` bind。LAN 露出なし |
| **box scope（任意）** | `CDP_BOX=<box名>` を指定すると egress を `--sandbox` でその box だけに絞る。未指定だと host 上の全 box が relay を張れるため、複数 box を回す時は指定推奨 |
| **tight な policy allow** | `localhost:<port>` のみ許可（`**` ではない） |
| **opt-in / ephemeral** | 既定無効。`up` した時だけ起動、`down` で Chrome 停止 + relay 停止 + **egress rule 削除**まで戻す |
| **committed 設定を汚さない** | `.mcp.json` は変更しない。MCP 接続は `claude mcp add-json`（local scope）で opt-in |

> **⚠️ box headless と「同等リスク」ではない**: 使い捨て profile でも、CDP は **host 上で動く実ブラウザ**を操作する。agent はそのブラウザを `http://localhost:<host のサービス>` や `file://...` に navigate させ、レンダリング結果を CDP で読み取れる。これは box の egress policy（CONNECT トンネルしか gate しない）を**迂回して host ローカルの管理サービス・dev server・ローカルファイルに到達**しうる。box の headless Chromium は microVM 内に隔離されているのでこの経路は無い。host 側に機微なローカルサービスがある環境では、必要時のみ `up` し用が済んだら即 `down` すること。

**運用ルール**: ブリッジした Chrome は「agent のブラウザ」とみなし、**実アカウントでログインしない**こと。終わったら必ず `down`。

## アーキテクチャ（なぜ relay が要るか）

この sbx 環境では box→host の直リンクローカル（`169.254.1.1` / `fe80::1`）は gateway appliance 止まりで **host のサービスに届かない**。box→host は **sbx proxy（`gateway.docker.internal:3128`）経由が唯一の正路**で、`sbx policy allow` で gate される。

一方 puppeteer（chrome-devtools-mcp の中身）は `HTTP_PROXY` を自動では使わない。そこで **box 内に socat 中継**を置き、puppeteer は box localhost（NO_PROXY → 直結）に繋ぎ、socat が proxy の **HTTP CONNECT** で host Chrome までトンネルする:

```text
[box] chrome-devtools-mcp --browser-url http://localhost:9333
        |  (NO_PROXY: box localhost 直結)
        v
[box] socat TCP-LISTEN:9333 -> PROXY(CONNECT) gateway.docker.internal:3128
        |  (sbx policy allow network localhost:9222)
        v
[host] Chrome --remote-debugging-port=9222  (使い捨て profile / loopback / 見える)
```

HTTP（`/json/*`）も WebSocket upgrade も CDP コマンドも、この経路で通ることを実測済み。Chrome は Host ヘッダを `webSocketDebuggerUrl` に反映するので、`localhost:<relay>` で叩けば自己整合し、Host 書き換えや IP リテラル細工は不要。

## 手順（推奨: host で一発）

`--box <box名>` を渡すと、host `up` が **port 自動選択 → 使い捨て Chrome 起動 → egress 許可 → `sbx exec` で box relay 起動 → MCP 登録** まで 1 コマンドで行う。

```bash
# host 側 (box 名は box 内 `echo $SANDBOX_VM_ID` で確認)
bash scripts/cdp-bridge.sh up --box <box名>
# Windows: pwsh scripts/cdp-bridge.ps1 up -Box <box名>
```

- **port 自動選択**: `--port` 未指定なら既定 9222 が埋まっていても空き port を自動で選ぶ（占有 port には触れない＝実 profile の Chrome を晒さない安全性は不変）。固定したいときは `--port 9223`。
- **box relay 自動起動**: `sbx exec <box> bash scripts/cdp-bridge.sh up ...` で box 側 relay を立てる。`--no-connect` で抑止し手動運用に戻せる。

### agent 側の接続（重要な前提）

MCP サーバーは **Claude Code のセッション起動時にしか load されない**（[hot-reload 不可](https://github.com/anthropics/claude-code/issues/46426)）。よって:

- **現行 box セッション**（既に動いている claude）: MCP には反映されない。relay を直接叩いて操作する（`http://localhost:<relay>` の CDP HTTP/WS。例: `curl -X PUT "http://localhost:9333/json/new?<url>"` で navigate）。
- **次に起動する box セッション**: `up --box` が登録した `chrome-devtools-host` MCP が最初から使える（box headless の `chrome-devtools` と並存）。

### 手動（`--box` を使わない / 細かく制御したいとき）

```bash
# 1) host: Chrome 起動 + egress 許可（box relay は張らない）
bash scripts/cdp-bridge.sh up --no-connect --port 9223
# 2) box: relay 起動（host が選んだ port を渡す）
bash scripts/cdp-bridge.sh up --port 9223
# 3) (新セッション用) MCP 登録
claude mcp add-json chrome-devtools-host \
  '{"command":"npx","args":["chrome-devtools-mcp@latest","--browser-url","http://localhost:9333"]}'
```

### 片付け（必須）

```bash
# host: Chrome 停止 + egress rule 削除 + 使い捨て profile 削除 (+ --box/scope があれば box relay も停止)
bash scripts/cdp-bridge.sh down
# Windows host: pwsh scripts/cdp-bridge.ps1 down
# MCP を登録した場合: claude mcp remove chrome-devtools-host
```

`up --box` で張った場合、host `down` は up 時に保存した box scope から box relay も `sbx exec ... down` で畳む。box 単独で畳むなら box 内 `bash scripts/cdp-bridge.sh down`。

## options / env

各オプションは flag（`--port` 等、Windows は `-Port` 等）でも env でも指定でき、**flag > env > 既定**の優先順。

| flag | env | 既定 | 用途 |
|---|---|---|---|
| `--port N` | `CDP_PORT` | `9222`（未指定時は host `up` が空き port を自動選択） | host Chrome の remote-debugging port。明示時は占有なら abort、非明示時は空きを自動 scan |
| `--relay-port N` | `CDP_RELAY_PORT` | `9333` | box relay の listen port |
| `--profile-dir DIR` | `CDP_PROFILE_DIR` | 未指定時は `up` ごとに `mktemp` で作成し `down` で削除 | 使い捨て profile dir。明示時は `down` の auto 削除対象外（user 所有扱い）。既知の実 profile root は guard が拒否するが網羅ではないため、明示する場合は実 profile を渡さないこと |
| `--box NAME` | `CDP_BOX` | 未指定（全 box 許可・relay 手動） | host `up` で (a) egress を `--sandbox <box名>` でその box だけに絞り、(b) `sbx exec` で box relay まで自動起動する |
| `--no-connect` | — | off | host `up` で box relay の自動起動を抑止（Chrome + egress だけ張る） |

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| box `status` が `no` | host で `up` 済みか / `sbx policy ls` に `localhost:<選択された port>` allow があるか確認（port は host `status` で表示。auto 選択時は 9222 とは限らない） |
| `relay 起動。ただし host Chrome 未到達` | host Chrome が落ちている or policy 未許可。host `status` で確認 |
| `CDP_PROFILE_DIR が実ブラウザ profile を指しています` | 安全 guard。別 dir を指定（既定のまま推奨） |
| `localhost:<port> で既に別プロセスが CDP を listen しています` | `--port` を**明示**したのにその port が占有されている時だけ出る（明示意図を尊重して abort）。閉じるか別 `--port` を指定。`--port` 非明示なら自動で空き port に逃げるのでこのエラーは出ない |
| egress rule が残る | `sbx policy ls` で `localhost:<選択された port>` を探して削除（`down` が自動削除を試みる。port は host `status` で確認） |
| Windows host で `socat` が無い | relay（box 側）は Linux box 内で bash 実行が前提。host 側 `up/down` のみ PowerShell で使う |
