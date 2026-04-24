.. _fbd-theme-validate(1):

==================
fbd-theme-validate
==================

-------------------------
Validate feedbackd themes
-------------------------

SYNOPSIS
--------
|   **fbd-theme-validate** [OPTIONS...] <FILE>


DESCRIPTION
-----------

``fbd-theme-validate`` parses and validates the given feedbackd theme
file. If the theme specifies parent themes then these are parsed and
validates as well.

OPTIONS
=======

``-h``, ``--help``
   print help and exit

``--version``
   print version information and exit

``--compatible=COMPATIBLE``
  Specify the device compatible to use. Specify this if you validate a user
  theme and want to simulate how it would look like on a device with compatible
  ```COMPATIBLE```.

EXAMPLES
========

Validate a custom theme in the users home directory the same way as it would be
loaded on a Librem 5:

::

    fbd-theme-validate --compatible=purism,librem5 ~/.config/feedbackd/themes/custom.json

Validate the device theme for a OnePlus 6T:

::

    fbd-theme-validate /usr/share/feedbackd/themes/oneplus,fajita.json

See also
========

``feedbackd(8)`` ``fbcli(1)`` ``feedback-themes``
