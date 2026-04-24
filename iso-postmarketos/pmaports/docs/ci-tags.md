# CI tags

You can add various tags in the commit message of your last commit  to modify
the continuous integration behaviour for your merge requests.

## Current CI tags

* `[ci:skip-build]`: Do not build modified packages, only verify their
  checksums. Use this when pushing changes to an MR that should not trigger a
  complete build.
* `[ci:skip-vercheck]`: Do not verify if the version of a changed package has
  been increased. Use this, when making a cosmetic change in an APKBUILD that
  should not cause the package to get rebuilt, or when changing the enabled
  architectures.
* `[ci:skip-kconfigcheck]`: Do not check the kernel config for packages
  changed in the commit. Use this when moving kernel packages between
  categories or performing bulk changes across a lot of kernel packages, but
  never when upgrading the kernel.
* `[ci:skip-dint]`: Do not run the device-linter check. Use this when moving
  or modifying many devices not maintained by you that due to historical reasons
  might not pass the check.
* `[skip ci]`: Completely skip the pipeline for the merge request. This is a
  GitLab [feature](https://docs.gitlab.com/ci/pipelines/#skip-a-pipeline). Use
  this only in very extreme situations where CI might be broken, but a change is
  needed to fix critical bugs. Whenever possible, try to use the other tags.

## Former CI tags

* `[ci:ignore-count]`: Allow skipping the "too many packages changed" check.
  Use this when automatically modifying many device packages.
  * Removed after v25.12 together with the package count check as it hampered
    productivity to little gain since we no longer have runners with limited
    compute minutes.
