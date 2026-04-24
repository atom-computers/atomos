# DBus server interface
prefix = 'org.sigxcpu.'
namespace = 'LfbGdbus'

generated_dbus_sources = []

dbus_interfaces = ['org.sigxcpu.Feedback.xml', 'org.sigxcpu.Feedback.Haptic.xml']

generated_dbus_sources += gnome.gdbus_codegen(
  'lfb-gdbus',
  sources: dbus_interfaces,
  object_manager: false,
  docbook: 'libfeedback',
  interface_prefix: prefix,
  install_header: true,
  install_dir: join_paths(get_option('includedir'), libname),
  namespace: namespace,
)

dbus_header_dir = meson.current_build_dir()
dbus_inc = include_directories('.')
install_data(dbus_interfaces, install_dir: ifacedir)

schemas = ['org.sigxcpu.feedbackd.gschema.xml']
compiled_schemas = gnome.compile_schemas(depend_files: schemas, build_by_default: true)

compile_schemas = find_program('glib-compile-schemas', required: false)
if compile_schemas.found()
  test(
    'Validate schema file',
    compile_schemas,
    args: ['--strict', '--dry-run', meson.current_source_dir()],
  )
endif

install_data(schemas, install_dir: 'share/glib-2.0/schemas')


if get_option('daemon')

  service_data = configuration_data()
  service_data.set('libexecdir', libexecdir)
  service_file = 'org.sigxcpu.Feedback.service'

  configure_file(
    input: service_file + '.in',
    output: service_file,
    configuration: service_data,
    install: true,
    install_dir: servicedir,
  )

  theme_json = ['default.json']
  install_data(theme_json, install_dir: feedbackd_theme_dir)

  if json_glib_validate.found()
    jsons = []
    foreach theme : theme_json
      jsons += (join_paths(meson.current_source_dir(), theme))
    endforeach
    custom_target(
      'validate-json',
      build_by_default: true,
      input: theme_json,
      output: 'json_validate_stamp',
      command: [json_glib_validate.full_path()] + jsons,
    )
  endif

  if get_option('udev')
    install_data('72-feedbackd.rules', install_dir: udevdir)
  endif

  systemd_user_unit_dir = get_option('systemd_user_unit_dir')
  systemd_dep = dependency('systemd', required: false)
  if systemd_user_unit_dir == ''
    if systemd_dep.found()
      systemd_user_unit_dir = systemd_dep.get_variable('systemd_user_unit_dir')
    else
      systemd_user_unit_dir = prefix / libdir / 'systemd' / 'user'
    endif
  endif

  # Alert slider Systemd user service
  alert_slider_unit = 'fbd-alert-slider.service'
  configure_file(
    input: alert_slider_unit + '.in',
    output: alert_slider_unit,
    configuration: service_data,
    install: true,
    install_dir: systemd_user_unit_dir,
  )

  systemd_sysusers_dir = get_option('systemd_sysusers_dir')
  if systemd_sysusers_dir == ''
    if systemd_dep.found()
      systemd_sysusers_dir = systemd_dep.get_variable('sysusersdir')
    else
      systemd_sysusers_dir = prefix / libdir / 'sysusers.d'
    endif
  endif

  install_data('feedbackd.sysusers', rename: 'feedbackd.conf', install_dir: systemd_sysusers_dir)

  if get_option('media-roles')
    install_data('media-role-nodes.conf', install_dir: wireplumberdir)
  endif
endif  # daemon
