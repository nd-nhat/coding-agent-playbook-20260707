#!/usr/bin/env node
// SSRF-safe fetcher: host 側 /host-fetch-grant が box の代理で 1 URL を取得するときの中核。
// box は untrusted (injection 経路) なので、box が指定する URL を host が踏む = SSRF の入口になる
// (box は host からしか見えない 169.254.169.254 metadata / localhost の admin port / LAN host を
// host に踏ませられる)。この検証ロジックは IPv4/IPv6 の特殊レンジ判定・IPv4-mapped 展開・DNS
// rebinding 対策 (接続に使う解決済み IP をそのまま検証) など間違えると穴になる細かさなので、
// bash/PowerShell に二重実装せず node 単一実装にする (CLAUDE.md「cross-platform 要件」の node 例外。
// security-critical logic を 1 箇所に閉じるための積極的選択で、.sh/.ps1 の欠落ではない)。
//
// 契約:
//   node host-fetch.js <url> [--method GET|HEAD] [--max-bytes N] [--timeout-ms N]
//                            [--max-redirs 0] [--out-dir DIR]
//   - 標準出力に単一 JSON を出す (成功/失敗いずれも JSON。exit code でも区別)
//   - redirect は追わない (max-redirs は将来拡張の予約。3xx は Location を返して box に再 fetch させる)
//   - GET/HEAD のみ / credential・cookie・Authorization・proxy env は一切送らない / TLS 検証 ON
//   - 解決 IP が private/loopback/link-local/ULA/CGNAT/multicast/IPv4-mapped 等なら接続前に拒否
//   - 本文は「小さい text」だけ inline(body)。それ以外は out-dir に artifact を落として path+sha256+mime を返す
//
// exit code: 0=成功(2xx/3xx を JSON で報告), 3=SSRF ブロック, 4=引数エラー, 5=fetch エラー(DNS/接続/timeout)

'use strict';

// SSRF guard を権威にするため env proxy を無効化する。Node 22+ の NODE_USE_ENV_PROXY=1 や
// HTTP(S)_PROXY が効いていると、Node は target ではなく proxy に接続するため lookup hook が
// target IP を検証できず guard が素通りになる (proxy 経由だと解決/接続を proxy が行う)。host-fetch は
// 「host が target へ直接到達できる」前提の道具 (box が sbx policy で塞がれている先を host が代理取得) なので
// 直結が正。直結不可で proxy が必須なら、それは host も同じ制約 = corporate policy の領域で host-fetch の
// 対象外。require の前に env を落として http module 初期化時点で proxy を掴ませない。
// proxy 制御 env は「0 を代入」ではなく完全削除する。NODE_USE_ENV_PROXY の built-in proxy agent は
// no_proxy に載る host (localhost 等) を「proxy 迂回の直結」として扱うが、その直結経路は request の
// lookup option を通さず解決するため guard が素通りする。値を残すと迂回ロジックが生き続けるので、
// proxy / no_proxy / 有効化フラグを全て消して「素の直結 + custom lookup」に一本化する。
for (const k of [
  'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy', 'ALL_PROXY', 'all_proxy',
  'npm_config_proxy', 'npm_config_https_proxy', 'NODE_USE_ENV_PROXY', 'no_proxy', 'NO_PROXY',
]) {
  delete process.env[k];
}

const http = require('http');
const https = require('https');
const dns = require('dns');
const net = require('net');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

function emit(obj, code) {
  process.stdout.write(JSON.stringify(obj) + '\n');
  process.exit(code);
}

function fail(kind, message, code) {
  emit({ ok: false, kind, error: message }, code);
}

