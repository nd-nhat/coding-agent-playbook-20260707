"""triage_core の unit test(stdlib unittest・boto3 不要)。`python3 -m unittest` で走る。

sanitize gate の核(schema 検証・secret redact・dedup キー・actionable 判定・size 上限)を
AWS 無しで検証する。handler.py の boto3 部分は AWS 環境での結合テスト側。
"""

import os
import sys
import unittest

# dir 名に dash を含み package 化できないので、自分の dir を sys.path に足して flat import する
# (CWD に依らず `python3 -m unittest` / discover で動かせるように)。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import triage_core as tc  # noqa: E402


class TestValidate(unittest.TestCase):
    def _valid(self):
        return tc.build_triage("diag-api", "upstream_contract_violation", 502,
                               "/x", "evidence", "2026-01-01T00:00:00Z", 5)

    def test_valid_passes(self):
        tc.validate_triage(self._valid())

    def test_unknown_top_key_rejected(self):
        t = self._valid()
        t["extra"] = 1
        with self.assertRaises(ValueError):
            tc.validate_triage(t)

    def test_unknown_incident_key_rejected(self):
        t = self._valid()
        t["incident"]["surprise"] = "x"
        with self.assertRaises(ValueError):
            tc.validate_triage(t)

    def test_unknown_constraints_key_rejected(self):
        t = self._valid()
        t["constraints"]["surprise"] = "x"
        with self.assertRaises(ValueError):
            tc.validate_triage(t)

    def test_missing_signature_rejected(self):
        t = self._valid()
        del t["incident"]["signature"]
        with self.assertRaises(ValueError):
            tc.validate_triage(t)


class TestRedact(unittest.TestCase):
    def test_strips_aws_key_and_pem(self):
        out = tc.redact("key AKIAIOSFODNN7EXAMPLE and -----BEGIN X-----secret-----END X-----")
        self.assertNotIn("AKIAIOSFODNN7EXAMPLE", out)
        self.assertNotIn("BEGIN X", out)
        self.assertIn("[REDACTED]", out)

    def test_collapses_newlines_and_caps_length(self):
        out = tc.redact("a\nb\n  c", limit=600)
        self.assertEqual(out, "a b c")
        self.assertLessEqual(len(tc.redact("x" * 5000, limit=600)), 600)

    def test_strips_bearer_token(self):
        self.assertNotIn("supersecret", tc.redact("Authorization: supersecret"))

    def test_strips_authorization_bearer_two_word_form(self):
        out = tc.redact("Authorization: Bearer abc123tok and Bearer xyz789tok")
        self.assertNotIn("abc123tok", out)
        self.assertNotIn("xyz789tok", out)

    def test_strips_non_bearer_scheme(self):
        self.assertNotIn("dXNlcjpwYXNz", tc.redact("Authorization: Basic dXNlcjpwYXNz"))

    def test_scan_catches_quoted_json_secrets(self):
        self.assertTrue(tc.scan_secrets('{"aws_secret_access_key":"wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY"}'))
        self.assertTrue(tc.scan_secrets('{"api_key":"supersecret"}'))


class TestDedupKey(unittest.TestCase):
    def test_slug_is_branch_safe_chars(self):
        for raw in ["diag api: 502\n../../etc", "Weird/Sig", "  "]:
            k = tc.dedup_key("svc", raw)
            self.assertRegex(k, r"^[a-z0-9-]+$")

    def test_stable_for_same_input(self):
        self.assertEqual(
            tc.dedup_key("diag-api", "upstream_contract_violation"),
            tc.dedup_key("diag-api", "upstream_contract_violation"),
        )

    def test_non_ascii_signatures_do_not_collide(self):
        # slug が潰れる非 ASCII signature でも hash で別キーになる(dedup 衝突防止)。
        a = tc.dedup_key("svc", "契約違反")
        b = tc.dedup_key("svc", "タイムアウト")
        self.assertNotEqual(a, b)
        self.assertRegex(a, r"^[a-z0-9-]+$")


class TestActionable(unittest.TestCase):
    def test_threshold(self):
        self.assertTrue(tc.is_actionable(3, 3))
        self.assertTrue(tc.is_actionable(10, 3))
        self.assertFalse(tc.is_actionable(2, 3))
        self.assertFalse(tc.is_actionable(None, 3))


class TestBuildAndSerialize(unittest.TestCase):
    def test_build_redacts_evidence_and_fixes_constraints(self):
        t = tc.build_triage("diag-api", "sig", 502, "/x",
                            "tok AKIAIOSFODNN7EXAMPLE", "ts", 5)
        self.assertNotIn("AKIAIOSFODNN7EXAMPLE", t["incident"]["evidence"])
        self.assertTrue(t["constraints"]["no_secrets"])
        self.assertTrue(t["constraints"]["no_raw_logs"])
        tc.validate_triage(t)

    def test_serialize_enforces_size_limit(self):
        t = tc.build_triage("diag-api", "sig", 502, "/x", "e", "ts", 5)
        t["incident"]["evidence"] = "x" * 10000  # bypass redact to force oversize
        with self.assertRaises(ValueError):
            tc.serialize(t)

    def test_serialize_returns_bytes(self):
        t = tc.build_triage("diag-api", "sig", 502, "/x", "e", "ts", 5)
        self.assertIsInstance(tc.serialize(t), bytes)

    def test_serialize_rejects_secret_in_non_evidence_field(self):
        # external_call は redact 対象外。secret が紛れたら whole-triage scan で弾く(fail-closed)。
        t = tc.build_triage("diag-api", "sig", 502, "/x", "e", "ts", 5,
                            external_call={"path": "AKIAIOSFODNN7EXAMPLE"})
        with self.assertRaises(ValueError):
            tc.serialize(t)

    def test_serialize_rejects_quoted_json_secret_key(self):
        # JSON 形式 {"api_key":"..."} の secret も serialize の whole-triage scan で弾く。
        t = tc.build_triage("diag-api", "sig", 502, "/x", "e", "ts", 5,
                            external_call={"api_key": "supersecretvalue"})
        with self.assertRaises(ValueError):
            tc.serialize(t)


if __name__ == "__main__":
    unittest.main()
