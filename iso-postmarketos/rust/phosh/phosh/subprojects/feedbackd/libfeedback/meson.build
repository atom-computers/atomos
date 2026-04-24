# Shared library and language bindings

libfeedback_libdir = get_option('libdir')
libfeedback_header_dir = get_option('includedir') / libname
libfeedback_link_args = []
libfeedback_symbols_file = 'libfeedback.syms'

# Check linker flags
ld_version_script_arg = '-Wl,--version-script,@0@'.format(
  meson.current_source_dir() / libfeedback_symbols_file,
)
if cc.links(
  'int main() { return 0; }',
  args: ld_version_script_arg,
  name: 'ld_supports_version_script',
)
  libfeedback_link_args += [ld_version_script_arg]
endif

lfb_enum_headers = files('lfb-event.h')
lfb_enum_sources = gnome.mkenums_simple(
  'lfb-enums',
  sources: lfb_enum_headers,
  install_header: true,
  install_dir: libfeedback_header_dir,
)

libfeedback_headers = ['libfeedback.h', 'lfb-event.h', 'lfb-main.h']

libfeedback_sources = [
  generated_dbus_sources,
  lfb_enum_sources,
  libfeedback_headers,
  'lfb-event.c',
  'lfb-main.c',
]

libfeedback_deps = [gio, gio_unix, glib]

libfeedback_c_args = [
  '-DG_LOG_DOMAIN="libfeedback"',
  '-DLIBFEEDBACK_COMPILATION',
  '-DLIBFEEDBACK_USE_UNSTABLE_API',
]

libfeedback = library(
  'feedback-' + apiversion,
  libfeedback_sources,
  soversion: 0,
  c_args: libfeedback_c_args,
  dependencies: libfeedback_deps,
  link_args: libfeedback_link_args,
  install: true,
  install_dir: libfeedback_libdir,
)

libfeedback_inc = include_directories('.')
libfeedback_dep = declare_dependency(
  sources: [generated_dbus_sources, lfb_enum_sources[1]],
  link_with: libfeedback,
  dependencies: libfeedback_deps,
  include_directories: libfeedback_inc,
)
install_headers(libfeedback_headers, subdir: libname)

pkgconfig = import('pkgconfig')

pkgconfig.generate(
  libraries: [libfeedback],
  subdirs: libname,
  version: meson.project_version(),
  name: 'Feedback',
  filebase: 'libfeedback-@0@'.format(apiversion),
  description: 'Cross desktop feedback library',
  requires: 'gio-2.0',
  install_dir: join_paths(libfeedback_libdir, 'pkgconfig'),
)

if introspection
  libfeedback_gir_extra_args = [
    '-I' + dbus_header_dir,
    '--c-include=libfeedback.h',
    '--quiet',
    '-DLIBFEEDBACK_COMPILATION',
    '-DLIBFEEDBACK_USE_UNSTABLE_API',
    '--warn-all',
  ]

  libfeedback_gir = gnome.generate_gir(
    libfeedback,
    sources: libfeedback_sources,
    nsversion: apiversion,
    namespace: 'Lfb',
    export_packages: 'libfeedback-@0@'.format(apiversion),
    symbol_prefix: 'lfb',
    identifier_prefix: 'Lfb',
    link_with: libfeedback,
    includes: ['Gio-2.0'],
    install: true,
    install_dir_gir: girdir,
    install_dir_typelib: typelibdir,
    extra_args: libfeedback_gir_extra_args,
    fatal_warnings: true,
  )

  if get_option('vapi')
    libfeedback_vapi = gnome.generate_vapi(
      'libfeedback-' + apiversion,
      sources: libfeedback_gir[0],
      packages: ['gio-2.0'],
      install: true,
      install_dir: vapidir,
      metadata_dirs: [meson.current_source_dir()],
    )
  endif
endif
