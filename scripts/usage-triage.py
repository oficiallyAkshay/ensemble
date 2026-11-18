#!/usr/bin/env python3
"""Reads the anonymous `daily_summary` events from PostHog Cloud (US), checks them against the rules in
scripts/usage-thresholds.json and prints the findings. It never talks to GitHub or to any ticket system.

Usage:
  POSTHOG_PERSONAL_API_KEY=... POSTHOG_PROJECT_ID=... scripts/usage-triage.py [--days 14] [--json]

The key is a read key (query:read). It comes from the environment only and is never printed or stored. Exit status is 0
unless something is broken (no key, PostHog refused, bad rules file). No event is trusted: the project write key is
public, so every event is checked (schema, checksum, version string, bounds) and the rest is discarded and counted.
Nothing that identifies an install ever goes into a ticket draft. See docs/telemetry.md.

It also reads a 60-day look-back (the rules and the report still use --days) to tell a stale or broken feed from a thin one:
the report holds `feed` and `summary_line`, and up to one feed alert (usage_feed_stale or usage_kept_zero) is drafted
without any minimum of installs. --key-alert-from-log LOGFILE drafts usage_key_unreadable from the monitor's log.

Contract with the caller. Tickets live in Linear. With --json the output holds, next to the report, `ticket_drafts`: one
ready-to-file draft per FIRING rule or alert, each {rule_id, marker, title, body_markdown, observed_value, affected_versions}.
Without --json the text report ends with the same drafts as a dry run. The caller, scripts/usage-file-tickets.py (run by
scripts/usage-monitor.sh), files and dedupes:
  1. Search Linear for the draft's `marker` (the hidden comment `<!-- usage-triage:<rule_id> -->`).
  2. No ticket has it: create one in team Ensemble (key ENS), project "Ensemble: Board", with the draft's title and
     body_markdown.
  3. A ticket has it: add a comment only if observed_value moved by 25 percent or more from the value last recorded
     there, or affected_versions changed; otherwise do nothing.
"""
import argparse
import collections
import datetime
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_THRESHOLDS = os.path.join(HERE, "usage-thresholds.json")
HOST = "https://us.posthog.com"
ROW_LIMIT = 50000
LOOKBACK_DAYS = 60  # only the feed alerts use it; the rules stay on --days
STALE_DAYS = 3
SALT = "ensemble-usage-1"
SCHEMA_VERSION = 1

# Mirrors UsageEvents.swift. A name that is not here is not something the app can send.
GESTURES = ["pinch", "thumbs_up", "scroll", "peace", "scissors"]
REFUSALS = ["not_in_front", "nothing_dictated", "typed_or_clicked", "empty_draft", "claude_not_ready",
            "other_microphone", "busy", "no_face", "camera_covered", "screen_locked", "stop_unconfirmed",
            "turned_off", "other"]
STOPS = ["dead_man", "standing_check", "multiple_faces", "no_face", "camera_covered", "other_microphone",
         "typing_or_click", "input_device_changed", "sleep_or_lock", "claude_quit"]

FIXED_NAMES = {"app_version", "macos_version", "schema_version", "launches", "active_minutes", "focus_moves",
               "camera_width", "camera_height", "camera_fps", "chk"}
COUNT_NAMES = {"launches", "active_minutes", "focus_moves", "camera_width", "camera_height", "camera_fps",
               "schema_version"}
for _g in GESTURES:
    COUNT_NAMES |= {"gesture_%s_attempted" % _g, "gesture_%s_succeeded" % _g}
for _r in REFUSALS:
    COUNT_NAMES.add("sends_refused_%s" % _r)
for _s in STOPS:
    COUNT_NAMES.add("safety_stops_%s" % _s)
ALLOWED_NAMES = FIXED_NAMES | COUNT_NAMES

# Upper bounds for a plausible single day. Anything above is forged or broken.
MAX_BY_NAME = {"active_minutes": 1440, "launches": 1000, "camera_width": 16384, "camera_height": 16384,
               "camera_fps": 1000, "schema_version": SCHEMA_VERSION}
MAX_COUNT = 100000

VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+){1,3}(-[A-Za-z0-9]{1,16})?$")
MACOS_RE = re.compile(r"^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$")
TEST_WORDS = ("livecheck", "test", "debug", "dev", "fake")


class HardError(Exception):
    pass


# ---------------------------------------------------------------- validation

