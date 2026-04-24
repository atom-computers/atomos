if get_option('tests')

  umockdev_dep = dependency('umockdev-1.0')

  add_test_setup('umockdev', exe_wrapper: 'umockdev-wrapper', is_default: true)

  test_env = environment()
  test_env.set('G_TEST_SRCDIR', meson.current_source_dir())
  test_env.set('G_TEST_BUILDDIR', meson.current_build_dir())
  test_env.set('G_DEBUG', 'gc-friendly,fatal-warnings')
  test_env.set('GSETTINGS_BACKEND', 'memory')
  test_env.set('GSETTINGS_SCHEMA_DIR', '@0@/data'.format(meson.project_build_root()))
  test_env.set('PYTHONDONTWRITEBYTECODE', 'yes')
  test_env.set('MALLOC_CHECK_', '2')
  test_env.set('XDG_CONFIG_HOME', meson.current_source_dir() / 'data' / 'user-config')
  test_env.set('XDG_CONFIG_DIRS', meson.current_source_dir())
  # Override desktop so we don't depend on GNOME schemas in the tests
  test_env.set('XDG_CURRENT_DESKTOP', 'doesnotexist')

  # Shared library Unit tests

  test_lfb_cflags = [
    '-DTEST_APP_ID="org.sigxcpu.feedbackd_test"',
    '-DLIBFEEDBACK_USE_UNSTABLE_API',
    '-DTEST_DATA_DIR="@0@"'.format(join_paths(meson.current_source_dir(), 'data')),
  ]

  test_lfb_link_args = ['-fPIC']

  test_lfb_deps = [libfeedback_dep, glib, gio_unix]

  if get_option('daemon')
    # The integration test needs the daemon
    test = 'lfb-integration'
    subdir('services')
    t = executable(
      'test-@0@'.format(test),
      ['test-@0@.c'.format(test)],
      c_args: test_lfb_cflags,
      pie: true,
      link_args: test_lfb_link_args,
      dependencies: test_lfb_deps,
    )
    test(test, t, env: test_env, depends: fbd_exe)
  endif

  unit_tests = ['lfb-event', 'lfb-main']
  foreach test : unit_tests
    t = executable(
      'test-@0@'.format(test),
      ['test-@0@.c'.format(test)],
      c_args: test_lfb_cflags,
      pie: true,
      link_args: test_lfb_link_args,
      dependencies: test_lfb_deps,
    )
    test(test, t, env: test_env)
  endforeach

  # Daemon Unit tests
  if get_option('daemon')

    test_env_fbd = test_env
    test_env_fbd.set('XDG_DATA_DIRS', meson.current_source_dir() / 'data' / 'xdg-data')

    test_fbd_cflags = [
      '-DTEST_APP_ID="org.sigxcpu.feedbackd_test"',
      '-DTEST_DATA_DIR="@0@"'.format(join_paths(meson.current_source_dir(), 'data')),
    ]

    test_fbd_link_args = ['-fPIC']

    test_fbd_deps = [fbd_dep, umockdev_dep]

    # HW independent tests
    fbd_tests = [
      'fbd-feedback-led',
      'fbd-feedback-profile',
      'fbd-feedback-sound',
      'fbd-feedback-vibra',
      'fbd-feedback-theme',
      'fbd-event',
      'fbd-theme-expander',
      'fbd-dev-led',
    ]

    foreach test : fbd_tests
      t = executable(
        'test-@0@'.format(test),
        ['test-@0@.c'.format(test), 'testlib.c', generated_dbus_sources[1]],
        c_args: test_fbd_cflags,
        pie: true,
        link_args: test_fbd_link_args,
        include_directories: fbd_inc,
        dependencies: test_fbd_deps,
      )
      test(test, t, env: test_env_fbd, depends: compiled_schemas)
    endforeach

  endif  # daemon

endif
