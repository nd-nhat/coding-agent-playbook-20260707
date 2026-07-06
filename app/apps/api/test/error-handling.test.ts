import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';

// TIMEOUT_MS は external.ts の読み込み時に評価されるため、app の import（動的）より前に固定する
process.env.EXTERNAL_TIMEOUT_MS = '200';

type UpstreamMode = 'error' | 'hang' | 'ok-html' | 'body-hang';
let mode: UpstreamMode = 'error';
let server: Server;
let app: (typeof import('../src/app.ts'))['app'];
let issueToken: (typeof import('../src/auth.ts'))['issueToken'];

before(async () => {
  server = createServer((_req, res) => {
    if (mode === 'hang') return; // 応答せず timeout を誘発
    if (mode === 'ok-html') {
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end('<html>gateway error page</html>');
      return;
    }
    if (mode === 'body-hang') {
      // 200 ヘッダと body の先頭だけ送って stall し、body 読み取り中の timeout を誘発
      res.writeHead(200, { 'content-type': 'application/json' });
      res.write('{"verified":');
      return;
    }
    res.statusCode = 500;
    res.end('upstream boom');
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  process.env.EXTERNAL_BASE_URL = `http://127.0.0.1:${port}`;
  ({ app } = await import('../src/app.ts'));
  ({ issueToken } = await import('../src/auth.ts'));
});

after(() => {
  server.closeAllConnections();
  server.close();
});

test('未定義 route は 404 の JSON を返す', async () => {
  const res = await app.request('/no-such-route');
  assert.equal(res.status, 404);
  assert.deepEqual(await res.json(), { error: 'not found' });
});

test('上流が 5xx を返すと 502 に写像する', async () => {
  mode = 'error';
  const token = await issueToken('sub-1');
  const res = await app.request('/api/consent', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(res.status, 502);
  assert.deepEqual(await res.json(), { error: 'upstream error' });
});

test('上流が timeout すると 504 に写像する', async () => {
  mode = 'hang';
  const res = await app.request('/api/auth/sms', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ phone: '090-1234-5678' }),
  });
  assert.equal(res.status, 504);
  assert.deepEqual(await res.json(), { error: 'upstream timeout' });
});

test('上流が 200 で JSON でない body を返すと 502 に写像する', async () => {
  mode = 'ok-html';
  const res = await app.request('/api/auth/verify', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ phone: '090-1234-5678', code: '123456' }),
  });
  assert.equal(res.status, 502);
  assert.deepEqual(await res.json(), { error: 'upstream error' });
});

test('200 応答後に body が stall すると 504 に写像する', async () => {
  mode = 'body-hang';
  const res = await app.request('/api/auth/verify', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ phone: '090-1234-5678', code: '123456' }),
  });
  assert.equal(res.status, 504);
  assert.deepEqual(await res.json(), { error: 'upstream timeout' });
});

test('SMS verify の上流 5xx はコード不正（401）でなく 502 に写像する', async () => {
  mode = 'error';
  const res = await app.request('/api/auth/verify', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ phone: '090-1234-5678', code: '123456' }),
  });
  assert.equal(res.status, 502);
  assert.deepEqual(await res.json(), { error: 'upstream error' });
});

test('外部呼び出しの失敗は external_call ログに kind 付きで記録される', async () => {
  mode = 'error';
  const lines: string[] = [];
  const original = console.error;
  console.error = (msg?: unknown) => {
    lines.push(String(msg));
  };
  try {
    const token = await issueToken('sub-1');
    await app.request('/api/consent', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
    });
  } finally {
    console.error = original;
  }
  const row = lines
    .map((l) => {
      try {
        return JSON.parse(l) as Record<string, unknown>;
      } catch {
        return null;
      }
    })
    .find((o) => o !== null && o.event === 'external_call');
  // observe 側の切り分け契約: 失敗時のみ path / durationMs / kind で出る
  assert.ok(row, 'external_call ログが出ていること');
  assert.equal(row.kind, 'upstream');
  assert.equal(row.path, '/power-data/consent');
  assert.equal(typeof row.durationMs, 'number');
});

test('上流に到達できない場合は 502 に写像する', async () => {
  const saved = process.env.EXTERNAL_BASE_URL;
  process.env.EXTERNAL_BASE_URL = 'http://127.0.0.1:1'; // 接続拒否されるポート
  try {
    const token = await issueToken('sub-1');
    const res = await app.request('/api/consent', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
    });
    assert.equal(res.status, 502);
  } finally {
    process.env.EXTERNAL_BASE_URL = saved;
  }
});
