// ステートレス署名トークン（docs/design.md §8, §13）。
// SMS 検証後に発行し、以降の API が Bearer で検証。DB/セッション無しで
// ECS の複数タスク auto-scaling と両立（署名鍵は全タスク共有）。

import { createHmac } from 'node:crypto';
import { sign, verify } from 'hono/jwt';
import { createMiddleware } from 'hono/factory';

/** subject 擬似化用の pepper（鍵）。専用が無ければ署名鍵を流用 */
function pepper(): string {
  return process.env.SUBJECT_PEPPER ?? secret();
}

/**
 * JWT の sub に載せる前に電話番号を擬似化する。JWT は base64url で復号可能なため
 * 生の電話番号（PII）を載せない（docs/design.md §8「電話番号ハッシュ」）。
 * 携帯番号空間は小さく素の SHA-256 は辞書で逆引き可能なため、**keyed HMAC**（pepper）
 * を使ってオフライン事前計算を防ぐ。先に数字のみへ正規化し表記揺れを吸収する。
 */
export function hashSubject(phone: string): string {
  const canonical = phone.replace(/\D/g, ''); // ハイフン等を除去
  return createHmac('sha256', pepper()).update(canonical).digest('hex');
}

/** 署名鍵。本番(NODE_ENV=production)で未設定なら fail-fast（既知固定値での署名を防ぐ） */
function secret(): string {
  const s = process.env.TOKEN_SECRET;
  if (s) return s;
  if (process.env.NODE_ENV === 'production') {
    throw new Error('TOKEN_SECRET must be set in production (inject via Secrets Manager)');
  }
  return 'dev-secret-change-me'; // ローカル開発のみのフォールバック
}
const TTL_SEC = 60 * 30; // 30分

export interface AuthClaims {
  /** 本人識別（電話番号。本番ではハッシュ化想定） */
  sub: string;
  /** データ提供同意 ID（consent 後に付与） */
  consentId?: string;
  /** 失効（epoch 秒） */
  exp: number;
}

export async function issueToken(sub: string, consentId?: string): Promise<string> {
  // 文字列 index signature を持つ JWTPayload にそのまま載るオブジェクトリテラルを渡す
  return sign(
    {
      sub,
      ...(consentId ? { consentId } : {}),
      exp: Math.floor(Date.now() / 1000) + TTL_SEC,
    },
    secret(),
    'HS256',
  );
}

/** Bearer トークンを検証し c.get('auth') に claims を載せる。失効/不正は 401 */
export const authMiddleware = createMiddleware<{ Variables: { auth: AuthClaims } }>(
  async (c, next) => {
    const header = c.req.header('Authorization');
    const token = header?.startsWith('Bearer ') ? header.slice(7) : undefined;
    if (!token) return c.json({ error: 'unauthorized' }, 401);
    try {
      const payload = (await verify(token, secret(), 'HS256')) as unknown as AuthClaims;
      c.set('auth', payload);
    } catch {
      return c.json({ error: 'invalid token' }, 401);
    }
    await next();
  },
);

/**
 * データ提供同意済みを要求する（authMiddleware の後段）。consentId claim が無い
 * トークン（SMS 検証直後・未同意）で診断/契約/申込を叩けないようにする。
 */
export const consentMiddleware = createMiddleware<{ Variables: { auth: AuthClaims } }>(
  async (c, next) => {
    if (!c.get('auth')?.consentId) {
      return c.json({ error: 'consent required' }, 403);
    }
    await next();
  },
);
