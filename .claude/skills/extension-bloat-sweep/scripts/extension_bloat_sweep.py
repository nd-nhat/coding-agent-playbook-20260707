#!/usr/bin/env python3
"""extension-bloat-sweep: pre-PR sweep for ideal-form-first violations.

Detects pre-PR diffs where agents extend existing implementations
(file / function / signature) instead of splitting / extracting / replacing.

See SKILL.md for details.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


EXIT_OK = 0
EXIT_ARG_ERROR = 1
EXIT_GIT_ERROR = 2
EXIT_SKIPPED = 3
EXIT_OTHER = 6


DEFAULT_FILE_LINES_THRESHOLD = 300
DEFAULT_ADDED_LINES_THRESHOLD = 50
DEFAULT_PARAM_THRESHOLD = 4
DEFAULT_MODIFY_COUNT_THRESHOLD = 2


TS_FUNCTION_RE = re.compile(
    r"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+(\w+)(?:\s*<[^<>]*>)?\s*\("
)
TS_CONST_FN_RE = re.compile(
    r"^\s*(?:export\s+)?const\s+(\w+)(?:\s*:\s*.*?)?\s*=\s*(?:async\s+)?(?:function\s*)?(?:<[^<>]*>\s*)?\("
)
PY_FUNCTION_RE = re.compile(r"^\s*(?:async\s+)?def\s+(\w+)\s*\(")

_DEFAULT_ASSIGN_RE = re.compile(r"(?<![=])=(?![=>])")


def _extract_balanced_parens(text: str, open_index: int) -> str | None:
    """Return content between '(' at open_index and the matching ')'.

    Handles nested parens (e.g. callback types `cb: () => void`). Returns None
    when the opener is not '(' or the parens are unbalanced.
    """
    if open_index >= len(text) or text[open_index] != "(":
        return None
    depth = 0
    for i in range(open_index, len(text)):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[open_index + 1 : i]
    return None


@dataclass
class Finding:
    kind: str
    file: str
    line_range: str
    base_state: str
    diff_impact: str
    subtractive_question: str
    suggested_next_action: str
    confidence: str


@dataclass
class Config:
    file_lines_threshold: int = DEFAULT_FILE_LINES_THRESHOLD
    added_lines_threshold: int = DEFAULT_ADDED_LINES_THRESHOLD
    param_threshold: int = DEFAULT_PARAM_THRESHOLD
    modify_count_threshold: int = DEFAULT_MODIFY_COUNT_THRESHOLD


def run_git(args: list[str], cwd: Path) -> tuple[int, str, str]:
    proc = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout, proc.stderr


def repo_root_from(cwd: Path) -> Path | None:
    code, out, _ = run_git(["rev-parse", "--show-toplevel"], cwd)
    if code != 0:
        return None
    return Path(out.strip())


def resolve_base_ref(repo_root: Path, base_arg: str | None) -> str | None:
    if base_arg:
        return base_arg
    code, out, _ = run_git(
        ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], repo_root
    )
    if code == 0 and out.strip():
        return out.strip()
    for candidate in ("origin/main", "origin/master", "main", "master"):
        code, _, _ = run_git(["rev-parse", "--verify", candidate], repo_root)
        if code == 0:
            return candidate
    return None


def detect_languages(repo_root: Path) -> set[str]:
    languages: set[str] = set()
    if (repo_root / "package.json").exists():
        languages.add("ts")
    py_markers = [
        "pyproject.toml",
        "setup.py",
        "setup.cfg",
        "requirements.txt",
        "Pipfile",
    ]
    if any((repo_root / m).exists() for m in py_markers):
        languages.add("py")
    if "py" not in languages:
        for path in repo_root.glob("requirements*.txt"):
            if path.is_file():
                languages.add("py")
                break
    return languages


def is_pure_revert(repo_root: Path, base: str, head: str = "HEAD") -> bool:
    code, out, _ = run_git(["log", "--format=%s", f"{base}..{head}"], repo_root)
    if code != 0:
        return False
    subjects = [s for s in out.splitlines() if s.strip()]
    if not subjects:
        return False
    return all(s.startswith('Revert "') for s in subjects)


class GitDiffError(RuntimeError):
    """Raised when `git diff` for changed_files fails; caller exits with EXIT_GIT_ERROR."""


def changed_files(repo_root: Path, base: str | None, mode: str) -> list[str]:
    """Return paths that exist in the head side of the diff (deletions excluded)."""
    if mode == "staged":
        args = ["diff", "--cached", "--name-status"]
    elif mode == "worktree":
        args = ["diff", "HEAD", "--name-status"]
    else:
        if not base:
            raise GitDiffError("base ref unresolved for diff mode")
        args = ["diff", f"{base}...HEAD", "--name-status"]
    code, out, err = run_git(args, repo_root)
    if code != 0:
        raise GitDiffError(f"git {' '.join(args)} failed: {err.strip()}")
    files: list[str] = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 2 or not parts[0]:
            continue
        status = parts[0]
        if status.startswith("D"):
            continue
        files.append(parts[-1])
    return files


def resolve_merge_base(repo_root: Path, base: str | None) -> str | None:
    """Resolve `git merge-base <base> HEAD` so detectors read the right tree.

    `base...HEAD` diffs use the merge-base implicitly, but `git show <base>:<file>`
    walks the moving branch tip — if base advanced and deleted/renamed the file,
    those reads return the wrong tree. Resolving once keeps every detector aligned.
    """
    if not base:
        return None
    code, out, _ = run_git(["merge-base", base, "HEAD"], repo_root)
    if code != 0 or not out.strip():
        return None
    return out.strip()


def file_base_lines(repo_root: Path, base: str, file: str) -> int | None:
    code, out, _ = run_git(["show", "--no-textconv", f"{base}:{file}"], repo_root)
    if code != 0:
        return None
    return out.count("\n") + (1 if out and not out.endswith("\n") else 0)


def numstat_for_file(
    repo_root: Path, base: str | None, mode: str, file: str
) -> tuple[int, int]:
    """Return (added, deleted) line counts from `git diff --numstat`."""
    if mode == "staged":
        args = ["diff", "--cached", "--numstat", "--", file]
    elif mode == "worktree":
        args = ["diff", "HEAD", "--numstat", "--", file]
    else:
        if not base:
            return (0, 0)
        args = ["diff", f"{base}...HEAD", "--numstat", "--", file]
    code, out, _ = run_git(args, repo_root)
    if code != 0 or not out.strip():
        return (0, 0)
    parts = out.strip().split("\t")
    if len(parts) < 2:
        return (0, 0)
    try:
        return (int(parts[0]), int(parts[1]))
    except ValueError:
        return (0, 0)


def comparison_base_ref(base: str | None, mode: str) -> str | None:
    """Return the ref used to look up base file state for the given mode.

    diff mode uses the resolved base ref; pre-commit modes compare against HEAD
    (the file state before staging / before working-tree modification).
    """
    if mode in ("staged", "worktree"):
        return "HEAD"
    return base


def file_extension_language(file: str) -> str | None:
    if any(
        file.endswith(ext)
        for ext in (".ts", ".tsx", ".js", ".jsx", ".mts", ".cts", ".mjs", ".cjs")
    ):
        return "ts"
    if file.endswith(".py"):
        return "py"
    return None


def detect_e1(
    repo_root: Path,
    base: str | None,
    mode: str,
    files: list[str],
    languages: set[str],
    config: Config,
) -> list[Finding]:
    findings: list[Finding] = []
    base_for_show = comparison_base_ref(base, mode)
    if base_for_show is None:
        return findings
    for file in files:
        lang = file_extension_language(file)
        if lang not in languages:
            continue
        base_lines = file_base_lines(repo_root, base_for_show, file)
        if base_lines is None or base_lines < config.file_lines_threshold:
            continue
        added, deleted = numstat_for_file(repo_root, base, mode, file)
        net_growth = added - deleted
        if added < config.added_lines_threshold:
            continue
        if net_growth < config.added_lines_threshold:
            continue
        ratio = (net_growth / base_lines * 100) if base_lines else 0
        findings.append(
            Finding(
                kind="E1: 既存大型ファイル末尾追加",
                file=file,
                line_range=f"+{added} / -{deleted} (net +{net_growth})",
                base_state=f"base file is {base_lines} lines",
                diff_impact=f"net growth +{net_growth} lines (+{ratio:.0f}% of base)",
                subtractive_question=(
                    f"この追加分は別 file に切り出せないか? "
                    f"base file が既に {base_lines} 行あり、本 PR で net +{net_growth} 行 "
                    f"({added} added, {deleted} deleted) 増加している。"
                    "責務が異なる部分は新規 file に分離することを検討。"
                ),
                suggested_next_action=(
                    "追加した行が独立した責務 (例: 新機能・新領域) なら、"
                    "新 file に切り出して既存 file の re-export / import 経由で繋ぐ形を検討する。"
                ),
                confidence="high",
            )
        )
    return findings


_BRACKET_OPEN = {"(": ")", "[": "]", "{": "}", "<": ">"}
_BRACKET_CLOSE = {v: k for k, v in _BRACKET_OPEN.items()}


def _split_params_nest_aware(params_str: str) -> list[str]:
    """Split on top-level commas, ignoring commas inside brackets or quotes.

    Handles generics (`Map<K, V>`), inline types (`{a: string, b: number}`),
    tuple defaults (`= [1, 2]`), call expressions in default values, and
    string-literal defaults (`pattern='a,b,c'`).
    """
    parts: list[str] = []
    current: list[str] = []
    depth: dict[str, int] = {k: 0 for k in _BRACKET_OPEN}
    quote: str | None = None
    escape = False
    for ch in params_str:
        if quote is not None:
            current.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == quote:
                quote = None
            continue
        if ch in ("'", '"', "`"):
            quote = ch
            current.append(ch)
        elif ch in _BRACKET_OPEN:
            depth[ch] += 1
            current.append(ch)
        elif ch in _BRACKET_CLOSE:
            opener = _BRACKET_CLOSE[ch]
            if depth[opener] > 0:
                depth[opener] -= 1
            current.append(ch)
        elif ch == "," and sum(depth.values()) == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
    if current:
        parts.append("".join(current).strip())
    return [p for p in parts if p]


def _strip_python_receiver(params_str: str) -> str:
    """Drop self / cls receivers and bare `*` / `/` separators (no caller-passed arity)."""
    params = _split_params_nest_aware(params_str)
    if params and re.match(r"^\s*(?:self|cls)\b", params[0]):
        params = params[1:]
    params = [p for p in params if p.strip() not in ("*", "/")]
    return ", ".join(params)


def _has_top_level_optional_marker(param: str) -> bool:
    """Detect a `?:` or default `=` assignment at top level (outside brackets / quotes)."""
    depth: dict[str, int] = {k: 0 for k in _BRACKET_OPEN}
    quote: str | None = None
    escape = False
    i = 0
    while i < len(param):
        ch = param[i]
        if quote is not None:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == quote:
                quote = None
            i += 1
            continue
        if ch in ("'", '"', "`"):
            quote = ch
        elif ch in _BRACKET_OPEN:
            depth[ch] += 1
        elif ch in _BRACKET_CLOSE:
            opener = _BRACKET_CLOSE[ch]
            if depth[opener] > 0:
                depth[opener] -= 1
        elif sum(depth.values()) == 0:
            if ch == "?" and i + 1 < len(param) and param[i + 1] == ":":
                return True
            if ch == "=":
                prev = param[i - 1] if i > 0 else ""
                next_ch = param[i + 1] if i + 1 < len(param) else ""
                if prev != "=" and next_ch not in ("=", ">"):
                    return True
        i += 1
    return False


def parse_params(params_str: str) -> tuple[int, int]:
    """Return (param count, consecutive optional count)."""
    params = _split_params_nest_aware(params_str)
    optional_run = 0
    max_optional_run = 0
    for p in params:
        if _has_top_level_optional_marker(p):
            optional_run += 1
            max_optional_run = max(max_optional_run, optional_run)
        else:
            optional_run = 0
    return len(params), max_optional_run


def _extract_base_arity(
    base_content: str, func_name: str, lang: str
) -> tuple[int, int] | None:
    """Find `func_name`'s definition in `base_content` and return its arity.

    Returns (param_count, optional_run) or None when the function is not defined
    in base (comment / string mentions don't count). Used for both base-existence
    proof and arity-delta comparison in E2.
    """
    escaped = re.escape(func_name)
    if lang == "ts":
        patterns = [
            re.compile(
                rf"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+{escaped}(?:\s*<[^<>]*>)?\s*\("
            ),
            re.compile(
                rf"^\s*(?:export\s+)?const\s+{escaped}(?:\s*:\s*.*?)?\s*=\s*(?:async\s+)?(?:function\s*)?(?:<[^<>]*>\s*)?\("
            ),
        ]
    elif lang == "py":
        patterns = [re.compile(rf"^\s*(?:async\s+)?def\s+{escaped}\s*\(")]
    else:
        return None
    matches: list[tuple[int, int]] = []
    for line in base_content.splitlines():
        for pattern in patterns:
            m = pattern.match(line)
            if not m:
                continue
            params_str = _extract_balanced_parens(line, m.end() - 1)
            if params_str is None:
                continue
            if lang == "py":
                params_str = _strip_python_receiver(params_str)
            matches.append(parse_params(params_str))
            break
    if len(matches) != 1:
        return None
    return matches[0]


def detect_e2(
    repo_root: Path,
    base: str | None,
    mode: str,
    files: list[str],
    languages: set[str],
    config: Config,
) -> list[Finding]:
    findings: list[Finding] = []
    if mode == "staged":
        args = ["diff", "--cached", "--unified=0"]
    elif mode == "worktree":
        args = ["diff", "HEAD", "--unified=0"]
    else:
        if not base:
            return findings
        args = ["diff", f"{base}...HEAD", "--unified=0"]
    code, diff_out, diff_err = run_git(args, repo_root)
    if code != 0:
        raise GitDiffError(f"git {' '.join(args)} failed: {diff_err.strip()}")
    diff = diff_out
    current_file: str | None = None
    file_header_re = re.compile(r"^\+\+\+ b/(.+)$")
    for line in diff.splitlines():
        m = file_header_re.match(line)
        if m:
            current_file = m.group(1)
            continue
        if not current_file or not line.startswith("+") or line.startswith("+++"):
            continue
        lang = file_extension_language(current_file)
        if lang not in languages:
            continue
        body = line[1:]
        match = None
        if lang == "ts":
            match = TS_FUNCTION_RE.match(body) or TS_CONST_FN_RE.match(body)
        elif lang == "py":
            match = PY_FUNCTION_RE.match(body)
        if not match:
            continue
        func_name = match.group(1)
        params_str = _extract_balanced_parens(body, match.end() - 1)
        if params_str is None:
            continue
        if lang == "py":
            params_str = _strip_python_receiver(params_str)
        param_count, optional_run = parse_params(params_str)
        if param_count < config.param_threshold and optional_run < 3:
            continue
        base_for_show = comparison_base_ref(base, mode)
        if base_for_show is None:
            continue
        base_def_code, base_def_content, _ = run_git(
            ["show", "--no-textconv", f"{base_for_show}:{current_file}"], repo_root
        )
        if base_def_code != 0:
            continue
        base_arity = _extract_base_arity(base_def_content, func_name, lang)
        if base_arity is None:
            continue
        base_params, base_optional = base_arity
        if param_count <= base_params and optional_run <= base_optional:
            continue
        findings.append(
            Finding(
                kind="E2: 関数シグネチャ複雑化",
                file=current_file,
                line_range=f"function {func_name}",
                base_state="function existed in base",
                diff_impact=(
                    f"new signature: {param_count} params"
                    + (
                        f", {optional_run} consecutive optional"
                        if optional_run >= 3
                        else ""
                    )
                ),
                subtractive_question=(
                    f"関数 {func_name} の引数を object 化"
                    " (`{{ option1, option2, ... }}`)"
                    "するか、責務で関数分割できないか? "
                    f"現在 param 数 {param_count}"
                    + (f" (optional 連続 {optional_run})" if optional_run >= 3 else "")
                ),
                suggested_next_action=(
                    f"{func_name} の呼び出し箇所を grep して、"
                    "引数 object 化または関数分割の影響範囲を確認する。"
                ),
                confidence="high" if param_count >= 5 else "medium",
            )
        )
    return findings


def detect_e6(
    repo_root: Path,
    base: str | None,
    mode: str,
    files: list[str],
    languages: set[str],
    config: Config,
) -> list[Finding]:
    findings: list[Finding] = []
    if mode != "diff" or not base:
        return findings
    code, out, _ = run_git(["log", "--format=%H", f"{base}..HEAD"], repo_root)
    if code != 0:
        return findings
    commits = [sha.strip() for sha in out.splitlines() if sha.strip()]
    if len(commits) < config.modify_count_threshold:
        return findings
    final_diff_files = set(files)
    file_touch_count: dict[str, int] = {}
    for sha in commits:
        code, files_out, _ = run_git(
            ["show", "--format=", "--name-only", sha], repo_root
        )
        if code != 0:
            continue
        for file in files_out.splitlines():
            file = file.strip()
            if file:
                file_touch_count[file] = file_touch_count.get(file, 0) + 1
    for file, count in file_touch_count.items():
        if count < config.modify_count_threshold:
            continue
        if file not in final_diff_files:
            continue
        if file_base_lines(repo_root, base, file) is None:
            continue
        lang = file_extension_language(file)
        if lang not in languages:
            continue
        findings.append(
            Finding(
                kind="E6: 同一ファイルの複数回 modify",
                file=file,
                line_range="file-level",
                base_state=f"touched in {count} commits",
                diff_impact=f"{count} commits in base..HEAD touch this file",
                subtractive_question=(
                    f"このファイルを {count} 回 modify している。"
                    "責務肥大の兆候。同一関数の段階的修正なら、関数分割を検討。"
                ),
                suggested_next_action=(
                    f"git log --oneline {base}..HEAD -- {file} で commit 履歴を確認し、"
                    "同一 symptom を繰り返し直しているか reframe-and-redesign 規範で再評価する。"
                ),
                confidence="low",
            )
        )
    return findings


def format_text(findings: list[Finding]) -> str:
    if not findings:
        return "✅ extension-bloat-sweep: no extension-bloat opportunities found\n"
    lines: list[str] = []
    counts = {"high": 0, "medium": 0, "low": 0}
    for f in findings:
        counts[f.confidence] = counts.get(f.confidence, 0) + 1
        lines.append(f"Extension bloat opportunity: {f.kind}")
        lines.append(f"Evidence: {f.file} ({f.line_range})")
        lines.append(f"Base state: {f.base_state}")
        lines.append(f"Diff impact: {f.diff_impact}")
        lines.append(f"Subtractive question: {f.subtractive_question}")
        lines.append(f"Suggested next action: {f.suggested_next_action}")
        lines.append(f"Confidence: {f.confidence}")
        lines.append("")
    lines.append(
        f"✅ extension-bloat-sweep: {len(findings)} finding(s) "
        f"({counts['high']} high / {counts['medium']} medium / {counts['low']} low confidence)"
    )
    return "\n".join(lines) + "\n"


def format_json_output(findings: list[Finding]) -> str:
    payload = {
        "findings": [asdict(f) for f in findings],
        "summary": {
            "total": len(findings),
            "high": sum(1 for f in findings if f.confidence == "high"),
            "medium": sum(1 for f in findings if f.confidence == "medium"),
            "low": sum(1 for f in findings if f.confidence == "low"),
        },
    }
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def load_config_from_env() -> Config:
    def _int_env(name: str, default: int) -> int:
        raw = os.environ.get(name)
        if raw is None or not raw.strip():
            return default
        try:
            value = int(raw.strip())
        except ValueError:
            return default
        return value if value > 0 else default

    return Config(
        file_lines_threshold=_int_env(
            "CLAUDE_SKILL_EXTENSION_BLOAT_FILE_LINES_THRESHOLD",
            DEFAULT_FILE_LINES_THRESHOLD,
        ),
        added_lines_threshold=_int_env(
            "CLAUDE_SKILL_EXTENSION_BLOAT_ADDED_LINES_THRESHOLD",
            DEFAULT_ADDED_LINES_THRESHOLD,
        ),
        param_threshold=_int_env(
            "CLAUDE_SKILL_EXTENSION_BLOAT_PARAM_THRESHOLD",
            DEFAULT_PARAM_THRESHOLD,
        ),
        modify_count_threshold=_int_env(
            "CLAUDE_SKILL_EXTENSION_BLOAT_MODIFY_COUNT_THRESHOLD",
            DEFAULT_MODIFY_COUNT_THRESHOLD,
        ),
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="extension-bloat-sweep: pre-PR sweep for ideal-form-first violations"
    )
    parser.add_argument(
        "base_branch",
        nargs="?",
        default=None,
        help="positional base branch (e.g. main); takes precedence over --base when both are given",
    )
    parser.add_argument("--base", default=None, help="base ref (default: origin/HEAD)")
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument("--staged", action="store_true", help="diff --cached")
    mode_group.add_argument("--worktree", action="store_true", help="diff HEAD")
    parser.add_argument("--json", action="store_true", help="JSON output")
    parser.add_argument(
        "--cwd", default=None, help="repo root override (default: discovered from cwd)"
    )
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        sys.exit(EXIT_ARG_ERROR if exc.code == 2 else (exc.code if exc.code is not None else EXIT_OTHER))
    if args.base_branch:
        args.base = args.base_branch
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])

    if args.base and args.base.startswith("-"):
        sys.stderr.write(f"BASE_BRANCH: ref must not start with '-': {args.base!r}\n")
        return EXIT_ARG_ERROR

    if os.environ.get("CLAUDE_SKILL_EXTENSION_BLOAT_DISABLE") == "1":
        if args.json:
            sys.stdout.write(format_json_output([]))
        else:
            sys.stdout.write("✅ extension-bloat-sweep: disabled via env\n")
        return EXIT_SKIPPED

    start_cwd = Path(args.cwd) if args.cwd else Path.cwd()
    repo_root = repo_root_from(start_cwd)
    if repo_root is None:
        sys.stderr.write("git rev-parse failed; not a git repo\n")
        return EXIT_GIT_ERROR

    languages = detect_languages(repo_root)
    languages_env = os.environ.get("CLAUDE_SKILL_EXTENSION_BLOAT_LANGUAGES")
    if languages_env:
        override = {x.strip() for x in languages_env.split(",") if x.strip()}
        languages = override & {"ts", "py"}
    if not languages:
        if args.json:
            sys.stdout.write(format_json_output([]))
        else:
            sys.stdout.write(
                "✅ extension-bloat-sweep: project language not detected; skipped\n"
            )
        return EXIT_SKIPPED

    mode = "staged" if args.staged else "worktree" if args.worktree else "diff"

    base_ref: str | None = None
    if mode == "diff":
        resolved = resolve_base_ref(repo_root, args.base)
        if not resolved:
            sys.stderr.write("could not resolve base ref\n")
            return EXIT_GIT_ERROR
        if is_pure_revert(repo_root, resolved):
            if args.json:
                sys.stdout.write(format_json_output([]))
            else:
                sys.stdout.write(
                    "✅ extension-bloat-sweep: revert-only diff; skipped\n"
                )
            return EXIT_SKIPPED
        base_ref = resolve_merge_base(repo_root, resolved) or resolved

    config = load_config_from_env()
    try:
        files = changed_files(repo_root, base_ref, mode)
    except GitDiffError as e:
        sys.stderr.write(f"{e}\n")
        return EXIT_GIT_ERROR
    if not files:
        if args.json:
            sys.stdout.write(format_json_output([]))
        else:
            sys.stdout.write(
                "✅ extension-bloat-sweep: no extension-bloat opportunities found\n"
            )
        return EXIT_OK

    findings: list[Finding] = []
    try:
        findings.extend(detect_e1(repo_root, base_ref, mode, files, languages, config))
        findings.extend(detect_e2(repo_root, base_ref, mode, files, languages, config))
        findings.extend(detect_e6(repo_root, base_ref, mode, files, languages, config))
    except GitDiffError as e:
        sys.stderr.write(f"{e}\n")
        return EXIT_GIT_ERROR

    if args.json:
        sys.stdout.write(format_json_output(findings))
    else:
        sys.stdout.write(format_text(findings))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