// ---- 引数 parse ----
const argv = process.argv.slice(2);
if (argv.length < 1) {
  fail('args', 'usage: host-fetch.js <url> [--method GET|HEAD] [--max-bytes N] [--timeout-ms N] [--out-dir DIR]', 4);
}
const rawUrl = argv[0];
const opts = {
  method: 'GET',
  maxBytes: 5 * 1024 * 1024, // 5MB 超は truncate して artifact 化 (host メモリ/disk 保護)
  timeoutMs: 20000,
  outDir: '.claude/host-bridge',
};
for (let i = 1; i < argv.length; i++) {
  const a = argv[i];
  const next = () => {
    const v = argv[++i];
    if (v === undefined) fail('args', `missing value for ${a}`, 4);
    return v;
  };
  if (a === '--method') opts.method = next().toUpperCase();
  else if (a === '--max-bytes') opts.maxBytes = parseInt(next(), 10);
  else if (a === '--timeout-ms') opts.timeoutMs = parseInt(next(), 10);
  else if (a === '--inline-cap') opts.inlineCap = parseInt(next(), 10);
  else if (a === '--out-dir') opts.outDir = next();
  else if (a === '--max-redirs') next(); // 予約 (現状 redirect 非追従で固定)
  else if (a === '--validate-only') opts.validateOnly = true; // URL + literal-IP 検証のみで fetch しない
  else fail('args', `unknown option: ${a}`, 4);
}
if (opts.method !== 'GET' && opts.method !== 'HEAD') {
  fail('args', `method must be GET or HEAD (got ${opts.method}); box の代理 fetch は読み取りのみ`, 4);
}
for (const [k, v] of [['maxBytes', opts.maxBytes], ['timeoutMs', opts.timeoutMs]]) {
  if (!Number.isFinite(v) || v <= 0) fail('args', `--${k} must be a positive number`, 4);
}

// ---- URL 検証 ----
let u;
try {
  // WHATWG URL parser は decimal/octal/hex IPv4 リテラル (0x7f000001 / 017700000001 / 2130706433) を
  // dotted-decimal に正規化するので、この時点で数値表記の loopback 偽装は canonical 形に落ちる。
  // 最終防御は「解決済み IP のレンジ判定」(lookup hook) 側にあるため、ここは protocol/method の門番。
  u = new URL(rawUrl);
} catch (e) {
  fail('args', `invalid URL: ${rawUrl}`, 4);
}
if (u.protocol !== 'http:' && u.protocol !== 'https:') {
  fail('args', `only http/https allowed (got ${u.protocol})`, 4);
}
if (u.username || u.password) {
  // URL 埋め込み credential は送らない方針を破るので拒否 (http://user:pass@host)
  fail('args', 'credentials in URL are not allowed', 4);
}

// 末尾ドット (FQDN root, "localhost." / "example.com.") を剥がして正規化する。解決先は同じだが、
// 一部環境 (transparent proxy 等) が trailing-dot host を「no_proxy 非該当」と見なして custom lookup を
// 通さない別経路に流し、guardedLookup を素通りさせる観測があるため。剥がすことで必ず guard を通す。
if (u.hostname.endsWith('.') && u.hostname !== '.') {
  u.hostname = u.hostname.replace(/\.+$/, '');
}

// 重要: host が数値 IP リテラルの場合、Node の net.connect は DNS 解決を行わず lookup hook を
// 呼ばない。従って literal-IP URL (http://169.254.169.254/ や WHATWG が正規化した decimal/hex/octal)
// は guardedLookup を素通りする。ここで host を直接判定して塞ぐ (これが無いと SSRF guard に大穴)。
// u.hostname は IPv6 を角括弧付きで返す ([::1]) ので剥がしてから net.isIP に掛ける。
const bareHost = u.hostname.replace(/^\[|\]$/g, '');
const litFamily = net.isIP(bareHost);
if (litFamily) {
  const reason = ipBlockedReason(bareHost, litFamily);
  if (reason) fail('ssrf', `SSRF blocked: literal host ${bareHost} (${reason})`, 3);
}

