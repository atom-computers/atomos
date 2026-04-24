.. _feedbackd(8):

=========
feedbackd
=========

--------------------------------------
A daemon to provide feedback on events
--------------------------------------

SYNOPSIS
--------
|   **feedbackd** [OPTIONS...]


DESCRIPTION
===========

``Feedbackd`` is a daemon that runs in the users session to trigger
event feedback such as playing a sound, trigger a haptic motor or blink
a LED.

The feedback triggered by a given event is determined by the feedback theme in
use (see `feedback-themes(5)`). Events are submitted via a DBus API.

Any feedback triggered by a client via an event will be stopped latest when the
client disconnects from DBus. This makes sure all feedbacks get canceled if the
app that triggered it crashes.

For details refer to the event and feedback theme specs at
`<https://gitlab.freedesktop.org/feedbackd/feedbackd/>`__.

Feedbackd reloads the feedback theme on `SIGHUP` (i.e. `pkill -HUP feedbackd`).

Options
=======

``-h``, ``--help``
   print help and exit

``-v``, ``--verbose``
   print verbose  information

``-r``, ``--replace``
   replace a running instance

``--version``
   print version and exit

Configuration
=============

These gsettings are used by ``feedbackd``:

- `org.gnome.desktop.sound`

    - `sound-theme`: The sound theme used for sound events

- `org.sigxcpu.feedbackd`

    - `profile`: The current overall feedback profile. Valid  values are
      `full`, `quiet` and `silent`.
    - `allow-important`: List of apps that can override the global feedback
      level (useful for e.g. allowing the alarm clock to also emit sound when
      device is in silent mode).
    - `prefer-flash`: Prefer camera flash over status LED
    - `theme`: The feedback theme to use. This can be used to override
      the feedback theme picked by feedbackd based on device information.
    - `max-haptic-strength`: Limits th maximum strength used for the
      haptic motor `[0.0, 1.0]`.

- `org.sigxcpu.feedbackd.application`

   - `profile`: Per application profile levels. Valid  values are
      `full`, `quiet` and `silent`.

See also
========

``fbcli(1)`` ``fbd-theme-validate(1)`` ``feedback-themes(5)`` ``gsettings(1)``
