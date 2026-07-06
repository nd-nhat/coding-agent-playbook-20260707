#!/usr/bin/env bun
/**
 * detect-generated-local.ts - ローカル git diff の自動生成ファイルを検出する
 *
 * 名前規則 / .gitattributes / 先頭マーカーで判定し {generated, review} を JSON 出力する。
 * リモート PR を gh fetch する detect-generated.ts のローカル diff 版で、検出ロジックは
 * _shared/generated-detect.ts を共有する。comment-sweep / verify(mode=local) が diff
 * スコープから生成物を除外するために使う。--names-only は git を叩かず stdin のパス一覧を
 * 名前規則のみで判定する (内容 fetch 手段の無い Bitbucket PR 等の縮退経路)。
 *
 * Usage:
 *   detect-generated-local.ts --range <base>...HEAD
 *   detect-generated-local.ts --staged
 *   detect-generated-local.ts --worktree
 *   detect-generated-local.ts --names-only      (stdin に改行区切りのパス一覧)
 *
 * Exit codes:
 *   0: 成功 (generated が空でも 0)
 *   1: 引数不正
 *   6: git 実行エラー等
 */

import {
  classifyByName,
  classifyByContent,
  parseGitattributes,
  gitattributesGenerated,
} from "./generated-detect.ts";

// ============================================================
// Pure arg / diff parsing (テスト対象)
// ============================================================

export type Mode =
  | { kind: "range"; range: string }
  | { kind: "staged" }
  | { kind: "worktree" }
  | { kind: "names-only" };

export function parseArgs(argv: string[]): { mode: Mode | null; error: string | null } {
  const modes = "--range / --staged / --worktree / --names-only";
  let mode: Mode | null = null;
  // モード重複は判定が曖昧になるため最初の 1 つに限定する
  const setMode = (m: Mode): string | null => {
    if (mode) return `モードは 1 つだけ指定してください (${modes})。`;
    mode = m;
    return null;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    let e: string | null = null;
    if (a === "--range") {
      const v = argv[++i];
      if (v === undefined || v.startsWith("-")) {
        return { mode: null, error: "--range には <base>...HEAD 形式の range を指定してください。" };
      }
      e = setMode({ kind: "range", range: v });
    } else if (a === "--staged") {
      e = setMode({ kind: "staged" });
    } else if (a === "--worktree") {
      e = setMode({ kind: "worktree" });
    } else if (a === "--names-only") {
      e = setMode({ kind: "names-only" });
    } else {
      return { mode: null, error: `不明な引数: ${a}` };
    }
    if (e) return { mode: null, error: e };
  }
  if (!mode) return { mode: null, error: `モードを指定してください (${modes})。` };
  return { mode, error: null };
}

// rename (R<score>) / copy (C<score>) は old/new の 2 path を持つため、判定対象の new path を採用する。
export function parseNameStatus(stdout: string): { path: string; status: string }[] {
  const out: { path: string; status: string }[] = [];
  for (const line of stdout.split("\n")) {
    if (!line) continue;
    const parts = line.split("\t");
    const status = parts[0][0]; // R100 → R, C75 → C
    const path = parts.length >= 3 ? parts[2] : parts[1];
    if (path) out.push({ path, status });
  }
  return out;
}

// `base...HEAD` / `base..feature` から内容を読む側 (右辺) の rev を取り出す。
export function rangeRightRev(range: string): string {
  const sides = range.split(/\.{2,3}/);
  return sides[sides.length - 1] || "HEAD";
}

// ============================================================
// git I/O (副作用)
// ============================================================

async function git(args: string[]): Promise<{ ok: boolean; stdout: string; stderr: string }> {
  const proc = Bun.spawn(["git", ...args], { stdout: "pipe", stderr: "pipe" });
  // stdout/stderr を並行 drain しないと stderr が pipe buffer を満たした際に子が書き込みで
  // block しデッドロックする (detect-generated.ts の gh() と同じ Promise.all 形)
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const code = await proc.exited;
  return { ok: code === 0, stdout, stderr };
}