// ---- IP レンジ判定 (SSRF 中核) ----
// public global unicast 以外を deny する denylist 方式。判定漏れが穴になるため広めに弾く。
function ipv4Blocked(ip) {
  const p = ip.split('.').map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return 'malformed-ipv4';
  const [a, b] = p;
  if (a === 0) return 'unspecified/this-network 0.0.0.0/8';
  if (a === 10) return 'private 10.0.0.0/8';
  if (a === 127) return 'loopback 127.0.0.0/8';
  if (a === 169 && b === 254) return 'link-local 169.254.0.0/16';
  if (a === 172 && b >= 16 && b <= 31) return 'private 172.16.0.0/12';
  if (a === 192 && b === 168) return 'private 192.168.0.0/16';
  if (a === 100 && b >= 64 && b <= 127) return 'CGNAT 100.64.0.0/10';
  if (a === 192 && b === 0 && p[2] === 0) return 'IETF 192.0.0.0/24';
  if (a === 192 && b === 0 && p[2] === 2) return 'TEST-NET-1 192.0.2.0/24';
  if (a === 198 && b === 51 && p[2] === 100) return 'TEST-NET-2 198.51.100.0/24';
  if (a === 203 && b === 0 && p[2] === 113) return 'TEST-NET-3 203.0.113.0/24';
  if (a === 198 && (b === 18 || b === 19)) return 'benchmark 198.18.0.0/15';
  if (a === 192 && b === 88 && p[2] === 99) return '6to4-relay 192.88.99.0/24';
  if (a >= 224 && a <= 239) return 'multicast 224.0.0.0/4';
  if (a >= 240) return 'reserved 240.0.0.0/4';
  return null;
}

function expandV6(ip) {
  // "::ffff:127.0.0.1" のような mixed 表記も含めて 8 グループの 16bit 配列に展開する
  let embeddedV4 = null;
  let head = ip;
  const lastColon = ip.lastIndexOf(':');
  const tail = ip.slice(lastColon + 1);
  if (tail.includes('.')) {
    // 末尾が dotted IPv4 (IPv4-mapped / NAT64 / 6to4-in-textual)
    embeddedV4 = tail;
    head = ip.slice(0, lastColon + 1);
  }
  const dbl = head.indexOf('::');
  let groups;
  if (dbl >= 0) {
    const left = head.slice(0, dbl).split(':').filter((s) => s.length);
    const right = head.slice(dbl + 2).split(':').filter((s) => s.length);
    const embeddedGroups = embeddedV4 ? 2 : 0;
    const missing = 8 - left.length - right.length - embeddedGroups;
    groups = left.concat(Array(Math.max(0, missing)).fill('0'), right);
  } else {
    groups = head.split(':').filter((s) => s.length);
  }
  const nums = groups.map((g) => parseInt(g, 16) & 0xffff);
  if (embeddedV4) {
    const q = embeddedV4.split('.').map(Number);
    nums.push(((q[0] << 8) | q[1]) & 0xffff, ((q[2] << 8) | q[3]) & 0xffff);
  }
  while (nums.length < 8) nums.push(0);
  return { nums: nums.slice(0, 8), embeddedV4 };
}

