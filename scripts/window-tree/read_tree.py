"""Launches the stand-in app with accessibility on, reads its window tree with xa11y and prints it.

Prints the window titles and the control names it expects, then one RESULT line. Each failure is one
"DIAG:" line, so a log is counted by those lines. Exit code 0 only when the title and at least three
expected control names were read from the tree.

Environment: OUT (output folder, default "out"), SHOT_CMD (shell command that writes the screenshot).
"""
import os
import subprocess
import sys
import time

import xa11y

HERE = os.path.dirname(os.path.abspath(__file__))
TITLE = "Window Tree Stand-In"
EXPECTED = ["Alpha button", "Beta button", "Name field", "Agree box"]
WAIT_SECONDS = 60
MAX_DEPTH = 25


def diag(message):
    print("DIAG: " + message, flush=True)


def launch():
    name = "electron.cmd" if sys.platform == "win32" else "electron"
    exe = os.path.join(HERE, "node_modules", ".bin", name)
    if not os.path.exists(exe):
        diag("electron is not installed at " + exe)
        return None
    args = [exe, HERE, "--force-renderer-accessibility"]
    if sys.platform.startswith("linux"):
        args.append("--no-sandbox")  # the hosted runner's sandbox helper is not set up
    return subprocess.Popen(args)


def walk(element, depth, lines, names):
    if depth > MAX_DEPTH:
        return
    name = element.name
    lines.append("  " * depth + str(element.role) + ": " + (name if name else ""))
    if name:
        names.append(name)
    for child in element.children():
        walk(child, depth + 1, lines, names)


def find_app():
    """The app whose tree holds the stand-in window title, or None. Matching by title avoids guessing which Electron process owns the window."""
    last_error = None
    deadline = time.time() + WAIT_SECONDS
    while time.time() < deadline:
        try:
            apps = xa11y.App.list()
        except Exception as error:  # noqa: BLE001 - any failure here is the result being reported
            last_error = "listing applications failed: " + repr(error)
            apps = []
        for app in apps:
            try:
                if TITLE in app.dump(max_depth=MAX_DEPTH):
                    return app, None
            except Exception as error:  # noqa: BLE001
                last_error = "reading one application failed: " + repr(error)
        time.sleep(2)
    return None, last_error or ("no application tree held the title " + TITLE)


def main():
    out = os.environ.get("OUT", "out")
    os.makedirs(out, exist_ok=True)
    print("platform: " + sys.platform + ", xa11y: " + str(getattr(xa11y, "__version__", "unknown")), flush=True)
    process = launch()
    if process is None:
        print("RESULT: FAIL first failure: stand-in app did not start", flush=True)
        return 1
    failure = None
    try:
        app, error = find_app()
        if app is None:
            failure = error
        else:
            lines, names = [], []
            walk(app, 0, lines, names)
            print("\n".join(lines), flush=True)
            windows = [w.name for w in app.children() if w.name]
            print("WINDOW TITLES: " + repr(windows), flush=True)
            found = [n for n in EXPECTED if n in names]
            print("CONTROL NAMES: " + repr(found), flush=True)
            if TITLE not in windows and TITLE not in names:
                failure = "window title not in the tree"
            elif len(found) < 3:
                failure = "only %d of %d expected control names in the tree" % (len(found), len(EXPECTED))
        shot = os.environ.get("SHOT_CMD")
        if shot:
            if subprocess.run(shot, shell=True).returncode != 0:
                diag("screenshot command failed")
    finally:
        process.terminate()
    if failure:
        diag(failure)
        print("RESULT: FAIL first failure: " + failure, flush=True)
        return 1
    print("RESULT: PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
