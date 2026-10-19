"""Tests for scripts/usage-triage.py. No network: PostHog is not contacted.
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


if __name__ == "__main__":
    unittest.main()
