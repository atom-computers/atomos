#!/usr/bin/python3
#
# depends on GObject introspection data for libfeedback
#
# After building from source you can start this example like this:
#   _build/run examples/example.py
# Otherwise like this:
#   GI_TYPELIB_PATH=</somepath/girepository-x.y/> example.py

import gi
import time
gi.require_version('Lfb', '0.0')
from gi.repository import Lfb

Lfb.init('org.sigxcpu.lfbexample')
event = Lfb.Event.new('phone-incoming-call')
event.trigger_feedback()
# feedbackd terminates feedback from clients that disconnect from DBus to avoid
# feedback not being stopped. So wait a bit before quitting:
time.sleep(3)
