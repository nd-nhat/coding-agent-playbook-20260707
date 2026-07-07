import { useMemo, useState } from 'react';
import type { MonthlyResult } from '@diag/core';
import { yen, monthLabel } from '../format.ts';

// 現行プラン(clay) と 市場連動(teal) を線で描き、その差分を面で塗る。
// 差分の符号変化点(交差)で区間を切り、市場連動が下回る区間は teal wash(節約)、
// 上回る区間は spike wash(高騰) に塗り分けて「正直さ」を形で示す。
const CLAY = '#bf5b2e';
const TEAL = '#0a7fa8';
const SPIKE = '#c0392b';

const W = 340;
const H = 188;
const PAD = { l: 8, r: 8, t: 20, b: 26 };
const plotW = W - PAD.l - PAD.r;
const plotH = H - PAD.t - PAD.b;

type Pt = [number, number];
const toPath = (pts: Pt[]) => pts.map((p, i) => `${i ? 'L' : 'M'}${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join(' ');

export function DiffChart({ monthly }: { monthly: MonthlyResult[] }) {
  const [hover, setHover] = useState<number | null>(null);

  const geo = useMemo(() => {
    const n = monthly.length;
    const maxV = Math.max(1, ...monthly.flatMap((m) => [m.currentTotal, m.marketTotal])) * 1.08;
    const x = (i: number) => PAD.l + (n > 1 ? (plotW * i) / (n - 1) : plotW / 2);
    const y = (v: number) => PAD.t + plotH * (1 - v / maxV);
    const cur: Pt[] = monthly.map((m, i) => [x(i), y(m.currentTotal)]);
    const mkt: Pt[] = monthly.map((m, i) => [x(i), y(m.marketTotal)]);

    // 隣接月ペアごとに 現行↔市場連動 の間を塗る。差分(market - current)の符号が
    // 変わる箇所は交点で切り、市場連動が下回る側 = 節約 / 上回る側 = 高騰 に振り分ける。
    const savings: Pt[][] = [];
    const overshoot: Pt[][] = [];
    for (let i = 0; i + 1 < n; i++) {
      const ci = monthly[i].currentTotal;
      const mi = monthly[i].marketTotal;
      const ci1 = monthly[i + 1].currentTotal;
      const mi1 = monthly[i + 1].marketTotal;
      const d0 = mi - ci; // >0 = 高騰(市場連動が上)
      const d1 = mi1 - ci1;
      const xi = x(i);
      const xi1 = x(i + 1);
      const A: Pt = [xi, y(ci)];
      const B: Pt = [xi1, y(ci1)];
      const P: Pt = [xi, y(mi)];
      const Q: Pt = [xi1, y(mi1)];

      if (d0 * d1 < 0) {
        // 交点で分割: t は現行=市場連動になる内挿位置
        const t = d0 / (d0 - d1);
        const xc = xi + t * (xi1 - xi);
        const yc = y(ci + t * (ci1 - ci));
        const C: Pt = [xc, yc];
        (d0 > 0 ? overshoot : savings).push([A, C, P]);
        (d1 > 0 ? overshoot : savings).push([C, B, Q]);
      } else {
        // 符号一定(または境界で 0): 台形をそのまま振り分ける
        (d0 > 0 || d1 > 0 ? overshoot : savings).push([A, B, Q, P]);
      }
    }
    return { x, y, cur, mkt, savings, overshoot };
  }, [monthly]);

  const last = monthly.length - 1;
  const cheaperCount = monthly.filter((m) => m.marketTotal < m.currentTotal).length;
  const spikeCount = monthly.filter((m) => m.isSpike).length;

  return (
    <div className="diff-chart">
      <svg
        viewBox={`0 0 ${W} ${H}`}
        role="img"
        aria-label={`現行プランと市場連動プランの月次料金推移。全 ${monthly.length} ヶ月中 ${cheaperCount} ヶ月で市場連動が安く、${spikeCount} ヶ月が高騰月。`}
      >
        {[1, 2, 3].map((g) => {
          const gy = PAD.t + (plotH * g) / 4;
          return <line key={g} x1={PAD.l} x2={W - PAD.r} y1={gy} y2={gy} stroke="var(--line)" strokeWidth={1} />;
        })}

        {/* 節約(市場連動が下)を teal wash で塗る */}
        {geo.savings.map((poly, i) => (
          <path key={`sv${i}`} d={`${toPath(poly)} Z`} fill={TEAL} fillOpacity={0.12} />
        ))}
        {/* 高騰(市場連動が上)を spike wash で塗る */}
        {geo.overshoot.map((poly, i) => (
          <path key={`ov${i}`} d={`${toPath(poly)} Z`} fill={SPIKE} fillOpacity={0.16} />
        ))}

        <path d={toPath(geo.cur)} fill="none" stroke={CLAY} strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" />
        <path d={toPath(geo.mkt)} fill="none" stroke={TEAL} strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" />

        {/* 高騰月の市場連動点に status マーカー */}
        {monthly.map((m, i) =>
          m.isSpike ? (
            <circle key={`s${i}`} cx={geo.x(i)} cy={geo.y(m.marketTotal)} r={3.4} fill={SPIKE} stroke="var(--card)" strokeWidth={1.5} />
          ) : null,
        )}
        {/* 直近点を強調(direct emphasis) */}
        {last >= 0 && (
          <circle cx={geo.x(last)} cy={geo.y(monthly[last].marketTotal)} r={3.6} fill={TEAL} stroke="var(--card)" strokeWidth={2} />
        )}
        {/* 単月データは line が引けないため両系列を点で示す */}
        {monthly.length === 1 && (
          <circle cx={geo.x(0)} cy={geo.y(monthly[0].currentTotal)} r={3.6} fill={CLAY} stroke="var(--card)" strokeWidth={2} />
        )}

        {monthly.map((m, i) => {
          if (i % 2 !== 0 && i !== last) return null;
          return (
            <text
              key={`x${i}`}
              x={geo.x(i)}
              y={H - 8}
              textAnchor={i === last ? 'end' : 'middle'}
              fill="var(--faint)"
              fontSize={8.5}
            >
              {monthLabel(m.month)}
            </text>
          );
        })}

        {/* hover 列 */}
        {monthly.map((_m, i) => {
          const half = plotW / Math.max(1, monthly.length - 1) / 2;
          const rx = Math.max(PAD.l, geo.x(i) - half);
          const rw = Math.min(W - PAD.r, geo.x(i) + half) - rx;
          return (
            <rect
              key={`h${i}`}
              x={rx}
              y={PAD.t}
              width={rw}
              height={plotH}
              fill="transparent"
              style={{ cursor: 'crosshair' }}
              onMouseEnter={() => setHover(i)}
              onMouseMove={() => setHover(i)}
              onMouseLeave={() => setHover(null)}
            />
          );
        })}
      </svg>

      {hover !== null && (
        <div
          className="diff-tip"
          style={{
            left: `${(geo.x(hover) / W) * 100}%`,
            top: `${(Math.min(geo.y(monthly[hover].currentTotal), geo.y(monthly[hover].marketTotal)) / H) * 100}%`,
          }}
        >
          <div className="m">
            {monthLabel(monthly[hover].month)}
            {monthly[hover].isSpike ? ' · 高騰月' : ''}
          </div>
          <div className="r">
            <span>
              <span className="dot" style={{ background: CLAY }} />現行
            </span>
            <span>{yen(monthly[hover].currentTotal)}</span>
          </div>
          <div className="r">
            <span>
              <span className="dot" style={{ background: TEAL }} />市場連動
            </span>
            <span>{yen(monthly[hover].marketTotal)}</span>
          </div>
        </div>
      )}
    </div>
  );
}
