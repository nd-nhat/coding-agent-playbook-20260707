"""観測 identity の triage Lambda(CloudWatch 5xx alarm → SNS → 本 handler)。

役割: 該当ログを Logs Insights で取り → actionable 判定 → sanitize 済み triage を組み →
DynamoDB で dedup → S3 に PUT(観測の出力はここまで。GitHub には一切触らない)。起動は別途
S3 event → EventBridge → fixer(pipeline/README.md の配線図)。純ロジックは triage_core.py。

env:
  APP_LOG_GROUP        対象アプリの CloudWatch Logs グループ名
  TRIAGE_BUCKET        sanitized triage を置く S3 バケット
  SERVICE_NAME         incident.service に入れる論理サービス名(既定 'diag-api')
  WINDOW_MINUTES       Logs Insights の遡及窓(既定 15)
  ACTIONABLE_THRESHOLD window 内 5xx 件数の actionable 閾値(既定 3)
  DEDUP_TABLE          dedup state の DynamoDB table 名(任意。未設定なら dedup 無効)
  DEDUP_TTL_SECONDS    dedup window 秒(既定 1800)

注意: 観測 role は GitHub egress を持たない。issue 作成・PR は一切しない(identity 境界。README 参照)。
"""

import json
import os
import time
import uuid
from datetime import datetime

import boto3

import triage_core

_logs = boto3.client("logs")
_s3 = boto3.client("s3")

_BASE_FILTER = ("filter @message like /\\b5\\d\\d\\b/"
                " and @message like /(?i)contract|upstream|error/")


def _alarm_time(event):
    """SNS 経由の CloudWatch alarm payload の StateChangeTime を窓の終端に使う。SNS 配信や Lambda 再試行で
    invocation 時刻がアラームから数分ずれても、トリガとなった 5xx を窓から外さない。取れなければ now。"""
    try:
        msg = json.loads(event["Records"][0]["Sns"]["Message"])
        t = msg.get("StateChangeTime")
        if t:
            return int(datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp())
    except (KeyError, IndexError, TypeError, ValueError):
        pass
    return int(time.time())


def _run_query(log_group, start, end, query_string):
    """Logs Insights を 1 本流して Complete まで polling し results を返す。
    Failed/Cancelled/未完了を空結果に丸めると incident を取りこぼすので明示的に raise(可視化/再試行)。"""
    qid = _logs.start_query(logGroupName=log_group, startTime=start, endTime=end,
                            queryString=query_string)["queryId"]
    res = {}
    for _ in range(30):
        res = _logs.get_query_results(queryId=qid)
        if res["status"] in ("Complete", "Failed", "Cancelled", "Timeout"):
            break
        time.sleep(1)
    if res.get("status") != "Complete":
        raise RuntimeError("Logs Insights query が Complete しません: status=%s" % res.get("status"))
    return res.get("results", [])


def _query_logs(log_group, window_minutes, anchor_end):
    """anchor_end を窓の終端に固定して 5xx を集計。count は `stats count()` で正確に取り(単一 page の
    len() は大量時に過小計数する)、evidence は別途 1 件だけサンプルする。signature 抽出はアプリ依存の reference。
    5xx を必須にした上で contract/upstream/error marker を併せ持つ行だけ数える(marker だけの非 5xx を弾く)。"""
    end = anchor_end
    start = end - window_minutes * 60
    crows = _run_query(log_group, start, end,
                       "fields @message | " + _BASE_FILTER + " | stats count() as cnt")
    count = 0
    if crows:
        cell = {c["field"]: c["value"] for c in crows[0]}
        count = int(cell.get("cnt", "0") or "0")
    first_seen, evidence = None, ""
    if count:
        srows = _run_query(log_group, start, end,
                           "fields @timestamp, @message | " + _BASE_FILTER + " | sort @timestamp asc | limit 1")
        if srows:
            cols = {c["field"]: c["value"] for c in srows[0]}
            first_seen = cols.get("@timestamp")
            evidence = cols.get("@message", "")
    return count, first_seen, evidence


