Title: Overview
Slug: Overview

# Libfeedback Introduction

The purpose of libfeedback is to make it simple to supply audible,
haptic and visual feedback to the user. This is done by
notifying a feedback_daemon over DBus that a certain event
happened. The daemon then selects the appropriate feedbacks (such
as a buzzing haptic motor or playing an audio file) based on the
user session's current feedback profile, feedback theme and
available hardware.

Events are identified by strings like `message-new-sms` or
`message-new-sms`. The available event names are described in the
[Event naming specification](Event-naming-spec-0.0.0.html).

Libfeedback provides synchronous and asynchronous APIs to trigger and
stop feedback for these events and is usable from other languages than
C by GObject introspection.

See [Compiling with libfeedback](build-howto.html) on how to include
libfeedback in your project.
