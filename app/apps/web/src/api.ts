// Hono RPC クライアント（docs/design.md §3, §8）。backend の AppType から
// 型付きクライアントを生成。/api/* は dev では Vite proxy → apps/api。
import { hc } from 'hono/client';
import type { AppType } from '@diag/api';

export const client = hc<AppType>('/');

/** Bearer ヘッダを作る */
export const auth = (token: string) => ({ headers: { Authorization: `Bearer ${token}` } });
