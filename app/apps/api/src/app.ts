// Hono backend（docs/design.md §8）。BFF + 診断エンジン + 外部連携アダプタ。
// routes を chain して AppType を export → frontend が Hono RPC で型共有。

import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { HTTPException } from 'hono/http-exception';
import { zValidator } from '@hono/zod-validator';
import {
  diagnose,
  CURRENT_PLAN,
  MARKET_PLAN,
  zSmsSendRequest,
  zSmsVerifyRequest,
  zApplicationRequest,
} from '@diag/core';
import { external, ExternalError } from './external.ts';
import { issueToken, authMiddleware, consentMiddleware, hashSubject } from './auth.ts';
import { log } from './log.ts';

const app = new Hono();
app.use('*', cors());
// リクエスト単位の構造化アクセスログ（onError 適用後の最終 status を記録）
app.use('*', async (c, next) => {
  const start = Date.now();
  await next();
  log(c.res.status >= 500 ? 'error' : 'info', 'request', {
    method: c.req.method,
    path: c.req.path,
    status: c.res.status,
    durationMs: Date.now() - start,
  });
});
app.notFound((c) => c.json({ error: 'not found' as const }, 404));
// 未捕捉例外を種別分けする: 上流 timeout=504 / 上流エラー=502 / 自コード=500
app.onError((err, c) => {
  if (err instanceof HTTPException) return err.getResponse();
  const failure = err instanceof ExternalError ? err.kind : 'internal';
  log('error', 'unhandled_error', {
    method: c.req.method,
    path: c.req.path,
    failure,
    message: err.message,
  });
  if (failure === 'timeout') return c.json({ error: 'upstream timeout' as const }, 504);
  if (failure === 'upstream') return c.json({ error: 'upstream error' as const }, 502);
  return c.json({ error: 'internal server error' as const }, 500);
});
app.get('/health', (c) => c.json({ ok: true }));

const routes = app
  // 電話番号受付 → SMS 送信
  .post('/api/auth/sms', zValidator('json', zSmsSendRequest), async (c) => {
    // NOTE: SMS スパム/課金対策の rate limit は跨タスクの共有状態が要るため、
    // ステートレス MVP の範囲外。本番は CloudFront/ALB の WAF rate-based rule で実施する。
    const { phone } = c.req.valid('json');
    const ok = await external.smsSend(phone);
    if (!ok) return c.json({ error: 'SMS の送信に失敗しました' as const }, 502);
    return c.json({ sent: true as const });
  })
  // コード検証 → ステートレス署名トークン発行
  .post('/api/auth/verify', zValidator('json', zSmsVerifyRequest), async (c) => {
    const { phone, code } = c.req.valid('json');
    const ok = await external.smsVerify(phone, code);
    if (!ok) return c.json({ error: 'invalid code' as const }, 401);
    // sub には生電話番号でなくハッシュを載せる
    const token = await issueToken(hashSubject(phone));
    return c.json({ token });
  })
  // データ提供同意 → consentId を claim に追記してトークン再発行
  .post('/api/consent', authMiddleware, async (c) => {
    const auth = c.get('auth');
    // 認証済み subject を渡して同意を作成（実 API ではこのユーザーの同意として紐付く）
    const { consentId } = await external.consent(auth.sub);
    const token = await issueToken(auth.sub, consentId);
    return c.json({ consentId, token });
  })
  // 30分値・市場価格を取得 → 診断エンジンで計算（要・同意済みトークン）
  .post('/api/diagnose', authMiddleware, consentMiddleware, async (c) => {
    const consentId = c.get('auth').consentId!; // consentMiddleware で存在保証
    const [readings, prices] = await Promise.all([
      external.readings(consentId),
      external.marketSpot(),
    ]);
    const result = diagnose(readings, prices, CURRENT_PLAN, MARKET_PLAN);
    // 12ヶ月そろわない不完全な窓を "年間" として返さない（fail-loud。design §13 の前提を assert）
    if (result.monthly.length !== 12) {
      return c.json({ error: 'incomplete data window (expected 12 months)' as const }, 422);
    }
    return c.json(result);
  })
  // プレフィル用の契約マスタ（要・同意済みトークン）
  .get('/api/contract', authMiddleware, consentMiddleware, async (c) => {
    const consentId = c.get('auth').consentId!;
    return c.json(await external.contract(consentId));
  })
  // 申込（要・同意済みトークン。永続化なし、受領レスポンスのみ）
  .post('/api/application', authMiddleware, consentMiddleware, zValidator('json', zApplicationRequest), async (c) => {
    const body = c.req.valid('json');
    const consentId = c.get('auth').consentId!;
    // 改変不可フィールド（供給地点・契約電力）は client 値を信用せずサーバ側の契約マスタから採用。
    // なりすまし（他人の供給地点での申込）を防ぐ。client からは編集可能な項目のみ受ける。
    const contract = await external.contract(consentId);
    const record = {
      holderName: body.holderName,
      address: body.address,
      email: body.email,
      supplyPointId: contract.supplyPointId,
      contractAmpere: contract.contractAmpere,
    };
    return c.json({
      accepted: true as const,
      applicationId: `app-${Math.floor(Date.now() / 1000)}-${record.contractAmpere}`,
    });
  });

export type AppType = typeof routes;
export { app };
