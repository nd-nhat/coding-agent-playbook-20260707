// 外部連携アダプタ（docs/design.md §7, §12）。base URL を env で切替し、
// dev/demo は mock サーバ、本番は実 API を叩く。レスポンスは core の Zod で検証。

import {
  zReadingsResponse,
  zMarketSpotResponse,
  zContractResponse,
  zExternalConsentResponse,
  zExternalSmsVerifyResponse,
  type ConsumptionReading,
  type MarketPrice,
  type ContractInfo,
} from '@diag/core';
import { log } from './log.ts';

const baseUrl = () => process.env.EXTERNAL_BASE_URL ?? 'http://localhost:8787';

// 上流が stall してもリクエストを無限滞留させない application-level deadline
const TIMEOUT_MS = Number(process.env.EXTERNAL_TIMEOUT_MS ?? 8000);

/** 上流起因の失敗種別。app.onError が timeout=504 / upstream=502 に写像する */
export type ExternalFailureKind = 'timeout' | 'upstream';

/** 外部呼び出しの失敗を自コードのバグ（500）と区別するための種別付きエラー */
export class ExternalError extends Error {
  constructor(
    message: string,
    readonly kind: ExternalFailureKind,
    readonly path: string,
  ) {
    super(message);
    this.name = 'ExternalError';
  }
}

// consentId 等を含む query はログ・エラーに載せない
const stripQuery = (path: string) => path.split('?')[0]!;

// 失敗を ExternalError に正規化しつつ external_call の失敗ログを 1 行出す。
// observe 側の切り分け契約（examples/observe/runbook.md）に合わせ、event=external_call は
// 失敗時のみ・path / durationMs / kind の固定 key で出す。
function failExternal(
  kind: ExternalFailureKind,
  path: string,
  start: number,
  message: string,
): ExternalError {
  log('error', 'external_call', { path, durationMs: Date.now() - start, kind });
  return new ExternalError(message, kind, path);
}

/** timeout / 到達不能を種別分けする共通経路 */
async function fetchExternal(path: string, init?: RequestInit): Promise<Response> {
  const p = stripQuery(path);
  const start = Date.now();
  try {
    return await fetch(baseUrl() + path, {
      ...init,
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (err) {
    // AbortSignal.timeout による中断は TimeoutError、それ以外（DNS/接続断等）は上流到達不能
    const kind: ExternalFailureKind =
      err instanceof Error && err.name === 'TimeoutError' ? 'timeout' : 'upstream';
    throw failExternal(kind, p, start, `external ${p} ${kind}`);
  }
}

async function postJson(path: string, body: unknown): Promise<Response> {
  return fetchExternal(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

/** 本文の形式不正（JSON でない / Zod 不一致）も上流起因（502）として種別付けする */
async function parseJson<T>(
  res: Response,
  schema: { parse: (v: unknown) => T },
  path: string,
): Promise<T> {
  const start = Date.now();
  try {
    return schema.parse(await res.json());
  } catch (err) {
    // 200 応答後の body 読み取り中でも AbortSignal.timeout は発火しうるので timeout に写像
    if (err instanceof Error && err.name === 'TimeoutError') {
      throw failExternal('timeout', path, start, `external ${path} timeout`);
    }
    throw failExternal('upstream', path, start, `external ${path} returned invalid body`);
  }
}

async function getJson<T>(path: string, schema: { parse: (v: unknown) => T }): Promise<T> {
  const p = stripQuery(path);
  const start = Date.now();
  const res = await fetchExternal(path);
  if (!res.ok) throw failExternal('upstream', p, start, `external GET ${p} failed: ${res.status}`);
  return parseJson(res, schema, p);
}

export const external = {
  async smsSend(phone: string): Promise<boolean> {
    const path = '/sms/send';
    const start = Date.now();
    const res = await postJson(path, { phone });
    // 非 2xx の応答契約（502 とエラーメッセージ）は呼び出し側 route が持つため throw せず記録のみ
    if (!res.ok) failExternal('upstream', path, start, `external ${path} failed: ${res.status}`);
    return res.ok;
  },

  async smsVerify(phone: string, code: string): Promise<boolean> {
    const path = '/sms/verify';
    const start = Date.now();
    const res = await postJson(path, { phone, code });
    // 5xx は上流障害（502）、4xx は「コード不正」= 検証失敗として false（401）に倒す
    if (res.status >= 500) throw failExternal('upstream', path, start, `external ${path} failed: ${res.status}`);
    if (!res.ok) return false;
    return (await parseJson(res, zExternalSmsVerifyResponse, path)).verified;
  },

  // subject（ハッシュ済み）を渡して同意を作成。mock は無視するが、実 API では
  // 「このユーザーの同意」として upstream に紐付けるための seam。
  async consent(subject: string): Promise<{ consentId: string }> {
    const path = '/power-data/consent';
    const start = Date.now();
    const res = await postJson(path, { subject });
    if (!res.ok) throw failExternal('upstream', path, start, `external consent failed: ${res.status}`);
    // 他の power-data 同様 Zod 検証（consentId が非空であること）
    return parseJson(res, zExternalConsentResponse, path);
  },

  // 個データ取得には consent 文脈（consentId）を渡す。mock は無視するが、
  // 実 API 切替時に「対象ユーザーの認可済みデータ」を要求できる seam（README §本番境界）。
  async readings(consentId: string): Promise<ConsumptionReading[]> {
    const q = `?consentId=${encodeURIComponent(consentId)}`;
    return (await getJson('/power-data/readings' + q, zReadingsResponse)).readings;
  },

  // 市場価格は公開データ（JEPX）でユーザー固有でないため consent 文脈は不要
  async marketSpot(): Promise<MarketPrice[]> {
    return (await getJson('/market/spot', zMarketSpotResponse)).prices;
  },

  async contract(consentId: string): Promise<ContractInfo> {
    const q = `?consentId=${encodeURIComponent(consentId)}`;
    return getJson('/power-data/contract' + q, zContractResponse);
  },
};