async function readContent(mode: Mode, path: string, repoRoot: string): Promise<string | null> {
  if (mode.kind === "worktree") {
    // git diff のパスは repo root 相対。subdir から実行しても読めるよう root 基準で解決する
    try {
      return await Bun.file(`${repoRoot}/${path}`).text();
    } catch {
      return null;
    }
  }
  const rev = mode.kind === "staged" ? `:${path}` : `${rangeRightRev((mode as { range: string }).range)}:${path}`;
  const res = await git(["show", rev]);
  return res.ok ? res.stdout : null;
}

function fail(code: number, message: string): never {
  console.error(`detect-generated-local: ${message}`);
  process.exit(code);
}

function emit(generated: { path: string; reason: string }[], review: string[]): void {
  console.log(JSON.stringify({ generated, review }, null, 2));
}

// ============================================================
// Main
// ============================================================

async function main() {
  const { mode, error } = parseArgs(process.argv.slice(2));
  if (error || !mode) fail(1, error ?? "モードを特定できません。");

  const generated: { path: string; reason: string }[] = [];
  const review: string[] = [];

  // 内容 fetch 不能な縮退経路: stdin のパス一覧を名前規則のみで分類する
  if (mode.kind === "names-only") {
    const stdin = await Bun.stdin.text();
    for (const path of stdin.split("\n").map((l) => l.trim()).filter(Boolean)) {
      const reason = classifyByName(path);
      if (reason) generated.push({ path, reason });
      else review.push(path);
    }
    emit(generated, review);
    return;
  }

  const diffArgs =
    mode.kind === "range"
      ? ["diff", mode.range, "--name-status"]
      : mode.kind === "staged"
        ? ["diff", "--cached", "--name-status"]
        : ["diff", "HEAD", "--name-status"];
  const diffRes = await git(diffArgs);
  if (!diffRes.ok) fail(6, `git ${diffArgs.join(" ")} に失敗しました: ${diffRes.stderr.trim()}`);
  let files = parseNameStatus(diffRes.stdout);

  if (mode.kind === "worktree") {
    const untrackedRes = await git(["ls-files", "--others", "--exclude-standard"]);
    if (untrackedRes.ok) {
      const untrackedFiles = untrackedRes.stdout
        .split("\n")
        .filter(Boolean)
        .map((path) => ({ path, status: "A" }));
      files = [...files, ...untrackedFiles];
    }
  }

  // worktree モードの Bun.file は cwd 相対だが git diff のパスは repo root 相対。subdir 実行でも
  // 読めるよう root を解決して渡す (staged/range は git show が repo 基準で解決するため不要)
  const rootRes = await git(["rev-parse", "--show-toplevel"]);
  const repoRoot = rootRes.ok ? rootRes.stdout.trim() : ".";

  // .gitattributes は content と同じ source から読む (HEAD 固定だと staged/worktree/range で
  // 属性変更が content と判定 ref でズレ、生成ファイルを取りこぼす)
  const gaContent = await readContent(mode, ".gitattributes", repoRoot);
  const gaEntries = gaContent !== null ? parseGitattributes(gaContent) : [];

  for (const f of files) {
    const nameReason = classifyByName(f.path);
    if (nameReason) {
      generated.push({ path: f.path, reason: nameReason });
      continue;
    }
    if (gaEntries.length > 0 && gitattributesGenerated(f.path, gaEntries)) {
      generated.push({ path: f.path, reason: "gitattributes:linguist-generated" });
      continue;
    }
    // 削除は HEAD/index/worktree に内容が無く、名前で拾えなければ review に残す
    if (f.status === "D") {
      review.push(f.path);
      continue;
    }
    const content = await readContent(mode, f.path, repoRoot);
    const reason = content !== null ? classifyByContent(content) : null;
    if (reason) generated.push({ path: f.path, reason });
    else review.push(f.path);
  }

  emit(generated, review);
}

if (import.meta.main) {
  main().catch((e) => {
    fail(6, `予期しないエラー: ${e?.message ?? e}`);
  });
}
