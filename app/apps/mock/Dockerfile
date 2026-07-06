# Hono mock サーバ（docs/design.md §7, §10）。build context = リポジトリルート。
#   docker build -f apps/mock/Dockerfile -t diag-mock .
FROM node:22-slim AS deps
WORKDIR /app
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
COPY apps/mock ./apps/mock
ENV MOCK_PORT=8787
EXPOSE 8787
CMD ["npm", "run", "start", "--workspace", "@diag/mock"]
