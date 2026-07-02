#!/usr/bin/env python3
"""co-evolve-check: pre-PR sweep for retention bias (version parallelism).

Detects retention bias in pre-PR diffs where agents add new versions of
interfaces / classes / functions alongside the old ones, when (a) all
callers of the old symbol are touched in the same PR and (b) no public
consumer markers exist.

See SKILL.md for details.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path


EXIT_OK = 0
EXIT_ARG_ERROR = 1
EXIT_GIT_ERROR = 2
EXIT_SKIPPED = 3
EXIT_OTHER = 6


TS_SUFFIX_PATTERN = re.compile(r"(V\d+|Old|New|Legacy|Compat|Deprecated)$")
PY_SUFFIX_PATTERN = re.compile(r"_(v\d+|new|old|legacy|compat|deprecated)$")

LEGACY_TS_SUFFIXES = frozenset({"Old", "Legacy", "Compat", "Deprecated"})
LEGACY_PY_SUFFIXES = frozenset({"_old", "_legacy", "_compat", "_deprecated"})

LEGACY_TS_PREFIXES = frozenset({"Legacy", "Deprecated", "Compat", "Old"})
LEGACY_PY_PREFIXES = frozenset({"legacy_", "deprecated_", "compat_", "old_"})


def _is_legacy_suffix(suffix: str, language: str) -> bool:
    """Return True if the suffix indicates the *suffixed* symbol is the legacy one.

    Legacy suffixes (Old/Legacy/Compat/Deprecated): the suffixed symbol is the
    retention candidate (delete it, keep the base name).
    Successor suffixes (V\\d+/New): the base name is the retention candidate
    (delete it, keep the suffixed symbol).

    Python class suffixes use CamelCase (`FooV2`) like TS rather than snake_case
    (`foo_v2`), so fall through to the TS table when no underscore prefix.
    """
    if language == "ts" or not suffix.startswith("_"):
        return suffix in LEGACY_TS_SUFFIXES
        return suffix in LEGACY_TS_SUFFIXES
    return suffix in LEGACY_PY_SUFFIXES


TS_INTERFACE_RE = re.compile(r"^\+\s*(?:export\s+)?interface\s+(\w+)")
TS_TYPE_RE = re.compile(r"^\+\s*(?:export\s+)?type\s+(\w+)\s*=")
TS_FUNCTION_RE = re.compile(r"^\+\s*(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s+(\w+)")
TS_CONST_FUNCTION_RE = re.compile(r"^\+\s*(?:export\s+)?const\s+(\w+)\s*[:=].*=>\s*")
TS_CONST_FN_RE = re.compile(
    r"^\+\s*(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s+)?(?:function\b|\()"
)

PY_CLASS_RE = re.compile(r"^\+\s*class\s+(\w+)")
PY_FUNCTION_RE = re.compile(r"^\+\s*(?:async\s+)?def\s+(\w+)")

DIFF_FILE_HEADER_RE = re.compile(r"^\+\+\+ b/(.+)$")


@dataclass
class Candidate:
    kind: str
    language: str
    old_symbol: str
    new_symbol: str
    old_evidence: str
    new_evidence: str


@dataclass
class CallerRef:
    location: str
    touched: bool


@dataclass
class Finding:
    candidate: Candidate
    callers: list[CallerRef] = field(default_factory=list)
    public_marker: str = "none"
    co_evolution_scope: str = "uncertain"
    confidence: str = "low"
    subtractive_question: str = ""
    suggested_next_action: str = ""


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
    """Resolve the base ref for `git diff <base>...HEAD`."""
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
    """Detect project languages from marker files at repo root."""
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


def get_diff(repo_root: Path, base: str | None, mode: str) -> tuple[int, str]:
    if mode == "staged":
        return _get_diff_output(repo_root, ["diff", "--cached", "--unified=0"])
    if mode == "worktree":
        return _get_diff_output(repo_root, ["diff", "HEAD", "--unified=0"])
    if not base:
        return EXIT_GIT_ERROR, ""
    return _get_diff_output(repo_root, ["diff", f"{base}...HEAD", "--unified=0"])


def _get_diff_output(repo_root: Path, args: list[str]) -> tuple[int, str]:
    code, out, err = run_git(args, repo_root)
    if code != 0:
        sys.stderr.write(f"git {' '.join(args)} failed: {err}")
        return EXIT_GIT_ERROR, ""
    return EXIT_OK, out


def parse_diff_added_symbols(
    diff: str, languages: set[str]
) -> dict[str, list[tuple[str, str]]]:
    """Parse diff and return {symbol_kind: [(symbol_name, file:line), ...]}.

    symbol_kind: "ts-type" | "ts-function" | "py-class" | "py-function"
    """
    results: dict[str, list[tuple[str, str]]] = {
        "ts-type": [],
        "ts-function": [],
        "py-class": [],
        "py-function": [],
    }
    current_file: str | None = None
    line_in_new_file: int = 0
    hunk_re = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")

    for raw_line in diff.splitlines():
        header_match = DIFF_FILE_HEADER_RE.match(raw_line)
        if header_match:
            current_file = header_match.group(1)
            line_in_new_file = 0
            continue
        if raw_line.startswith("--- ") or raw_line.startswith("diff --git"):
            continue
        hunk_match = hunk_re.match(raw_line)
        if hunk_match:
            line_in_new_file = int(hunk_match.group(1)) - 1
            continue
        if not current_file:
            continue

        if raw_line.startswith("+") and not raw_line.startswith("+++"):
            line_in_new_file += 1
            if "ts" in languages and _is_ts_file(current_file):
                _match_ts_definitions(raw_line, current_file, line_in_new_file, results)
            if "py" in languages and current_file.endswith(".py"):
                _match_py_definitions(raw_line, current_file, line_in_new_file, results)
        elif not raw_line.startswith("-") and not raw_line.startswith("\\"):
            line_in_new_file += 1

    return results


def _is_ts_file(path: str) -> bool:
    return any(
        path.endswith(ext) for ext in (".ts", ".tsx", ".js", ".jsx", ".mts", ".cts")
    )


def _match_ts_definitions(
    line: str,
    file: str,
    line_no: int,
    results: dict[str, list[tuple[str, str]]],
) -> None:
    for pattern, bucket in (
        (TS_INTERFACE_RE, "ts-type"),
        (TS_TYPE_RE, "ts-type"),
        (TS_FUNCTION_RE, "ts-function"),
        (TS_CONST_FN_RE, "ts-function"),
        (TS_CONST_FUNCTION_RE, "ts-function"),
    ):
        m = pattern.match(line)
        if m:
            results[bucket].append((m.group(1), f"{file}:{line_no}"))
            return


def _match_py_definitions(
    line: str,
    file: str,
    line_no: int,
    results: dict[str, list[tuple[str, str]]],
) -> None:
    for pattern, bucket in (
        (PY_CLASS_RE, "py-class"),
        (PY_FUNCTION_RE, "py-function"),
    ):
        m = pattern.match(line)
        if m:
            results[bucket].append((m.group(1), f"{file}:{line_no}"))
            return


def find_pair_candidates(
    added: dict[str, list[tuple[str, str]]],
    repo_root: Path,
    languages: set[str],
) -> list[Candidate]:
    """Find (old_symbol, new_symbol) pairs based on version suffix/prefix patterns."""
    candidates: list[Candidate] = []
    if "ts" in languages:
        candidates.extend(
            _find_pairs_for_bucket(
                added.get("ts-type", []),
                repo_root,
                language="ts",
                kind="X1: 型並走",
                suffix_pattern=TS_SUFFIX_PATTERN,
                grep_definition=_ts_type_definition_patterns,
                legacy_suffixes=LEGACY_TS_SUFFIXES,
                legacy_prefixes=LEGACY_TS_PREFIXES,
            )
        )
        candidates.extend(
            _find_pairs_for_bucket(
                added.get("ts-function", []),
                repo_root,
                language="ts",
                kind="X2: 関数 wrapper 並走",
                suffix_pattern=TS_SUFFIX_PATTERN,
                grep_definition=_ts_function_definition_patterns,
                legacy_suffixes=LEGACY_TS_SUFFIXES,
                legacy_prefixes=LEGACY_TS_PREFIXES,
            )
        )
    if "py" in languages:
        candidates.extend(
            _find_pairs_for_bucket(
                added.get("py-class", []),
                repo_root,
                language="py",
                kind="X1: 型並走",
                suffix_pattern=TS_SUFFIX_PATTERN,
                grep_definition=_py_class_definition_patterns,
                legacy_suffixes=LEGACY_TS_SUFFIXES,
                legacy_prefixes=LEGACY_TS_PREFIXES,
            )
        )
        candidates.extend(
            _find_pairs_for_bucket(
                added.get("py-function", []),
                repo_root,
                language="py",
                kind="X2: 関数 wrapper 並走",
                suffix_pattern=PY_SUFFIX_PATTERN,
                grep_definition=_py_function_definition_patterns,
                legacy_suffixes=LEGACY_PY_SUFFIXES,
                legacy_prefixes=LEGACY_PY_PREFIXES,
            )
        )
    return candidates


def _find_pairs_for_bucket(
    added: list[tuple[str, str]],
    repo_root: Path,
    language: str,
    kind: str,
    suffix_pattern: re.Pattern[str],
    grep_definition,
    legacy_suffixes: frozenset[str] = frozenset(),
    legacy_prefixes: frozenset[str] = frozenset(),
) -> list[Candidate]:
    candidates: list[Candidate] = []
    seen: set[tuple[str, str]] = set()

    def _add(old_sym: str, new_sym: str, old_ev: str, new_ev: str) -> None:
        key = (old_sym, new_sym)
        if key not in seen:
            seen.add(key)
            candidates.append(
                Candidate(
                    kind=kind,
                    language=language,
                    old_symbol=old_sym,
                    new_symbol=new_sym,
                    old_evidence=old_ev,
                    new_evidence=new_ev,
                )
            )

    for symbol, loc in added:
        file = loc.split(":", 1)[0]

        # Case A: added symbol has a suffix/prefix (original direction)
        m = suffix_pattern.search(symbol)
        if m:
            suffix = m.group(0)
            base_name = symbol[: -len(suffix)]
            if not base_name:
                continue
            base_loc = _find_symbol_definition(
                base_name, repo_root, grep_definition, hint_file=file
            )
            if not base_loc or base_loc == loc:
                for other_sym, other_loc in added:
                    if (
                        other_sym == base_name
                        and other_loc != loc
                        and other_loc.split(":", 1)[0] == file
                    ):
                        base_loc = other_loc
                        break
            if not base_loc or base_loc == loc:
                continue
            if _is_legacy_suffix(suffix, language):
                _add(symbol, base_name, loc, base_loc)
            else:
                _add(base_name, symbol, base_loc, loc)
            continue

        # Case B: added symbol has no suffix — search for retained old (suffixed/prefixed) version.
        # Handles: PR adds `User` (new clean name), `UserOld`/`LegacyUser` already exists in repo.
        for legacy_suffix in legacy_suffixes:
            old_name = symbol + legacy_suffix
            old_loc = _find_symbol_definition(
                old_name, repo_root, grep_definition, hint_file=file
            )
            if old_loc and old_loc != loc:
                _add(old_name, symbol, old_loc, loc)
        for legacy_prefix in legacy_prefixes:
            old_name = legacy_prefix + symbol
            old_loc = _find_symbol_definition(
                old_name, repo_root, grep_definition, hint_file=file
            )
            if old_loc and old_loc != loc:
                _add(old_name, symbol, old_loc, loc)

    return candidates


def _find_symbol_definition(
    symbol: str,
    repo_root: Path,
    patterns_fn,
    hint_file: str | None = None,
) -> str | None:
    """Search for `symbol`'s definition; restrict to `hint_file` when given.

    Cross-module hits (different files, e.g. unrelated `User` defined elsewhere)
    are noise for pair-finding because they mismatch the suffixed symbol's
    actual module. When `hint_file` is provided the search is confined to that
    file; falling back to repo-wide scan is intentionally avoided to suppress
    bogus pairs.
    """
    if hint_file:
        if not (repo_root / hint_file).is_file():
            return None
        for pattern in patterns_fn(symbol):
            proc = subprocess.run(
                ["grep", "-En", "-e", pattern, "--", hint_file],
                cwd=str(repo_root),
                capture_output=True,
                text=True,
                check=False,
            )
            if proc.returncode == 0:
                first_line = proc.stdout.splitlines()[0] if proc.stdout else ""
                line_no, _, _ = first_line.partition(":")
                if line_no.isdigit():
                    return f"{hint_file}:{line_no}"
        return None
    for pattern in patterns_fn(symbol):
        proc = subprocess.run(
            [
                "grep",
                "-rEn",
                "--include=*.ts",
                "--include=*.tsx",
                "--include=*.js",
                "--include=*.jsx",
                "--include=*.mjs",
                "--include=*.cjs",
                "--include=*.mts",
                "--include=*.cts",
                "--include=*.py",
                pattern,
                ".",
            ],
            cwd=str(repo_root),
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            for line in proc.stdout.splitlines():
                parts = line.split(":", 2)
                if len(parts) >= 2:
                    file = parts[0].removeprefix("./")
                    return f"{file}:{parts[1]}"
    return None


def _ts_type_definition_patterns(symbol: str) -> list[str]:
    return [
        rf"^\s*(export\s+)?(interface|type)\s+{re.escape(symbol)}\b",
    ]


def _ts_function_definition_patterns(symbol: str) -> list[str]:
    return [
        rf"^\s*(export\s+(default\s+)?)?(async\s+)?function\s+{re.escape(symbol)}\b",
        rf"^\s*(export\s+)?const\s+{re.escape(symbol)}\s*=\s*(async\s+)?(function|\()",
        rf"^\s*(export\s+)?const\s+{re.escape(symbol)}\s*:[^=]+=\s*(async\s+)?(function|\()",
    ]


def _py_class_definition_patterns(symbol: str) -> list[str]:
    return [rf"^\s*class\s+{re.escape(symbol)}\b"]


def _py_function_definition_patterns(symbol: str) -> list[str]:
    return [rf"^\s*(async\s+)?def\s+{re.escape(symbol)}\b"]


def find_callers(
    symbol: str, repo_root: Path, definition_file: str | None
) -> list[str]:
    """Find all reference locations of symbol via grep -rEn.

    Excludes the file:line that contains the symbol definition.
    """
    proc = subprocess.run(
        [
            "grep",
            "-rEn",
            "--exclude-dir=.venv",
            "--exclude-dir=node_modules",
            "--exclude-dir=__pycache__",
            "--exclude-dir=.git",
            "--exclude-dir=.worktrees",
            "--exclude-dir=dist",
            "--exclude-dir=build",
            "--include=*.ts",
            "--include=*.tsx",
            "--include=*.js",
            "--include=*.jsx",
            "--include=*.mjs",
            "--include=*.cjs",
            "--include=*.mts",
            "--include=*.cts",
            "--include=*.py",
            rf"\b{re.escape(symbol)}\b",
            ".",
        ],
        cwd=str(repo_root),
        capture_output=True,
        text=True,
        check=False,
    )
    refs: list[str] = []
    if proc.returncode != 0:
        return refs
    for line in proc.stdout.splitlines():
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        file = parts[0].removeprefix("./")
        line_no = parts[1]
        line_content = parts[2]
        location = f"{file}:{line_no}"
        if definition_file and location == definition_file:
            continue
        if re.search(
            rf"^\s*(?:export\s+)?(?:async\s+)?(?:function|class|interface|type|def|const)\s+{re.escape(symbol)}\b",
            line_content,
        ):
            continue
        refs.append(location)
    return refs


def build_touched_ranges(diff: str) -> dict[str, list[tuple[int, int]]]:
    """Parse diff hunks and return {file: [(start_line, end_line), ...]} for new-file line ranges."""
    ranges: dict[str, list[tuple[int, int]]] = {}
    current_file: str | None = None
    hunk_re = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
    for line in diff.splitlines():
        header_match = DIFF_FILE_HEADER_RE.match(line)
        if header_match:
            current_file = header_match.group(1)
            continue
        if not current_file:
            continue
        m = hunk_re.match(line)
        if m:
            start = int(m.group(1))
            count = int(m.group(2)) if m.group(2) is not None else 1
            if count > 0:
                ranges.setdefault(current_file, []).append((start, start + count - 1))
    return ranges


def is_touched(location: str, touched_ranges: dict[str, list[tuple[int, int]]]) -> bool:
    """Return True if the caller location's line number falls within a touched hunk range."""
    parts = location.split(":", 1)
    if len(parts) != 2 or not parts[1].isdigit():
        return False
    file = parts[0]
    line_no = int(parts[1])
    for start, end in touched_ranges.get(file, []):
        if start <= line_no <= end:
            return True
    return False


