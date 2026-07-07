export type Step =
  | 'phone'
  | 'sms'
  | 'consent'
  | 'fetching'
  | 'result'
  | 'application'
  | 'done';

const STEPS: { key: Step; label: string }[] = [
  { key: 'phone', label: '電話番号' },
  { key: 'sms', label: 'SMS認証' },
  { key: 'consent', label: '同意' },
  { key: 'result', label: '診断結果' },
  { key: 'application', label: '申込' },
];

// fetching は result に、done は application に畳んで表示する
const collapse = (s: Step): Step => (s === 'fetching' ? 'result' : s === 'done' ? 'application' : s);

export function Stepper({ current }: { current: Step }) {
  const cur = collapse(current);
  const curIdx = STEPS.findIndex((s) => s.key === cur);
  return (
    <div className="rail-wrap">
      <ol className="rail" aria-label={`ステップ ${curIdx + 1} / ${STEPS.length}: ${STEPS[curIdx]?.label}`}>
        {STEPS.map((s, i) => {
          const status = i < curIdx ? 'complete' : i === curIdx ? 'current' : 'upcoming';
          return <li key={s.key} className={status} />;
        })}
      </ol>
      <p className="rail-cap" aria-hidden="true">
        STEP {curIdx + 1} / {STEPS.length} · {STEPS[curIdx]?.label}
      </p>
    </div>
  );
}
