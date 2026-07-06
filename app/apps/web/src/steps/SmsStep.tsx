import { useState } from 'react';

// デモモードのみ固定コードのヒントを出す（本番=VITE_DEMO='false' では隠す）
const DEMO = import.meta.env.VITE_DEMO !== 'false';

export function SmsStep({
  loading,
  phone,
  onSubmit,
  onBack,
}: {
  loading: boolean;
  phone: string;
  onSubmit: (code: string) => void;
  onBack: () => void;
}) {
  const [code, setCode] = useState('');
  const valid = /^\d{6}$/.test(code);
  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        if (valid) onSubmit(code);
      }}
    >
      <h2>SMS 認証コード</h2>
      <p className="lead">
        {phone} に送信した 6 桁のコードを入力してください。
        {DEMO && (
          <>
            <br />
            <span className="demo-note">（デモ：コードは <strong>123456</strong>）</span>
          </>
        )}
      </p>
      <label className="field">
        <span>認証コード</span>
        <input
          type="text"
          inputMode="numeric"
          maxLength={6}
          value={code}
          onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))}
          placeholder="______"
          autoComplete="one-time-code"
        />
      </label>
      <button type="submit" className="primary" disabled={!valid || loading}>
        {loading ? '確認中…' : '認証する'}
      </button>
      <button type="button" className="link" onClick={onBack} disabled={loading}>
        電話番号を入力し直す
      </button>
    </form>
  );
}