def detect_public_marker(
    symbol: str,
    repo_root: Path,
    language: str,
    definition_evidence: str | None = None,
) -> str:
    """Return a string describing the strongest public marker, or 'none'.

    `definition_evidence` (format: 'file:line') is used by the TypeScript path
    to verify the symbol itself is exported, not just that the package as a
    whole is publishable.
    """
    if language == "py":
        if not symbol.startswith("_"):
            pyproject = repo_root / "pyproject.toml"
            if pyproject.exists():
                try:
                    content = pyproject.read_text(encoding="utf-8")
                except OSError:
                    content = ""
                if re.search(r"^\s*\[project\]", content, re.MULTILINE):
                    return "detected: PyPI metadata in pyproject.toml"
            if _in_all_export(symbol, repo_root):
                return "detected: listed in __all__"
    if (
        language == "ts"
        and definition_evidence
        and _ts_symbol_is_exported(symbol, repo_root, definition_evidence)
    ):
        package_json = repo_root / "package.json"
        if package_json.exists():
            try:
                content = package_json.read_text(encoding="utf-8")
            except OSError:
                content = ""
            try:
                pkg = json.loads(content) if content else {}
            except json.JSONDecodeError:
                pkg = {}
            if pkg.get("private") is not True and (
                pkg.get("exports") or pkg.get("main") or pkg.get("types")
            ):
                return "detected: exported symbol in public package"
    for spec in (
        "openapi.yaml", "openapi.yml", "swagger.yaml", "swagger.yml",
        "openapi.json", "swagger.json", "schema.json",
    ):
        if (repo_root / spec).exists():
            if _grep_quick(rf"\b{re.escape(symbol)}\b", repo_root / spec):
                return f"detected: referenced in {spec}"
    proto_or_graphql = _grep_quick_files(
        rf"\b{re.escape(symbol)}\b",
        repo_root,
        ("*.proto", "*.graphql", "*.gql"),
    )
    if proto_or_graphql:
        return f"detected: referenced in {proto_or_graphql}"
    deprecation_hit = _grep_quick(
        rf"(@deprecated|Deprecation:|/\*\*.*@deprecated).*\b{re.escape(symbol)}\b",
        repo_root,
    )
    if deprecation_hit:
        return "detected: @deprecated annotation"
    return "none"


