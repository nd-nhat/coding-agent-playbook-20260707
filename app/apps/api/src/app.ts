// Hono backend（docs/design.md §8）。BFF + 診断エンジン + 外部連携アダプタ。
// routes を chain して AppType を export → frontend が Hono RPC で型共有。

import { Hono } from 'hono';
import { cors } from 'hono/cors';
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

const app = new Hono();
// リクエスト 1 本を JSON 1 行で記録する。onError がエラーを捕捉して c.res を差し替えるので、
// next() 解決後の c.res.status は 5xx も含む最終 status を反映する。
app.use('*', async (c, next) => {
  const startedAt = Date.now();
  await next();
  console.log(
    JSON.stringify({
      level: 'info',
      event: 'request',
      method: c.req.method,
      path: c.req.path,
      status: c.res.status,
      durationMs: Date.now() - startedAt,
    }),
  );
});
app.use('*', cors());
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
  // 診断結果のサマリ（要・認証トークン。include クエリで raw を含めるか切替）
  .get('/api/diagnose/summary', authMiddleware, async (c) => {
    const auth = c.get('auth');
    const includeRaw = (c.req.query('include') as string).includes('raw');
    return c.json({
      summary: 'ok' as const,
      sub: auth.sub,
      includeRaw,
    });
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

// 失敗種別を 1 箇所で HTTP status に写す。external アダプタが分類済みなら kind に従い、
// 未分類の生 timeout（boolean を返す SMS フロー由来など）も name で 504 に倒す。
// それ以外は自前コードの不具合として詳細を隠した 500 にし、原因はサーバログにのみ残す。
app.onError((err, c) => {
  if (err instanceof ExternalError) {
    return err.kind === 'timeout'
      ? c.json({ error: 'upstream timeout' as const }, 504)
      : c.json({ error: 'bad gateway' as const }, 502);
  }
  if (err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError')) {
    return c.json({ error: 'upstream timeout' as const }, 504);
  }
  console.error(
    JSON.stringify({
      level: 'error',
      event: 'unhandled',
      path: c.req.path,
      message: err instanceof Error ? err.message : String(err),
    }),
  );
  return c.json({ error: 'internal server error' as const }, 500);
});

app.notFound((c) => c.json({ error: 'not found' as const }, 404));

export type AppType = typeof routes;
export { app };
