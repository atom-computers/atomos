project(
  'feedbackd',
  'c',
  version: '0.8.9',
  license: 'LGPLv3+',
  meson_version: '>= 1.7.0',
  default_options: ['warning_level=1', 'buildtype=debugoptimized', 'c_std=gnu11'],
)

gio = dependency('gio-2.0', version: '>=2.50.0')
gio_unix = dependency('gio-unix-2.0', version: '>=2.50.0')
glib = dependency('glib-2.0', version: '>=2.50.0')
udev = dependency('udev', required: false)
if get_option('daemon')
  gobject = dependency('gobject-2.0', version: '>=2.50.0')
  gmobile = dependency(
    'gmobile',
    version: '>= 0.1.0',
    fallback: ['gmobile', 'gmobile_dep'],
    default_options: ['examples=false', 'introspection=false', 'gtk_doc=false', 'tests=false'],
  )
  gsound = dependency('gsound')
  gudev = dependency('gudev-1.0', version: '>=232')
  json_glib = dependency('json-glib-1.0')
  systemd_dep = dependency('systemd', required: false)
endif

prefix = get_option('prefix')

bindir = join_paths(prefix, get_option('bindir'))
datadir = join_paths(prefix, get_option('datadir'))
libdir = join_paths(prefix, get_option('libdir'))
girdir = join_paths(prefix, join_paths(datadir, 'gir-1.0'))
ifacedir = join_paths(prefix, join_paths(datadir, 'dbus-1', 'interfaces'))
servicedir = join_paths(prefix, join_paths(datadir, 'dbus-1', 'services'))
libexecdir = join_paths(prefix, get_option('libexecdir'))
typelibdir = join_paths(prefix, join_paths(libdir, 'girepository-1.0'))
vapidir = join_paths(prefix, join_paths(datadir, 'vala', 'vapi'))
feedbackd_theme_dir = join_paths(datadir, 'feedbackd', 'themes')
if udev.found() and get_option('daemon')
  udevdir = udev.get_variable('udevdir') / 'rules.d'
else
  udevdir = prefix / 'lib' / 'udev' / 'rules.d'
endif
wireplumberdir = datadir / 'wireplumber' / 'wireplumber.conf.d'

run_data = configuration_data()
run_data.set('ABS_BUILDDIR', meson.current_build_dir())
run_data.set('ABS_SRCDIR', meson.current_source_dir())
configure_file(input: 'run.in', output: 'run', configuration: run_data)

gnome = import('gnome')

cc = meson.get_compiler('c')

test_c_args = [
  '-Wcast-align',
  '-Wdate-time',
  ['-Werror=format-security', '-Werror=format=2'],
  '-Wendif-labels',
  '-Werror=incompatible-pointer-types',
  '-Werror=missing-declarations',
  '-Werror=overflow',
  '-Werror=return-type',
  '-Werror=shift-count-overflow',
  '-Werror=shift-overflow=2',
  '-Werror=implicit-fallthrough=3',
  '-Wformat-nonliteral',
  '-Wformat-security',
  '-Winit-self',
  '-Wmaybe-uninitialized',
  '-Wmissing-field-initializers',
  '-Wmissing-include-dirs',
  '-Wmissing-noreturn',
  '-Wnested-externs',
  '-Wno-missing-field-initializers',
  '-Wno-sign-compare',
  '-Wno-strict-aliasing',
  '-Wno-unused-parameter',
  '-Wold-style-definition',
  '-Wpointer-arith',
  '-Wredundant-decls',
  '-Wstrict-prototypes',
  '-Wtype-limits',
  '-Wundef',
  '-Wunused-function',
]

if get_option('buildtype') != 'plain'
  test_c_args += '-fstack-protector-strong'
endif

global_c_args = [
  '-DFEEDBACKD_THEME_DIR="@0@"'.format(feedbackd_theme_dir),
  '-DLIBFEEDBACK_COMPILATION',
  '-DFBD_VERSION="@0@"'.format(meson.project_version()),
]

add_project_arguments(global_c_args + cc.get_supported_arguments(test_c_args), language: 'c')

introspection_feature = get_option('introspection')
introspection = introspection_feature.enabled() or introspection_feature.auto()

apiversion = '0.0'
libname = 'libfeedback-' + apiversion

json_glib_validate = find_program('json-glib-validate', required: false)

subdir('data')
subdir('libfeedback')
subdir('src')
subdir('cli')
subdir('tests')
subdir('doc')

summary = [
  '',
  '---------------',
  'feedbackd @0@'.format(meson.project_version()),
  '',
  '         Daemon: @0@'.format(get_option('daemon')),
  '     Udev rules: @0@'.format(get_option('udev')),
  '  Documentation: @0@'.format(get_option('gtk_doc')),
  '   Manual pages: @0@'.format(get_option('man')),
  '  Introspection: @0@'.format(introspection),
  '           Vapi: @0@'.format(get_option('vapi')),
  '          Tests: @0@'.format(get_option('tests')),
  '    Media Roles: @0@'.format(get_option('media-roles')),
  '---------------',
  '',
]
message('\n'.join(summary))

gnome.post_install(glib_compile_schemas: true)
