# CI workflows

本リポは現在 **private repo** のため、GitHub Actions の無料分消費を避けて lint 系 workflow (`actionlint.yml` / `shellcheck.yml` / `python-syntax.yml` / `ps1-ascii.yml`) を **`on: workflow_dispatch`** のみで定義している (= push / pull_request では自動実行されない、Actions タブから手動 trigger でのみ走る)。`pages.yml` は例外で、下記「GitHub Pages (`pages.yml`) の有効化」の通り `slides/**` 限定の `push` trigger を有効にしている (1 run の実行時間が小さく private repo でも課金影響が軽微なため)。

## 規範: main の workflow は branch ゲート必須

`stage/*` は main の全ツリー（この `.github/workflows/` 含む）を持つ stacked 連鎖のため（[../../docs/decisions/stage-stacked-branches.md](../../docs/decisions/stage-stacked-branches.md)）、**main に push trigger の workflow を足すときは `branches: [main]`（または適切な branch filter）を必ず付ける**。付けないと restack 後の stage push で意図しない workflow が走る。app の CI（`ci.yml`）は stage 側にのみ存在し `branches: [stage/**]` + `paths: [app/**]` でフィルタする。配置は **app が npm project になる stage（`04-mvp` 以降）**のみ — `01`–`03` は app が docs だけで `npm ci` が成立しないため置かない。

## TODO: public 化時の有効化手順 (lint 系 workflow)

本リポを public にする (または private のまま lint 系 workflow も自動実行したくなった) とき、`actionlint.yml` / `shellcheck.yml` / `python-syntax.yml` / `ps1-ascii.yml` の `on:` を以下のように書き換える (`pages.yml` は既に push trigger 済みのため対象外):

```yaml
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
```

これで PR ごとに自動実行されるようになり、CLAUDE.md `## 開発フロー` Step 4 の "CI gate" が空っぽ ("no checks reported") にならない構成になる。

## workflow 一覧

| workflow | 対象 | 目的 |
|---|---|---|
| [`actionlint.yml`](actionlint.yml) | `.github/workflows/*.yml` | workflow yaml 自身の syntax / common pitfall を check |
| [`shellcheck.yml`](shellcheck.yml) | 全 tracked `*.sh` (`scripts/` + `examples/`) | bash script の static analysis (cross-platform 要件のため重要) |
| [`python-syntax.yml`](python-syntax.yml) | 全 tracked `*.py` + triage-lambda unittest | 全 Python の syntax を `py_compile` で check + stdlib unittest (boto3 不要) で correctness を常時検証 |
| [`ps1-ascii.yml`](ps1-ascii.yml) | 全 tracked `*.ps1` | PowerShell script が ASCII only か check (Windows PowerShell 5.1 の BOM-less ANSI 読み対策、cross-platform 要件) |
| [`pages.yml`](pages.yml) | `slides/` | 講義スライドを GitHub Pages に配信 (deploy 系。lint とは別軸。`push` (`slides/**` 限定) + `workflow_dispatch`) |

## GitHub Pages (`pages.yml`) の有効化

`pages.yml` は lint 系と違い**デプロイ** workflow。配信するには repo owner が一度だけ **Settings > Pages > Build and deployment > Source = "GitHub Actions"** に設定する必要がある (trigger 種類に関わらず必須の手動操作)。private repo での Pages 配信は GitHub Team / Enterprise plan が必要 (無料 org plan では有効化時にエラーになる)。

trigger は `slides/**` (と本 workflow 自身) の変更に限定した `push` + 手動確認用の `workflow_dispatch` の両方を有効にしている。lint 系 workflow と異なり `workflow_dispatch` only にしていない理由: 1 run の実行時間が静的ファイルの deploy のみで小さく、`paths:` で無関係な push を弾いているため private repo の Actions 無料分消費への影響が軽微。

`deploy` job には `if: github.ref == 'refs/heads/main'` のガードがあるため、`workflow_dispatch` で main 以外の ref を指定して手動実行すると job が skip され配信されない (誤って非 main ref を公開しないための安全策)。

## 設計判断 (lint 系 workflow はなぜ `workflow_dispatch` only か)

- 案 A (yaml を書かず doc のみ): 将来 yaml を 0 から書くコストが残る
- 案 B (`_disabled/` 配下に置く): yaml 配置が非標準で、有効化に `git mv` が必要
- **案 C 採用 (本構成)**: `.github/workflows/` 直下に置く + `workflow_dispatch:` のみ = trigger 書き換え 1 行で有効化可、UI で workflow の存在も見える

`workflow_dispatch` は **手動 trigger を可能にする** ので、整備の動作確認をしたいときは Actions タブから走らせて自分で課金できる。
