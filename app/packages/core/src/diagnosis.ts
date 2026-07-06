// 診断エンジン（docs/design.md §6）。純関数。UI / サーバから独立。
// 計算は backend で実行し、結果(DiagnosisResult)のみ frontend に返す。

import type {
  ConsumptionReading,
  MarketPrice,
  CurrentPlan,
  MarketPlan,
  MonthlyResult,
  DiagnosisResult,
} from './types.ts';

/** ts("2025-06-01T13:30:00+09:00") から月キー "2025-06" を取り出す（JST 前提） */
function monthKey(ts: string): string {
  return ts.slice(0, 7);
}

interface MonthAccumulator {
  kwh: number;
  currentEnergy: number;
  marketEnergy: number;
}

/**
 * 30分値 × 市場価格で現行プランと市場連動プランを比較し、月次バックテストと
 * 年間サマリーを返す。
 *
 * - current_slot = kwh × currentPlan.energyYenPerKwh
 * - market_slot  = kwh × (price + marketPlan.marginYenPerKwh)
 * - *_total[m]   = Σ *_energy[m] + 各プランの basicYenPerMonth
 * - diff[m]      = current_total[m] - market_total[m]  (正 = 市場連動が安い)
 * - isSpike[m]   = market_total[m] > current_total[m]  (= diff[m] < 0)
 */
export function diagnose(
  readings: ConsumptionReading[],
  prices: MarketPrice[],
  currentPlan: CurrentPlan,
  marketPlan: MarketPlan,
): DiagnosisResult {
  const priceByTs = new Map<string, number>();
  for (const p of prices) priceByTs.set(p.ts, p.yenPerKwh);

  // 月キー -> 集計。挿入順を保つため Map を使い、後でソートする。
  const byMonth = new Map<string, MonthAccumulator>();

  for (const r of readings) {
    const price = priceByTs.get(r.ts);
    if (price === undefined) {
      throw new Error(`market price missing for ts=${r.ts}`);
    }
    const m = monthKey(r.ts);
    let acc = byMonth.get(m);
    if (!acc) {
      acc = { kwh: 0, currentEnergy: 0, marketEnergy: 0 };
      byMonth.set(m, acc);
    }
    acc.kwh += r.kwh;
    acc.currentEnergy += r.kwh * currentPlan.energyYenPerKwh;
    acc.marketEnergy += r.kwh * (price + marketPlan.marginYenPerKwh);
  }

  const monthly: MonthlyResult[] = [...byMonth.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([month, acc]) => {
      const currentTotal = acc.currentEnergy + currentPlan.basicYenPerMonth;
      const marketTotal = acc.marketEnergy + marketPlan.basicYenPerMonth;
      const diff = currentTotal - marketTotal;
      return {
        month,
        kwh: acc.kwh,
        currentTotal,
        marketTotal,
        diff,
        isSpike: marketTotal > currentTotal, // = diff < 0
      };
    });

  const annualCurrent = monthly.reduce((s, m) => s + m.currentTotal, 0);
  const annualMarket = monthly.reduce((s, m) => s + m.marketTotal, 0);
  const annualDiff = annualCurrent - annualMarket;
  const annualDiffPct = annualCurrent === 0 ? 0 : annualDiff / annualCurrent;

  return { monthly, annualCurrent, annualMarket, annualDiff, annualDiffPct };
}
