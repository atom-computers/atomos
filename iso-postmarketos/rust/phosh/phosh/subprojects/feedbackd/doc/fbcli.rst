.. _fbcli(1):

=====
fbcli
=====

------------------------
Emit events to feedbackd
------------------------

SYNOPSIS
--------
|   **fbcli** [OPTIONS...]


DESCRIPTION
-----------

``fbcli`` can be used to submit events to ``feedbackd`` to trigger
audio, visual or haptic feedback.

OPTIONS
=======

``-h``, ``--help``
   print help and exit

``-E=EVENT``, ``--event=EVENT``
  Submit the given event to ``feedbackd``. Valid events are listes in
  the event naming spec at
  https://gitlab.freedesktop.org/feedbackd/feedbackd/-/blob/main/doc/Event-naming-spec-0.0.0.md

``-I``, ``--important``
  Whether to set the important hint

``-t=TIMEOUT``, ``--timeout=TIMEOUT``
  The timeout in seconds after which feedback for the given event should
  be stopped.

``-P=PROFILE``, ``--profile=PROFILE``
  The feedback profile (``full``, ``quiet``, ``silent``)
  to use for the given event. If no event is specified then the global
  feedback profile is changed.

``-w=TIMEOUT``, ``--watch=TIMEOUT``
  Maximum timeout to wait for the feedback for the given event to end and
  ``fbcli`` to exit.

``-A=APP_ID``, ``--app-id=APP_ID``
  Override the used application id

``-S=SOUND_FILE``, ``--sound-file=SOUND_FILE``
  Override the sound effect used with the given file. This only has an
  effect when a sound event would be triggered by this event at the
  current level.


See also
========

``feedbackd(8)`` ``fbd-theme-validate(1)`` ``feedback-themes(5)``
