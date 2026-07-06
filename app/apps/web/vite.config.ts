import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// dev: /api/* を backend(apps/api) へ proxy。本番は CloudFront が同パスを ALB へ振る。
export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    host: true, // 0.0.0.0 で listen（コンテナ/別マシンの外から dev server に到達可能にする）
    allowedHosts: ['.localhost'], // *.localhost のリバースプロキシ経由アクセスを許可（Vite の既定ブロック回避）
    proxy: {
      '/api': {
        target: process.env.API_PROXY_TARGET ?? 'http://localhost:8788',
        changeOrigin: true,
      },
    },
  },
});
