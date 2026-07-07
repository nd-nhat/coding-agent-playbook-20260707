import type { DiagnosisResult } from '@diag/core';
import { yen, monthLabel } from '../format.ts';
import { heroVariant } from './heroVariant.ts';
import { DiffChart } from '../components/DiffChart.tsx';

export function ResultStep({
  diagnosis,
  loading,
  onApply,
  onShowSummary,
}: {
  diagnosis: DiagnosisResult;
  loading: boolean;
  onApply: () => void;
  onShowSummary?: () => void;
}) {
  const variant = heroVariant(diagnosis.annualDiff);
  const cheaper = variant === 'good';
  const breakEven = variant === 'even';
  const spikes = diagnosis.monthly.filter((m) => m.isSpike).map((m) => monthLabel(m.month));

  return (
    <div className="result">
      <div className={`hero ${variant}`}>
        <span className="hero-label">市場連動プランなら年間</span>
        <span className="hero-amount">
          {breakEven
            ? '差額なしの見込み'
            : `${yen(Math.abs(diagnosis.annualDiff))} ${cheaper ? '安くなる見込み' : '高くなる見込み'}`}
        </span>
        <span className="hero-sub">
          {breakEven
            ? '実効差 0.0%'
            : `実効${cheaper ? '削減' : '増加'}率 ${(Math.abs(diagnosis.annualDiffPct) * 100).toFixed(1)}%`}
          （現行 年間 {yen(diagnosis.annualCurrent)}）
        </span>
      </div>

      <h3>過去 12 ヶ月のバックテスト</h3>
      <div className="diff-legend" aria-hidden="true">
        <span><i className="sw clay" />現行プラン</span>
        <span><i className="sw teal" />市場連動</span>
        {spikes.length > 0 && <span><i className="sw spike" />高騰月</span>}
      </div>
      <div className="chart">
        <DiffChart monthly={diagnosis.monthly} />
      </div>

      {spikes.length > 0 && (
        <p className="spike-note">
          高騰月（{spikes.join('・')}）は市場連動が高くなります。高騰も隠さず、実データで正直に提示しています。
        </p>
      )}

      <button type="button" className="primary" onClick={onApply} disabled={loading}>
        {loading ? '準備中…' : 'この内容で申し込む'}
      </button>

      {onShowSummary && (
        <button type="button" className="link" onClick={onShowSummary} disabled={loading}>
          詳細サマリを表示
        </button>
      )}
    </div>
  );
}
