"""Tests for scripts/usage-triage.py. No network: PostHog is not contacted.
Run: python3 -I -m unittest scripts/test_usage_triage.py   (from the repository root)"""
import contextlib
import datetime
import importlib.util
import io
import json
import os
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("usage_triage", os.path.join(HERE, "usage-triage.py"))
ut = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ut)

KNOWN = {"active_minutes": 0, "app_version": "0.0.0-livecheck", "gesture_pinch_attempted": 1,
         "gesture_pinch_succeeded": 1, "gesture_thumbs_up_attempted": 1, "launches": 1, "macos_version": "26.0",
         "schema_version": 1}


def event(version="1.0.0", install="id-a", day="2026-10-10", **counts):
    p = {"app_version": version, "macos_version": "26.0", "schema_version": 1, "launches": 1, "active_minutes": 60,
         "$process_person_profile": False, "$geoip_disable": True}
    p.update(counts)
    p["chk"] = ut.checksum(p)
    return [p, install, day + "T12:00:00Z"]


def rules():
    return ut.load_rules(os.path.join(HERE, "usage-thresholds.json"))


def crowd(version, installs, attempted, succeeded, **extra):
    return [event(version, "%s-%d" % (version, i), "2026-10-%02d" % (1 + d), gesture_pinch_attempted=attempted,
                  gesture_pinch_succeeded=succeeded, **extra) for i in range(installs) for d in range(2)]


def status(report, rule_id):
    return next(r for r in report["rules"] if r["id"] == rule_id)


class Checksum(unittest.TestCase):
    def test_known_payload(self):
        self.assertEqual(ut.checksum(KNOWN), "60a17330")

    def test_ignores_chk_and_dollar_names(self):
        p = dict(KNOWN, chk="zzzz", **{"$geoip_disable": True, "$process_person_profile": False})
        self.assertEqual(ut.checksum(p), "60a17330")

    def test_flag_prints_as_word(self):
        # A boolean property that is not a $ name must print true/false, as the Swift side does.
        self.assertNotEqual(ut.checksum(dict(KNOWN, x=True)), ut.checksum(dict(KNOWN, x=1)))


class Discards(unittest.TestCase):
    def reasons(self, rows):
        return ut.load_events(rows)[1]

    def test_good_event_kept(self):
        valid, discarded, _ = ut.load_events([event()])
        self.assertEqual(len(valid), 1)
        self.assertEqual(sum(discarded.values()), 0)

    def test_bad_checksum(self):
        row = event()
        row[0]["launches"] = 2
        self.assertIn("checksum does not match", self.reasons([row]))

    def test_unknown_schema(self):
        p = {"app_version": "1.0.0", "macos_version": "26.0", "schema_version": 2}
        p["chk"] = ut.checksum(p)
        self.assertIn("unknown schema_version", self.reasons([[p, "x", "2026-10-10T12:00:00Z"]]))

    def test_livecheck_and_zero_versions(self):
        for v in ("0.0.0-livecheck", "0.0.0", "1.0.0-test"):
            self.assertIn("test or livecheck app_version", self.reasons([event(v)]), v)

    def test_not_a_version(self):
        self.assertIn("app_version is not a plain version", self.reasons([event("hello world")]))

    def test_bounds(self):
        for k, v in (("active_minutes", 1441), ("gesture_pinch_attempted", 100001), ("launches", -1)):
            self.assertIn("a count is out of bounds", self.reasons([event(**{k: v})]), k)

    def test_succeeded_over_attempted(self):
        self.assertIn("succeeded exceeds attempted",
                      self.reasons([event(gesture_pinch_attempted=1, gesture_pinch_succeeded=2)]))

    def test_unknown_property_and_float(self):
        self.assertIn("property not on the allowlist", self.reasons([event(extra_thing=1)]))
        self.assertIn("a count is out of bounds", self.reasons([event(launches=1.5)]))

    def test_duplicate_install_day(self):
        _, discarded, _ = ut.load_events([event(), event()])
        self.assertEqual(discarded["second event for one install and day"], 1)

    def test_properties_as_json_string(self):
        row = event()
        row[0] = json.dumps(row[0])
        self.assertEqual(len(ut.load_events([row])[0]), 1)


