Title: Compiling with libfeedback
Slug: building

# Compiling with libfeedback

If you need to build libfeedback, get the source from
[here](https://gitlab.freedesktop.org/feedbackd/feedbackd) and see the `README.md` file.

## Using `pkg-config`

Like other GObject based libraries, libfeedback uses `pkg-config` to provide compiler
options. The package name is `libfeedback-0.0`.

When using the Meson build system you can declare a dependency like:

```meson
dependency('libfeedback-0.0')
```

## Bundling the Library

### Using a Subproject

Libfeedback can be used as a Meson subproject.  Create a
`subprojects/libfeedback.wrap` file with the following contents:

```ini
[wrap-git]
directory=libfeedback
url=https://gitlab.freedesktop.org/feedbackd/feedbackd.git
revision=main
depth=1
```

Add this to your `meson.build`:

```meson
libfeedback = dependency(
  'libfeedback-0.0',
  version: '>= 0.0.1',
  fallback: ['libfeedback', 'libfeedback_dep'],
  default_options: [
    'daemon=false',
    'man=false',
    'gtk_doc=false',
    'vapi=false',
    'tests=false',
  ]
)
```

Then the `libfeedback` variable can be used as a dependency.

# Next Steps

Once libfeedback has been compiled and included into your project, it needs to be
initialized. See [Initialization](initialization.html).
