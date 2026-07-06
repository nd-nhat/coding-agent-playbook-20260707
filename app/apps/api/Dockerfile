# Hono API（docs/design.md §10）。build context = リポジトリルート（monorepo）。
#   docker build -f apps/api/Dockerfile -t diag-api .
FROM node:22-slim AS deps
WORKDIR /app
# 依存解決のため lockfile と各 workspace の package.json を先に取り込む（キャッシュ効率）
COPY package.json package-lock.json tsconfig.base.json ./
COPY packages/core/package.json ./packages/core/
COPY apps/api/package.json ./apps/api/
COPY apps/mock/package.json ./apps/mock/
COPY apps/web/package.json ./apps/web/
COPY infra/package.json ./infra/
RUN npm ci

FROM node:22-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json package-lock.json tsconfig.base.json ./
COPY packages/core ./packages/core
COPY apps/api ./apps/api
ENV API_PORT=8788
EXPOSE 8788
# tsx で TS を直接実行（@hono/node-server。常駐コンテナ）
CMD ["npm", "run", "start", "--workspace", "@diag/api"]