// IPv6 は allowlist posture: global unicast 2000::/3 の中で「special sub-range でない」ものだけ通す。
// denylist だと ::127.0.0.1 (IPv4-compatible)・::ffff:0:127.0.0.1・100::/64・2001:db8::/32 等の抜けが出る。
// embedded-v4 を持つ遷移形式 (IPv4-mapped / IPv4-compatible / NAT64 / 6to4) は必ず
// v4 を取り出して ipv4Blocked に掛ける。それ以外は 2000::/3 かつ非 special でなければ block。
function embeddedV4Str(hi, lo) {
  return `${(hi >> 8) & 0xff}.${hi & 0xff}.${(lo >> 8) & 0xff}.${lo & 0xff}`;
}
function ipv6Blocked(ip) {
  const { nums, embeddedV4 } = expandV6(ip);
  const [g0, g1, g2, g3, g4, g5, g6, g7] = nums;
  const top96Zero = g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0 && g5 === 0;

  if (top96Zero && g6 === 0 && g7 === 0) return 'unspecified ::';
  if (top96Zero && g6 === 0 && g7 === 1) return 'loopback ::1';
  // IPv4-compatible ::a.b.c.d (::/96, deprecated & non-global): embedded v4 を判定しつつ常に block
  if (top96Zero) {
    const v4 = embeddedV4 || embeddedV4Str(g6, g7);
    return `IPv4-compatible ::/96 -> ${ipv4Blocked(v4) || 'non-global special form'}`;
  }
  // IPv4-mapped ::ffff:0:0/96 (非 global の遷移形式): embedded v4 を判定しつつ常に block
  if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0 && g5 === 0xffff) {
    const v4 = embeddedV4 || embeddedV4Str(g6, g7);
    return `IPv4-mapped ::ffff:0:0/96 -> ${ipv4Blocked(v4) || 'non-global mapped form'}`;
  }
  // NAT64: g0/g1 だけ見て 64:ff9b::/32 全体を block する (well-known /96 と local-use /48 を内包する保守判定)。
  // /32 全体を弾くので実装は comment より広め = fail-safe。embedded v4 (下位 32bit) も取り出して判定に載せる。
  // 注意: operator 固有 Pref64 (DNS64 が任意 /96 で合成) は検出できない (limitations に明記)。
  if (g0 === 0x64 && g1 === 0xff9b) return `NAT64 64:ff9b::/32 -> ${ipv4Blocked(embeddedV4Str(g6, g7)) || 'NAT64 synthesized'}`;
  // 6to4 2002::/16: bits16-47 の embedded v4 を判定 (常に block: 遷移用で global unicast 扱いしない)
  if (g0 === 0x2002) return `6to4 2002::/16 -> ${ipv4Blocked(embeddedV4Str(g1, g2)) || 'transition form'}`;
  // special-use / documentation ranges
  if (g0 === 0x0100 && g1 === 0 && g2 === 0 && g3 === 0) return 'discard-only 100::/64';
  if (g0 === 0x2001 && g1 === 0x0db8) return 'documentation 2001:db8::/32';
  // 2001::/23 = IETF protocol assignments (Teredo 2001::/32 / ORCHIDv2 / benchmarking 等)。global unicast 実利用は
  // 2001:200:: 以降なので /23 を保守的に block (g1 の上位 7bit が 0 = 2001:0000..2001:01ff)
  if (g0 === 0x2001 && (g1 & 0xfe00) === 0x0000) return 'IETF-special 2001::/23';
  if ((g0 & 0xfe00) === 0xfc00) return 'ULA fc00::/7';
  if ((g0 & 0xffc0) === 0xfe80) return 'link-local fe80::/10';
  if ((g0 & 0xff00) === 0xff00) return 'multicast ff00::/8';
  // allowlist: ここまでで除外されなかった場合、global unicast 2000::/3 (top 3bit = 001) のみ通す
  if ((g0 & 0xe000) !== 0x2000) return 'non-global-unicast (outside 2000::/3)';
  return null;
}

function ipBlockedReason(ip, family) {
  if (family === 4 || net.isIPv4(ip)) return ipv4Blocked(ip);
  if (family === 6 || net.isIPv6(ip)) return ipv6Blocked(ip);
  return `unknown address family for ${ip}`;
}

// DNS 解決した「実際に接続する IP」を検証する lookup hook。http(s).request の lookup に渡すことで、
// 検証した address がそのまま接続に使われる (別解決との TOCTOU / DNS rebinding を構造的に排除)。
function guardedLookup(hostname, options, callback) {
  dns.lookup(hostname, { all: true, verbatim: true }, (err, addresses) => {
    if (err) return callback(err);
    const list = Array.isArray(addresses) ? addresses : [addresses];
    if (!list.length) return callback(new Error(`no address for ${hostname}`));
    // 解決した全 address を検証し、1 つでも blocked なら接続しない (round-robin で別 record に化ける穴を塞ぐ)
    for (const rec of list) {
      const reason = ipBlockedReason(rec.address, rec.family);
      if (reason) {
        const e = new Error(`SSRF blocked: ${hostname} -> ${rec.address} (${reason})`);
        e.ssrf = true;
        return callback(e);
      }
    }
    const chosen = list[0];
    callback(null, chosen.address, chosen.family);
  });
}

// --validate-only: box 側の advisory pre-check 用。URL 形式 + literal-IP レンジ判定まで済んだ時点で
// 「delegate してよい形」と判定して返す (実 fetch はしない)。box DNS と host DNS は環境差があるため
// hostname の解決検証はここでは行わない (host 側 host-fetch.js が接続時に guardedLookup で権威判定する)。
if (opts.validateOnly) {
  emit({ ok: true, kind: 'validate', url: u.href, method: opts.method }, 0);
}

