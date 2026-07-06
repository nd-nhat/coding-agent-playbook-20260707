#!/usr/bin/env node
// tracked *.md の相対リンク実在検査。委譲リンク網がファイル移動で静かに腐る事故
// (例: docs/box-ops.md → rules/box-ops.md の取り残し) を防ぐ。アンカーは検査しない。
// 単一実装の node 例外 (CLAUDE.md「cross-platform 要件」) につき .sh/.ps1 pair は持たない。
// 使い方: node scripts/internal/check-links.js   (exit 0 = clean / 1 = broken link あり)
'use strict';
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const repoRoot = execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim();
const files = execSync('git ls-files "*.md"', { cwd: repoRoot, encoding: 'utf8' })
  .split('\n')
  .filter(Boolean);

const LINK_RE = /\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
let broken = [];

for (const file of files) {
  const abs = path.join(repoRoot, file);
  const lines = fs.readFileSync(abs, 'utf8').split('\n');
  let inFence = false;
  lines.forEach((line, i) => {
    if (/^\s*(```|~~~)/.test(line)) { inFence = !inFence; return; }
    if (inFence) return;
    for (const m of line.matchAll(LINK_RE)) {
      const target = m[1];
      if (/^[a-z][a-z0-9+.-]*:/i.test(target)) continue; // http(s):, mailto: 等の scheme 付き
      if (target.startsWith('#')) continue; // 同一ファイル内アンカー
      const rel = target.split('#')[0];
      if (rel === '') continue;
      // 相対リンクは当該ファイルのディレクトリ基準で解決 (絶対 "/..." は repo root 基準。
      // path.join は第 2 引数が絶対でも repoRoot を保持する — 落とすのは path.resolve)
      const resolved = rel.startsWith('/')
        ? path.join(repoRoot, rel)
        : path.resolve(path.dirname(abs), rel);
      // repo 外へ出るリンクは手元に実在しても GitHub 上で 404 になるため broken 扱い
      if (resolved !== repoRoot && !resolved.startsWith(repoRoot + path.sep)) {
        broken.push(`${file}:${i + 1}: [${target}] -> escapes repo root`);
      } else if (!fs.existsSync(resolved)) {
        broken.push(`${file}:${i + 1}: [${target}] -> not found`);
      }
    }
  });
}

if (broken.length) {
  console.error(`broken relative links: ${broken.length}`);
  for (const b of broken) console.error('  ' + b);
  process.exit(1);
}
console.log(`ok: ${files.length} md files, all relative links resolve`);
