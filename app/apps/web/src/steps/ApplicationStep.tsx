import { useState } from 'react';
import type { ContractInfo } from '@diag/core';

export function ApplicationStep({
  contract,
  loading,
  onSubmit,
}: {
  contract: ContractInfo;
  loading: boolean;
  onSubmit: (form: ContractInfo & { email: string }) => void;
}) {
  // 契約マスタをプレフィル
  const [holderName, setHolderName] = useState(contract.holderName);
  const [address, setAddress] = useState(contract.address);
  const [email, setEmail] = useState('');
  const emailValid = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email);

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        if (emailValid) {
          onSubmit({ ...contract, holderName, address, email });
        }
      }}
    >
      <h2>お申し込み</h2>
      <p className="lead">取得した契約情報をプレフィルしています。ご確認のうえお申し込みください。</p>

      <label className="field">
        <span>契約名義</span>
        <input value={holderName} onChange={(e) => setHolderName(e.target.value)} />
      </label>
      <label className="field">
        <span>供給地点特定番号</span>
        <input value={contract.supplyPointId} readOnly />
      </label>
      <label className="field">
        <span>契約電力</span>
        <input value={`${contract.contractAmpere} A`} readOnly />
      </label>
      <label className="field">
        <span>住所</span>
        <input value={address} onChange={(e) => setAddress(e.target.value)} />
      </label>
      <label className="field">
        <span>メールアドレス</span>
        <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" />
      </label>
      {!emailValid && email.length > 0 && <p className="hint-error">メールアドレスの形式が正しくありません</p>}

      <button type="submit" className="primary" disabled={!emailValid || loading}>
        {loading ? '送信中…' : '申し込む'}
      </button>
    </form>
  );
}