def checksum(props):
    """First 8 hex of SHA-256 over the salt and one `name=value` line per property in name order, leaving out `chk`
    and every `$` name. Ints print as decimal, flags as true/false, text as is (UsageValue.checksumText)."""
    lines = []
    for name in sorted(k for k in props if k != "chk" and not k.startswith("$")):
        v = props[name]
        if isinstance(v, bool):
            text = "true" if v else "false"
        else:
            text = str(v)
        lines.append("%s=%s" % (name, text))
    return hashlib.sha256("\n".join([SALT] + lines).encode("utf-8")).hexdigest()[:8]


def is_count(v):
    return isinstance(v, int) and not isinstance(v, bool)


def discard_reason(props):
    """None when the event is acceptable, else a short reason."""
    if not isinstance(props, dict):
        return "properties are not an object"
    if props.get("schema_version") != SCHEMA_VERSION or not is_count(props.get("schema_version")):
        return "unknown schema_version"
    chk = props.get("chk")
    if not isinstance(chk, str) or chk != checksum(props):
        return "checksum does not match"
    for name, v in props.items():
        if name.startswith("$"):
            continue
        if name not in ALLOWED_NAMES:
            return "property not on the allowlist"
    version = props.get("app_version")
    if not isinstance(version, str) or not VERSION_RE.match(version):
        return "app_version is not a plain version"
    lowered = version.lower()
    if any(w in lowered for w in TEST_WORDS) or all(int(p) == 0 for p in re.findall(r"[0-9]+", version.split("-")[0])):
        return "test or livecheck app_version"
    macos = props.get("macos_version")
    if not isinstance(macos, str) or not MACOS_RE.match(macos):
        return "macos_version is not a plain version"
    for name in COUNT_NAMES:
        if name not in props:
            continue
        v = props[name]
        if not is_count(v) or v < 0 or v > MAX_BY_NAME.get(name, MAX_COUNT):
            return "a count is out of bounds"
    for g in GESTURES:
        if props.get("gesture_%s_succeeded" % g, 0) > props.get("gesture_%s_attempted" % g, 0):
            return "succeeded exceeds attempted"
    return None


def load_events(rows):
    """rows: [properties, distinct_id, timestamp]. Returns (valid, discarded_counter, total_rows)."""
    valid, discarded = [], collections.Counter()
    seen = set()
    today = datetime.date.today()
    for row in rows:
        try:
            props, distinct_id, ts = row[0], row[1], row[2]
        except (TypeError, IndexError):
            discarded["malformed row"] += 1
            continue
        if isinstance(props, str):
            try:
                props = json.loads(props)
            except ValueError:
                discarded["properties are not JSON"] += 1
                continue
        reason = discard_reason(props)
        if reason is None and not (isinstance(distinct_id, str) and distinct_id):
            reason = "missing distinct_id"
        day = None
        if reason is None:
            try:
                day = datetime.date.fromisoformat(str(ts)[:10])
            except ValueError:
                reason = "unreadable timestamp"
        if reason is None and day > today + datetime.timedelta(days=1):
            reason = "timestamp in the future"
        if reason is None and (distinct_id, day) in seen:
            reason = "second event for one install and day"
        if reason is not None:
            discarded[reason] += 1
            continue
        seen.add((distinct_id, day))
        valid.append({"props": props, "id": distinct_id, "day": day})
    return valid, discarded, len(rows)


# ---------------------------------------------------------------- metrics

class Group:
    def __init__(self):
        self.installs = set()
        self.days = 0
        self.active_minutes = 0
        self.launches = 0
        self.attempted = collections.Counter()
        self.succeeded = collections.Counter()
        self.stops = collections.Counter()
        self.refused = collections.Counter()

    def add(self, ev):
        p = ev["props"]
        self.installs.add(ev["id"])
        self.days += 1
        self.active_minutes += p.get("active_minutes", 0)
        self.launches += p.get("launches", 0)
        for g in GESTURES:
            self.attempted[g] += p.get("gesture_%s_attempted" % g, 0)
            self.succeeded[g] += p.get("gesture_%s_succeeded" % g, 0)
        for s in STOPS:
            self.stops[s] += p.get("safety_stops_%s" % s, 0)
        for r in REFUSALS:
            self.refused[r] += p.get("sends_refused_%s" % r, 0)

    @property
    def active_hours(self):
        return self.active_minutes / 60.0


