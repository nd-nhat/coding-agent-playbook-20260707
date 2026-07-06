// 外部連携 / backend API の契約（docs/design.md §7, §8）。
// 公開仕様の無い協会 API は自前で Zod 定義、JEPX は正規化済み JSON 契約。
// 型とランタイム検証を同時に得る。

import { z } from 'zod';

// --- ドメイン値（wire 表現） ---
// ts は JST(+09:00) 固定（docs/design.md §3）。UTC 等の別 offset を受け入れると
// diagnose() の ts.slice(0,7) 月次集計が月跨ぎで誤るため、契約段階で弾く。
const zJstTs = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+09:00$/, 'ts must be JST (+09:00)');

export const zConsumptionReading = z.object({
  ts: zJstTs,
  kwh: z.number().nonnegative(),
});
export const zMarketPrice = z.object({
  ts: zJstTs,
  yenPerKwh: z.number(),
});
export const zContractInfo = z.object({
  holderName: z.string(),
  contractAmpere: z.number().int().positive(),
  supplyPointId: z.string(),
  address: z.string(),
});

// --- 認証（SMS） ---
/** 日本の携帯番号（070/080/090 + 8桁、ハイフン任意）。SMS 認証対象 */
export const zPhone = z
  .string()
  .regex(/^0[789]0-?\d{4}-?\d{4}$/, '携帯電話番号（070/080/090）の形式が正しくありません');
export const zSmsSendRequest = z.object({ phone: zPhone });
export const zSmsSendResponse = z.object({ sent: z.literal(true) });
export const zSmsVerifyRequest = z.object({
  phone: zPhone,
  code: z.string().length(6),
});
export const zSmsVerifyResponse = z.object({ token: z.string() });

// --- データ提供同意 ---
// 同意で consentId を claim に追記したトークンを再発行する（docs/design.md §8）
export const zConsentResponse = z.object({
  consentId: z.string(),
  token: z.string(),
});

// --- 診断結果 ---
export const zMonthlyResult = z.object({
  month: z.string(),
  kwh: z.number(),
  currentTotal: z.number(),
  marketTotal: z.number(),
  diff: z.number(),
  isSpike: z.boolean(),
});
export const zDiagnosisResult = z.object({
  monthly: z.array(zMonthlyResult),
  annualCurrent: z.number(),
  annualMarket: z.number(),
  annualDiff: z.number(),
  annualDiffPct: z.number(),
});

// --- 申込 ---
export const zApplicationRequest = z.object({
  holderName: z.string().min(1),
  contractAmpere: z.number().int().positive(),
  supplyPointId: z.string().min(1),
  address: z.string().min(1),
  email: z.string().email(),
});
export const zApplicationResponse = z.object({
  accepted: z.literal(true),
  applicationId: z.string(),
});

// 外部（協会 mock）consent レスポンス。consentId が非空であることを検証する
export const zExternalConsentResponse = z.object({
  consentId: z.string().min(1),
});

// 外部 SMS verify レスポンス。verified が boolean であることを検証する
// （shape 不正な 200 を「コード不正(401)」でなく上流契約違反(502)に倒すため）
export const zExternalSmsVerifyResponse = z.object({
  verified: z.boolean(),
});

// 外部 readings / market / contract レスポンス
// readings は上流 API が data オブジェクトで包んで返す
export const zReadingsResponse = z.object({
  data: z.object({
    readings: z.array(zConsumptionReading),
  }),
});
export const zMarketSpotResponse = z.object({
  prices: z.array(zMarketPrice),
});
export const zContractResponse = zContractInfo;
