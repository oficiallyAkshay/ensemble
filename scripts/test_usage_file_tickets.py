"""Tests for scripts/usage-file-tickets.py. No network: Linear is a stand-in held in memory.
Run: python3 -I -m unittest discover -s scripts   (from the repository root)"""
import importlib.util
import io
import json
import os
import unittest
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("usage_file_tickets", os.path.join(HERE, "usage-file-tickets.py"))
uft = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(uft)

KEY = "lin_api_SECRETSECRETSECRET"


class FakeLinear:
    """Answers the five operations by their names; keeps tickets and comments the way Linear would."""

    def __init__(self, team=True, project=True):
        self.issues = []
        self.calls = []
        self.team, self.project = team, project

    def __call__(self, query, variables):
        op = query.split("(")[0].split()[-1]
        self.calls.append(op)
        if op == "Find":
            hits = [i for i in self.issues if variables["marker"] in i["description"]][:1]
            return {"issues": {"nodes": hits}}
        if op == "Team":
            return {"teams": {"nodes": [{"id": "team-1"}] if self.team else []}}
        if op == "Project":
            return {"projects": {"nodes": [{"id": "project-1"}] if self.project else []}}
        if op == "Create":
            i = variables["input"]
            assert (i["teamId"], i["projectId"]) == ("team-1", "project-1")
            self.issues.append({"id": "issue-%d" % len(self.issues), "title": i["title"],
                                "description": i["description"], "comments": {"nodes": []}})
            return {"issueCreate": {"success": True}}
        if op == "Comment":
            issue = next(i for i in self.issues if i["id"] == variables["input"]["issueId"])
            n = len(issue["comments"]["nodes"])
            issue["comments"]["nodes"].append({"body": variables["input"]["body"], "createdAt": "2026-10-%02d" % (10 + n)})
            return {"commentCreate": {"success": True}}
        raise AssertionError(op)


def draft(value=0.3, versions=("1.0.0",), rule="pinch_success_low"):
    marker = "<!-- usage-triage:%s -->" % rule
    return {"rule_id": rule, "marker": marker, "title": "Usage report: pinch success is low",
            "body_markdown": marker + "\n\nRule: pinch success\n\n- Sample size: 6 installs, 120 events\n",
            "observed_value": value, "affected_versions": list(versions)}


def run(drafts, linear):
    out = io.StringIO()
    code = uft.main(stdin=io.StringIO(json.dumps({"ticket_drafts": drafts})), out=out, gql=linear)
    return code, out.getvalue()


class Resp:
    def __init__(self, body=b'{"data": {"ok": 1}}'):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return self.body


class Filing(unittest.TestCase):
    def test_no_firing_rule_files_nothing_and_exits_0(self):
        linear = FakeLinear()
        code, out = run([], linear)
        self.assertEqual(code, 0)
        self.assertEqual(out, "no rule is firing; nothing filed\n")
        self.assertEqual(linear.calls, [])

    def test_one_firing_rule_files_exactly_one_ticket(self):
        linear = FakeLinear()
        code, out = run([draft()], linear)
        self.assertEqual((code, out), (0, "filed pinch_success_low\n"))
        self.assertEqual(len(linear.issues), 1)
        self.assertIn("<!-- usage-triage:pinch_success_low -->", linear.issues[0]["description"])

    def test_second_run_with_same_draft_adds_nothing(self):
        linear = FakeLinear()
        run([draft()], linear)
        code, out = run([draft()], linear)
        self.assertEqual((code, out), (0, "unchanged pinch_success_low\n"))
        self.assertEqual(len(linear.issues), 1)
        self.assertEqual(linear.issues[0]["comments"]["nodes"], [])

    def test_small_move_is_unchanged_and_big_move_comments(self):
        linear = FakeLinear()
        run([draft(0.30)], linear)
        self.assertEqual(run([draft(0.35)], linear)[1], "unchanged pinch_success_low\n")
        self.assertEqual(run([draft(0.40)], linear)[1], "commented pinch_success_low\n")
        self.assertEqual(len(linear.issues), 1)
        self.assertEqual(len(linear.issues[0]["comments"]["nodes"]), 1)
        # The comment becomes the new reference: the same value again is quiet, and 0.40 -> 0.45 is only 12.5 percent.
        self.assertEqual(run([draft(0.40)], linear)[1], "unchanged pinch_success_low\n")
        self.assertEqual(run([draft(0.45)], linear)[1], "unchanged pinch_success_low\n")

    def test_changed_versions_comment(self):
        linear = FakeLinear()
        run([draft(versions=["1.0.0"])], linear)
        self.assertEqual(run([draft(versions=["1.0.0", "1.1.0"])], linear)[1], "commented pinch_success_low\n")
        self.assertEqual(run([draft(versions=["1.0.0", "1.1.0"])], linear)[1], "unchanged pinch_success_low\n")

    def test_zero_reference_and_non_numeric_reference(self):
        self.assertFalse(uft.moved(0, 0))
        self.assertTrue(uft.moved(0, 0.1))
        self.assertTrue(uft.moved("x", 0.1))

    def test_ticket_without_recorded_state_gets_a_comment(self):
        linear = FakeLinear()
        d = draft()
        linear.issues.append({"id": "issue-0", "title": "t", "description": d["marker"], "comments": {"nodes": []}})
        self.assertEqual(run([d], linear)[1], "commented pinch_success_low\n")

    def test_unreadable_recorded_state_is_treated_as_none(self):
        issue = {"description": "<!-- usage-triage-state: {nope} -->", "comments": {"nodes": []}}
        self.assertIsNone(uft.last_state(issue))
        self.assertIsNone(uft.last_state({"description": None, "comments": {"nodes": []}}))

    def test_two_rules_one_line_each(self):
        linear = FakeLinear()
        code, out = run([draft(rule="a_rule"), draft(rule="b_rule")], linear)
        self.assertEqual((code, out), (0, "filed a_rule\nfiled b_rule\n"))
        self.assertEqual(len(linear.issues), 2)

    def test_install_id_in_a_draft_is_refused_and_not_sent(self):
        for leak in ("3f2b8c1e-9d4a-4e7b-8a11-0c5d6e7f8a9b", "3f2b8c1e9d4a4e7b8a110c5d6e7f8a9b"):
            linear = FakeLinear()
            d = draft()
            d["body_markdown"] += "- Observed: %s\n" % leak
            code, out = run([d, draft(rule="ok_rule")], linear)
            self.assertEqual((code, out), (1, "refused pinch_success_low\nfiled ok_rule\n"), leak)
            self.assertEqual(len(linear.issues), 1)

    def test_plain_versions_and_numbers_are_not_mistaken_for_ids(self):
        self.assertFalse(uft.looks_like_install_id("1.0.0, 1.1.0-beta2; 6 installs, 120 events, 0.3 -> 0.123456789"))

    def test_malformed_draft_stops_the_run(self):
        for bad in ({"rule_id": "x"}, "text", dict(draft(), observed_value="x"), dict(draft(), marker="<!-- usage-triage:other -->")):
            code = uft.main(stdin=io.StringIO(json.dumps({"ticket_drafts": [bad]})), out=io.StringIO(), gql=FakeLinear())
            self.assertEqual(code, 1)

    def test_missing_team_or_project_fails(self):
        for linear in (FakeLinear(team=False), FakeLinear(project=False)):
            code = uft.main(stdin=io.StringIO(json.dumps({"ticket_drafts": [draft()]})), out=io.StringIO(), gql=linear)
            self.assertEqual(code, 1)
            self.assertEqual(linear.issues, [])


