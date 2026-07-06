# ワンタップ実データ診断 MVP

電力データ活用制度のスマートメーター30分値を、**SMS認証 + データ提供同意だけ**で取得し、市場連動プランの料金診断（過去12ヶ月バックテスト）を提示するフルスタック MVP。

- 企画: [one-pager.md](one-pager.md)
- 設計: [docs/design.md](docs/design.md)（本実装はこれに準拠）

## 構成（monorepo / npm workspaces）

```
apps/
  web/    Vite + React + TS の SPA（useReducer 状態機械 + Recharts）
  api/    Hono backend（BFF + 診断エンジン呼び出し + 外部連携アダプタ + 署名トークン）
  mock/   Hono mock サーバ（協会 power-data / SMS / JEPX を擬似 + 決定的サンプルデータ）
packages/
  core/   共有: ドメイン型 + Zod 契約 + 診断エンジン（純TS）+ プラン定数
infra/    AWS CDK（ECS Fargate + internal ALB + S3 + CloudFront）
```

データの流れ: ブラウザ → backend API（診断計算）→ 外部連携アダプタ → mock（or 実 API）。frontend は計算を持たず API を叩く。型は Hono RPC（`hc<AppType>`）で backend → frontend に共有。

## 必要環境

- Node.js **22.12+**（LTS）

## ローカル開発

```bash
npm install

# 3 つ（mock / api / web）をまとめて起動
npm run dev
# → web:  http://localhost:3000
#   api:  http://localhost:8788（Vite が /api を proxy）
#   mock: http://localhost:8787
```

`123456` を SMS 認証コードに入力するとデモが進む（[docs/design.md §7](docs/design.md#7-外部連携と-mock-サーバappsmock)）。

### コンテナで動かす（mock + api）

```bash
docker compose up --build      # mock:8787 / api:8788
npm run dev:web                # web は Vite で別途
```

## テスト / 型検査 / ビルド

```bash
npm test           # 診断エンジンの単体テスト（packages/core）
npm run typecheck  # 全 workspace の型検査
npm run build      # web の本番ビルド（apps/web/dist）
```

## 環境変数

実行時に読む env 変数。**ローカル開発はすべて既定のまま動く**。本番（`NODE_ENV=production`）では `TOKEN_SECRET` だけが必須。未設定でも起動と `/health` は通ってしまい、認証 API だけが全滅する（トークン発行は 500・検証は 401）ので、health check の green を設定済みの根拠にしないこと（CDK deploy では Secrets Manager から自動注入される）。

| 変数 | 対象 | 既定 | 必須/任意 | 説明 |
|------|------|------|-----------|------|
| `TOKEN_SECRET` | api | dev 用の固定値 | 本番のみ必須 | 署名トークン（JWT）の鍵。ローカルでは dev 値に fallback、`NODE_ENV=production` では未設定なら認証 API がリクエスト時にエラー（発行 500 / 検証 401） |
| `SUBJECT_PEPPER` | api | `TOKEN_SECRET` の値 | 任意 | 電話番号を HMAC で擬似化する際の pepper。未設定なら署名鍵を流用 |
| `EXTERNAL_BASE_URL` | api / infra | api: `http://localhost:8787`（mock）/ infra: mock service の internal ALB DNS | 任意 | 外部連携アダプタの接続先 base URL。実 API への切替はこれを差し替えるだけ（[docs/deploy.md §4](docs/deploy.md#4-外部連携先の切替任意)） |
| `EXTERNAL_TIMEOUT_MS` | api | `8000` | 任意 | 外部呼び出しのアプリ側 deadline（ミリ秒） |
| `API_PORT` | api | `8788` | 任意 | api の listen ポート |
| `NODE_ENV` | api | （未設定） | 任意 | `production` で `TOKEN_SECRET` の dev 値への fallback を無効化（未設定なら認証 API がエラーに） |
| `MOCK_PORT` | mock | `8787` | 任意 | mock の listen ポート |
| `API_PROXY_TARGET` | web（dev） | `http://localhost:8788` | 任意 | Vite dev server が `/api` を proxy する向き先 |
| `VITE_DEMO` | web | （未設定 = デモ表示） | 任意 | `false` で SMS 画面の固定コードのヒント表示を隠す（build 時に埋め込み） |
| `CDK_DEFAULT_ACCOUNT` / `CDK_DEFAULT_REGION` | infra | AWS 認証情報から / `ap-northeast-1` | 任意 | CDK の deploy 先 account / region |

## デプロイ（AWS / CDK）

[docs/design.md §10](docs/design.md#10-aws-構成--デプロイinfracdk) の構成（S3+CloudFront / ECS Fargate internal ALB / VPC Origin）。
**認証（SSO）・bootstrap・teardown まで含む手順は [docs/deploy.md](docs/deploy.md)**。

クイック実行（先に `apps/web/dist` を build して `BucketDeployment` に渡す）:

```bash
npm run build --workspace @diag/web   # apps/web/dist を生成
cd infra && npx aws-cdk deploy        # 要 AWS 認証情報・CDK bootstrap
```

> デモのため SMS・スマートメーター・市場価格・契約・申込はすべて mock。実 API への切替は backend の `EXTERNAL_BASE_URL` を差し替えるだけ（本番境界の seam）。