// ---- fetch 実行 ----
const client = u.protocol === 'https:' ? https : http;
const reqOpts = {
  method: opts.method,
  lookup: guardedLookup,
  // credential / cookie / proxy は一切載せない。UA だけ明示 (無 UA を弾く相手向けの最小限)。
  headers: { 'User-Agent': 'coding-agent-playbook-host-fetch/1', 'Accept': '*/*' },
  // TLS 検証は default (rejectUnauthorized: true)。明示的に無効化しない。
};

// truncated は response callback と req.on('error') の両方から見えるよう外側に置く
// (maxBytes 超過で res.destroy() した後に req 側 error が来ても hard fail 化させないため)。
let truncated = false;

const req = client.request(u, reqOpts, (res) => {
  const status = res.statusCode;
  const contentType = res.headers['content-type'] || '';
  const location = res.headers['location'] || null;

  // redirect は追わない: 3xx は Location を box に返し、box が (再検証込みで) 新 URL を再 fetch する。
  // 自動追従すると redirect 先が SSRF レンジに飛ぶ hop ごと再検証が要り、穴になりやすい。
  if (status >= 300 && status < 400 && location) {
    res.resume(); // drain
    // Location は attacker-controlled なので host stdout に出す前に「well-formed な http/https URL」に絞る
    // (HTTP header は 1 行なので改行注入は不可、これで host context に載る redirect 情報を URL 1 本に bound する。
    // 追従はせず box が再検証して /host-fetch を取り直すので、無効な Location は捨ててよい)。
    let safeLocation = null;
    try {
      const lu = new URL(location, u);
      if (lu.protocol === 'http:' || lu.protocol === 'https:') safeLocation = lu.href;
    } catch (_) { /* 無効 Location は落とす */ }
    emit({
      ok: true, kind: 'redirect', status, finalUrl: u.href, contentType,
      location: safeLocation,
      note: 'redirect は自動追従しない。box 側で Location を検証し新規 /host-fetch で取り直すこと',
    }, 0);
    return;
  }

  const chunks = [];
  let received = 0;
  let settled = false;
  const hash = crypto.createHash('sha256');
  const settleFinalize = () => {
    if (settled) return;
    settled = true;
    finalize(status, contentType, chunks, truncated, hash);
  };

  if (opts.method === 'HEAD') {
    res.resume();
    res.on('end', () => emit({
      ok: true, kind: 'head', status, finalUrl: u.href, contentType,
      contentLength: res.headers['content-length'] || null,
    }, 0));
    return;
  }

  res.on('data', (c) => {
    received += c.length;
    if (received <= opts.maxBytes) {
      chunks.push(c);
      hash.update(c);
    } else if (!truncated) {
      // maxBytes 到達: これ以上は捨てて response を切る (巨大レスポンスで host メモリ/disk を食わせない)。
      // req.destroy() でなく res.destroy() を使う (req.destroy() は req 'error' を誘発し、意図した
      // 「truncated artifact」を hard な kind:fetch error に化けさせる)。truncated は正常結果として finalize する。
      truncated = true;
      const room = opts.maxBytes - (received - c.length);
      if (room > 0) { chunks.push(c.slice(0, room)); hash.update(c.slice(0, room)); }
      res.destroy();
    }
  });
  res.on('end', settleFinalize);
  res.on('close', () => { if (truncated) settleFinalize(); });
  res.on('error', (e) => {
    if (truncated) { settleFinalize(); return; }
    if (!settled) { settled = true; fail('fetch', `response error: ${e.message}`, 5); }
  });
});

// socket idle timeout (無通信で timeoutMs)
req.setTimeout(opts.timeoutMs, () => {
  req.destroy(new Error(`idle timeout after ${opts.timeoutMs}ms`));
});
// wall-clock deadline: idle timeout をリセットし続ける drip-feed (slowloris 型) 相手でも全体時間を上限で切る。
// idle timeout だけだと 1 byte/tick で永久に fetch が続く。emit/fail は process.exit するので明示 clear は不要。
const wallClock = setTimeout(() => {
  req.destroy(new Error(`wall-clock timeout after ${opts.timeoutMs}ms`));
}, opts.timeoutMs);
if (wallClock.unref) wallClock.unref();
req.on('error', (e) => {
  if (e.ssrf) fail('ssrf', e.message, 3);
  // truncation で res.destroy() した後に req 側へ来る error は正常な打ち切りなので hard fail にしない
  if (truncated) return;
  fail('fetch', e.message, 5);
});
req.end();

