SHELL := /bin/bash
ROOT_DIR := $(CURDIR)
FP4_PROFILE := config/fairphone-fp4.env
QEMU_PROFILE := config/arm64-virt.env
DEFAULT_PROFILE := $(FP4_PROFILE)
BUILD_FP4_SCRIPT := $(ROOT_DIR)/scripts/build-fairphone4-v2.sh
BUILD_FP4_PMBOOTSTRAP_SCRIPT := $(ROOT_DIR)/scripts/build-image.sh
BUILD_QEMU_SCRIPT := $(ROOT_DIR)/scripts/build-qemu.sh
BUILD_QEMU_V2_SCRIPT := $(ROOT_DIR)/scripts/build-qemu-2.sh
BUILD_FP4_V2_SCRIPT := $(ROOT_DIR)/scripts/build-fairphone4-v2-2.sh
FP4_OVERLAY_SCRIPT := $(ROOT_DIR)/scripts/device/sync-fairphone-fp4-overlay.sh

help:
	@echo "Single-path image build:"
	@echo "  make build                       # Alias for build-fairphone4 (default profile)"
	@echo "  make build-fairphone4            # Fairphone FP4: Alpine + postmarketOS APK mirror,"
	@echo "                                   #   container-based, NO pmbootstrap. Mirrors build-qemu model."
	@echo "                                   #   Ships VENDOR phosh from rust/phosh/phosh by default."
	@echo "                                   #   Opt out: ATOMOS_SKIP_VENDOR_PHOSH_BUILD=1 make build-fairphone4"
	@echo "  make build-fairphone4-2          # Fairphone FP4 V2 (AtomOS-Comp replacing Phosh)"
	@echo "  make build-fairphone4-pmbootstrap # Legacy: Fairphone FP4 via pmbootstrap (kept for diffing)."
	@echo "  make build-qemu                  # ARM64 QEMU profile (Alpine-based, ships vendor phosh)"
	@echo "  make build-qemu-2                # ARM64 QEMU profile V2 (AtomOS-Comp replacing Phosh)"
	@echo "                                   #   Meson cache persists in a docker volume; unchanged"
	@echo "                                   #   rust/phosh skips recompile (see build-qemu.sh env docs)."
	@echo "  make qemu                        # Boot exported image via qemu-system-aarch64"
	@echo ""
	@echo "Fairphone 4 build details (build-fairphone4):"
	@echo "  - Bootstraps an aarch64 rootfs into a docker volume."
	@echo "  - Installs Alpine edge {main,community,testing} APKs + postmarketOS APKs"
	@echo "    (https://mirror.postmarketos.org/postmarketos/main) via 'apk --root /target add'."
	@echo "  - Pulls device-fairphone-fp4 + firmware-fairphone-fp4-* +"
	@echo "    linux-postmarketos-qcom-sm6350 + mkbootimg + make-dynpart-mappings + soc-qcom*"
	@echo "    as PRE-BUILT APKs from the postmarketOS mirror."
	@echo "  - Builds custom phosh (default; opt out via ATOMOS_SKIP_VENDOR_PHOSH_BUILD=1)"
	@echo "    + atomos-overview-chat-ui + atomos-home-bg in an Alpine arm64 container."
	@echo "  - Assembles boot.img with mkbootimg using deviceinfo offsets from"
	@echo "    pmaports/device/community/device-fairphone-fp4/deviceinfo."
	@echo "  - Packs rootfs into a sparse ext4 fairphone-fp4.img for fastboot."
	@echo ""
	@echo "Offline / local-first package store (build-fairphone4):"
	@echo "  - apk + Rust crates persist in docker volume atomos-fp4v2-pkg-cache-"
	@echo "    fairphone-fp4 (default). On multipass the repo tree is virtiofs and"
	@echo "    cannot host apk's cache -- do NOT point ATOMOS_FP4V2_PKG_CACHE_HOST_DIR"
	@echo "    at build/ under /home/ubuntu/atomos. Use a VM-native path instead."
	@echo "  - FIRST build seeds the store online; later builds run OFFLINE from"
	@echo "    stored versions (immune to mirror/DNS outages)."
	@echo "  - Pull newest + repopulate: ATOMOS_FP4V2_PKG_REFRESH=1 make build-fairphone4"
	@echo "  - Missing package auto-refreshes that phase from the network."
	@echo ""
	@echo "SSH:"
	@echo "  Device (USB): 172.16.42.1 -- after make build-fairphone4 + USB developer mode"
	@echo "  QEMU (make qemu): ssh -p 2222 user@127.0.0.1 -- user networking, not bridge100"
	@echo ""
	@echo "Build output:"
	@echo "  build/host-export-fairphone-fp4/boot.img"
	@echo "  build/host-export-fairphone-fp4/fairphone-fp4.img"
	@echo "  build/host-export-arm64-virt/arm64-virt.img"
	@echo ""
	@echo "Flash (FP4 in fastboot/bootloader):"
	@echo "  fastboot flash boot     build/host-export-fairphone-fp4/boot.img"
	@echo "  fastboot flash userdata build/host-export-fairphone-fp4/fairphone-fp4.img"

WITHOUT_HOME_BG ?= 0

# Support building without the home-bg WebGL background.
# Pass --without-home-bg to build scripts if WITHOUT_HOME_BG=1.
HOME_BG_ARG :=
ifeq ($(WITHOUT_HOME_BG),1)
HOME_BG_ARG := --without-home-bg
endif

build: build-fairphone4

build-fairphone4:
	ATOMOS_ENABLE_VENDOR_PHOSH_ON_FP4=1 bash "$(BUILD_FP4_SCRIPT)" "$(FP4_PROFILE)" $(HOME_BG_ARG)