def version_key(v):
    nums = tuple(int(x) for x in re.findall(r"[0-9]+", v.split("-")[0]))
    return nums, v


def build_groups(events):
    overall = Group()
    by_version = collections.defaultdict(Group)
    for ev in events:
        overall.add(ev)
        by_version[ev["props"]["app_version"]].add(ev)
    return overall, dict(sorted(by_version.items(), key=lambda kv: version_key(kv[0])))


def metric_value(group, metric):
    """Returns (value or None, sample size the value is measured over). The sample size is attempts for gesture rates
    and refusal shares, install-days for per-day and per-hour metrics."""
    kind, _, arg = metric.partition(":")
    if kind == "gesture_success_rate":
        n = group.attempted[arg]
        return (group.succeeded[arg] / n if n else None), n
    if kind == "launches_per_install_day":
        return (group.launches / group.days if group.days else None), group.days
    if kind == "safety_stops_per_active_hour":
        h = group.active_hours
        return (group.stops[arg] / h if h > 0 else None), group.days
    if kind == "sends_refused_per_thumbs_up_attempt":
        n = group.attempted["thumbs_up"]
        return (group.refused[arg] / n if n else None), n
    raise HardError("unknown metric %r" % metric)


def distribution(events, fn):
    c = collections.Counter()
    for ev in events:
        c[fn(ev["props"])] += 1
    return c


def camera_format(p):
    if "camera_width" in p and "camera_height" in p:
        return "%dx%d@%d" % (p["camera_width"], p["camera_height"], p.get("camera_fps", 0))
    return "unknown"


# ---------------------------------------------------------------- rules