def _in_all_export(symbol: str, repo_root: Path) -> bool:
    """Check if symbol appears in any __all__ list, including multiline forms."""
    sym_re = re.compile(rf"\b{re.escape(symbol)}\b")
    all_re = re.compile(r"__all__\s*[+]?=\s*\[([^\]]*)", re.DOTALL)
    for path in repo_root.rglob("*.py"):
        try:
            rel = path.relative_to(repo_root)
        except ValueError:
            rel = path
        if any(part in _SKIP_DIRS for part in rel.parts):
            continue
        try:
            content = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        m = all_re.search(content)
        if m and sym_re.search(m.group(1)):
            return True
    return False


def _grep_quick(pattern: str, target: Path) -> bool:
    if target.is_file():
        proc = subprocess.run(
            ["grep", "-Eq", pattern, str(target)],
            capture_output=True,
            check=False,
        )
        return proc.returncode == 0
    proc = subprocess.run(
        [
            "grep",
            "-rEq",
            "--exclude-dir=.git",
            "--exclude-dir=.worktrees",
            "--exclude-dir=node_modules",
            "--exclude-dir=.venv",
            "--exclude-dir=__pycache__",
            "--exclude-dir=dist",
            "--exclude-dir=build",
            "--include=*.ts",
            "--include=*.tsx",
            "--include=*.js",
            "--include=*.jsx",
            "--include=*.mjs",
            "--include=*.cjs",
            "--include=*.py",
            "--include=*.md",
            "--include=*.txt",
            pattern,
            ".",
        ],
        cwd=str(target),
        capture_output=True,
        check=False,
    )
    return proc.returncode == 0


