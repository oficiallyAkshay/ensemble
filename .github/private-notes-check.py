"""The owner's private notes live only in one private repository; this one holds none of their text.

Fails when a file in this checkout holds:
  1. a line in the notes' own form: a bold second-person line that opens with one of
     the verbs in SOUL_LINE;
  2. a copy of one of the notes' section headings;
  3. a copied sentence from the notes, matched only by truncated SHA-256 hashes of
     each sentence's first eight words (HASHES; empty where the repository is public);
  4. code or a command that attaches the notes' ticket label.
The notes' name is built from parts so this file never holds it whole.
Stdlib only; run from the repository root.
"""

import hashlib
import re
import subprocess
import sys

NAME = "pr" + "aan"
SOUL_LINE = re.compile(r"\*\*You (?:judge|do|feel|think|serve|spend|trust|want)\b")
HEADING = re.compile(
    r"^#{1,6}\s+(?:" + NAME + r"\b|Portrait\s*$|.*\bsitting\b.*\bratified\b|Lines from his authored notes)",
    re.IGNORECASE,
)
LABEL = re.compile(
    r"\b(?:[Ll]abels|[Ll]abelNames|[Ll]abelIds|requiredLabels|add[Ll]abels?|[Ll]abel)\s*[:=(]\s*"
    r"(?:\[\s*(?:['\"`][^'\"`\n]*['\"`]\s*,\s*)*)?['\"`]" + NAME + r"['\"`]|--label[= ]['\"]?" + NAME + r"\b"
)
WORDS = 8
HASHES = set()  # empty: this repository is public


def words(text):
    text = text.replace("\\n", " ").lower().replace("’", "").replace("'", "")
    return [w for w in re.sub(r"[^a-z0-9]+", " ", text).split() if w]


def shingle(ws):
    return hashlib.sha256(" ".join(ws).encode()).hexdigest()[:16]


def find(text, hashes=HASHES):
    found = []
    for i, line in enumerate(text.split("\n"), 1):
        if SOUL_LINE.search(line):
            found.append((i, "line in the notes' form"))
        if HEADING.search(line):
            found.append((i, "copied section heading"))
        if LABEL.search(line):
            found.append((i, "notes label attached"))
    ws = words(text)
    if any(shingle(ws[i : i + WORDS]) in hashes for i in range(len(ws) - WORDS + 1)):
        found.append((0, "copied sentence"))
    return found


def self_test():
    b = "**"
    assert find(b + "You judge a thing by what it frees." + b)
    assert not find(b + "You narrate nothing." + b)
    assert find("## Portrait") and find("### First sitting — ratified 2026-08-30")
    assert find('labels: ["ops", "' + NAME + '"]') and find("issue create --label " + NAME)
    assert not find("{ key: 'x', label: 'Monthly sitting' }")
    s = "the quick brown fox keeps every promise it makes"
    h = {shingle(words(s)[:WORDS])}
    assert find("Intro. The Quick brown fox\nkeeps every promise it makes.", h)
    assert not find("the quick brown fox keeps a different promise", h)


def main():
    self_test()
    paths = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=True, capture_output=True,
    ).stdout.decode().split("\0")
    paths = [p for p in paths if p]
    if not paths:
        sys.exit("private-notes-check: git ls-files listed no files; refusing to pass blind")
    bad = []
    for p in paths:
        try:
            with open(p, "rb") as f:
                raw = f.read(4 * 1024 * 1024 + 1)
        except OSError:
            continue
        if len(raw) > 4 * 1024 * 1024 or b"\0" in raw:
            continue
        for line, rule in find(raw.decode("utf-8", "replace")):
            bad.append(f"{p}{':' + str(line) if line else ''} ({rule})")
    if bad:
        print("The owner's private notes never live in this repository:")
        print("\n".join("  " + b for b in bad))
        sys.exit(1)
    print(f"private-notes-check: {len(paths)} paths checked, none found")


if __name__ == "__main__":
    main()
