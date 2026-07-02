// Claude Code statusLine: box 名 ($SANDBOX_VM_ID) + session_id を出し、host から transcript を引く一意キーにする。
// 取得: sbx exec <box> sh -lc 'cat ~/.claude/projects/*/<session id>.jsonl'
//
// node 実装に統一した理由: statusLine は host session (Windows 含む) でも回る (/pr-ci, /codex-review,
// /host-answer, browser 確認 等は host)。bash 版は jq と GNU date に依存し、Git Bash 同梱でない jq が
// 無い Windows host で無言で blank になっていた。node は claude CLI の動作前提なので host/box の全 OS に
// 必ず居り、単一の committed command (.claude/settings.json) で mac/linux/box/Windows host を賄える。
// command は `node "$(git rev-parse --show-toplevel)/scripts/internal/statusline.js"`。$() は POSIX sh /
// bash / PowerShell 共通の subexpression 構文なので PowerShell 5.1 でも壊れず (PS7 限定なのは && / || の方、
// それらと 2>/dev/null は不使用)、git rev-parse で repo root を解決するため cwd が repo 内のどのサブ
// ディレクトリでも script に到達できる (claude をサブディレクトリから起動しても blank にならない)。
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ESC = '\x1b';
const BEL = '\x07';
const GREEN = '\x1b[32m';
const YELLOW = '\x1b[33m';
const RED = '\x1b[31m';
const DIM = '\x1b[2m';
const UNDERLINE = '\x1b[4m';
const RESET = '\x1b[0m';

function git(args) {
  const r = spawnSync('git', args, { encoding: 'utf8' });
  if (r.status !== 0 || r.error) return null;
  return (r.stdout || '').trim();
}

// 非数値は null を返す (rate limit 未提供時に bar を placeholder へ落とす判定に使う)。
function floorClampPct(v) {
  if (v === null || v === undefined) return null;
  const n = Math.floor(Number(v));
  if (!Number.isFinite(n)) return null;
  return n < 0 ? 0 : n > 100 ? 100 : n;
}

function makeBar(pct) {
  const color = pct >= 90 ? RED : pct >= 70 ? YELLOW : GREEN;
  const width = 10;
  let filled = Math.floor((pct * width) / 100);
  if (filled > width) filled = width;
  const bar = '▓'.repeat(filled) + '░'.repeat(width - filled);
  return `${color}${bar} ${pct}%${RESET}`;
}

