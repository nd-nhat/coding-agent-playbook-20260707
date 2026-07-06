export function FetchingStep({
  error,
  onRetry,
  onBack,
}: {
  error?: string;
  onRetry: () => void;
  onBack: () => void;
}) {
  // 診断失敗時はスピナーに張り付かせず、再試行/やり直しの導線を出す
  if (error) {
    return (
      <div className="fetching">
        <h2>診断に失敗しました</h2>
        <p className="lead">{error}</p>
        <button type="button" className="primary" onClick={onRetry}>
          再試行する
        </button>
        <button type="button" className="link" onClick={onBack}>
          最初からやり直す
        </button>
      </div>
    );
  }
  return (
    <div className="fetching">
      <div className="spinner" aria-hidden />
      <h2>実データを取得して診断中…</h2>
      <p className="lead">スマートメーターの 30 分値（過去 12 ヶ月）と市場価格を取得し、料金を計算しています。</p>
    </div>
  );
}