function isTextish(ct) {
  const t = ct.toLowerCase();
  return t.startsWith('text/')
    || t.includes('application/json') || t.endsWith('+json')
    || t.includes('application/xml') || t.endsWith('+xml')
    || t.includes('application/javascript')
    || t.includes('x-www-form-urlencoded')
    || t.includes('application/yaml') || t.includes('application/x-yaml');
}

// artifact を symlink 追従なしで書く。out-dir (.claude/host-bridge) は box が書ける = box が
// fetch-artifact-<hash>.bin を host file への symlink として先回り作成でき、素の writeFileSync だと
// それを追って host file を上書きしうる。O_EXCL ('wx') で既存 path (symlink 含む) には書かない。
// 同 hash artifact が既存の場合だけ lstat で regular file を確認 + 内容一致を照合して再利用する。
function writeArtifactNoFollow(p, body, sha256) {
  try {
    fs.writeFileSync(p, body, { flag: 'wx' });
    return;
  } catch (e) {
    if (e.code !== 'EEXIST') {
      fail('fetch', `cannot write artifact: ${e.message}`, 5);
    }
  }
  // EEXIST: 同 hash artifact が既存。lstat→readFileSync(path) の 2 段は box-writable dir で TOCTOU になる
  // (lstat 後に regular file を symlink/FIFO に差し替えられる)。O_NOFOLLOW で 1 度だけ open し、その fd を
  // fstat + read する (path でなく inode に束ねるので差し替え race を排除)。symlink なら O_NOFOLLOW が ELOOP。
  let fd;
  try {
    fd = fs.openSync(p, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  } catch (oe) {
    fail('fetch', `artifact path exists and is not a safe regular file (symlink attack?): ${p} (${oe.code})`, 3);
  }
  try {
    const st = fs.fstatSync(fd);
    if (!st.isFile()) fail('fetch', `artifact path exists and is not a regular file: ${p}`, 3);
    // 既存 artifact のサイズを maxBytes で上限クランプ (box が巨大 file を仕込んで host に確保させる DoS 防止)。
    // 我々が書く body は maxBytes 以下なので、それを超えるサイズ = 内容不一致確定として弾く。
    if (st.size > opts.maxBytes) fail('fetch', `preexisting artifact exceeds max-bytes (${st.size} > ${opts.maxBytes}): ${p}`, 5);
    const existing = Buffer.alloc(st.size);
    let off = 0;
    while (off < st.size) {
      const n = fs.readSync(fd, existing, off, st.size - off, off);
      if (n <= 0) break;
      off += n;
    }
    if (crypto.createHash('sha256').update(existing.subarray(0, off)).digest('hex') !== sha256) {
      fail('fetch', `artifact path exists with different content: ${p}`, 5);
    }
    // 同一内容が既にある (同 URL の再取得等) → そのまま使う
  } finally {
    fs.closeSync(fd);
  }
}

function finalize(status, contentType, chunks, truncatedFlag, hash) {
  const body = Buffer.concat(chunks);
  const sha256 = hash.digest('hex');
  const byteCount = body.length;
  // 本文は host stdout に一切出さない。inline すると host-fetch-grant が JSON を読む時点で host model が
  // attacker-controlled 本文を context に取り込む = 特権 host session への prompt-injection 経路になる。
  // 常に artifact file に落として meta (path/sha256/size/content-type) だけ返し、untrusted 本文は
  // bind-mount 経由で box 側だけが読む (box は元々その本文を欲しがっている untrusted 側)。
  try {
    fs.mkdirSync(opts.outDir, { recursive: true });
  } catch (e) {
    fail('fetch', `cannot create out-dir ${opts.outDir}: ${e.message}`, 5);
  }
  const artifact = path.join(opts.outDir, `fetch-artifact-${sha256.slice(0, 16)}.bin`);
  writeArtifactNoFollow(artifact, body, sha256);
  emit({
    ok: true, kind: 'artifact', status, finalUrl: u.href, contentType, byteCount, sha256,
    truncated: truncatedFlag, artifactPath: artifact, textLike: isTextish(contentType),
  }, 0);
}
