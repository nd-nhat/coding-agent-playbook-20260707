"""観測側 triage の純ロジック(boto3 非依存・local で unit test 可能)。

ADR cloud-unattended-sre.md / pipeline/README.md の sanitize gate を Python で実装したもの。
handler.py が boto3(Logs Insights / S3 / DynamoDB)でこの純関数群を I/O で囲む。schema は
spike/triage.json・fixer-entrypoint.sh の検証と等価に保つ(drift させると修正 identity 側で弾かれる)。
"""

import hashlib
import json
import re

MAX_BYTES = 8192
ALLOWED_TOP = {"schema_version", "_note", "incident", "constraints"}
ALLOWED_INCIDENT = {
    "service", "signature", "http_status", "failing_path",
    "external_call", "evidence", "first_seen", "count_5xx_window",
}
ALLOWED_CONSTRAINTS = {"scope", "no_raw_logs", "no_secrets", "fixer_inputs"}

# raw log/secret の持ち出しを sanitize で潰す。命令注入の無害化ではない(それは fixer に triage 以外を
# 読ませない設計で担保。pipeline/README.md「optional: issue layer」参照)。
_SECRET_PATTERNS = [
    re.compile(r"-----BEGIN[^-]+-----.*?-----END[^-]+-----", re.DOTALL),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    # quote 有無どちらの aws_secret_access_key も消す(JSON `"aws_secret_access_key":"..."` 含む)。
    re.compile(r"(?i)\baws_secret_access_key\b[\"']?\s*[:=]?\s*[\"']?[^\s'\"},]+"),
    # `Bearer <token>` 単独形(scheme 語の後ろに token が続くので 1 語先まで含めて消す)。
    re.compile(r"(?i)\bbearer\s+[^\s'\"]+"),
    # `key: value` / `key=value` / `"key":"value"`(JSON) / `Authorization: <scheme> value`。
    # キー/値の前後の quote を許容し、scheme 語(Bearer/Basic 等)を 1 つ任意に挟み、値は空白/quote/`}`/`,` で止める。
    re.compile(r"(?i)\b(authorization|api[_-]?key|x-api-key|access[_-]?token|token|secret|password|passwd|pwd)\b[\"']?\s*[:=]?\s*[\"']?(?:[A-Za-z]+\s+)?[^\s'\"},]+"),
    re.compile(r"\b[A-Fa-f0-9]{40,}\b"),  # 長い hex(鍵/hash の塊)
]


def scan_secrets(text):
    """secret らしき断片が残っていれば True。serialize で triage 全体(evidence 以外も)を fail-closed に弾く。"""
    return any(p.search(text or "") for p in _SECRET_PATTERNS)


def redact(text, limit=600):
    """evidence を要約サイズに保ち secret らしき断片を伏せる。raw log 全文の混入を防ぐ。"""
    s = "" if text is None else str(text)
    for pat in _SECRET_PATTERNS:
        s = pat.sub("[REDACTED]", s)
    s = re.sub(r"\s+", " ", s).strip()  # 改行を畳んで複数行 log dump を 1 行要約に
    return s[:limit]


def dedup_key(service, signature, resource=""):
    """dedup state(DynamoDB)用の安定キー。triage 自由文字列を [a-z0-9-] に slug 化し、raw の短い
    hash を付す(非 ASCII signature は slug が fallback に潰れて衝突するため、hash で一意性を保つ)。"""
    raw = "%s-%s-%s" % (service or "svc", signature or "", resource or "")
    slug = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")[:96].strip("-")
    digest = hashlib.sha1(raw.encode("utf-8")).hexdigest()[:12]
    return ("%s-%s" % (slug, digest)) if slug else "incident-" + digest


def is_actionable(count_5xx, threshold=3):
    """noise を弾く: window 内の 5xx 件数が閾値以上なら agent を起こす対象。"""
    try:
        return int(count_5xx) >= int(threshold)
    except (TypeError, ValueError):
        return False


def build_triage(service, signature, http_status, failing_path,
                 evidence, first_seen, count_5xx_window, external_call=None):
    """schema 準拠の triage を組む。constraints は固定(fixer の前提を明示)。evidence は redact 済みを使う。"""
    incident = {
        "service": service,
        "signature": signature,
        "http_status": http_status,
        "failing_path": failing_path,
        "evidence": redact(evidence),
        "first_seen": first_seen,
        "count_5xx_window": count_5xx_window,
    }
    if external_call is not None:
        incident["external_call"] = external_call
    return {
        "schema_version": "1",
        "incident": incident,
        "constraints": {
            "scope": "最小修正のみ。無関係な refactor をしない。",
            "no_raw_logs": True,
            "no_secrets": True,
            "fixer_inputs": "repo + 本 triage のみ。AWS / network には出ない。",
        },
    }


def validate_triage(triage):
    """sanitized handoff の制約を enforce(spike/fixer と等価)。NG は ValueError。"""
    if not isinstance(triage, dict):
        raise ValueError("triage の top-level が object でない")
    extra = set(triage) - ALLOWED_TOP
    if extra:
        raise ValueError("triage に未知の top-level キー: %s" % sorted(extra))
    if "schema_version" not in triage:
        raise ValueError("triage に schema_version がない")
    inc = triage.get("incident")
    if not isinstance(inc, dict) or "signature" not in inc:
        raise ValueError("triage に incident.signature がない")
    inc_extra = set(inc) - ALLOWED_INCIDENT
    if inc_extra:
        raise ValueError("incident に未知のキー: %s" % sorted(inc_extra))
    con = triage.get("constraints", {})
    if not isinstance(con, dict):
        raise ValueError("constraints が object でない")
    con_extra = set(con) - ALLOWED_CONSTRAINTS
    if con_extra:
        raise ValueError("constraints に未知のキー: %s" % sorted(con_extra))


def serialize(triage):
    """検証済み triage を S3 PutObject 用の bytes にする。size 上限と全フィールドの secret scan も
    sanitize gate の一部(redact は evidence のみなので、_note / external_call 等に secret が紛れたら
    ここで fail-closed に弾く。emit せず捨てる方が安全)。"""
    validate_triage(triage)
    text = json.dumps(triage, ensure_ascii=False, separators=(",", ":"))
    if scan_secrets(text):
        raise ValueError("triage に secret らしき内容が残存(redact 漏れ / evidence 以外の経路)")
    body = text.encode("utf-8")
    if len(body) > MAX_BYTES:
        raise ValueError("triage が大きすぎます (%dB > %d)" % (len(body), MAX_BYTES))
    return body