def load_rules(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise HardError("cannot read thresholds file: %s" % e)
    defaults = data.get("defaults", {})
    rules, ids = [], set()
    for r in data.get("rules", []):
        for key in ("id", "description", "metric", "comparator", "threshold", "investigation"):
            if key not in r:
                raise HardError("rule %r lacks %r" % (r.get("id"), key))
        if r["id"] in ids:
            raise HardError("duplicate rule id %s" % r["id"])
        ids.add(r["id"])
        r = dict(r)
        r["scope"] = r.get("scope", "overall")
        r["min_installs"] = r.get("min_installs", defaults.get("min_installs", 5))
        r["min_events"] = r.get("min_events", defaults.get("min_events", 30))
        r["min_active_hours"] = r.get("min_active_hours", defaults.get("min_active_hours", 10))
        if r["scope"] not in ("overall", "version", "version_regression"):
            raise HardError("rule %s: unknown scope" % r["id"])
        if r["comparator"] not in ("<", "<=", ">", ">=", "drop_greater_than"):
            raise HardError("rule %s: unknown comparator" % r["id"])
        rules.append(r)
    return rules


def compare(value, comparator, threshold):
    return {"<": value < threshold, "<=": value <= threshold, ">": value > threshold,
            ">=": value >= threshold}[comparator]


def enough(rule, group, sample):
    if len(group.installs) < rule["min_installs"] or sample < rule["min_events"]:
        return False
    if rule["metric"].startswith("safety_stops_per_active_hour") and group.active_hours < rule["min_active_hours"]:
        return False
    return True


def evaluate_rule(rule, overall, by_version):
    """Returns a result dict. Nothing in it identifies an install."""
    res = {"id": rule["id"], "description": rule["description"], "metric": rule["metric"], "scope": rule["scope"],
           "comparator": rule["comparator"], "threshold": rule["threshold"], "min_installs": rule["min_installs"],
           "min_events": rule["min_events"], "investigation": rule["investigation"], "status": "ok",
           "value": None, "installs": 0, "events": 0, "versions": [], "detail": ""}
    if rule["scope"] == "version_regression":
        return evaluate_regression(rule, res, by_version)
    groups = [("overall", overall)] if rule["scope"] == "overall" else list(by_version.items())
    eligible = []
    for name, g in groups:
        value, sample = metric_value(g, rule["metric"])
        if value is not None and enough(rule, g, sample):
            eligible.append((name, g, value, sample))
    if not eligible:
        res["status"] = "not enough data"
        best = max((len(g.installs) for _, g in groups), default=0)
        res["detail"] = "needs %d installs and %d events %s; most installs seen there: %d" % (
            rule["min_installs"], rule["min_events"], "in one version" if rule["scope"] == "version" else "overall", best)
        return res
    breaching = [e for e in eligible if compare(e[2], rule["comparator"], rule["threshold"])]
    shown = breaching or eligible
    # The worst one: lowest for "<", highest for ">".
    pick = (min if rule["comparator"].startswith("<") else max)(shown, key=lambda e: e[2])
    res["value"], res["events"], res["installs"] = pick[2], pick[3], len(pick[1].installs)
    if breaching:
        res["status"] = "FIRING"
        res["versions"] = [e[0] for e in breaching if e[0] != "overall"]
        res["installs"] = len(set().union(*[e[1].installs for e in breaching]))
        res["events"] = sum(e[3] for e in breaching)
        res["detail"] = ", ".join("%s: %s" % (e[0], fmt(e[2])) for e in breaching)
    else:
        res["detail"] = ", ".join("%s: %s" % (e[0], fmt(e[2])) for e in eligible)
    return res


def evaluate_regression(rule, res, by_version):
    ok_versions = []
    for name, g in by_version.items():
        value, sample = metric_value(g, rule["metric"])
        if value is not None and enough(rule, g, sample):
            ok_versions.append((name, g, value, sample))
    if len(ok_versions) < 2:
        res["status"] = "not enough data"
        res["detail"] = "needs two versions that each have %d installs and %d events; have %d" % (
            rule["min_installs"], rule["min_events"], len(ok_versions))
        return res
    hits = []
    for prev, cur in zip(ok_versions, ok_versions[1:]):
        drop = prev[2] - cur[2]
        if drop > rule["threshold"]:
            hits.append((prev, cur, drop))
    if not hits:
        res["detail"] = "; ".join("%s: %s" % (v[0], fmt(v[2])) for v in ok_versions)
        return res
    worst = max(hits, key=lambda h: h[2])
    res["status"] = "FIRING"
    res["value"] = worst[2]
    res["versions"] = sorted({h[0][0] for h in hits} | {h[1][0] for h in hits}, key=version_key)
    res["installs"] = len(set().union(*[h[1][1].installs for h in hits]))
    res["events"] = sum(h[1][3] for h in hits)
    res["detail"] = "; ".join("%s -> %s: %s -> %s (drop %s)" % (h[0][0], h[1][0], fmt(h[0][2]), fmt(h[1][2]),
                                                                fmt(h[2])) for h in hits)
    return res


def fmt(v):
    return "%.3f" % v if isinstance(v, float) else str(v)


# ---------------------------------------------------------------- report

def row_day(row):
    """The day a row arrived, kept or not; None when unreadable."""
    try:
        return datetime.date.fromisoformat(str(row[2])[:10])
    except (TypeError, IndexError, ValueError):
        return None


def feed_state(rows, events, today):
    """What the longer look-back shows about the feed itself. Only kept events say the feed has ever worked, because
    the write key is public; rows of any kind say it is still sending."""
    last = max((ev["day"] for ev in events), default=None)
    first_recent = today - datetime.timedelta(days=STALE_DAYS - 1)
    return {"days_since_last_kept": None if last is None else max(0, (today - last).days),
            "kept_events_lookback": len(events),
            "rows_last_3_days": sum(1 for r in rows if (row_day(r) or datetime.date.min) >= first_recent),
            "row_limit_reached": len(rows) >= ROW_LIMIT}


def summary_line(report):
    feed = report["feed"]
    last = feed["days_since_last_kept"]
    return "usage feed: last kept report %s, installs %d, events kept %d, discarded %d, rules with enough data %d of %d%s" % (
        "none in the look-back" if last is None else "%d days ago" % last, report["installs"], report["valid_events"],
        report["discarded_total"], feed["rules_with_data"], len(report["rules"]),
        "; row limit reached, older rows are missing" if feed["row_limit_reached"] else "")


def analyse(rows, rules, days, today=None, lookback=0):
    """The rules and the report use the last `days` days. With `lookback` above `days`, rows holds that longer read and
    the feed alerts use all of it; the report numbers are the same as if only the last `days` days had been read."""
    today = today or datetime.date.today()
    wide, wide_events = rows, None
    if lookback > days:
        cutoff = today - datetime.timedelta(days=days)
        rows = [r for r in wide if row_day(r) is None or row_day(r) >= cutoff]
        wide_events = load_events(wide)[0]
    events, discarded, total = load_events(rows)
    overall, by_version = build_groups(events)
    report = {
        "days": days,
        "rows_read": total,
        "valid_events": len(events),
        "discarded": dict(discarded),
        "discarded_total": sum(discarded.values()),
        "installs": len(overall.installs),
        "install_days": overall.days,
        "active_hours": round(overall.active_hours, 1),
        "versions": {},
        "camera_formats": dict(distribution(events, camera_format).most_common()),
        "app_versions": dict(distribution(events, lambda p: p["app_version"]).most_common()),
        "macos_versions": dict(distribution(events, lambda p: p["macos_version"]).most_common()),
        "overall": group_summary(overall),
        "rules": [evaluate_rule(r, overall, by_version) for r in rules],
    }
    for name, g in by_version.items():
        report["versions"][name] = group_summary(g)
    report["feed"] = feed_state(wide, wide_events if wide_events is not None else events, today)
    report["feed"]["rules_with_data"] = sum(1 for r in report["rules"] if r["status"] != "not enough data")
    report["summary_line"] = summary_line(report)
    return report


def group_summary(g):
    out = {"installs": len(g.installs), "install_days": g.days, "active_hours": round(g.active_hours, 1),
           "launches_per_install_day": round(g.launches / g.days, 2) if g.days else None, "gestures": {},
           "safety_stops_per_active_hour": {}, "sends_refused_per_thumbs_up_attempt": {}}
    for gest in GESTURES:
        a, s = g.attempted[gest], g.succeeded[gest]
        out["gestures"][gest] = {"attempted": a, "succeeded": s, "success_rate": round(s / a, 3) if a else None}
    for s in STOPS:
        if g.stops[s]:
            out["safety_stops_per_active_hour"][s] = {
                "count": g.stops[s], "per_hour": round(g.stops[s] / g.active_hours, 3) if g.active_hours else None}
    n = g.attempted["thumbs_up"]
    for r in REFUSALS:
        if g.refused[r]:
            out["sends_refused_per_thumbs_up_attempt"][r] = {
                "count": g.refused[r], "per_attempt": round(g.refused[r] / n, 3) if n else None}
    return out


def render(report):
    out = []
    w = out.append
    w("# Usage triage")
    w("")
    w("Window: last %d days. Sample size: %d installs, %d install-days, %s active hours." % (
        report["days"], report["installs"], report["install_days"], report["active_hours"]))
    w("")
    w(report["summary_line"])
    w("")
    w("## Counts")
    w("- Events read: %d" % report["rows_read"])
    w("- Used: %d" % report["valid_events"])
    w("- Discarded: %d" % report["discarded_total"])
    for reason, n in sorted(report["discarded"].items(), key=lambda kv: -kv[1]):
        w("  - %s: %d" % (reason, n))
    w("- Installs: %d, install-days: %d" % (report["installs"], report["install_days"]))
    if report["installs"] < 5:
        w("- Small sample: with fewer than 5 installs these numbers describe a few people, not the user base.")
    w("")
    w("## Rules")
    for r in report["rules"]:
        line = "- [%s] %s (%s)" % (r["status"], r["id"], r["description"])
        w(line)
        if r["detail"]:
            w("  - %s" % r["detail"])
        if r["status"] == "FIRING":
            w("  - threshold %s %s; sample: %d installs, %d events%s" % (
                r["comparator"], r["threshold"], r["installs"], r["events"],
                "; versions: " + ", ".join(r["versions"]) if r["versions"] else ""))
    w("")
    w("## Metrics, overall")
    summary_lines(out, report["overall"])
    for v, s in report["versions"].items():
        w("")
        w("## Metrics, version %s" % v)
        summary_lines(out, s)
    w("")
    w("## Distributions (install-days)")
    for title, key in (("App version", "app_versions"), ("macOS version", "macos_versions"),
                       ("Camera format", "camera_formats")):
        w("- %s: %s" % (title, ", ".join("%s %d" % kv for kv in report[key].items()) or "none"))
    return "\n".join(out)


def summary_lines(out, s):
    out.append("- installs %d, install-days %d, active hours %s, launches per install-day %s" % (
        s["installs"], s["install_days"], s["active_hours"], s["launches_per_install_day"]))
    for gest, d in s["gestures"].items():
        rate = "n/a" if d["success_rate"] is None else "%.0f%%" % (d["success_rate"] * 100)
        out.append("  - %s: %d/%d (%s)" % (gest, d["succeeded"], d["attempted"], rate))
    if s["safety_stops_per_active_hour"]:
        out.append("  - safety stops per active hour: " + ", ".join(
            "%s %s (%d)" % (k, v["per_hour"], v["count"]) for k, v in s["safety_stops_per_active_hour"].items()))
    if s["sends_refused_per_thumbs_up_attempt"]:
        out.append("  - sends refused per thumbs-up attempt: " + ", ".join(
            "%s %s (%d)" % (k, v["per_attempt"], v["count"]) for k, v in
            s["sends_refused_per_thumbs_up_attempt"].items()))


# ---------------------------------------------------------------- PostHog

def fetch_rows(key, project_id, days, opener=urllib.request.urlopen):
    query = ("select properties, distinct_id, timestamp from events where event = 'daily_summary' "
             "and timestamp > now() - interval %d day order by timestamp desc limit %d" % (days, ROW_LIMIT))
    body = json.dumps({"query": {"kind": "HogQLQuery", "query": query}, "refresh": "force_blocking"}).encode()
    req = urllib.request.Request(
        "%s/api/projects/%s/query/" % (HOST, project_id), data=body, method="POST",
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                 "User-Agent": "ensemble-usage-triage"})
    try:
        with opener(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise HardError("PostHog answered HTTP %d" % e.code)
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise HardError("PostHog request failed: %s" % type(e).__name__)
    rows = data.get("results")
    if not isinstance(rows, list):
        raise HardError("PostHog answer has no results")
    if len(rows) >= ROW_LIMIT:
        sys.stderr.write("warning: row limit %d reached; older events are missing\n" % ROW_LIMIT)
    # Newest first, so a cut read drops only the oldest rows; back to oldest first for the rest of the script.
    return rows[::-1]


# ---------------------------------------------------------------- ticket drafts

MARKER = "<!-- usage-triage:%s -->"
FOOTER = ("Filed from anonymous daily summaries by the usage triage; "
          "see docs/telemetry.md in the Ensemble repository.")


def draft_body(result):
    versions = ", ".join(result["versions"]) or "all versions together"
    return "\n".join([
        MARKER % result["id"],
        "",
        "Rule: %s" % result["description"],
        "",
        "- Metric: `%s`" % result["metric"],
        "- Observed: %s" % result["detail"],
        "- Threshold: %s %s" % (result["comparator"], result["threshold"]),
        "- Sample size: %d installs, %d events (minimums for this rule: %d installs, %d events)" % (
            result["installs"], result["events"], result["min_installs"], result["min_events"]),
        "- Versions affected: %s" % versions,
        "",
        "Suggested investigation: %s" % result["investigation"],
        "",
        FOOTER,
        "",
    ])


def ticket_drafts(results, distinct_ids):
    """One draft per FIRING rule. Refuses outright if a body holds an install id."""
    drafts = []
    for r in results:
        if r["status"] != "FIRING":
            continue
        body = draft_body(r)
        if any(i in body for i in distinct_ids):
            raise HardError("refusing to draft %s: body contains an install id" % r["id"])
        drafts.append({"rule_id": r["id"], "marker": MARKER % r["id"],
                       "title": "Usage report: %s" % r["description"], "body_markdown": body,
                       "observed_value": r["value"], "affected_versions": list(r["versions"])})
    return drafts


def alert_draft(rule_id, title, observed, value, investigation, distinct_ids):
    """A draft for an alert that is not a threshold rule (no minimum of installs). Same shape as ticket_drafts."""
    body = "\n".join([MARKER % rule_id, "", "Observed: %s" % observed, "",
                      "Suggested investigation: %s" % investigation, "", FOOTER, ""])
    if any(i in body for i in distinct_ids):
        raise HardError("refusing to draft %s: body contains an install id" % rule_id)
    return {"rule_id": rule_id, "marker": MARKER % rule_id, "title": "Usage monitor: %s" % title,
            "body_markdown": body, "observed_value": value, "affected_versions": []}


def feed_alert_drafts(feed, distinct_ids):
    """At most one draft. Both alerts need a kept event in the look-back (so none fires before the first real report),
    none when the row limit cut the read, and no kept event for STALE_DAYS days. They split on whether rows of any kind
    still arrive: none is a stale feed, rows with nothing kept is a feed whose events no longer pass the checks."""
    last = feed["days_since_last_kept"]
    if last is None or last < STALE_DAYS or feed["row_limit_reached"]:
        return []
    if feed["rows_last_3_days"] == 0:
        return [alert_draft(
            "usage_feed_stale", "no usage report for %d days" % last,
            "No row of any kind arrived in the last %d days. The last kept report was %d days ago." % (STALE_DAYS, last),
            last, "Check that the app's usage report still reaches PostHog and that the project key was not rotated or "
            "deleted (docs/telemetry.md).", distinct_ids)]
    return [alert_draft(
        "usage_kept_zero", "usage reports arrive but none passes the checks",
        "Rows arrived in the last %d days, but none was kept. The last kept report was %d days ago; %d were kept "
        "in the look-back." % (STALE_DAYS, last, feed["kept_events_lookback"]),
        feed["kept_events_lookback"], "A schema or checksum change in the app's report, or a changed allowlist, would "
        "do this. Read the discard reasons in the latest report.", distinct_ids)]


KEY_ERROR_RE = re.compile(r"^\[[^\]]*\] error: could not read (the (?:PostHog read key|PostHog project id|Linear key)) "
                          "from 1Password$")


def key_alert_from_log(text):
    """The draft when the log ends with the same key-read error twice in a row, else None. Any other line between
    them (a result of a good run) breaks the run. No network and no key."""
    last = [KEY_ERROR_RE.match(line) for line in [l for l in text.splitlines() if l.strip()][-2:]]
    if len(last) < 2 or not all(last) or last[0].group(1) != last[1].group(1):
        return None
    return alert_draft(
        "usage_key_unreadable", "%s could not be read twice in a row" % last[1].group(1),
        "The usage monitor could not read %s from 1Password on its last two runs, so it could not look at the usage "
        "numbers." % last[1].group(1), 2, "Check that 1Password is unlocked for the monitor and that the item still "
        "exists. The monitor log holds the error lines.", ())


# ---------------------------------------------------------------- main

def main(argv=None):
    ap = argparse.ArgumentParser(description="Find issues worth a ticket in the anonymous usage summaries.")
    ap.add_argument("--days", type=int, default=14, help="how many days back to read (default 14)")
    ap.add_argument("--json", action="store_true", help="machine-readable output, with a ticket draft per firing rule")
    ap.add_argument("--thresholds", default=DEFAULT_THRESHOLDS, help="rules file")
    ap.add_argument("--key-alert-from-log", metavar="LOGFILE",
                    help="no network and no key: print a ticket draft if the log ends with the same key-read error twice")
    args = ap.parse_args(argv)
    try:
        if args.key_alert_from_log:
            try:
                with open(args.key_alert_from_log, encoding="utf-8", errors="replace") as f:
                    draft = key_alert_from_log(f.read())
            except OSError as e:
                raise HardError("cannot read the log: %s" % type(e).__name__)
            if draft:
                print(json.dumps({"ticket_drafts": [draft]}, indent=2, sort_keys=True))
            return 0
        if not 1 <= args.days <= 365:
            raise HardError("--days must be between 1 and 365")
        key = os.environ.get("POSTHOG_PERSONAL_API_KEY", "")
        project = os.environ.get("POSTHOG_PROJECT_ID", "")
        if not key or not project:
            raise HardError("set POSTHOG_PERSONAL_API_KEY and POSTHOG_PROJECT_ID")
        if not re.fullmatch(r"[0-9]+", project):
            raise HardError("POSTHOG_PROJECT_ID must be a number")
        rules = load_rules(args.thresholds)
        look = max(args.days, LOOKBACK_DAYS)
        rows = fetch_rows(key, project, look)
        report = analyse(rows, rules, args.days, lookback=look)
        ids = {r[1] for r in rows if isinstance(r, list) and len(r) > 1 and isinstance(r[1], str)}
        if any(i in report["summary_line"] for i in ids):
            raise HardError("refusing the summary line: it contains an install id")
        drafts = ticket_drafts(report["rules"], ids) + feed_alert_drafts(report["feed"], ids)
        if args.json:
            print(json.dumps(dict(report, ticket_drafts=drafts), indent=2, sort_keys=True))
        else:
            print(render(report))
            print("")
            print("## Ticket drafts (dry run; the caller files them in Linear)")
            if not drafts:
                print("No rule is firing; nothing to file.")
            for d in drafts:
                print("")
                print("### %s" % d["title"])
                print(d["body_markdown"])
    except HardError as e:
        sys.stderr.write("error: %s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