def _dedup_claim(dedup_key, ttl_seconds):
    """DynamoDB 条件付き put で incident を atomic に claim: 未 claim なら書いて False(=処理する)、
    既 claim なら True(=skip)。AWS 内書き込みで GitHub egress ではないので観測境界は破らない。
    dedup の SoT は GitHub でなく state。handoff 失敗時は _dedup_release で claim を外す(取りこぼし防止)。"""
    table = os.environ.get("DEDUP_TABLE")
    if not table:
        return False
    ddb = boto3.client("dynamodb")
    now = int(time.time())
    try:
        ddb.put_item(
            TableName=table,
            Item={"dedup_key": {"S": dedup_key}, "expires_at": {"N": str(now + ttl_seconds)}},
            ConditionExpression="attribute_not_exists(dedup_key) OR expires_at < :now",
            ExpressionAttributeValues={":now": {"N": str(now)}},
        )
        return False
    except ddb.exceptions.ConditionalCheckFailedException:
        return True


def _dedup_release(dedup_key):
    """handoff(serialize/S3 PUT)が失敗したら claim を外す。marker だけ残って次回が dedup 抑止され
    incident を取りこぼすのを防ぐ(incident の取りこぼし > 重複処理、なので at-least-once 側に倒す)。"""
    table = os.environ.get("DEDUP_TABLE")
    if not table:
        return
    boto3.client("dynamodb").delete_item(
        TableName=table, Key={"dedup_key": {"S": dedup_key}})


def handler(event, _context=None):
    log_group = os.environ["APP_LOG_GROUP"]
    bucket = os.environ["TRIAGE_BUCKET"]
    service = os.environ.get("SERVICE_NAME", "diag-api")
    window = int(os.environ.get("WINDOW_MINUTES", "15"))
    threshold = int(os.environ.get("ACTIONABLE_THRESHOLD", "3"))
    ttl = int(os.environ.get("DEDUP_TTL_SECONDS", "1800"))

    count, first_seen, evidence_raw = _query_logs(log_group, window, _alarm_time(event))

    # noise(閾値未満)は agent を起こさず記録に留める(GitHub には触らない)。
    if not triage_core.is_actionable(count, threshold):
        print("noise: count=%d < threshold=%d, skip" % (count, threshold))
        return {"actionable": False, "count": count}

    signature = "upstream_contract_violation"  # reference: 実アプリでは log から導出する
    failing_path = "/power-data/readings"      # reference: 同上
    # dedup は resource(failing_path) も含める。同 signature でも別 path は別 incident として扱う
    # (含めないと別 path の障害が TTL 窓内で相互に抑止される)。
    key = triage_core.dedup_key(service, signature, failing_path)
    if _dedup_claim(key, ttl):
        print("dedup: %s already claimed in window, skip" % key)
        return {"deduped": True, "dedup_key": key}

    # claim 後に handoff が失敗したら claim を外す(marker だけ残して次回を抑止＝取りこぼし、を防ぐ)。
    try:
        triage = triage_core.build_triage(
            service=service,
            signature=signature,
            http_status=502,
            failing_path=failing_path,
            evidence=evidence_raw,
            first_seen=first_seen,
            count_5xx_window=count,
        )
        body = triage_core.serialize(triage)  # validate + secret scan + size + bytes 化
        # S3 key は推測不能(fixer が他 incident を列挙・推測できないように)。
        object_key = "triage/%s.json" % uuid.uuid4()
        _s3.put_object(Bucket=bucket, Key=object_key, Body=body, ContentType="application/json")
    except Exception:
        _dedup_release(key)
        raise

    print("wrote sanitized triage: s3://%s/%s" % (bucket, object_key))
    return {"actionable": True, "count": count, "s3_key": object_key}
