// 決定的サンプルデータ生成（docs/design.md §7）。
// 窓は固定 2025-06 〜 2026-05（直近の完了月までの12ヶ月・未来日を含めない）。
// seeded PRNG で生成し、再起動しても同じ値（デモ再現性）。

import { mulberry32, type ConsumptionReading, type MarketPrice } from '@diag/core';

/** 窓の月数。consecutive チェックと併せて WINDOW の形を固定する */
const WINDOW_LENGTH = 12;

/** 窓内の各月（{year, month1to12}）。2026 は非うるう年・2月=28日 */
export const WINDOW: ReadonlyArray<{ y: number; m: number }> = [
  { y: 2025, m: 6 },
  { y: 2025, m: 7 },
  { y: 2025, m: 8 },
  { y: 2025, m: 9 },
  { y: 2025, m: 10 },
  { y: 2025, m: 11 },
  { y: 2025, m: 12 },
  { y: 2026, m: 1 },
  { y: 2026, m: 2 },
  { y: 2026, m: 3 },
  { y: 2026, m: 4 },
  { y: 2026, m: 5 },
];

/** 高騰月（冬の市場価格スパイク） */
export const SPIKE_MONTHS: ReadonlySet<string> = new Set(['2026-01', '2026-02']);

const pad = (n: number) => String(n).padStart(2, '0');

/** WINDOW の各月を 'YYYY-MM' キーにした配列（生成・突合の単一ソース） */
export function windowMonthKeys(): string[] {
  return WINDOW.map(({ y, m }) => `${y}-${pad(m)}`);
}

// WINDOW と SPIKE_MONTHS は別々のリテラルなので、片方をずらすと isSpike が
// 恒久 false（spike 分岐が dead）になる。両者の整合を import 時に fail-loud で守る。
export function assertWindowConsistency(): void {
  if (WINDOW.length !== WINDOW_LENGTH) {
    throw new Error(
      `WINDOW must have exactly ${WINDOW_LENGTH} entries, got ${WINDOW.length}`,
    );
  }
  for (let i = 1; i < WINDOW.length; i++) {
    const prev = WINDOW[i - 1]!;
    const cur = WINDOW[i]!;
    const expectedY = prev.m === 12 ? prev.y + 1 : prev.y;
    const expectedM = prev.m === 12 ? 1 : prev.m + 1;
    if (cur.y !== expectedY || cur.m !== expectedM) {
      throw new Error(
        `WINDOW must be consecutive months: ${prev.y}-${pad(prev.m)} -> ${cur.y}-${pad(cur.m)} ` +
          `(expected ${expectedY}-${pad(expectedM)})`,
      );
    }
  }
  const keys = new Set(windowMonthKeys());
  for (const spike of SPIKE_MONTHS) {
    if (!keys.has(spike)) {
      throw new Error(`SPIKE_MONTHS member ${spike} is not within WINDOW`);
    }
  }
}

assertWindowConsistency();

function daysInMonth(y: number, m: number): number {
  return new Date(y, m, 0).getDate(); // m は 1-12、day=0 で前月末 → 当月日数
}

/** その日の曜日（0=日, 6=土）。JST だが日付の曜日は offset 不要 */
function dayOfWeek(y: number, m: number, d: number): number {
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

/** 時刻 h(0-23) の消費の相対形（朝・夕にピーク） */
function consumptionHourWeight(h: number): number {
  // 夜間ベース 0.5、朝 7-9 と 夕 18-22 にピーク
  const base = 0.5;
  const morning = 0.9 * Math.exp(-((h - 8) ** 2) / 3);
  const evening = 1.3 * Math.exp(-((h - 20) ** 2) / 4);
  const daytime = 0.3 * Math.exp(-((h - 13) ** 2) / 10);
  return base + morning + evening + daytime;
}

/** 月の季節係数（夏・冬を高く） */
function seasonalFactor(m: number): number {
  if (m === 7 || m === 8) return 1.35; // 盛夏（冷房）
  if (m === 9 || m === 6) return 1.1;
  if (m === 12 || m === 1 || m === 2) return 1.3; // 冬（暖房）
  return 0.95; // 春秋
}

/** 時刻 h の市場価格の相対形（夕方ピーク） */
function priceHourShape(h: number): number {
  const base = 9;
  const evening = 8 * Math.exp(-((h - 18) ** 2) / 6);
  const daytime = 3 * Math.exp(-((h - 13) ** 2) / 12);
  const night = -2 * Math.exp(-((h - 3) ** 2) / 6);
  return base + evening + daytime + night;
}

export interface SampleData {
  readings: ConsumptionReading[];
  prices: MarketPrice[];
}

/** 12ヶ月分の30分値・市場価格を決定的に生成する */
export function generateSampleData(seed = 20260601): SampleData {
  const rndC = mulberry32(seed);
  const rndP = mulberry32(seed ^ 0x9e3779b9);
  const readings: ConsumptionReading[] = [];
  const prices: MarketPrice[] = [];

  for (const { y, m } of WINDOW) {
    const monthKey = `${y}-${pad(m)}`;
    const isSpike = SPIKE_MONTHS.has(monthKey);
    const season = seasonalFactor(m);
    const days = daysInMonth(y, m);

    for (let d = 1; d <= days; d++) {
      const dow = dayOfWeek(y, m, d);
      const isWeekend = dow === 0 || dow === 6;
      for (let slot = 0; slot < 48; slot++) {
        const h = Math.floor(slot / 2);
        const mm = slot % 2 === 0 ? 0 : 30;
        const ts = `${y}-${pad(m)}-${pad(d)}T${pad(h)}:${pad(mm)}:00+09:00`;

        // --- 消費 30分値 ---
        const weekendBoost = isWeekend && h >= 9 && h <= 17 ? 1.15 : 1.0;
        const noiseC = 0.85 + rndC() * 0.3; // ±15%
        // 0.227 でスケール調整（年間 ~4,000kWh 目安・40A 単身〜2人世帯）
        const kwh =
          Math.round(consumptionHourWeight(h) * season * weekendBoost * noiseC * 0.227 * 1000) /
          1000;
        readings.push({ ts, kwh });

        // --- 市場価格（円/kWh、東京エリア相当） ---
        const noiseP = 0.9 + rndP() * 0.2;
        let yenPerKwh: number;
        if (isSpike) {
          // 冬の高騰月: 全体的に高く、夕方は超高騰（月平均が現行従量単価を上回る）
          yenPerKwh =
            h >= 17 && h <= 21
              ? (55 + rndP() * 65) * noiseP // 夕方 55-120
              : (22 + priceHourShape(h) * 1.2) * noiseP; // 他時間帯 ~28-40
        } else {
          yenPerKwh = priceHourShape(h) * noiseP; // 平常月 ~7-17
        }
        prices.push({ ts, yenPerKwh: Math.round(yenPerKwh * 100) / 100 });
      }
    }
  }

  return { readings, prices };
}
