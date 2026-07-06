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

const baseUrl = () => process.env.EXTERNAL_BASE_URL ?? 'http://localhost:8787';

// 上流が stall してもリクエストを無限滞留させない application-level deadline
const TIMEOUT_MS = Number(process.env.EXTERNAL_TIMEOUT_MS ?? 8000);

// 外部呼び出しの失敗種別。onError 側がこの kind を見て HTTP status を選ぶ
// （upstream → 502 bad gateway / timeout → 504）ため、生の fetch 例外を握り潰さず型で運ぶ。
export type ExternalFailureKind = 'upstream' | 'timeout';

export class ExternalError extends Error {
  readonly kind: ExternalFailureKind;
  readonly path: string;
  constructor(kind: ExternalFailureKind, path: string, message: string) {
    super(message);
    this.name = 'ExternalError';
    this.kind = kind;
    this.path = path;
  }
}

// AbortSignal.timeout() は fetch を TimeoutError（DOMException）で reject するが、
// runtime によっては AbortError として上げるため name で両対応する。
function isTimeout(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'name' in err &&
    ((err as { name: string }).name === 'TimeoutError' || (err as { name: string }).name === 'AbortError')
  );
}

// consentId は対象ユーザーの power-data を引く認可コンテキストなので、query string ごと
// ログ/エラーメッセージに残さない（endpoint だけ記録する）。
function logPath(path: string): string {
  return path.split('?', 1)[0]!;
}

// 失敗を ExternalError に正規化しつつ、外部呼び出し 1 回を JSON 1 行で記録する seam。
// 上流本文は untrusted（第三者 API 由来）なのでログに verbatim で出さない。原因調査に要る
// のは「どれだけ返ってきたか」の目安だけなので、本文でなくバイト長だけを残す。
function failExternal(path: string, startedAt: number, kind: ExternalFailureKind, upstreamBody?: string): ExternalError {
  const durationMs = Date.now() - startedAt;
  const safePath = logPath(path);
  const upstreamBytes = upstreamBody === undefined ? undefined : new TextEncoder().encode(upstreamBody).length;
  console.error(JSON.stringify({ level: 'error', event: 'external_call', path: safePath, durationMs, kind, upstreamBytes }));
  return new ExternalError(kind, safePath, `external ${safePath} ${kind} failure`);
}

// boolean を返す SMS 認証フロー（非 ok を false に握り潰す）は呼び出し側で res.ok を見るため
// Response をそのまま返すが、接続拒否/DNS/timeout 等の throw は getJson と同じく ExternalError に
// 正規化して onError が 502/504 に分類できるようにする（非 ok 応答は throw せず呼び出し側に委ねる）。
async function postJson(path: string, body: unknown): Promise<Response> {
  const startedAt = Date.now();
  try {
    return await fetch(baseUrl() + path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (err) {
    throw failExternal(path, startedAt, isTimeout(err) ? 'timeout' : 'upstream');
  }
}

// データ取得用: タイムアウト / ネットワーク失敗 / 非 ok を全て ExternalError に集約する。
// 上流障害（502/504）と自前コードのバグ（500）を onError が区別できるようにするのが目的。
async function fetchExternal(path: string, init?: RequestInit): Promise<Response> {
  const startedAt = Date.now();
  let res: Response;
  try {
    res = await fetch(baseUrl() + path, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch (err) {
    throw failExternal(path, startedAt, isTimeout(err) ? 'timeout' : 'upstream');
  }
  if (!res.ok) throw failExternal(path, startedAt, 'upstream', await res.text());
  return res;
}

// 200 でも本文が壊れている = 上流のレスポンス契約違反なので 502 に倒す（自前バグの 500 ではない）。
// res.json() を叩く全経路（getJson / consent / smsVerify）で共通に通す。body 読み取り中に
// AbortSignal.timeout が発火する経路もあるため、timeout は 504 として分離する。
async function readJson(res: Response, path: string): Promise<unknown> {
  try {
    return await res.json();
  } catch (err) {
    throw failExternal(path, Date.now(), isTimeout(err) ? 'timeout' : 'upstream');
  }
}

async function getJson(path: string): Promise<unknown> {
  return readJson(await fetchExternal(path), path);
}

// 上流レスポンスの Zod 検証。schema 不一致も上流契約違反として 502 に分類する。
function parseUpstream<T>(schema: { parse: (value: unknown) => T }, value: unknown, path: string): T {
  try {
    return schema.parse(value);
  } catch {
    throw failExternal(path, Date.now(), 'upstream');
  }
}

export const external = {
  async smsSend(phone: string): Promise<boolean> {
    const res = await postJson('/sms/send', { phone });
    return res.ok;
  },

  async smsVerify(phone: string, code: string): Promise<boolean> {
    const startedAt = Date.now();
    const res = await postJson('/sms/verify', { phone, code });
    // 5xx は upstream 障害なので 502 に倒す。4xx は「コード不正」= 検証失敗として false（401）に倒す。
    if (res.status >= 500) throw failExternal('/sms/verify', startedAt, 'upstream');
    if (!res.ok) return false;
    // shape 不正な 200（{} や verified が非 boolean）は検証失敗(401)でなく上流契約違反(502)に倒す。
    const json = parseUpstream(zExternalSmsVerifyResponse, await readJson(res, '/sms/verify'), '/sms/verify');
    return json.verified === true;
  },

  // subject（ハッシュ済み）を渡して同意を作成。mock は無視するが、実 API では
  // 「このユーザーの同意」として upstream に紐付けるための seam。
  async consent(subject: string): Promise<{ consentId: string }> {
    const path = '/power-data/consent';
    const res = await fetchExternal(path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ subject }),
    });
    // 他の power-data 同様 Zod 検証（consentId が非空であること）
    return parseUpstream(zExternalConsentResponse, await readJson(res, path), path);
  },

  // 個データ取得には consent 文脈（consentId）を渡す。mock は無視するが、
  // 実 API 切替時に「対象ユーザーの認可済みデータ」を要求できる seam（README §本番境界）。
  async readings(consentId: string): Promise<ConsumptionReading[]> {
    const path = '/power-data/readings?consentId=' + encodeURIComponent(consentId);
    return parseUpstream(zReadingsResponse, await getJson(path), path).data.readings;
  },

  // 市場価格は公開データ（JEPX）でユーザー固有でないため consent 文脈は不要
  async marketSpot(): Promise<MarketPrice[]> {
    const path = '/market/spot';
    return parseUpstream(zMarketSpotResponse, await getJson(path), path).prices;
  },

  async contract(consentId: string): Promise<ContractInfo> {
    const path = '/power-data/contract?consentId=' + encodeURIComponent(consentId);
    return parseUpstream(zContractResponse, await getJson(path), path);
  },
};
