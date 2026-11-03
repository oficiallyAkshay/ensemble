#!/usr/bin/env python3
"""Files the ticket drafts from `scripts/usage-triage.py --json` in Linear. This is the one script that talks to a
ticket system; usage-triage.py never does.

Usage:
  LINEAR_API_KEY=... scripts/usage-triage.py --json | scripts/usage-file-tickets.py

Per entry in `ticket_drafts` it searches team Ensemble (key ENS) for the hidden marker `<!-- usage-triage:<rule_id> -->`:
  - no ticket has it: creates one in project "Ensemble: Board" ("filed");
  - a ticket has it: adds a comment only if `observed_value` moved by 25 percent or more from the value last recorded
    on that ticket, or `affected_versions` changed ("commented"); otherwise does nothing ("unchanged").
One line per draft is printed. With no draft it prints one summary line and exits 0. A draft whose text looks like an
install id is refused ("refused") and the run exits 1. Any failure of the input or of Linear exits 1 with a message that
never holds the key. The key comes from the environment only and is never printed or stored.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

ENDPOINT = "https://api.linear.app/graphql"
TEAM_KEY = "ENS"
PROJECT_NAME = "Ensemble: Board"
MOVE_FRACTION = 0.25

# What last happened on a ticket is kept in a hidden line on the ticket itself, so no local state file is needed.
STATE_RE = re.compile(r"<!-- usage-triage-state: (\{.*?\}) -->")
RULE_ID_RE = re.compile(r"^[a-z0-9_]+$")
# Install ids are random UUIDs; a long run of hex digits is treated the same way.
INSTALL_ID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{20,}")

FIND = """query Find($team: String!, $marker: String!) {
  issues(first: 1, filter: {team: {key: {eq: $team}}, description: {contains: $marker}}) {
    nodes { id description comments(first: 100) { nodes { body createdAt } } }
  }
}"""
TEAM = """query Team($team: String!) { teams(filter: {key: {eq: $team}}) { nodes { id } } }"""
PROJECT = """query Project($name: String!) { projects(filter: {name: {eq: $name}}) { nodes { id } } }"""
CREATE = """mutation Create($input: IssueCreateInput!) { issueCreate(input: $input) { success } }"""
COMMENT = """mutation Comment($input: CommentCreateInput!) { commentCreate(input: $input) { success } }"""


class FilingError(Exception):
    pass


class Refused(FilingError):
    pass


def linear_transport(key, opener=urllib.request.urlopen):
    """Returns gql(query, variables) -> data. Tests pass their own gql or opener, so no test needs a network."""
    def gql(query, variables):
        req = urllib.request.Request(
            ENDPOINT, data=json.dumps({"query": query, "variables": variables}).encode(), method="POST",
            headers={"Authorization": key, "Content-Type": "application/json", "User-Agent": "ensemble-usage-tickets"})
        try:
            with opener(req, timeout=60) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raise FilingError("Linear answered HTTP %d" % e.code)
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise FilingError("Linear request failed: %s" % type(e).__name__)
        if not isinstance(data, dict) or data.get("errors") or not isinstance(data.get("data"), dict):
            raise FilingError("Linear refused the request")
        return data["data"]
    return gql


def looks_like_install_id(text):
    return bool(INSTALL_ID_RE.search(text))


def state_line(value, versions):
    return "<!-- usage-triage-state: %s -->" % json.dumps({"v": value, "versions": versions}, sort_keys=True)


def last_state(issue):
    """The newest recorded {v, versions}: the latest comment that has one, else the description; None if none."""
    comments = sorted(issue["comments"]["nodes"], key=lambda c: c["createdAt"])
    for text in [c["body"] for c in reversed(comments)] + [issue["description"] or ""]:
        found = STATE_RE.findall(text)
        if found:
            try:
                return json.loads(found[-1])
            except ValueError:
                return None
    return None


def moved(old, new):
    if not isinstance(old, (int, float)) or not isinstance(new, (int, float)):
        return True
    if old == 0:
        return new != 0
    return abs(new - old) >= MOVE_FRACTION * abs(old)


def check_draft(d):
    if not isinstance(d, dict):
        raise FilingError("a draft is not an object")
    for name, kind in (("rule_id", str), ("marker", str), ("title", str), ("body_markdown", str),
                       ("affected_versions", list)):
        if not isinstance(d.get(name), kind):
            raise FilingError("a draft lacks %s" % name)
    if not isinstance(d.get("observed_value"), (int, float)):
        raise FilingError("a draft lacks observed_value")
    if not RULE_ID_RE.match(d["rule_id"]) or d["marker"] != "<!-- usage-triage:%s -->" % d["rule_id"] \
            or d["marker"] not in d["body_markdown"]:
        raise FilingError("a draft has a bad rule_id or marker")


def file_one(d, gql):
    """Returns 'filed', 'commented' or 'unchanged'."""
    check_draft(d)
    state = state_line(d["observed_value"], d["affected_versions"])
    body = d["body_markdown"].rstrip("\n") + "\n\n" + state + "\n"
    if looks_like_install_id(d["title"] + "\n" + body):
        raise Refused("refusing %s: the text looks like an install id" % d["rule_id"])
    nodes = gql(FIND, {"team": TEAM_KEY, "marker": d["marker"]})["issues"]["nodes"]
    if not nodes:
        team = gql(TEAM, {"team": TEAM_KEY})["teams"]["nodes"]
        project = gql(PROJECT, {"name": PROJECT_NAME})["projects"]["nodes"]
        if not team or not project:
            raise FilingError("team %s or project %r not found in Linear" % (TEAM_KEY, PROJECT_NAME))
        gql(CREATE, {"input": {"teamId": team[0]["id"], "projectId": project[0]["id"], "title": d["title"],
                               "description": body}})
        return "filed"
    old = last_state(nodes[0])
    if old is not None and not moved(old.get("v"), d["observed_value"]) \
            and old.get("versions") == d["affected_versions"]:
        return "unchanged"
    text = "Still firing. Observed: %s. Versions affected: %s.\n\n%s\n" % (
        d["observed_value"], ", ".join(d["affected_versions"]) or "all versions together", state)
    gql(COMMENT, {"input": {"issueId": nodes[0]["id"], "body": text}})
    return "commented"


def run(report, gql, out):
    """Returns the exit status."""
    drafts = report.get("ticket_drafts") if isinstance(report, dict) else None
    if not isinstance(drafts, list):
        raise FilingError("the input has no ticket_drafts list")
    if not drafts:
        out.write("no rule is firing; nothing filed\n")
        return 0
    status = 0
    for d in drafts:
        rule = d.get("rule_id") if isinstance(d, dict) and isinstance(d.get("rule_id"), str) else "?"
        try:
            out.write("%s %s\n" % (file_one(d, gql), rule))
        except Refused:
            out.write("refused %s\n" % rule)
            status = 1
    return status


def main(stdin=None, out=None, gql=None):
    stdin = stdin or sys.stdin
    out = out or sys.stdout
    try:
        try:
            report = json.load(stdin)
        except ValueError:
            raise FilingError("the input is not JSON")
        if gql is None:
            key = os.environ.get("LINEAR_API_KEY", "")
            if not key:
                raise FilingError("set LINEAR_API_KEY")
            gql = linear_transport(key)
        return run(report, gql, out)
    except FilingError as e:
        sys.stderr.write("error: %s\n" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
