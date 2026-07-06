// プラン定数（docs/design.md §5「プランの取得元」）。
// CurrentPlan / MarketPlan は外部 API から取得しない（30分値や契約マスタに
// 現行料金単価が含まれないため）。MVP では代表値を定数で持つ。

import type { CurrentPlan, MarketPlan, ContractInfo } from './types.ts';

/** 想定する典型的な従量電灯B（40A 相当・実効従量単価を固定値で仮置き） */
export const CURRENT_PLAN: CurrentPlan = {
  name: '従量電灯B（現行・想定）',
  basicYenPerMonth: 1247.7, // 40A の基本料金 相当
  energyYenPerKwh: 30.0, // 段階を畳んだ実効単価
};

/** 提供する市場連動商品（基本料金・マージンは自社商品の定義値） */
export const MARKET_PLAN: MarketPlan = {
  name: '市場連動プラン（提供商品）',
  basicYenPerMonth: 0, // 基本料金ゼロ型
  marginYenPerKwh: 3.3, // 市場価格への上乗せマージン
};

/** 契約マスタ（プレフィル用のモック値）。料金計算の入力には使わない */
export const CONTRACT_INFO: ContractInfo = {
  holderName: '診断 太郎',
  contractAmpere: 40,
  supplyPointId: '03-0000-0000-0000-0000-0000', // モック供給地点特定番号
  address: '東京都千代田区丸の内0-0-0',
};