def _ts_symbol_is_exported(
    symbol: str, repo_root: Path, definition_evidence: str
) -> bool:
    """Return True if the TS/JS symbol is exported at its definition site.

    Avoids the false positive where a TS package is publishable but the
    specific symbol is internal-only (no `export` keyword at its definition).
    """
    file_str, _, _ = definition_evidence.partition(":")
    if not file_str:
        return False
    file_path = repo_root / file_str
    if not file_path.is_file():
        return False
    try:
        content = file_path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False
    export_re = re.compile(
        rf"^\s*export\s+(?:default\s+)?(?:async\s+)?"
        rf"(?:interface|type|function|class|const|let|var)\s+{re.escape(symbol)}\b",
        re.MULTILINE,
    )
    if export_re.search(content):
        return True
    reexport_re = re.compile(
        rf"^\s*export\s+(?:type\s+)?\{{[^}}]*\b{re.escape(symbol)}\b[^}}]*\}}",
        re.MULTILINE,
    )
    return bool(reexport_re.search(content))


_SKIP_DIRS = frozenset({".git", ".worktrees", "node_modules", ".venv", "__pycache__", "dist", "build"})


def _grep_quick_files(pattern: str, repo_root: Path, globs: tuple[str, ...]) -> str:
    for glob in globs:
        for path in repo_root.rglob(glob):
            try:
                rel = path.relative_to(repo_root)
            except ValueError:
                rel = path
            if any(part in _SKIP_DIRS for part in rel.parts):
                continue
            try:
                content = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            if re.search(pattern, content):
                return str(rel)
    return ""


