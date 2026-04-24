#!/usr/bin/python3

import gi

gi.require_version("Gm", "0")
from gi.repository import Gm

Gm.init()

dt = "oneplus,fajita"
device_info = Gm.DeviceInfo(compatibles=[dt])
panel = device_info.get_display_panel()
width = panel.get_width()
height = panel.get_height()

radii = panel.get_corner_radii()

print(f"{dt}: {width}x{height}, corner radii: {radii}")
