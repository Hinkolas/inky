# The layout of Inky's disk image, for dmgbuild (https://dmgbuild.readthedocs.io).
# The release workflow builds it with:
#
#   dmgbuild -s Scripts/dmg-settings.py -D app=<path to Inky.app> Inky <output.dmg>
#
# A plain window: Inky on the left, the Applications folder on the right, to
# drag it onto.

import os.path

app = defines["app"]  # noqa: F821 (given by dmgbuild)
app_name = os.path.basename(app)

format = "ULFO"  # LZFSE compression; macOS 10.11 and later open it
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

# The disk's own icon in Finder is Inky's.
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

window_rect = ((200, 200), (540, 340))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (140, 150),
    "Applications": (400, 150),
}