class Rules(unittest.TestCase):
    def test_few_installs_never_fire(self):
        report = ut.analyse(crowd("1.0.0", 4, 50, 1), rules(), 14)
        self.assertEqual(status(report, "pinch_success_low")["status"], "not enough data")
        self.assertFalse([r for r in report["rules"] if r["status"] == "FIRING"])

    def test_few_events_never_fire(self):
        report = ut.analyse(crowd("1.0.0", 6, 1, 0), rules(), 14)  # 12 attempts only
        self.assertEqual(status(report, "pinch_success_low")["status"], "not enough data")

    def test_fires_with_enough_data(self):
        report = ut.analyse(crowd("1.0.0", 6, 10, 3), rules(), 14)
        r = status(report, "pinch_success_low")
        self.assertEqual(r["status"], "FIRING")
        self.assertEqual(r["installs"], 6)
        self.assertEqual(r["events"], 120)

    def test_ok_when_good(self):
        report = ut.analyse(crowd("1.0.0", 6, 10, 9), rules(), 14)
        self.assertEqual(status(report, "pinch_success_low")["status"], "ok")

    def test_crash_loop_per_version(self):
        evs = [event("1.1.0", "i-%d" % i, "2026-10-%02d" % (1 + d), launches=9) for i in range(6) for d in range(6)]
        r = status(ut.analyse(evs, rules(), 14), "launches_crash_loop")
        self.assertEqual(r["status"], "FIRING")
        self.assertEqual(r["versions"], ["1.1.0"])

    def test_regression(self):
        rows = crowd("1.0.0", 6, 10, 9) + crowd("1.1.0", 6, 10, 5)
        r = status(ut.analyse(rows, rules(), 14), "pinch_regression")
        self.assertEqual(r["status"], "FIRING")
        self.assertEqual(r["versions"], ["1.0.0", "1.1.0"])

    def test_regression_needs_two_versions(self):
        r = status(ut.analyse(crowd("1.0.0", 6, 10, 9), rules(), 14), "pinch_regression")
        self.assertEqual(r["status"], "not enough data")

    def test_refusal_share_uses_thumbs_up_attempts(self):
        rows = [event("1.0.0", "i-%d" % i, "2026-10-%02d" % (1 + d), gesture_thumbs_up_attempted=10,
                      gesture_thumbs_up_succeeded=5, sends_refused_claude_not_ready=5)
                for i in range(6) for d in range(2)]
        r = status(ut.analyse(rows, rules(), 14), "refused_claude_not_ready_high")
        self.assertEqual(r["status"], "FIRING")
        self.assertAlmostEqual(r["value"], 0.5)

    def test_every_rule_has_minimums_and_text(self):
        for r in rules():
            self.assertGreaterEqual(r["min_installs"], 5)
            self.assertGreaterEqual(r["min_events"], 30)
            self.assertTrue(r["investigation"] and r["description"])

    def test_empty_data(self):
        report = ut.analyse([], rules(), 14)
        self.assertEqual({r["status"] for r in report["rules"]}, {"not enough data"})
        self.assertIn("Small sample", ut.render(report))


class Drafts(unittest.TestCase):
    def firing(self):
        rows = crowd("1.0.0", 6, 10, 3)
        report = ut.analyse(rows, rules(), 14)
        return report, {r[1] for r in rows}

    def test_one_draft_per_firing_rule_with_contract_fields(self):
        report, ids = self.firing()
        drafts = ut.ticket_drafts(report["rules"], ids)
        firing = [r for r in report["rules"] if r["status"] == "FIRING"]
        self.assertEqual([d["rule_id"] for d in drafts], [r["id"] for r in firing])
        d = next(d for d in drafts if d["rule_id"] == "pinch_success_low")
        self.assertEqual(set(d), {"rule_id", "marker", "title", "body_markdown", "observed_value",
                                  "affected_versions"})
        self.assertEqual(d["marker"], "<!-- usage-triage:pinch_success_low -->")
        self.assertTrue(d["title"].startswith("Usage report: "))
        self.assertIn(d["marker"], d["body_markdown"])
        self.assertIn("6 installs, 120 events", d["body_markdown"])
        self.assertIn("Suggested investigation:", d["body_markdown"])
        self.assertIn("Threshold:", d["body_markdown"])
        self.assertIn("Versions affected:", d["body_markdown"])
        self.assertTrue(d["body_markdown"].rstrip().endswith(ut.FOOTER))
        self.assertAlmostEqual(d["observed_value"], 0.3)

    def test_no_drafts_when_nothing_fires(self):
        rows = crowd("1.0.0", 6, 10, 9)
        report = ut.analyse(rows, rules(), 14)
        self.assertEqual(ut.ticket_drafts(report["rules"], {r[1] for r in rows}), [])

    def test_drafts_never_hold_an_install_id(self):
        report, ids = self.firing()
        for d in ut.ticket_drafts(report["rules"], ids):
            for i in ids:
                self.assertNotIn(i, json.dumps(d))

    def test_refuses_body_with_install_id(self):
        report, ids = self.firing()
        firing = [r for r in report["rules"] if r["status"] == "FIRING"]
        firing[0]["detail"] = "leak %s" % next(iter(ids))
        with self.assertRaises(ut.HardError):
            ut.ticket_drafts(firing, ids)

    def test_affected_versions_listed(self):
        rows = crowd("1.0.0", 6, 10, 9) + crowd("1.1.0", 6, 10, 5)
        report = ut.analyse(rows, rules(), 14)
        d = next(d for d in ut.ticket_drafts(report["rules"], {r[1] for r in rows})
                 if d["rule_id"] == "pinch_regression")
        self.assertEqual(d["affected_versions"], ["1.0.0", "1.1.0"])
        self.assertIn("1.0.0, 1.1.0", d["body_markdown"])