def analyze(candidate: Candidate, repo_root: Path, touched_ranges: dict[str, list[tuple[int, int]]]) -> Finding:
    finding = Finding(candidate=candidate)
    raw_refs = find_callers(candidate.old_symbol, repo_root, candidate.old_evidence)
    finding.callers = [
        CallerRef(location=ref, touched=is_touched(ref, touched_ranges)) for ref in raw_refs
    ]
    finding.public_marker = detect_public_marker(
        candidate.old_symbol,
        repo_root,
        candidate.language,
        candidate.old_evidence,
    )
    if finding.public_marker != "none":
        finding.co_evolution_scope = f"excluded ({finding.public_marker})"
        finding.confidence = "low"
    elif not finding.callers:
        finding.co_evolution_scope = "confirmed (no callers)"
        finding.confidence = "medium"
    elif all(c.touched for c in finding.callers):
        finding.co_evolution_scope = "confirmed"
        finding.confidence = "high"
    else:
        untouched = sum(1 for c in finding.callers if not c.touched)
        finding.co_evolution_scope = f"uncertain ({untouched} reference(s) not touched)"
        finding.confidence = "low"

    finding.subtractive_question = (
        f"なぜ {candidate.old_symbol} を残したか? "
        "全 caller が同 PR 内で touched され、外部消費者がいない場合、"
        f"{candidate.old_symbol} を削除して {candidate.new_symbol} のみに統一できる。"
    )
    finding.suggested_next_action = (
        f"{candidate.old_evidence} の {candidate.old_symbol} 定義を削除し、"
        f"全 caller を {candidate.new_symbol} に置換することを検討する"
        " (caller 一覧は本 finding を参照)。"
    )
    return finding