const pad2 = (n) => String(n).padStart(2, '0');
// node なら BSD host でも reset 時刻が出る (bash 版の date -d @epoch は GNU 依存で host 環境次第で空だった)。
function fmtEpoch(v, kind) {
  // null は Number(null)=0 で epoch 0 に化けるため明示的に弾く (bash 版の // empty 相当)。
  if (v === null || v === undefined) return '';
  const epoch = Math.floor(Number(v));
  if (!Number.isFinite(epoch)) return '';
  const d = new Date(epoch * 1000);
  const hm = `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  return kind === 'md' ? `${pad2(d.getMonth() + 1)}/${pad2(d.getDate())} ${hm}` : hm;
}

// untrusted repo 防御: remote URL / branch は C0 制御 + DEL を剥がしてから OSC8 に載せ、生 ESC/BEL 注入を防ぐ。
const stripCtrl = (s) => (s || '').replace(/[\x00-\x1f\x7f]/g, '');

function isPidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM'; // 存在するが権限なし
  }
}

function main() {
  let input = {};
  try {
    input = JSON.parse(fs.readFileSync(0, 'utf8')) || {};
  } catch (e) {
    input = {};
  }

  const SESSION = input.session_id || '';
  const MODEL = (input.model && input.model.display_name) || '';
  const BOX = process.env.SANDBOX_VM_ID || 'host';
  const PCT = floorClampPct(input.context_window && input.context_window.used_percentage) || 0;
  const COST = Number((input.cost && input.cost.total_cost_usd) || 0) || 0;
  const COST_FMT = `$${COST.toFixed(2)}`;

  // cdx serve 死活: per-NAME pair lease file (main checkout root 配下の .claude/tmp/cdx-serve-<NAME>.lease) で判定。
  // TCP probe を描画毎に走らせると Windows / WSL2 / VPN で >100ms 税が乗るため、statusline は file stat のみに留め
  // probe は /pr-codex-ci preflight に寄せる。box 内は host PID 名前空間に触れないため file 存在のみで ok 扱い。
  // root 解決は --show-toplevel (worktree root) でなく --git-common-dir の親で行う (writer = a2a-review.sh の cd 先と一致)。
  let CDX_PART = '';
  const gitCommon = git(['rev-parse', '--path-format=absolute', '--git-common-dir']);
  if (gitCommon) {
    const tmpDir = path.join(path.dirname(gitCommon), '.claude', 'tmp');
    if (BOX === 'host') {
      // host: NAME 不明のため任意の lease を 1 件採用し pid 死活で判定。
      // bash 版 (glob + [ -f ]) と同じく lexical sort 後、regular file のみ採用 (複数 box の lease 共存時に決定的に)。
      let lease = '';
      try {
        const f = fs
          .readdirSync(tmpDir)
          .filter((n) => /^cdx-serve-.*\.lease$/.test(n))
          .sort()
          .find((n) => {
            try {
              return fs.statSync(path.join(tmpDir, n)).isFile();
            } catch (e) {
              return false;
            }
          });
        if (f) lease = path.join(tmpDir, f);
      } catch (e) {
        lease = '';
      }
      if (lease) {
        let pid = null;
        try {
          pid = JSON.parse(fs.readFileSync(lease, 'utf8')).pid;
        } catch (e) {
          pid = null;
        }
        CDX_PART = pid && isPidAlive(pid) ? ` ${GREEN}cdx:ok${RESET}` : ` ${YELLOW}cdx:stale${RESET}`;
      } else {
        CDX_PART = ` ${DIM}cdx:n/a${RESET}`;
      }
    } else {
      // box 内: 自分の NAME に対応する lease のみ参照。host PID 検査不能のため file 存在で ok 扱い。
      const lease = path.join(tmpDir, `cdx-serve-${BOX}.lease`);
      CDX_PART = fs.existsSync(lease) ? ` ${GREEN}cdx:ok${RESET}` : ` ${DIM}cdx:n/a${RESET}`;
    }
  }

  let GIT_PART = '';
  if (git(['rev-parse', '--git-dir']) !== null) {
    const BRANCH = stripCtrl(git(['branch', '--show-current']));
    let url = git(['remote', 'get-url', 'origin']) || '';
    url = stripCtrl(
      url
        .replace(/git@([^:]*):/, 'https://$1/')
        .replace(/^([a-z]+:\/\/)[^/@]+@/, '$1')
        .replace(/\.git$/, '')
    );
    if (BRANCH) {
      if (url) {
        const repo = url.replace(/\/+$/, '').split('/').pop();
        GIT_PART = ` ${ESC}]8;;${url}${BEL}${UNDERLINE}${repo}${RESET}${ESC}]8;;${BEL}:${BRANCH}`;
      } else {
        GIT_PART = ` ${BRANCH}`;
      }
    }
  }

  const lines = [];
  if (SESSION) lines.push(`${DIM}[${BOX}] ${SESSION}${RESET}${CDX_PART}`);
  lines.push(`${MODEL}${GIT_PART} ${makeBar(PCT)} ${COST_FMT}`);

  // Rate limits (stdin JSON, Claude Code v2.1.80+)。used_percentage が無い旧版は placeholder bar を出す。
  const rl = input.rate_limits || {};
  const PLACEHOLDER_BAR = `${DIM}░░░░░░░░░░ ---%${RESET}`;

  const fiveUtil = floorClampPct(rl.five_hour && rl.five_hour.used_percentage);
  if (fiveUtil !== null) {
    const t = fmtEpoch(rl.five_hour.resets_at, 'hm');
    lines.push(`5h ${makeBar(fiveUtil)}${t ? `${DIM} reset ${t}${RESET}` : ''}`);
  } else {
    lines.push(`5h ${PLACEHOLDER_BAR}`);
  }

  const sevenUtil = floorClampPct(rl.seven_day && rl.seven_day.used_percentage);
  if (sevenUtil !== null) {
    const t = fmtEpoch(rl.seven_day.resets_at, 'md');
    lines.push(`7d ${makeBar(sevenUtil)}${t ? `${DIM} reset ${t}${RESET}` : ''}`);
  } else {
    lines.push(`7d ${PLACEHOLDER_BAR}`);
  }

  process.stdout.write(lines.map((l) => l + '\n').join(''));
}

main();
