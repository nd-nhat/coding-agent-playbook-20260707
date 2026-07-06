// ドメイン型（docs/design.md §5）。すべて JST(+09:00) で扱う。

/** 30分値（スマートメーターの計量値、1コマ = 30分） */
export interface ConsumptionReading {
  /** ISO8601。コマ開始時刻（例 2025-06-01T13:30:00+09:00） */
  ts: string;
  /** そのコマの消費電力量 [kWh] */
  kwh: number;
}

/** 市場スポット価格（JEPX 相当、30分コマ単位） */
export interface MarketPrice {
  /** ConsumptionReading.ts と1対1 */
  ts: string;
  /** そのコマの市場価格（エリアプライス）[円/kWh] */
  yenPerKwh: number;
}

/** 現行プラン（従量電灯B 相当） */
export interface CurrentPlan {
  name: string;
  /** 基本料金（契約アンペアで決まる固定額）[円/月] */
  basicYenPerMonth: number;
  /** 従量単価（MVP は段階を畳んだ実効単価の固定値）[円/kWh] */
  energyYenPerKwh: number;
}

/** 市場連動プラン */
export interface MarketPlan {
  name: string;
  /** 基本料金 [円/月] */
  basicYenPerMonth: number;
  /** 市場価格に上乗せするマージン [円/kWh] */
  marginYenPerKwh: number;
}

/** 契約マスタ（申込フォームのプレフィル用、制度経由で取得される想定） */
export interface ContractInfo {
  /** 契約名義 */
  holderName: string;
  /** 契約電力 [A] */
  contractAmpere: number;
  /** 供給地点特定番号（モック値） */
  supplyPointId: string;
  address: string;
}

/** 月次の診断結果（1要素 = 1ヶ月） */
export interface MonthlyResult {
  /** "2025-06" */
  month: string;
  kwh: number;
  /** 現行プランの月額総額（従量 + 基本料金）[円] */
  currentTotal: number;
  /** 市場連動プランの月額総額（従量 + 基本料金）[円] */
  marketTotal: number;
  /** currentTotal - marketTotal。正 = 市場連動が安い [円] */
  diff: number;
  /** 市場連動が「総額で」高い月（= diff < 0）。「高騰月」 */
  isSpike: boolean;
}

/** 診断結果（年間サマリー + 月次バックテスト） */
export interface DiagnosisResult {
  /** 12要素、時系列昇順 */
  monthly: MonthlyResult[];
  /** 年間の現行総額 [円] */
  annualCurrent: number;
  /** 年間の市場連動総額 [円] */
  annualMarket: number;
  /** annualCurrent - annualMarket。正 = 年間で安くなる [円] */
  annualDiff: number;
  /** annualDiff / annualCurrent */
  annualDiffPct: number;
}
