service_file = 'org.sigxcpu.Feedback.service'
service_data = configuration_data()
service_data.set('ABS_BUILDDIR', meson.project_build_root())

configure_file(input: service_file + '.in', output: service_file, configuration: service_data)
