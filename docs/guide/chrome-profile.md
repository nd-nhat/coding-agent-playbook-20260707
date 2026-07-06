# chrome-profile MCP の運用手順（起動・ログイン・片付け）

host session の claude から、**ログイン状態を保持した専用 profile の headful Chrome** を操作するための MCP。用途は **WebFetch / curl では取れないもの**（ログイン必須のページ、bot 判定で塞がれるサイト）の取得・操作。壁打ちフェーズの「Chrome を agent に運転させる」の実体がこれ。

本 doc は**人間向けの運用手順**。agent がどの経路（chrome-devtools / chrome-profile / cdp-bridge）をいつ選ぶかの routing と、chrome-profile 使用時の agent 規範（prompt injection 前提・検証用アカウント限定・使用後 down）は [rules/chrome-devtools.md](../../rules/chrome-devtools.md) が SoT。

committed `.mcp.json` の `chrome-profile` server が `http://127.0.0.1:9335` の**起動済み Chrome に接続する**だけ（`--browser-url`。MCP 自身は Chrome を起動しない）。Chrome の上げ下げは helper が行う。

## 手順

1. **Chrome 起動**（host）:

   ```bash
   bash scripts/chrome-profile.sh up
   # Windows: pwsh scripts/chrome-profile.ps1 up
   ```

2. **人間がログイン**（初回・session 切れ時のみ）: 開いた Chrome の窓で、対象サイトに**検証用アカウント**でログインする（乗っ取られても失って困らないものだけ。実アカウント・機微サイトは禁止 — 理由は [rules/chrome-devtools.md](../../rules/chrome-devtools.md)）。profile は persistent なので次回 `up` でもログインが残る
3. **claude session を起動**: `.mcp.json` の `chrome-profile` MCP が load される（**MCP は session 起動時にしか load されない**ため、既に走っている session には反映されない。その session で使いたければ session を立て直す）
4. **agent に頼む**: 「chrome-profile で `<URL>` を開いて本文を取って」等。`mcp__chrome-profile__navigate_page` / `take_snapshot` / `evaluate_script` 等が使える
5. **片付け**:

   ```bash
   bash scripts/chrome-profile.sh down    # profile は残る (ログイン状態は次回に持ち越し)
   ```

## options

| flag | env | 既定 | 用途 |
|---|---|---|---|
| `--port N`（Windows: `-Port N`） | `CHROME_PROFILE_PORT` | `9335` | Chrome の remote-debugging port。profile dir も port ごとに分離されるので、別 port で 2 個目の profile を並走できる |

`.mcp.json` の `chrome-profile` は 9335 固定なので、別 port の profile を claude から使うには local scope で追加登録する（committed 設定は変えない）:

```bash
claude mcp add-json chrome-profile2 \
  '{"command":"npx","args":["chrome-devtools-mcp@latest","--browser-url=http://127.0.0.1:9336"]}'
```

profile の実体は `~/.cache/coding-agent-playbook/chrome-profile-<port>/`（Windows は `%LOCALAPPDATA%`）。ログイン状態ごと捨てたくなったら Chrome を down してからこの dir を手で消す。

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| tool call が接続エラー（Chrome に届かない） | `bash scripts/chrome-profile.sh status`（Windows: `pwsh scripts/chrome-profile.ps1 status`）で CDP 応答を確認。`no` なら `up` する。box 内なら仕様（host session 専用） |
| `chrome-profile` MCP がツール一覧に居ない | MCP は session 起動時 load。`up` してから claude session を立て直す |
| `localhost:9335 は CDP 以外のプロセスが使用中` | 別サービスが port を占有。`--port 9336` 等で回避（MCP 側は上記 `claude mcp add-json` で別登録） |
| `別プロセスが CDP を listen しています` で up が中止 | 本 helper 以外の Chrome（実 profile の可能性）が port を占有。安全 guard なのでそのブラウザを閉じるか `--port` で回避 |
| ログインが毎回切れる | サイト側の session 期限。profile 自体は残っているので再ログインだけでよい |
| ログイン状態を破棄したい | `down` してから profile dir（上記）を削除 |