def format_text(findings: list[Finding]) -> str:
    if not findings:
        return "✅ co-evolve-check: no co-evolution opportunities found\n"
    lines: list[str] = []
    high = medium = low = 0
    for f in findings:
        if f.confidence == "high":
            high += 1
        elif f.confidence == "medium":
            medium += 1
        else:
            low += 1
        c = f.candidate
        lines.append(f"Co-evolution opportunity: {c.kind}")
        lines.append(f"Evidence: {c.old_evidence} (old) + {c.new_evidence} (new)")
        lines.append(f"Old symbol: {c.old_symbol}")
        lines.append(f"New symbol: {c.new_symbol}")
        lines.append(f"Callers of old symbol: {len(f.callers)} reference(s)")
        for ref in f.callers:
            mark = "✓" if ref.touched else "✗"
            label = "touched in this PR" if ref.touched else "not touched"
            lines.append(f"  - {ref.location} [{label} {mark}]")
        lines.append(f"Public marker: {f.public_marker}")
        lines.append(f"Co-evolution scope: {f.co_evolution_scope}")
        lines.append(f"Subtractive question: {f.subtractive_question}")
        lines.append(f"Suggested next action: {f.suggested_next_action}")
        lines.append(f"Confidence: {f.confidence}")
        lines.append("")
    lines.append(
        f"✅ co-evolve-check: {len(findings)} finding(s) "
        f"({high} high / {medium} medium / {low} low confidence)"
    )
    return "\n".join(lines) + "\n"


