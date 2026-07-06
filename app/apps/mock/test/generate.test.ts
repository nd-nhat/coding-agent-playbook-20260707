import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  WINDOW,
  SPIKE_MONTHS,
  windowMonthKeys,
  assertWindowConsistency,
  generateSampleData,
} from '../src/generate.ts';

test('実定数は整合チェックを通る', () => {
  assert.doesNotThrow(() => assertWindowConsistency());
});

test('WINDOW は連続する12ヶ月', () => {
  assert.equal(WINDOW.length, 12);
  for (let i = 1; i < WINDOW.length; i++) {
    const prev = WINDOW[i - 1]!;
    const cur = WINDOW[i]!;
    const expectedY = prev.m === 12 ? prev.y + 1 : prev.y;
    const expectedM = prev.m === 12 ? 1 : prev.m + 1;
    assert.equal(cur.y, expectedY);
    assert.equal(cur.m, expectedM);
  }
});

test('SPIKE_MONTHS ⊆ WINDOW（spike 分岐が到達可能）', () => {
  const keys = new Set(windowMonthKeys());
  assert.ok(SPIKE_MONTHS.size > 0);
  for (const spike of SPIKE_MONTHS) {
    assert.ok(keys.has(spike), `${spike} should be within WINDOW`);
  }
});

test('生成データで spike 月の夕方価格が平常月より高騰している', () => {
  const { prices } = generateSampleData();
  const eveningHour = (ts: string) => {
    const h = Number(ts.slice(11, 13));
    return h >= 17 && h <= 21;
  };
  const spikeKey = [...SPIKE_MONTHS][0]!;
  const normalKey = windowMonthKeys().find((k) => !SPIKE_MONTHS.has(k))!;

  const spikeEvening = prices.filter((p) => p.ts.startsWith(spikeKey) && eveningHour(p.ts));
  const normalEvening = prices.filter((p) => p.ts.startsWith(normalKey) && eveningHour(p.ts));
  assert.ok(spikeEvening.length > 0);
  assert.ok(normalEvening.length > 0);

  const avg = (arr: typeof prices) => arr.reduce((s, p) => s + p.yenPerKwh, 0) / arr.length;
  assert.ok(avg(spikeEvening) > avg(normalEvening));
});