class Failures(unittest.TestCase):
    def main_with(self, text, env_key=KEY):
        old = os.environ.get("LINEAR_API_KEY")
        if env_key:
            os.environ["LINEAR_API_KEY"] = env_key
        else:
            os.environ.pop("LINEAR_API_KEY", None)
        try:
            return uft.main(stdin=io.StringIO(text))
        finally:
            os.environ.pop("LINEAR_API_KEY", None)
            if old is not None:
                os.environ["LINEAR_API_KEY"] = old

    def test_not_json_and_no_list_and_no_key(self):
        self.assertEqual(self.main_with("not json"), 1)
        self.assertEqual(self.main_with("{}"), 1)
        self.assertEqual(self.main_with('{"ticket_drafts": []}', env_key=""), 1)

    def test_empty_report_with_a_key_exits_0_without_a_request(self):
        self.assertEqual(self.main_with('{"ticket_drafts": []}'), 0)

    def test_transport_errors_never_hold_the_key(self):
        def http_error(req, timeout):
            raise urllib.error.HTTPError(req.full_url, 401, KEY, {}, None)

        def url_error(req, timeout):
            raise urllib.error.URLError(KEY)

        for opener in (http_error, url_error):
            gql = uft.linear_transport(KEY, opener=opener)
            with self.assertRaises(uft.FilingError) as ctx:
                gql("query Find { x }", {})
            self.assertNotIn(KEY, str(ctx.exception))

    def test_graphql_errors_are_refusals_without_the_text(self):
        body = json.dumps({"errors": [{"message": KEY}]}).encode()
        gql = uft.linear_transport(KEY, opener=lambda req, timeout: Resp(body))
        with self.assertRaises(uft.FilingError) as ctx:
            gql("query Find { x }", {})
        self.assertNotIn(KEY, str(ctx.exception))

    def test_request_carries_the_key_only_in_the_header(self):
        seen = {}

        def opener(req, timeout):
            seen["auth"] = req.get_header("Authorization")
            seen["body"] = req.data.decode()
            return Resp()

        self.assertEqual(uft.linear_transport(KEY, opener=opener)("query Find { x }", {}), {"ok": 1})
        self.assertEqual(seen["auth"], KEY)
        self.assertNotIn(KEY, seen["body"])


class Contract(unittest.TestCase):
    def test_accepts_what_usage_triage_produces(self):
        spec = importlib.util.spec_from_file_location("usage_triage", os.path.join(HERE, "usage-triage.py"))
        ut = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ut)
        result = {"id": "pinch_success_low", "description": "Pinch success is low", "metric": "m", "comparator": "<",
                  "threshold": 0.5, "min_installs": 5, "min_events": 30, "investigation": "look", "detail": "overall: 0.3",
                  "installs": 6, "events": 120, "versions": [], "value": 0.3, "status": "FIRING"}
        drafts = ut.ticket_drafts([result], set())
        linear = FakeLinear()
        self.assertEqual(run(drafts, linear), (0, "filed pinch_success_low\n"))
        self.assertEqual(run(drafts, linear)[1], "unchanged pinch_success_low\n")


if __name__ == "__main__":
    unittest.main()
