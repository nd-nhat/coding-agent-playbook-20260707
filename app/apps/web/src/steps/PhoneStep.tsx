import { useState } from 'react';

// 携帯番号（070/080/090 + 8桁）。backend の zPhone と一致させる
const PHONE_RE = /^0[789]0-?\d{4}-?\d{4}$/;

export function PhoneStep({ loading, onSubmit }: { loading: boolean; onSubmit: (phone: string) => void }) {
  // 初期値は空（誤送信防止）。例は placeholder で示す
  const [phone, setPhone] = useState('');
  const valid = PHONE_RE.test(phone);
  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        if (valid) onSubmit(phone);
      }}
    >
      <h2>電話番号で本人確認</h2>
      <p className="lead">SMS 認証で本人確認します。データ提供に同意するだけで、検針票の撮影も手入力も不要です。</p>
      <label className="field">
        <span>携帯電話番号</span>
        <input
          type="tel"
          inputMode="tel"
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
          placeholder="090-1234-5678"
          autoComplete="tel"
        />
      </label>
      {!valid && phone.length > 0 && <p className="hint-error">電話番号の形式が正しくありません</p>}
      <button type="submit" className="primary" disabled={!valid || loading}>
        {loading ? '送信中…' : 'SMS を送信'}
      </button>
    </form>
  );
}
