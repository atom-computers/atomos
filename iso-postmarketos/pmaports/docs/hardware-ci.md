# Hardware CI

Hardware CI includes a lot of moving parts, and as debugging is a lot harder
than development, it can be hard to understand which part of the whole system is
resulting in failures. This aims to explain the CI setup in pmaports to make it
easier to understand the different moving parts.

## Overall architecture

The hardware CI consists of the following building blocks:

* Dynamic generation of jobs: the `.ci/lib/generate_build_jobs.py` is run on CI
  to detect what changed from the target branch. If there are packages to be
  built, or changes that should prompt testing on hardware, a complete GitLab
  pipeline definition is created based on the input template. This generated
  pipeline is consumed by GitLab to create a [downstream
  pipeline](https://docs.gitlab.com/ci/pipelines/downstream_pipelines/#dynamic-child-pipelines)
  and contains all the details about what to build, and the specific process to
  test each of the relevant devices. If there is nothing to build or test, a
  dummy pipeline is created instead (see
  <https://gitlab.com/gitlab-org/gitlab/-/issues/368248>)
* Building changed packages: those packages that are changed are built by CI,
  together with a repo that allows to use `mrtest add` and `mrtest
  upgrade`. This is independent of any work related to hardware.
* Preparation of test artifacts: if any of the packages that were built is a
  dependency of a DUT, then CI proceeds to create boot artifacts for the DUT
  using those newly-built packages. This step often makes use of helper
  functions in
  [ci-common](https://gitlab.postmarketos.org/postmarketOS/ci-common/-/blob/ci-tron-integration/ci-tron/common.yml).
* Definition of tests: how and what to tests for a device is defined by a
  `gitlab-ci.yml.j2` jinja template under the device package folder. Those
  templates often include jobs from other places, since tests are usually
  generic and shared across multiple devices.

## Add a new device to pmaports

Adding a new device for testing under pmaports can be done by adding a
`gitlab-ci.yml.j2` file in your device package. This file should define all the
test jobs for your device and will get included when generating the final
pipeline by `generate_build_jobs.py`.

Your jobs are expected to set all the necessary attributes to run jobs
on a CI-tron-provided runner, but the following template variables and
hidden jobs are provided to you as helpers:

- Jinja template variables (defined in `.ci/lib/generate_build_jobs.py`):
  - `device`: Instance of the `Device` class which represents the
    device under test.
- Hidden jobs (defined in `.ci/build-jobs.yaml.j2`):
  - `.test-{{ device.name }}`: Defines all the common parameters for
    testing this device (;
  - `.device-boot-flow-separate-artifacts`: Sets the kernel
    and initramfs URLs when the prepare job generates separate kernel and
    initramfs files as artifacts.
  - `.device-boot-flow-fastboot-image`: Sets the full fastboot boot image when
    the prepare job generates a boot image ready for booting into the DUT.

:::{note}
Rather than duplicating the `gitlab-ci.yml.j2` file for all the devices that can
make use of it, you may save the file in `.gitlab-ci/packages/` then link to it
in the device folder.
:::

## Tests

There are 3 kind of tests in the postmarketOS hardware CI setup:

### Kernel tests

One important part of the hardware CI is to be able to test all the low-level
integration and logic. That includes, first and foremost, the kernel and some
initramfs functionality.

The package `postmarketos-mkinitfs-hook-ci` takes care of that. If installed, it
will:

* Run in the initramfs any scripts installed under
 `/usr/libexec/pmos-tests-initramfs`.
* Prints a success or fail so it can be detected by whatever is orchestrating
  the tests.
* Print a message that the execution is done, and halt the boot.

This allows for any package to provide arbitrary scripts in that location, and
have them execute during hardware-CI testing on the initramfs.

However, most test routines are pretty generic. So instead of every device
creating there own, most of them are aggregated as subpackages of the
`postmarketos-test` package. Then, if a DUT wants to enable a specific initramfs
test, everything it needs is a subpackage that depends on the corresponding
tests from `postmarketos-test`, and that gets installed if
`postmarketos-mkinitfs-hook-ci` is also installed. This subpackage is, as a
convention, named `pmtest`. This is how device package's APKBUILD that enables
tests for unl0kr and suspend would look like:

```sh
subpackages="$pkgname-pmtest"

pmtest() {
    install_if="$pkgname=$pkgver-r$pkgrel postmarketos-mkinitfs-hook-ci"
    depends="postmarketos-test-suspend postmarketos-test-unl0kr"

    mkdir -p "$subpkgdir"
}
```

### Boot tests

:::{note}
The infrastructure for these tests has not been developed yet.
:::

Boot tests are expected to test the boot sequence. For that, they should run the
exact same boot sequence that the DUTs they run on, including an unmodified
initramfs. These tests have not yet been developed. These tests could test
things like checking that the partition detection is correct, or that FDE runs
successfully.

### System tests

:::{note}
The infrastructure for these tests has not been developed yet.
:::

Anything that requires complex user-space integration or deamons should be done
on top of the rootfs, not the initramfs. These tests could cover things like
checking WiFi or Bluetooth connectivity, or making calls.

## Debugging

### Dynamic pipeline generation

Testing pipelines in pmaports are generated dynamically, so that
changing an armv7 devices only builds for that architecture, and does
not run ci-tron tests for any other device. The pipeline is generated by
the `.ci/lib/generate_build_jobs.py` script. The script requires jinja2
and pmbootstrap to be installed, but once they are it can be run passing
a jinja template (unless doing changes, it should be
`.ci/build-jobs.yaml.j2`) as a first argument, and the output file as a
second argument. This way, it is possible to run the code generation
locally, and inspect the resulting pipeline.
