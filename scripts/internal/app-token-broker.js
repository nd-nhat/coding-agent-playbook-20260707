#!/usr/bin/env node
// GitHub App installation-token broker for sbx boxes (design: 案Z).
//
// The sbx proxy substitutes a stored `github` secret into the box's outbound
// github requests, so whichever token is stored decides the PR author. This
// broker mints a short-lived, repo-scoped App installation token on the HOST
// (where the App private key lives) and pushes it into a box's per-box github
// secret via `sbx secret set`. The box never holds the private key or the token
// (it only ever sees the sentinel), yet authors PRs as the App bot. Installation
// tokens expire in 1h, so the loop re-mints well before expiry.
//
// node built-in only (crypto/https) — matches the repo's "node as the single
// cross-platform runtime" exception, so no .sh/.ps1 pair is needed.

const https = require('node:https');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function b64url(input) {
  return Buffer.from(input).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) continue;
    const key = argv[i].slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) out[key] = true;
    else { out[key] = next; i++; }
  }
  return out;
}

function loadLocalConfig() {
  // gitignored per-machine config (appId / keyPath; owner/repo auto-derive from the origin remote).
  // Surface a malformed/unreadable file instead of returning {}, or an operator typo silently disables the broker.
  const p = path.resolve(process.cwd(), '.claude/app-broker.local.json');
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (e) {
    if (e && e.code === 'ENOENT') return {};
    throw new Error(`failed to load ${p}: ${e.message}`);
  }
}

function deriveOwnerRepo() {
  // owner/repo default to the current repo's github.com origin. Anchored to github.com with exactly
  // owner/repo so a non-github / nested remote returns {} (fail-closed) instead of minting the wrong repo.
  const r = spawnSync('git', ['remote', 'get-url', 'origin'], { encoding: 'utf8' });
  if (r.status !== 0) return {};
  // scp-like git@github.com:o/r, https://github.com/o/r, ssh://git@github.com/o/r,
  // and SSH-over-HTTPS ssh://git@ssh.github.com:443/o/r — all with an optional .git suffix.
  const m = (r.stdout || '').trim()
    .match(/^(?:git@github\.com:|(?:https|ssh):\/\/(?:[^@/]+@)?(?:ssh\.)?github\.com(?::\d+)?\/)([^/]+)\/([^/]+?)(?:\.git)?$/);
  return m ? { owner: m[1], repo: m[2] } : {};
}

function makeAppJwt(appId, keyPem) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  // exp < 10min; iat back-dated 60s to tolerate host/GitHub clock skew.
  const payload = b64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: String(appId) }));
  const signingInput = `${header}.${payload}`;
  const sig = crypto.sign('RSA-SHA256', Buffer.from(signingInput), keyPem);
  return `${signingInput}.${b64url(sig)}`;
}

function ghApi(method, apiPath, token, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const req = https.request({
      host: 'api.github.com', path: apiPath, method,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'app-token-broker',
        ...(data ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } : {}),
      },
    }, (res) => {
      let chunks = '';
      res.on('data', (c) => { chunks += c; });
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) resolve(chunks ? JSON.parse(chunks) : {});
        else reject(new Error(`GitHub ${method} ${apiPath} -> ${res.statusCode}: ${chunks.slice(0, 300)}`));
      });
    });
    req.on('error', reject);
    // Without a timeout a stalled TCP/TLS handshake leaves the promise pending forever, wedging the refresh
    // loop (which awaits ghApi). destroy() surfaces the error so the loop's catch retries on the short interval.
    req.setTimeout(30000, () => req.destroy(new Error(`GitHub ${method} ${apiPath} timed out`)));
    if (data) req.write(data);
    req.end();
  });
}

async function resolveInstallationId(jwt, owner, repo) {
  // Resolve the installation covering owner/repo directly: one call, no pagination over /app/installations,
  // and a 404 if the App is not installed on that exact repo (inherent fail-closed, no owner/list matching).
  const inst = await ghApi('GET', `/repos/${owner}/${repo}/installation`, jwt);
  return inst.id;
}

function setBoxSecret(box, token) {
  // token via stdin (not argv) so it never appears in `ps`.
  const r = spawnSync('sbx', ['secret', 'set', box, 'github', '-f'], { input: token, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`sbx secret set ${box} github failed: ${(r.stderr || r.stdout || '').trim()}`);
}

async function refreshOnce(cfg) {
  const keyPem = fs.readFileSync(cfg.keyPath, 'utf8');
  const jwt = makeAppJwt(cfg.appId, keyPem);
  const installationId = await resolveInstallationId(jwt, cfg.owner, cfg.repo);
  const res = await ghApi('POST', `/app/installations/${installationId}/access_tokens`, jwt, { repositories: [cfg.repo] });
  const token = res.token;
  if (cfg.box) {
    setBoxSecret(cfg.box, token);
    console.error(`[broker] box '${cfg.box}' github <- App token (installation ${installationId}, repo ${cfg.repo}, exp ${res.expires_at})`);
  } else if (cfg.printToken) {
    process.stdout.write(`${token}\n`);
  } else {
    console.error(`[broker] minted installation token (installation ${installationId}, repo ${cfg.repo}, exp ${res.expires_at}); pass --box to inject or --print-token to emit`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const file = loadLocalConfig();
  const derived = deriveOwnerRepo();
  const cfg = {
    appId: args['app-id'] || process.env.APP_BROKER_APP_ID || file.appId,
    keyPath: args.key || process.env.APP_BROKER_KEY || file.keyPath,
    owner: args.owner || process.env.APP_BROKER_OWNER || derived.owner,
    repo: args.repo || process.env.APP_BROKER_REPO || derived.repo,
    box: args.box || process.env.APP_BROKER_BOX || file.box,
    printToken: Boolean(args['print-token']),
  };
  const once = Boolean(args.once);
  const intervalSec = Number(args.interval || file.intervalSec || 3000);

  const missing = ['appId', 'keyPath', 'owner', 'repo'].filter((k) => !cfg[k]);
  if (missing.length) {
    console.error(`app-token-broker: missing config: ${missing.join(', ')}`);
    console.error('appId/keyPath: set in .claude/app-broker.local.json (or --app-id/--key, APP_BROKER_*).');
    console.error('owner/repo: auto-derive from the github.com origin; override with --owner/--repo or APP_BROKER_OWNER/REPO if origin is not a github.com remote.');
    process.exit(2);
  }

  if (once || !cfg.box) { await refreshOnce(cfg); return; }
  // Retry quickly until the first successful inject: on a fresh start the box may not exist yet when the
  // broker launches, so `sbx secret set` fails once. After a success, refresh well before the 1h token
  // expiry. Any later failure also drops back to the short interval so a transient error self-heals fast.
  const fastRetrySec = Math.min(10, intervalSec);
  for (;;) {
    let ok = false;
    try { await refreshOnce(cfg); ok = true; }
    catch (e) { console.error(`[broker] refresh failed: ${e.message}`); }
    await new Promise((r) => setTimeout(r, (ok ? intervalSec : fastRetrySec) * 1000));
  }
}

main().catch((e) => { console.error(`app-token-broker: ${e.message}`); process.exit(1); });
