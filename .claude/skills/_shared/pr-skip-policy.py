#!/usr/bin/env python3
"""
pr-skip-policy.py - Decide the lightweight-PR skip profile for a base..head range.

`/comment-sweep` 等の pre-PR sweep skill が「sweep 対象 diff か否か」を統一判定
するための helper。本 repo では次の 2 profile を返す:

- ``pure-revert``  : base..head の全 commit subject が ``Revert "``
- ``tiny-json-hotfix`` : `.claude/` 配下の単一 JSON scalar 値置換等の構造的軽量 diff
- ``none``         : 上記いずれにも該当しない（通常フロー）

CLI:
    python3 -I .claude/skills/_shared/pr-skip-policy.py --base <ref> --head <ref> [--json]

Output (stdout, JSON):
    {"profile": "pure-revert" | "tiny-json-hotfix" | "none", "failed_check": <str|null>}

Exit codes:
    0  determination succeeded (profile is authoritative)
    2  usage error (bad/missing args)
    3  evaluation could not complete (git invocation failed) — caller should
       fall back to the normal flow WITHOUT recording the result

Range conventions:
    - commit subjects: ``git log <base>..<head>``  (two-dot range)
    - diffs:           ``git diff <base>...<head>`` (three-dot, merge-base based)
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

# tiny-json-hotfix の対象パス境界。本 repo 用の `.claude/` のみ。
PATH_PREFIXES = (".claude/",)

# touch されると軽量性が崩れる lockfile (`.json` 拡張子 gate 通過後に照合)。
LOCKFILES = frozenset({"package-lock.json", "npm-shrinkwrap.json"})

_REVERT_RE = re.compile(r'^Revert "')
_SKIP_GATES_RE = re.compile(r"^(hotfix|chore)\(skip-gates\):")
_MERGE_RE = re.compile(r"^Merge\s")


class GitError(RuntimeError):
    """git invocation failed; the caller cannot reach a determination."""


def _git(args: list[str]) -> str:
    try:
        proc = subprocess.run(
            ["git", *args],
            capture_output=True,
            text=True,
            errors="replace",
            check=False,
        )
    except OSError as exc:
        raise GitError(f"git {' '.join(args)}: {exc}") from exc
    if proc.returncode != 0:
        raise GitError(f"git {' '.join(args)}: {proc.stderr.strip()}")
    return proc.stdout


def _git_show(ref_path: str) -> str:
    return _git(["show", ref_path])


def jq_type(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    return "object"


def iter_paths(value):
    if isinstance(value, dict):
        for key, sub in value.items():
            yield (key,), sub
            for path, leaf in iter_paths(sub):
                yield (key, *path), leaf
    elif isinstance(value, list):
        for idx, sub in enumerate(value):
            yield (idx,), sub
            for path, leaf in iter_paths(sub):
                yield (idx, *path), leaf


def path_type_set(value) -> set[tuple]:
    return {(path, jq_type(leaf)) for path, leaf in iter_paths(value)}


def scalar_lines(value) -> set[str]:
    lines = set()
    for path, leaf in iter_paths(value):
        if not isinstance(leaf, (dict, list)):
            lines.add(json.dumps({"p": list(path), "v": leaf}, sort_keys=True))
    return lines


def _changed_files(base: str, head: str) -> list[tuple[str, str]]:
    out = _git(["diff", f"{base}...{head}", "--name-status"])
    rows = []
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        rows.append((parts[0], parts[-1]))
    return rows


def _numstat_total(base: str, head: str) -> int:
    out = _git(["diff", f"{base}...{head}", "--numstat"])
    total = 0
    for line in out.splitlines():
        if not line.strip():
            continue
        added, deleted, *_ = line.split("\t")
        if added == "-" or deleted == "-":
            return 1 << 30
        total += int(added) + int(deleted)
    return total


def _commit_subjects(base: str, head: str) -> list[str]:
    out = _git(["log", f"{base}..{head}", "--format=%s"])
    return out.splitlines()


def _eligible_tiny_json(base: str, head: str) -> str | None:
    rows = _changed_files(base, head)
    if not rows:
        return "no-files"

    paths = [path for _, path in rows]

    if any(status[0] != "M" for status, _ in rows):
        return "name-status-not-M-only"

    for path in paths:
        if not path.endswith(".json"):
            return "non-json-extension"
        if not path.startswith(PATH_PREFIXES):
            return "path-out-of-bounds"
        base_name = path.rsplit("/", 1)[-1]
        if base_name in LOCKFILES:
            return "lockfile"

    summary = _git(["diff", f"{base}...{head}", "--summary"])
    if "mode change" in summary or "100755" in summary:
        return "executable-mode"

    if _numstat_total(base, head) > 3:
        return "numstat-over-3"

    merge_base = _git(["merge-base", base, head]).strip()

    for path in paths:
        base_text = _git_show(f"{merge_base}:{path}")
        head_text = _git_show(f"{head}:{path}")
        try:
            base_json = json.loads(base_text)
            head_json = json.loads(head_text)
            if jq_type(base_json) != jq_type(head_json) or path_type_set(
                base_json
            ) != path_type_set(head_json):
                return "structure-changed"
            if len(scalar_lines(base_json) ^ scalar_lines(head_json)) > 2:
                return "multi-leaf-change"
        except (json.JSONDecodeError, RecursionError):
            return "invalid-json"

    return None


def determine_profile(base: str, head: str) -> dict:
    subjects = _commit_subjects(base, head)
    if not subjects:
        return {"profile": "none", "failed_check": "no-commits"}
    if any(_MERGE_RE.match(s) for s in subjects):
        return {"profile": "none", "failed_check": "merge-commit"}

    if all(_REVERT_RE.match(s) for s in subjects):
        return {"profile": "pure-revert", "failed_check": None}

    if all(_SKIP_GATES_RE.match(s) for s in subjects):
        failed = _eligible_tiny_json(base, head)
        if failed is None:
            return {"profile": "tiny-json-hotfix", "failed_check": None}
        return {"profile": "none", "failed_check": failed}

    return {"profile": "none", "failed_check": "subject-prefix"}


def _validate_ref(ref: str, flag_name: str) -> str:
    if ref.startswith("-"):
        raise SystemExit(f"{flag_name}: ref must not start with '-': {ref!r}")
    return ref


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="base ref")
    parser.add_argument("--head", required=True, help="head ref")
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit the result as JSON (default also emits JSON)",
    )
    args = parser.parse_args(argv)
    args.base = _validate_ref(args.base, "--base")
    args.head = _validate_ref(args.head, "--head")

    try:
        result = determine_profile(args.base, args.head)
    except GitError as exc:
        print(
            json.dumps({"profile": "none", "failed_check": f"git-error: {exc}"}),
            flush=True,
        )
        print(str(exc), file=sys.stderr)
        return 3

    print(json.dumps(result), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
