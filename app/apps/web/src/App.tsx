import { useReducer, useEffect, useCallback } from 'react';
import type { DiagnosisResult, ContractInfo } from '@diag/core';
import { client, auth } from './api.ts';
import { Stepper, type Step } from './components/Stepper.tsx';
import { PhoneStep } from './steps/PhoneStep.tsx';
import { SmsStep } from './steps/SmsStep.tsx';
import { ConsentStep } from './steps/ConsentStep.tsx';
import { FetchingStep } from './steps/FetchingStep.tsx';
import { ResultStep } from './steps/ResultStep.tsx';
import { ApplicationStep } from './steps/ApplicationStep.tsx';
import { DoneStep } from './steps/DoneStep.tsx';

interface State {
  step: Step;
  phone: string;
  token?: string;
  consentId?: string;
  diagnosis?: DiagnosisResult;
  contract?: ContractInfo;
  loading: boolean;
  error?: string;
  /** 診断(fetching)の再試行 nonce。bump で useEffect を再実行させる */
  retry: number;
}

type Action =
  | { type: 'smsSent'; phone: string }
  | { type: 'verified'; token: string }
  | { type: 'consented'; consentId: string; token: string }
  | { type: 'diagnosed'; diagnosis: DiagnosisResult }
  | { type: 'toApplication'; contract: ContractInfo }
  | { type: 'applied' }
  | { type: 'backToPhone' }
  | { type: 'retry' }
  | { type: 'loading'; loading: boolean }
  | { type: 'error'; error?: string };

const initial: State = { step: 'phone', phone: '', loading: false, retry: 0 };

function reducer(s: State, a: Action): State {
  switch (a.type) {
    case 'smsSent':
      return { ...s, step: 'sms', phone: a.phone, loading: false, error: undefined };
    case 'verified':
      return { ...s, step: 'consent', token: a.token, loading: false, error: undefined };
    case 'consented':
      return { ...s, step: 'fetching', consentId: a.consentId, token: a.token, error: undefined };
    case 'diagnosed':
      return { ...s, step: 'result', diagnosis: a.diagnosis, loading: false, error: undefined };
    case 'toApplication':
      return { ...s, step: 'application', contract: a.contract, loading: false, error: undefined };
    case 'applied':
      return { ...s, step: 'done', loading: false, error: undefined };
    case 'backToPhone':
      return { ...initial };
    case 'retry':
      // fetching に留まったまま nonce を bump して診断を再実行
      return { ...s, step: 'fetching', error: undefined, retry: s.retry + 1 };
    case 'loading':
      return { ...s, loading: a.loading };
    case 'error':
      return { ...s, loading: false, error: a.error };
    default:
      return s;
  }
}

export function App() {
  const [state, dispatch] = useReducer(reducer, initial);

  const onError = useCallback((e: unknown) => {
    dispatch({ type: 'error', error: e instanceof Error ? e.message : '通信に失敗しました' });
  }, []);

  // phone-input: 電話番号送信 → SMS
  const submitPhone = useCallback(
    async (phone: string) => {
      dispatch({ type: 'loading', loading: true });
      try {
        const res = await client.api.auth.sms.$post({ json: { phone } });
        if (!res.ok) throw new Error('SMS 送信に失敗しました');
        dispatch({ type: 'smsSent', phone });
      } catch (e) {
        onError(e);
      }
    },
    [onError],
  );

  // sms-verify: コード検証 → token
  const submitCode = useCallback(
    async (code: string) => {
      dispatch({ type: 'loading', loading: true });
      try {
        const res = await client.api.auth.verify.$post({ json: { phone: state.phone, code } });
        if (!res.ok) throw new Error('認証コードが正しくありません');
        const { token } = await res.json();
        dispatch({ type: 'verified', token });
      } catch (e) {
        onError(e);
      }
    },
    [state.phone, onError],
  );

  // consent: 同意 → consentId + token 再発行 → fetching へ
  const submitConsent = useCallback(async () => {
    if (!state.token) return;
    dispatch({ type: 'loading', loading: true });
    try {
      const res = await client.api.consent.$post({}, auth(state.token));
      if (!res.ok) throw new Error('同意処理に失敗しました');
      const { consentId, token } = await res.json();
      dispatch({ type: 'consented', consentId, token });
    } catch (e) {
      onError(e);
    }
  }, [state.token, onError]);

  // fetching: step に入ったら診断を実行
  useEffect(() => {
    if (state.step !== 'fetching' || !state.token) return;
    let cancelled = false;
    (async () => {
      try {
        const res = await client.api.diagnose.$post({}, auth(state.token!));
        if (!res.ok) throw new Error('診断に失敗しました');
        const diagnosis = await res.json();
        if (!cancelled) dispatch({ type: 'diagnosed', diagnosis });
      } catch (e) {
        if (!cancelled) onError(e);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [state.step, state.token, state.retry, onError]);

  // result -> application: 契約マスタ取得（プレフィル）
  const toApplication = useCallback(async () => {
    if (!state.token) return;
    dispatch({ type: 'loading', loading: true });
    try {
      // Hono RPC: headers は第2引数の options に渡す（第1引数は request args）
      const res = await client.api.contract.$get({}, auth(state.token));
      if (!res.ok) throw new Error('契約情報の取得に失敗しました');
      const contract = await res.json();
      dispatch({ type: 'toApplication', contract });
    } catch (e) {
      onError(e);
    }
  }, [state.token, onError]);

  // application -> done
  const submitApplication = useCallback(
    async (form: ContractInfo & { email: string }) => {
      if (!state.token) return;
      dispatch({ type: 'loading', loading: true });
      try {
        const res = await client.api.application.$post({ json: form }, auth(state.token));
        if (!res.ok) throw new Error('申込に失敗しました');
        dispatch({ type: 'applied' });
      } catch (e) {
        onError(e);
      }
    },
    [state.token, onError],
  );

  return (
    <div className="app">
      <header className="app-header">
        <h1>ワンタップ実データ診断</h1>
        <p className="tagline">同意だけで、あなたの実データで電気代を診断</p>
      </header>

      <Stepper current={state.step} />

      {state.error && state.step !== 'fetching' && (
        <div className="error" role="alert">{state.error}</div>
      )}

      <main className="card">
        {state.step === 'phone' && <PhoneStep loading={state.loading} onSubmit={submitPhone} />}
        {state.step === 'sms' && (
          <SmsStep loading={state.loading} phone={state.phone} onSubmit={submitCode} onBack={() => dispatch({ type: 'backToPhone' })} />
        )}
        {state.step === 'consent' && <ConsentStep loading={state.loading} onConsent={submitConsent} />}
        {state.step === 'fetching' && (
          <FetchingStep
            error={state.error}
            onRetry={() => dispatch({ type: 'retry' })}
            onBack={() => dispatch({ type: 'backToPhone' })}
          />
        )}
        {state.step === 'result' && state.diagnosis && (
          <ResultStep diagnosis={state.diagnosis} loading={state.loading} onApply={toApplication} />
        )}
        {state.step === 'application' && state.contract && (
          <ApplicationStep contract={state.contract} loading={state.loading} onSubmit={submitApplication} />
        )}
        {state.step === 'done' && <DoneStep />}
      </main>

      <footer className="app-footer">デモ（サンプルデータ・モック連携）。実際の契約・申込は行われません。</footer>
    </div>
  );
}
