"""Tests for scripts/usage-triage.py. No network: PostHog and gh are replaced.
Run: python3 -I -m unittest scripts/test_usage_triage.py   (from the repository root)"""
import importlib.util
import json
import os
import unittest

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


class FakeGh:
    def __init__(self, issues=None, labels=("bug",)):
        self.calls, self.issues, self.labels = [], issues or {}, labels
        self.bodies = []

    def __call__(self, args, input_text=None):
        self.calls.append(args)
        if args[:2] == ["repo", "view"]:
            return "owner/repo\n"
        if args[:2] == ["label", "list"]:
            return json.dumps([{"name": n} for n in self.labels])
        if args[:2] == ["issue", "list"]:
            return json.dumps([{"number": n, "body": b} for n, b in self.issues.items()])
        if args[:2] == ["issue", "view"]:
            return self.issues[int(args[2])]
        if args[:2] in (["issue", "create"], ["issue", "comment"]):
            path = args[args.index("--body-file") + 1]
            with open(path) as f:
                self.bodies.append(f.read())
            return "https://example.invalid/issues/1\n"
        raise AssertionError(args)


class Filing(unittest.TestCase):
    def firing(self):
        rows = crowd("1.0.0", 6, 10, 3)
        report = ut.analyse(rows, rules(), 14)
        ids = {r[1] for r in rows}
        return [r for r in report["rules"] if r["status"] == "FIRING"], ids

    def test_dry_run_files_nothing(self):
        res, ids = self.firing()
        gh = FakeGh()
        out = []
        ut.file_issues(res, ids, False, gh=gh, log=out.append)
        self.assertFalse([c for c in gh.calls if c[:2] in (["issue", "create"], ["issue", "comment"])])
        self.assertTrue(any("would create" in l for l in out))

    def test_creates_with_marker_label_and_no_ids(self):
        res, ids = self.firing()
        gh = FakeGh()
        ut.file_issues(res, ids, True, gh=gh, log=lambda s: None)
        create = next(c for c in gh.calls if c[:2] == ["issue", "create"])
        self.assertIn("--body-file", create)
        self.assertEqual(create[create.index("--label") + 1], "bug")
        self.assertTrue(create[create.index("--title") + 1].startswith("Usage report: "))
        body = gh.bodies[0]
        self.assertIn("<!-- usage-triage:pinch_success_low -->", body)
        self.assertIn(ut.FOOTER, body)
        for body in gh.bodies:
            for i in ids:
                self.assertNotIn(i, body)
        self.assertFalse(any(len(a) > 400 for c in gh.calls for a in c))

    def test_refuses_body_with_install_id(self):
        res, ids = self.firing()
        res[0]["detail"] = "leak %s" % next(iter(ids))
        with self.assertRaises(ut.HardError):
            ut.file_issues(res, ids, True, gh=FakeGh(), log=lambda s: None)

    def test_existing_issue_unchanged_gets_no_comment(self):
        res, ids = self.firing()
        gh = FakeGh({7: ut.issue_body(res[0])})
        ut.file_issues(res[:1], ids, True, gh=gh, log=lambda s: None)
        self.assertFalse([c for c in gh.calls if c[:2] in (["issue", "create"], ["issue", "comment"])])

    def test_existing_issue_material_change_comments(self):
        res, ids = self.firing()
        old = dict(res[0], value=res[0]["value"] * 2)
        gh = FakeGh({7: ut.issue_body(old)})
        ut.file_issues(res[:1], ids, True, gh=gh, log=lambda s: None)
        self.assertTrue([c for c in gh.calls if c[:2] == ["issue", "comment"]])
        self.assertFalse([c for c in gh.calls if c[:2] == ["issue", "create"]])

    def test_marker_must_match_exactly(self):
        res, ids = self.firing()
        other = ut.issue_body(dict(res[0], id="pinch_success_low_extra"))
        gh = FakeGh({7: other})
        ut.file_issues(res[:1], ids, True, gh=gh, log=lambda s: None)
        self.assertTrue([c for c in gh.calls if c[:2] == ["issue", "create"]])

    def test_missing_bug_label_is_skipped(self):
        res, ids = self.firing()
        gh = FakeGh(labels=())
        ut.file_issues(res[:1], ids, True, gh=gh, log=lambda s: None)
        create = next(c for c in gh.calls if c[:2] == ["issue", "create"])
        self.assertNotIn("--label", create)


if __name__ == "__main__":
    unittest.main()
