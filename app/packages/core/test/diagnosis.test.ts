import { test } from 'node:test';
import assert from 'node:assert/strict';
import { diagnose } from '../src/diagnosis.ts';
import type { ConsumptionReading, MarketPrice, CurrentPlan, MarketPlan } from '../src/types.ts';

const current: CurrentPlan = { name: 'cur', basicYenPerMonth: 1000, energyYenPerKwh: 30 };
const market: MarketPlan = { name: 'mkt', basicYenPerMonth: 0, marginYenPerKwh: 3 };

test('単月: 従量 + 基本料金で total と diff を計算する', () => {
  const readings: ConsumptionReading[] = [
    { ts: '2025-06-01T00:00:00+09:00', kwh: 1 },
    { ts: '2025-06-01T00:30:00+09:00', kwh: 2 },
  ];
  const prices: MarketPrice[] = [
    { ts: '2025-06-01T00:00:00+09:00', yenPerKwh: 10 },
    { ts: '2025-06-01T00:30:00+09:00', yenPerKwh: 10 },
  ];
  const r = diagnose(readings, prices, current, market);
  assert.equal(r.monthly.length, 1);
  const m = r.monthly[0]!;
  // current energy = (1+2)*30 = 90, +basic 1000 = 1090
  assert.equal(m.currentTotal, 1090);
  // market energy = 1*(10+3) + 2*(10+3) = 39, +basic 0 = 39
  assert.equal(m.marketTotal, 39);
  assert.equal(m.diff, 1090 - 39);
  assert.equal(m.isSpike, false);
  assert.equal(m.kwh, 3);
});

test('高騰月: 市場連動が総額で高い月は isSpike=true (diff<0)', () => {
  const readings: ConsumptionReading[] = [{ ts: '2026-01-15T18:00:00+09:00', kwh: 10 }];
  const prices: MarketPrice[] = [{ ts: '2026-01-15T18:00:00+09:00', yenPerKwh: 80 }];
  const r = diagnose(readings, prices, current, market);
  const m = r.monthly[0]!;
  // current = 10*30 +1000 = 1300; market = 10*(80+3) +0 = 830 → market 安い → not spike
  assert.equal(m.isSpike, false);
  // 基本料金を逆転させて市場連動が高くなるケース
  const r2 = diagnose(readings, prices, { ...current, basicYenPerMonth: 0, energyYenPerKwh: 20 }, market);
  const m2 = r2.monthly[0]!;
  // current = 10*20 = 200; market = 830 → market 高い → spike
  assert.equal(m2.isSpike, true);
  assert.ok(m2.diff < 0);
});

test('複数月: 時系列昇順 + 年間サマリー', () => {
  const readings: ConsumptionReading[] = [
    { ts: '2026-01-01T00:00:00+09:00', kwh: 5 },
    { ts: '2025-12-01T00:00:00+09:00', kwh: 5 },
  ];
  const prices: MarketPrice[] = [
    { ts: '2026-01-01T00:00:00+09:00', yenPerKwh: 10 },
    { ts: '2025-12-01T00:00:00+09:00', yenPerKwh: 10 },
  ];
  const r = diagnose(readings, prices, current, market);
  assert.deepEqual(r.monthly.map((m) => m.month), ['2025-12', '2026-01']);
  assert.equal(r.annualCurrent, r.monthly[0]!.currentTotal + r.monthly[1]!.currentTotal);
  assert.equal(r.annualDiff, r.annualCurrent - r.annualMarket);
});

test('価格欠損は例外', () => {
  assert.throws(() =>
    diagnose(
      [{ ts: '2025-06-01T00:00:00+09:00', kwh: 1 }],
      [],
      current,
      market,
    ),
  );
});
