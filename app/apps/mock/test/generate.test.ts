import { test } from 'node:test';
import assert from 'node:assert/strict';
import { assertWindowConsistency, generateSampleData } from '../src/generate.ts';

const months = (start: { y: number; m: number }, n: number) => {
  const out: { y: number; m: number }[] = [];
  let { y, m } = start;
  for (let i = 0; i < n; i++) {
    out.push({ y, m });
    if (m === 12) {
      y += 1;
      m = 1;
    } else {
      m += 1;
    }
  }
  return out;
};

test('連続12ヶ月 + 窓内の高騰月は整合チェックを通る', () => {
  assertWindowConsistency(months({ y: 2025, m: 6 }, 12), new Set(['2026-01', '2026-02']));
});

test('窓が12ヶ月でなければ throw する', () => {
  assert.throws(() => assertWindowConsistency(months({ y: 2025, m: 6 }, 11), new Set()), /12 months/);
});

test('窓が連続していなければ throw する（年跨ぎ含む）', () => {
  const gap = [...months({ y: 2025, m: 6 }, 6), ...months({ y: 2026, m: 2 }, 6)];
  assert.throws(() => assertWindowConsistency(gap, new Set()), /consecutive/);
});

test('窓外の高騰月は throw する', () => {
  assert.throws(
    () => assertWindowConsistency(months({ y: 2025, m: 6 }, 12), new Set(['2025-01'])),
    /outside/,
  );
});

test('生成データの高騰月にスパイク分岐が実際に効いている', () => {
  const { prices } = generateSampleData();
  const monthlyAvg = new Map<string, { sum: number; n: number }>();
  for (const { ts, yenPerKwh } of prices) {
    const key = ts.slice(0, 7);
    const cur = monthlyAvg.get(key) ?? { sum: 0, n: 0 };
    cur.sum += yenPerKwh;
    cur.n += 1;
    monthlyAvg.set(key, cur);
  }
  const avg = (key: string) => {
    const v = monthlyAvg.get(key);
    assert.ok(v, `month ${key} missing from generated data`);
    return v.sum / v.n;
  };
  for (const spike of ['2026-01', '2026-02']) {
    assert.ok(avg(spike) > avg('2025-06') * 1.5, `${spike} should be spiked vs normal month`);
  }
});