def format_json_output(findings: list[Finding]) -> str:
    payload = {
        "findings": [
            {
                **asdict(f.candidate),
                "callers": [asdict(c) for c in f.callers],
                "public_marker": f.public_marker,
                "co_evolution_scope": f.co_evolution_scope,
                "confidence": f.confidence,
                "subtractive_question": f.subtractive_question,
                "suggested_next_action": f.suggested_next_action,
            }
            for f in findings
        ],
        "summary": {
            "total": len(findings),
            "high": sum(1 for f in findings if f.confidence == "high"),
            "medium": sum(1 for f in findings if f.confidence == "medium"),
            "low": sum(1 for f in findings if f.confidence == "low"),
        },
    }
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="co-evolve-check: pre-PR sweep for retention bias"
    )
    parser.add_argument(
        "base_branch",
        nargs="?",
        default=None,
        help="positional base branch (e.g. main); takes precedence over --base",
    )
    parser.add_argument("--base", default=None, help="base ref (default: origin/HEAD)")
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument("--staged", action="store_true", help="diff --cached")
    mode_group.add_argument("--worktree", action="store_true", help="diff HEAD")
    parser.add_argument("--json", action="store_true", help="JSON output")
    parser.add_argument(
        "--cwd",
        default=None,
        help="repo root override (default: discovered from cwd)",
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

    if os.environ.get("CLAUDE_SKILL_CO_EVOLVE_CHECK_DISABLE") == "1":
        if args.json:
            sys.stdout.write(format_json_output([]))
        else:
            sys.stdout.write("✅ co-evolve-check: disabled via env\n")
        return EXIT_SKIPPED

    start_cwd = Path(args.cwd) if args.cwd else Path.cwd()
    repo_root = repo_root_from(start_cwd)
    if repo_root is None:
        sys.stderr.write("git rev-parse failed; not a git repo\n")
        return EXIT_GIT_ERROR

    languages = detect_languages(repo_root)
    languages_env = os.environ.get("CLAUDE_SKILL_CO_EVOLVE_CHECK_LANGUAGES")
    if languages_env:
        override = {x.strip() for x in languages_env.split(",") if x.strip()}
        languages = override & {"ts", "py"}
    if not languages:
        if args.json:
            sys.stdout.write(format_json_output([]))
        else:
            sys.stdout.write("✅ co-evolve-check: project language not detected; skipped\n")
        return EXIT_SKIPPED

    mode = "staged" if args.staged else "worktree" if args.worktree else "diff"

    base_ref = None
    if mode == "diff":
        base_ref = resolve_base_ref(repo_root, args.base)
        if not base_ref:
            sys.stderr.write("could not resolve base ref\n")
            return EXIT_GIT_ERROR
        if is_pure_revert(repo_root, base_ref):
            if args.json:
                sys.stdout.write(format_json_output([]))
            else:
                sys.stdout.write("✅ co-evolve-check: revert-only diff; skipped\n")
            return EXIT_SKIPPED

    code, diff = get_diff(repo_root, base_ref, mode)
    if code != EXIT_OK:
        return code
    if not diff.strip():
        if args.json:
            sys.stdout.write(format_json_output([]))
        else:
            sys.stdout.write("✅ co-evolve-check: no co-evolution opportunities found\n")
        return EXIT_OK

    added = parse_diff_added_symbols(diff, languages)
    candidates = find_pair_candidates(added, repo_root, languages)
    touched_ranges = build_touched_ranges(diff)
    findings = [analyze(c, repo_root, touched_ranges) for c in candidates]

    if args.json:
        sys.stdout.write(format_json_output(findings))
    else:
        sys.stdout.write(format_text(findings))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