build-fairphone4-2:
	ATOMOS_V2=1 bash "$(BUILD_FP4_V2_SCRIPT)" "$(FP4_PROFILE)" $(HOME_BG_ARG)

build-fairphone4-pmbootstrap:
	ATOMOS_ENABLE_VENDOR_PHOSH_ON_FP4=1 bash "$(BUILD_FP4_PMBOOTSTRAP_SCRIPT)" "$(FP4_PROFILE)" $(HOME_BG_ARG)

build-qemu:
	bash "$(BUILD_QEMU_SCRIPT)" "$(QEMU_PROFILE)" $(HOME_BG_ARG)

build-qemu-2:
	ATOMOS_V2=1 bash "$(BUILD_QEMU_V2_SCRIPT)" "$(QEMU_PROFILE)" $(HOME_BG_ARG)

qemu:
	@bash "$(ROOT_DIR)/scripts/qemu/run-local-qemu.sh" "$(QEMU_PROFILE)"

# Layered QEMU integration suite (see tests/integration/conftest.py).
# Runs L1 (args lint, no QEMU) first, then L2/L3 (boot survives + SSH up),
# then L4/L5 (post-login Phosh lifetime + scanout resize stress). L4/L5
# require an image built with PMOS_AUTOLOGIN=1 (already set in arm64-virt.env).
test-qemu-integration:
	cd "$(ROOT_DIR)/.." && python3 -m unittest discover -v \
	    -s iso-postmarketos/tests -p 'test_qemu_run_args.py'
	cd "$(ROOT_DIR)/.." && python3 -m unittest discover -v \
	    -s iso-postmarketos/tests/integration -p 'test_qemu_boot_survives.py'
	cd "$(ROOT_DIR)/.." && python3 -m unittest discover -v \
	    -s iso-postmarketos/tests/integration -p 'test_qemu_phosh_login_lifetime.py'

# Diagnose the "lockscreen -> load -> lockscreen" cycle over SSH.
# Polls greetd/phoc/phosh/gnome-session pids in a window and reports
# which side dies first plus journal/dmesg/coredump excerpts.
#   Defaults: QEMU profile, ssh user@localhost:2222, 30s window.
#   Override: SSH_TARGET=user@172.16.42.1 PROFILE=$(FP4_PROFILE) \
#             OBSERVE=60 make diagnose-session-restart-loop
SSH_TARGET ?= user@localhost
PROFILE    ?= $(QEMU_PROFILE)
OBSERVE    ?= 30
diagnose-session-restart-loop:
	ATOMOS_DIAG_OBSERVE_SECONDS=$(OBSERVE) \
	    bash "$(ROOT_DIR)/scripts/app-handler/diagnose-session-restart-loop.sh" \
	        "$(PROFILE)" "$(SSH_TARGET)"

# One-shot variant: "session never came up after unlock" (no cycle).
diagnose-session-boot-loop:
	bash "$(ROOT_DIR)/scripts/app-handler/diagnose-session-boot-loop.sh" \
	    "$(PROFILE)" "$(SSH_TARGET)"

# Bisect the post-login Phosh SIGSEGV by toggling the runtime knobs.
# Rewrites /etc/atomos/phosh-profile.env with all knobs OFF, optionally
# removes /etc/xdg/autostart/atomos-app-handler.desktop, restarts greetd,
# and holds for HOLD seconds. Splits "always-on phosh patches" from
# "runtime-gated phosh patches" as the SIGSEGV source.
#   HOLD                     window after greetd restart (default 30)
#   DISABLE_HANDLER_AUTOSTART also remove the layer-shell handler at-login (default 1)
#   REVERT_ON_EXIT           restore the original env on exit (default 0)
HOLD                     ?= 30
DISABLE_HANDLER_AUTOSTART ?= 1
REVERT_ON_EXIT            ?= 0
bisect-phosh-runtime-knobs:
	ATOMOS_BISECT_HOLD_SECONDS=$(HOLD) \
	ATOMOS_BISECT_DISABLE_HANDLER_AUTOSTART=$(DISABLE_HANDLER_AUTOSTART) \
	ATOMOS_BISECT_REVERT_ON_EXIT=$(REVERT_ON_EXIT) \
	    bash "$(ROOT_DIR)/scripts/app-handler/bisect-phosh-runtime-knobs.sh" \
	        "$(PROFILE)" "$(SSH_TARGET)"

# Capture a core dump from the post-login Phosh SIGSEGV and run gdb on it.
# Use after bisect-phosh-runtime-knobs returns the "always-on phosh patch"
# verdict, to pinpoint the faulting frame.
#   WAIT          poll window for the core file (default 30)
#   FETCH_CORE    scp the core back to host (default 0; cores are 50–200 MB)
WAIT       ?= 30
FETCH_CORE ?= 0
capture-phosh-coredump:
	ATOMOS_COREDUMP_WAIT_SECONDS=$(WAIT) \
	ATOMOS_COREDUMP_FETCH=$(FETCH_CORE) \
	    bash "$(ROOT_DIR)/scripts/app-handler/capture-phosh-coredump.sh" \
	        "$(PROFILE)" "$(SSH_TARGET)"

# Intelligently hotfixes only changed custom components (Phosh or Rust packages)
# on the running target (device or QEMU) over SSH.
pmos-hotfix-all:
	bash "$(ROOT_DIR)/scripts/phosh/hotfix-all.sh" "$(PROFILE)" "$(SSH_TARGET)"

.PHONY: help build build-fairphone4 build-fairphone4-pmbootstrap build-qemu qemu \
        test-qemu-integration diagnose-session-restart-loop diagnose-session-boot-loop \
        bisect-phosh-runtime-knobs capture-phosh-coredump pmos-hotfix-all

