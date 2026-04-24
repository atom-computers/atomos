# Packaging Guidelines

## Provides, priorities, alternatives, and forking packages

The APK concepts around selecting conflicting packages for a same purpose, e.g:
udev implementations is complex, barely documented, and full of foot
guns. Mistakes on this have caused a fair share of issues and bugs in the past,
and is important to understand them to avoid them in the future.

### Versioned provides

:::{note}
Upstream documentation
[exists](https://wiki.alpinelinux.org/wiki/APKBUILD_Reference#provides) but is
remarkably limited. Generic documentation here could be potentially moved
upstream if alpine docs improve in the future.
:::

Every APK package can be installed and identified by its name. But APK has a
feature for packages to identify themselves with alternative names for
installation. This is called "provides". Provides are most commonly versioned,
meaning that if two packages provide the same thing, they are considered in
conflict and not allowed to be installed concurrently.

:::{note}
abuild automatically adds provides for shared libraries under /usr/lib and
executables under the PATH. As a convention, shared libraries have a `so:`
prefix, and executables a `cmd:` prefix.
:::

Let's look at an example:

```sh
$ apk info --provides musl
musl-1.2.5-r21 provides:
so:libc.musl-x86_64.so.1=1

$ apk info --provides musl-utils
musl-utils-1.2.5-r21 provides:
libc-utils=1.2.5-r21
cmd:getconf=1.2.5-r21
cmd:getent=1.2.5-r21
cmd:iconv=1.2.5-r21
cmd:ldconfig=1.2.5-r21
cmd:ldd=1.2.5-r21

```

We can see, that the musl package is not only identified as `musl` with version
`1.2.5-r21`, but also as `so:libc.musl-x86_64.so.1` with version `1`. And that
`musl-utils` package can also be identified by all the executables it provides,
and as `libc-utils=1.25-r21`.

This logic and alternaties can become quite handy in multiple situations:

* **Tracing dependencies**: When building packages, abuild adds
  dependencies of packages in an equivalent from as it adds provides. If it
  detecs that a package depends on a certain library, instead of locking to the
  package that provides it, it depends on the `so:`-prefixed provider. This
  allows to replace any library with an alternative version of the same library
  without having to touch anything else. For example, we can see below how glib
  depends on `so:libc.musl-x86_64.so.1`, instead of depending direcly on `musl`.

```sh
$ apk info --depends glib
glib-2.86.3-r1 depends on:
/bin/sh
so:libc.musl-x86_64.so.1
so:libffi.so.8
so:libintl.so.8
so:libmount.so.1
so:libpcre2-8.so.0
so:libz.so.1
```

* **Renaming packages**: If we want to change the name of a package, but there
  is a chance that users have that package in their `/etc/apk/world`, then
  upgrades will fail, unless the renamed package can be backwards
  compatible. This is what we see when `musl-utils` provides
  `libc-utils=1.2.5-r21`. Indeed, on to of the line that adds it upstream there
  is this comment: `# for backwards compatibility`.

* **Providing default functionality**: For example, even though there are
  usually multiple versions of the `ceph` filesystem available in Alpine, only
  one of them provides the `ceph` name, allowing users to get a sane default
  instead of being pinned to a single version.

These are all simple, straight-forward uses of the provides feature. However,
there is more complexity and things that can be achieved with it.

### Virtual provides

Provides can not only have a version, but also have no version. This are called
"virtual" provides. Such provides work differently to versioned provides in the
sense that multiple packages that provide them can be installed
simultaneously. This can be helpful in situations where we can afford ourselves
more flexibility. For example, with the shell!

:::{note}
abuild also automatically adds a `/bin/sh` dependency when it detects that
packages have script files that depend on having a shell installed.
:::

```sh
$ apk info --provides busybox-binsh
busybox-binsh-1.37.0-r31 provides:
/bin/sh
cmd:sh=1.37.0-r31

$ apk info --provides dash-binsh
dash-binsh-0.5.13.1-r2 provides:
/bin/sh
cmd:sh=0.5.13.1-r2

$ apk info --depends glib
glib-2.86.3-r1 depends on:
/bin/sh
so:libc.musl-x86_64.so.1
so:libffi.so.8
so:libintl.so.8
so:libmount.so.1
so:libpcre2-8.so.0
so:libz.so.1
```

We can see how `glib` depends on `/bin/sh`, but that is provided by multiple
packages, without a version. `glib` needs a shell, but any POSIX-shell is
enough. At the same time, multiple POSIX shells can be installed simultaneously,
and that is not an issue!

:::{note}
In practice installing `dash` and `busybox` concurrently is possible, but
installing `dash-binsh` and `busybox-binsh` is not due to the versioned `cmd:`
provider. We leave an example that would work without `cmd:` as an exercise to
the reader.
:::

Other good examples to research are `linux-firmware-any`, and
`initramfs-generator` virtual providers.

#### Automatic selection: provider_priority

Since providers of virtual packages can all be installed at the same time, apk
does not have a direct way to decide what to do when asked to install
one. Should it install one, the other, or all of them? By default, when asked to
execute this impossible task apk will error out and ask the user to choose which
package providing the virtual name should be installed. However, generally there
is a desired default for such virtual package. If a `provider_priority` is added
to the `APKBUILD` together with a virtual provider, this will be used to select
the virtual to install (highest number) instead of prompting the user. A good
and easy example to research on this topic is the `initramfs-generator`.

### Forks, alternatives, and priorities

Unfortunately, the way providers are designed make it hard to reason about
forks. When forking packages, the most important things is to **always** use
versioned provides. Virtual providers might work in some situations, but APK
might randomly switch packages or consider conflicts depending on the status of
the user's `world` file. The forked package and the original package should
**never** be installed concurrently, thus the need of the versioned provides.

:::{warning}
There is a common misconception that `provider_priority` works with versioned
providers. This is due to the re-use of `provides` name, historical bugs, and
copy-paste of those bugs. `provider_priority` has no use together with versioned
provides, and any package that uses both should just remove the
`provider_priority` to avoid extending the confusion.
:::

However, most common bugs related to forks come from the difficulty
understanding which package will be installed when multiple provide the same
versioned provider. This is made specially complex because updates and new
installations can (and usually do!) behave differently, making reproducing
problems harder.

By default, versioned providers get installed based on the one with the greatest
version. This is straight forward when a fork should *always* be used. For
example, a temporary `libcamera` fork in `temp` providing `99990.6` will always
be selected instead of version `0.7`:

```sh
$ apk info -P libcamera
libcamera-0.7.0-r0 provides:
cmd:libcamerify=0.7.0-r0
so:libcamera-base.so.0.7=0.7.0
so:libcamera.so.0.7=0.7.0

libcamera-99990.6.0-r1 provides:
cmd:libcamerify=99990.6.0-r1
so:libcamera-base.so.0.6=0.6.0
so:libcamera.so.0.6=0.6.0

$ apk list --installed libcamera
libcamera-99990.6.0-r1 x86_64 {libcamera} (LGPL-2.1-or-later AND GPL-2.0-or-later) [installed]
```

This is also the reason why virtual providers seem to work when mixed with
versioned providers. A provider with any version is given priority over one
without a version, but given that one is versioned would still conflict. For
example.

:::{warning}
The example below shows a packaging bug. Forks should have never used virtual
providers! This is helpful to showcase this common pitfall
:::

```sh
$ apk info -P alsa-ucm-conf
alsa-ucm-conf-1.2.15.1-r0 provides:

alsa-ucm-conf-qcom-sdm660-1.2.14_git20251011-r0 provides:
alsa-ucm-conf

alsa-ucm-conf-qcom-sdm670-1.2.9_git20250707-r0 provides:
alsa-ucm-conf

alsa-ucm-conf-qcom-sm7150-1.2.14_git20251026-r1 provides:
alsa-ucm-conf

alsa-ucm-conf-sdm845-1-r1 provides:
alsa-ucm-conf

alsa-ucm-conf-unisoc-ums9230-1.2.9_git20251211-r0 provides:
alsa-ucm-conf

soc-qcom-msm8916-ucm-25-r1 provides:
alsa-ucm-conf

soc-qcom-msm8953-ucm-18-r1 provides:
alsa-ucm-conf

soc-qcom-msm8996-ucm-2-r0 provides:
alsa-ucm-conf

soc-qcom-msm89x7-ucm-5-r0 provides:
alsa-ucm-conf

soc-qcom-sm7125-ucm-2-r1 provides:
alsa-ucm-conf

$ apk list --installed alsa-ucm-conf
alsa-ucm-conf-1.2.15.3-r0 aarch64 {alsa-ucm-conf} (BSD-3-Clause) [installed]
```

So, what happens when we want to install a fork only in a specific-device, or
only in some specific circumstances? In those situations we have to:

* Make sure that the fork we want installed is installed in the specific
  conditions we want. For example, by depending on the fork in the device
  package. This will make the fork replace the original package.
* Consider what will happen to installations that shouldn't use the fork:
  * If the fork has a lower version than the original package, then the problem
    is solved for us by apk, as the higher version gets priority unless there
    are other constraints (like the device package dependency on the fork).
  * If the fork has an equal or higher version that then original package,
    however, we might bump into the situation that installs that shouldn't have
    the fork still get it installed due to the higher version. The solution to
    that problem is to force a dependency on the non-forked version in a common
    package used by most users. For example, `postmarketos-ui-gnome` added
    `!gnome-shell-mobile` to avoid regular installs getting the mobile versions.
    Sometimes, however, this gets complicated due to the fact that the provider
    is the name of the original package (like in the case of `alsa-ucm-conf`
    above). In those situations, it might be needed to introduce an alternative
    versioned provider to disambiguate (e.g:
    `provides="audio-conf=$pkgver-r$pkgrel"`), or to force the forked packages
    to provide a lower version than the other package.

## Meta packages

### Package versioning (pkgver, pkgrel)

Packages without upstream sources are a bit special. These are `device-*`
packages and other packages like `main/postmarketos-base`, where the source
files are included in the package directory. For these packages, the `pkgver`
should always be incremented instead of the `pkgrel` (so that `pkgrel` always
is `0`).
