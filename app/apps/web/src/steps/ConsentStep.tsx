export function ConsentStep({ loading, onConsent }: { loading: boolean; onConsent: () => void }) {
  return (
    <div>
      <h2>データ提供への同意</h2>
      <p className="lead">
        電力データ活用制度に基づき、スマートメーターの 30 分値と契約情報を取得して診断します。以下に同意のうえお進みください。
      </p>
      <dl className="consent-list">
        <div>
          <dt>提供先</dt>
          <dd>非実在電力株式会社</dd>
        </div>
        <div>
          <dt>利用目的</dt>
          <dd>料金プラン診断および切替の提案</dd>
        </div>
        <div>
          <dt>取得データ</dt>
          <dd>30 分ごとの電力使用量、契約マスタ（契約電力・名義等）</dd>
        </div>
        <div>
          <dt>提供期間</dt>
          <dd>同意日から 1 年間</dd>
        </div>
      </dl>
      <button type="button" className="primary" onClick={onConsent} disabled={loading}>
        {loading ? '処理中…' : '同意してデータを取得'}
      </button>
    </div>
  );
}
