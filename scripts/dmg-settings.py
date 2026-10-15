# dmgbuild settings for the installer window (https://github.com/dmgbuild/dmgbuild, MIT, pinned in scripts/release.sh).
# Called as: dmgbuild -s scripts/dmg-settings.py -D app=<path to Ensemble.app> "<volume name>" <dmg path>
# The background is drawn by scripts/make-dmg-background.swift; the icon positions below match its trail.
import os.path

application = defines.get("app", "build/Ensemble.app")  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(application)

format = "ULMO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon_locations = {appname: (170, 205), "Applications": (470, 205)}

background = "Assets/dmg-background.png"
window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
arrange_by = None