TODAY = datetime.date(2026, 11, 4)
_fspec = importlib.util.spec_from_file_location("usage_file_tickets", os.path.join(HERE, "usage-file-tickets.py"))
uf = importlib.util.module_from_spec(_fspec)
_fspec.loader.exec_module(uf)


def ago(n, install="feed-i-1", **counts):
    return event("1.0.0", install, (TODAY - datetime.timedelta(days=n)).isoformat(), **counts)


def bad(n):
    row = ago(n, "feed-i-bad")
    row[0]["launches"] = 2  # the checksum no longer matches, so the row is discarded
    return row


def drafts_for(rows):
    report = ut.analyse(rows, rules(), 14, today=TODAY, lookback=60)
    ids = {r[1] for r in rows}
    return report, ut.feed_alert_drafts(report["feed"], ids), ids


class FeedAlerts(unittest.TestCase):
    def test_no_rows_for_3_days_fires_stale_only(self):
        report, drafts, _ = drafts_for([ago(30)])
        self.assertEqual([d["rule_id"] for d in drafts], ["usage_feed_stale"])
        self.assertEqual(drafts[0]["observed_value"], 30)
        self.assertEqual(report["feed"]["days_since_last_kept"], 30)

    def test_only_discarded_rows_for_3_days_fires_kept_zero_only(self):
        _, drafts, _ = drafts_for([ago(30), bad(2), bad(1)])
        self.assertEqual([d["rule_id"] for d in drafts], ["usage_kept_zero"])
        self.assertEqual(drafts[0]["observed_value"], 1)

    def test_one_kept_event_yesterday_fires_neither(self):
        self.assertEqual(drafts_for([ago(30), ago(1)])[1], [])

    def test_never_had_a_kept_event_fires_neither(self):
        report, drafts, _ = drafts_for([bad(1), bad(10)])
        self.assertEqual(drafts, [])
        self.assertIsNone(report["feed"]["days_since_last_kept"])
        self.assertEqual(drafts_for([])[1], [])

    def test_row_limit_fires_neither_and_the_summary_says_so(self):
        with mock.patch.object(ut, "ROW_LIMIT", 2):
            report, drafts, _ = drafts_for([ago(30), ago(31)])
        self.assertTrue(report["feed"]["row_limit_reached"])
        self.assertEqual(drafts, [])
        self.assertIn("row limit reached, older rows are missing", report["summary_line"])

    def test_two_days_without_a_kept_event_is_not_stale(self):
        self.assertEqual(drafts_for([ago(30), ago(2)])[1], [])

    def test_read_query_orders_newest_first_and_rows_come_back_oldest_first(self):
        seen = {}

        class Resp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return json.dumps({"results": [["new"], ["old"]]}).encode()

        def opener(req, timeout):
            seen["query"] = json.loads(req.data)["query"]["query"]
            return Resp()

        rows = ut.fetch_rows("k", "1", 60, opener=opener)
        self.assertIn("order by timestamp desc limit", seen["query"])
        self.assertIn("interval 60 day", seen["query"])
        self.assertEqual(rows, [["old"], ["new"]])

    def test_report_numbers_for_14_days_do_not_depend_on_the_longer_read(self):
        recent = [ago(n, "feed-i-%d" % (n % 3)) for n in range(0, 12)] + [bad(3)]
        older = [ago(n, "feed-i-old") for n in range(20, 50)]
        narrow = ut.analyse(recent, rules(), 14, today=TODAY)
        wide = ut.analyse(older + recent, rules(), 14, today=TODAY, lookback=60)
        for report in (narrow, wide):
            del report["feed"], report["summary_line"]
        self.assertEqual(narrow, wide)

    def test_summary_line_and_drafts_hold_no_install_id(self):
        report, drafts, ids = drafts_for([ago(30), bad(1)])
        for text in [report["summary_line"], json.dumps(drafts), ut.render(report)]:
            for i in ids:
                self.assertNotIn(i, text)

    def test_alert_refuses_a_body_with_an_install_id(self):
        with self.assertRaises(ut.HardError):
            ut.alert_draft("usage_feed_stale", "t", "leak feed-i-1", 3, "x", {"feed-i-1"})

    def test_summary_line_without_any_report(self):
        report = ut.analyse([], rules(), 14, today=TODAY, lookback=60)
        self.assertIn("last kept report none in the look-back, installs 0, events kept 0, discarded 0, "
                      "rules with enough data 0 of %d" % len(rules()), report["summary_line"])


