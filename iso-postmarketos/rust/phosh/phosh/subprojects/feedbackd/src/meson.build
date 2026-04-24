# Feedback daemon
if get_option('daemon')

  config_h = configuration_data()
  config_h.set_quoted('PACKAGE_VERSION', meson.project_version())
  config_h.set_quoted('PACKAGE_NAME', meson.project_name())
  config_h.set('FBD_USE_MEDIA_ROLES', get_option('media-roles'))
  configure_file(output: 'fbd-config.h', configuration: config_h)

  fbd_enum_headers = files('fbd-event.h', 'fbd-feedback-led.h', 'fbd-feedback-vibra.h')
  fbd_enum_sources = gnome.mkenums_simple('fbd-enums', sources: fbd_enum_headers)

  sources = [
    generated_dbus_sources,
    fbd_enum_sources,
    'fbd-error.c',
    'fbd-dev-vibra.c',
    'fbd-dev-sound.c',
    'fbd-dev-led.c',
    'fbd-dev-led-flash.c',
    'fbd-dev-led-multicolor.c',
    'fbd-dev-led-qcom.c',
    'fbd-dev-led-qcom-multicolor.c',
    'fbd-dev-leds.c',
    'fbd-event.c',
    'fbd-feedback-base.c',
    'fbd-feedback-dummy.c',
    'fbd-feedback-led.c',
    'fbd-feedback-manager.c',
    'fbd-feedback-profile.c',
    'fbd-feedback-sound.c',
    'fbd-feedback-theme.c',
    'fbd-feedback-vibra.c',
    'fbd-feedback-vibra-pattern.c',
    'fbd-feedback-vibra-periodic.c',
    'fbd-feedback-vibra-rumble.c',
    'fbd-haptic-manager.c',
    'fbd-theme-expander.c',
    'fbd-udev.c',
  ]

  fbd_deps = [
    gio,
    gio_unix,
    glib,
    gmobile,
    gobject,
    gsound,
    gudev,
    json_glib,
    cc.find_library('m', required: false),
  ]

  fbd_inc = [include_directories('.'), libfeedback_inc, dbus_inc]

  fbd_lib = static_library(
    'fbd',
    sources,
    include_directories: fbd_inc,
    dependencies: fbd_deps,
    c_args: '-DGMOBILE_USE_UNSTABLE_API',
    install: false,
  )

  fbd_dep = declare_dependency(
    sources: [generated_dbus_sources, fbd_enum_sources],
    include_directories: fbd_inc,
    link_with: fbd_lib,
    dependencies: fbd_deps,
  )

  fbd_exe = executable(
    'feedbackd',
    sources: ['fbd.c', generated_dbus_sources[1]],
    include_directories: fbd_inc,
    dependencies: fbd_dep,
    install: true,
    install_dir: libexecdir,
  )

  executable(
    'fbd-ledctrl',
    sources: ['fbd-ledctrl.c'],
    include_directories: fbd_inc,
    dependencies: [glib],
    install: true,
    install_dir: libexecdir,
  )

  executable(
    'fbd-alert-slider',
    sources: ['fbd-alert-slider.c'],
    include_directories: fbd_inc,
    dependencies: [glib, gio, gio_unix, gudev, libfeedback_dep],
    install: true,
    install_dir: libexecdir,
  )

  executable(
    'fbd-theme-validate',
    sources: ['fbd-theme-validate.c'],
    include_directories: fbd_inc,
    dependencies: fbd_dep,
    install: true,
    install_dir: bindir,
  )

endif
