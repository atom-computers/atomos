Title: Feedback Theme Specification
Slug: Feedback Theme Specification

# Overview

A feedback theme defines the kind of feedback that events (as
described in the [Event naming spec][]) will trigger.

The feedback daemon is responsible to select an appropriate feedback
theme for a given device.

# Definitions

- Feedback: A feedback is something that notifies the user that
  s.th. happened (e.g. a played sound, the vibration of a haptic
  motor or led blinking).

- Feedback theme: A feedback theme is a set of feedbacks grouped by
  profiles. Each feedback is mapped to a single event.

- Feedback Profile: A feedback profile groups feedbacks by
  "noisiness". The currently defined profiles names are
  *full*, *quiet* and *silent*. With *full* being the noisiest
  profile.

- Event: What the user should be notified about. The event
  names are built according to the [Event naming spec][].

# Implementation

When an application requests feedback for an event via the feedback daemon
the daemon selects the provided feedback like this,
capping the noisiness for each limit:

1. The currently selected profile provides the (global) upper limit for noisiness

1. Per application settings impose another upper limit

1. Per event noisiness is the last noisiness constraint

1. All feedback consistent with the resulting limit are selected
   and run to provide the feedback to the user

With the above a feedback theme in YAML format could look like:

```yaml
full:
    - event-name: phone-incoming-call
      type: Sound
      effect: phone-incoming-call
    - event-name: message-new-sms
    ...
quiet:
    - event-name: phone-incoming-call
      type: Vibra
      duration: 0.5s
    - event-name: message-new-sms
    ...
silent:
    - event-name: phone-incoming-call
      type: Led
      location: Front
      Color: Green
      Interval: 0.2s
    - event-name: message-new-sms
    ...
```

At the time of writing the theme format is daemon dependent. E.g. feedbackd
uses a format [similar to the above in JSON](https://gitlab.freedesktop.org/feedbackd/feedbackd/-/blob/main/data/default.json)

# Recommendations

- The silent theme should not produce any audible feedback. This includes
  the buzzing of haptic motors.
- The quiet theme should not play any sounds. Haptic motors and LEDs can
  be used.
- The full feedback theme can use any available feedback mechanisms

[Event naming spec]: https://gitlab.freedesktop.org/feedbackd/feedbackd/-/blob/main/doc/Event-naming-spec-0.0.0.md