class KeyAlert(unittest.TestCase):
    ERR = "[2026-11-04T08:00:00Z] error: could not read the PostHog read key from 1Password\n"
    OK = "[2026-11-04T10:00:00Z] usage feed: last kept report 1 days ago, installs 1\n"

    def test_two_in_a_row_gives_a_draft(self):
        d = ut.key_alert_from_log(self.OK + self.ERR + self.ERR)
        self.assertEqual(d["rule_id"], "usage_key_unreadable")
        self.assertEqual(d["observed_value"], 2)
        self.assertIn("the PostHog read key", d["title"])
        self.assertIn(d["marker"], d["body_markdown"])

    def test_one_error_or_a_success_between_gives_none(self):
        self.assertIsNone(ut.key_alert_from_log(self.OK + self.ERR))
        self.assertIsNone(ut.key_alert_from_log(self.ERR + self.OK + self.ERR))
        self.assertIsNone(ut.key_alert_from_log(""))

    def test_different_keys_do_not_count_as_a_repeat(self):
        other = self.ERR.replace("PostHog read key", "Linear key")
        self.assertIsNone(ut.key_alert_from_log(self.ERR + other))

    def test_mode_prints_one_draft_and_needs_no_key(self):
        path = os.path.join(tempfile.mkdtemp(), "monitor.log")
        with open(path, "w") as f:
            f.write(self.ERR + self.ERR)
        out = io.StringIO()
        with mock.patch.dict(os.environ, {}, clear=True), contextlib.redirect_stdout(out):
            self.assertEqual(ut.main(["--key-alert-from-log", path]), 0)
        self.assertEqual([d["rule_id"] for d in json.loads(out.getvalue())["ticket_drafts"]], ["usage_key_unreadable"])

    def test_mode_prints_nothing_after_one_error(self):
        path = os.path.join(tempfile.mkdtemp(), "monitor.log")
        with open(path, "w") as f:
            f.write(self.ERR)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(ut.main(["--key-alert-from-log", path]), 0)
        self.assertEqual(out.getvalue(), "")


class FakeLinear:
    def __init__(self):
        self.issues = []

    def __call__(self, query, variables):
        if query == uf.FIND:
            return {"issues": {"nodes": [dict(i, comments={"nodes": []}) for i in self.issues
                                         if variables["marker"] in i["description"]]}}
        if query == uf.TEAM:
            return {"teams": {"nodes": [{"id": "team-1"}]}}
        if query == uf.PROJECT:
            return {"projects": {"nodes": [{"id": "project-1"}]}}
        if query == uf.CREATE:
            self.issues.append({"id": "issue-%d" % len(self.issues), "description": variables["input"]["description"]})
            return {"issueCreate": {"success": True}}
        raise AssertionError("unexpected call: a repeat run must not comment")


class Filing(unittest.TestCase):
    def test_a_repeat_run_files_no_second_ticket(self):
        _, drafts, _ = drafts_for([ago(30)])
        linear = FakeLinear()
        first, second = io.StringIO(), io.StringIO()
        self.assertEqual(uf.run({"ticket_drafts": drafts}, linear, first), 0)
        self.assertEqual(uf.run({"ticket_drafts": drafts}, linear, second), 0)
        self.assertEqual(first.getvalue(), "filed usage_feed_stale\n")
        self.assertEqual(second.getvalue(), "unchanged usage_feed_stale\n")
        self.assertEqual(len(linear.issues), 1)
        self.assertIn(drafts[0]["marker"], linear.issues[0]["description"])

    def test_the_summary_line_is_logged_even_with_nothing_to_file(self):
        report = ut.analyse([ago(1)], rules(), 14, today=TODAY, lookback=60)
        out = io.StringIO()
        self.assertEqual(uf.run(dict(report, ticket_drafts=[]), FakeLinear(), out), 0)
        self.assertEqual(out.getvalue().splitlines()[0], report["summary_line"])


class TelemetryPage(unittest.TestCase):
    def test_retention_and_deletion_headings_exist(self):
        path = os.path.join(HERE, "..", "docs", "telemetry.md")
        with open(path, encoding="utf-8") as f:
            headings = {line.strip() for line in f if line.startswith("#")}
        for heading in ("## Retention period", "## Deletion requests"):
            self.assertIn(heading, headings)


if __name__ == "__main__":
    unittest.main()
