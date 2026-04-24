if not get_option('tests')
  subdir_done()
endif

test_env = environment()
test_env.set('G_DEBUG', 'gc-friendly,fatal-warnings')
test_env.set('MALLOC_CHECK_', '2')
test_env.set('NO_AT_BRIDGE', '1')
# For -Db_sanitize=address
test_env.set(
  'LSAN_OPTIONS',
  'suppressions=@0@/data/leak-suppress.txt'.format(meson.project_source_root()),
)
test_env.set('ASAN_OPTIONS', 'fast_unwind_on_malloc=0')

test_cflags = ['-DTEST_DATA_DIR="@0@"'.format(meson.current_source_dir() / 'data')]

tests = ['cutout', 'display-panel', 'mcc-mnc', 'svg-path', 'timeout', 'utils', 'device-tree']
# These need data not available on the installed system:
not_installed = ['test-device-tree']

foreach test : tests

  test_name = 'test-@0@'.format(test)
  test_conf = configuration_data()
  test_conf.set('installed_tests_dir', installed_tests_execdir)
  test_conf.set('program', test_name)
  test_conf.set('program', test_name)

  if get_option('installed_tests') and test_name not in not_installed
    configure_file(
      input: files('template.test.in'),
      output: test_name + '.test',
      install_dir: installed_tests_metadir,
      configuration: test_conf,
    )
  endif

  t = executable(
    test_name,
    ['test-@0@.c'.format(test)],
    c_args: test_cflags,
    pie: true,
    link_with: gm_lib,
    dependencies: gmobile_dep,
    install: get_option('installed_tests'),
    install_dir: installed_tests_execdir,
  )
  test(test, t, env: test_env)
endforeach
