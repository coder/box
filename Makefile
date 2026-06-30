# Coder box — image build targets.
#
# An "appliance" is the box prebuilt as a bootable image (no install.sh):
# it boots straight into the fully-configured Coder box. Three formats:
#
#   make appliance/iso        # appliance ISO  (tmpfs overlay; state wiped on reboot)
#   make appliance/qcow2      # disk image (persistent; boots in QEMU/libvirt)
#   make appliance/raw        # disk image (persistent; dd-able to a drive)
#
# The "installer" is the box as an ISO that will install coder/box onto real
# hardware. For now it boots the same full GUI box as the appliance ISO; ISO only
# (no disk images):
#
#   make installer/iso
#
# For cheap validation (CI, quick "does the Nix evaluate?" checks) there are
# instantiate-only targets that evaluate the derivation and write its .drv to
# the store WITHOUT building the multi-GB image:
#
#   make installer/drv
#   make appliance/drv
#
# Each target also takes an architecture suffix; short names are normalized to
# a *-linux triple (e.g. aarch64 -> aarch64-linux):
#
#   make appliance/iso/x86_64-linux
#   make appliance/qcow2/aarch64-linux
#   make appliance/raw/aarch64
#   make installer/iso/aarch64-linux
#
# Requires Nix with flakes enabled (nix-command + flakes). All builds run on
# Linux only; cross-arch builds need a matching builder (native remote builder
# or binfmt/QEMU emulation). qcow2/raw additionally boot a QEMU VM during the
# build (disko image builder), so they want KVM to be fast.
#
# Outputs land in ./result (printed out-path). Flash a raw image or the ISO to
# a drive with e.g.
#   sudo dd if=result/...img of=/dev/sdX bs=4M status=progress oflag=sync

NIX   ?= nix
FLAKE ?= .

# Build revision injected into images (installer boot menu, /etc/coder-box-rev).
# We build through a path flakeref (getFlake (toString ./.)), which carries no
# git metadata, so self.rev/dirtyRev are empty — compute the rev here and pass
# it via the installer's `coderBox.rev` option. Full commit hash, with a -dirty
# suffix when the working tree has uncommitted changes. Empty if not a git
# checkout (the module then falls back to self.rev / "unknown").
GIT_REV := $(shell git rev-parse HEAD 2>/dev/null)$(shell git diff-index --quiet HEAD -- 2>/dev/null || echo -dirty)

# Normalize an arch token to a *-linux triple: $(call norm_arch,aarch64) -> aarch64-linux
norm_arch = $(if $(filter %-linux,$(1)),$(1),$(1)-linux)

# Single build helper used by every target. extendModules lets us override
# nixpkgs.hostPlatform (per-arch) and the disko image format from one recipe,
# so adding a format/arch is just a thin target below — no duplicated nix
# plumbing. We ALWAYS pin nixpkgs.hostPlatform: when no arch is given we use
# `builtins.currentSystem` (the builder's native arch), otherwise the bare
# `appliance/<format>` targets would inherit configuration.nix's
# `nixpkgs.hostPlatform = lib.mkOptionDefault "x86_64-linux"` and always build
# x86_64 even on an aarch64 host. `--impure` is what makes currentSystem
# available.
#   $(1) = host (nixosConfigurations.<host>)
#   $(2) = system.build.<attr>  (isoImage | diskoImages)
#   $(3) = extra module fields  (nix attrset body, may be empty)
#   $(4) = arch token           (empty = builder's native arch)
# The built image lives in /nix/store (always — that's how Nix works), but
# `--out-link` plants a GC-root symlink to it under ./out (named after the
# target, e.g. out/appliance-qcow2, out/appliance-raw-aarch64-linux). That's the
# native, non-copy way to surface the result in the repo: ./out/<link> points
# straight at the store path, and being a GC root it won't be garbage-collected.
# ./out is gitignored.
# The shared flake expression, factored out so box_build and box_instantiate
# can't drift apart. Selects `config.system.build` for the configured system;
# callers append the build attr (and, for instantiate, `.drvPath`). This is the
# per-arch override described above (always-pinned hostPlatform; native arch via
# currentSystem when no token is given; Makefile-injected coderBox.rev).
#   $(1) = host                 (nixosConfigurations.<host>)
#   $(2) = arch token           (empty = builder's native arch)
#   $(3) = extra module fields  (nix attrset body, may be empty)
box_cfg = let f = builtins.getFlake (toString ./.); in (f.nixosConfigurations.$(1).extendModules { modules = [ { nixpkgs.hostPlatform = "$(if $(2),$(call norm_arch,$(2)),$${builtins.currentSystem})"; coderBox.rev = "$(GIT_REV)"; $(3) } ]; }).config.system.build

define box_build
	@mkdir -p out
	$(NIX) build --impure --no-write-lock-file --print-out-paths \
	  --out-link 'out/$(subst /,-,$@)' --expr \
	  '$(call box_cfg,$(1),$(4),$(3)).$(2)'
endef

# ISO build helper: just box_build with the `isoImageDir` build product, which
# is the ISO bundled with its SHA-256 sidecar in one store output (see
# nixos/_images/base/iso.nix). So `--out-link` surfaces out/<target>/iso/ with
# both <name>.iso and <name>.iso.sha256, and a single `cp -L out/<target>/iso/*`
# copies them together. After the build we log each ISO's checksum. Same arg
# shape as box_build (callers pass $(2)=isoImageDir).
define box_iso
	$(call box_build,$(1),$(2),$(3),$(4))
	@for sha in 'out/$(subst /,-,$@)'/iso/*.iso.sha256; do cat "$$sha"; done
endef

# Disk-image build helper: box_build with the `diskoImagesDir` build product,
# which is the disk image bundled with its SHA-256 sidecar in one store output
# (see nixos/_images/base/disk.nix). So `--out-link` surfaces out/<target>/ with
# both <name>.<format> and <name>.<format>.sha256, and a single
# `cp -L out/<target>/*` copies them together. After the build we log each
# image's checksum. Same arg shape as box_build (callers pass $(2)=diskoImagesDir).
define box_disk
	$(call box_build,$(1),$(2),$(3),$(4))
	@for sha in 'out/$(subst /,-,$@)'/*.sha256; do cat "$$sha"; done
endef

# Instantiate-only counterpart to box_build: same flake expr, but evaluates
# `.drvPath` so Nix fully evaluates the config and writes the .drv to the store
# WITHOUT realising the (multi-GB) image. Cheap CI validation that the Nix is
# sound. Prints the resulting store .drv path. No ./out GC-root link: there's no
# built output to anchor, and the .drv itself is a GC root until next gc.
#   $(1) = host   $(2) = system.build.<attr>   $(3) = extra module fields   $(4) = arch token
define box_instantiate
	$(NIX) eval --impure --no-write-lock-file --raw --expr \
	  '$(call box_cfg,$(1),$(4),$(3)).$(2).drvPath'
	@echo
endef

.PHONY: installer/iso installer/drv appliance/iso appliance/drv appliance/qcow2 appliance/raw fmt fmt/check lint

# installer/iso is listed first so it's the default goal (bare `make`).

# ── installer/iso — installer ISO (hosts/_installer-iso); ISO only ────────────
installer/iso:
	$(call box_iso,_installer-iso,isoImageDir,,)
installer/iso/%:
	$(call box_iso,_installer-iso,isoImageDir,,$*)

# ── installer/drv — instantiate the installer ISO derivation (no build) ───────
installer/drv:
	$(call box_instantiate,_installer-iso,isoImage,,)
installer/drv/%:
	$(call box_instantiate,_installer-iso,isoImage,,$*)

# ── appliance/iso — ephemeral appliance ISO (hosts/_appliance-iso) ───────────
appliance/iso:
	$(call box_iso,_appliance-iso,isoImageDir,,)
appliance/iso/%:
	$(call box_iso,_appliance-iso,isoImageDir,,$*)

# ── appliance/drv — instantiate the appliance ISO derivation (no build) ───────
appliance/drv:
	$(call box_instantiate,_appliance-iso,isoImage,,)
appliance/drv/%:
	$(call box_instantiate,_appliance-iso,isoImage,,$*)

# ── appliance/qcow2 — persistent disk image (hosts/_appliance-disk) ──────────
appliance/qcow2:
	$(call box_disk,_appliance-disk,diskoImagesDir,disko.imageBuilder.imageFormat = "qcow2";,)
appliance/qcow2/%:
	$(call box_disk,_appliance-disk,diskoImagesDir,disko.imageBuilder.imageFormat = "qcow2";,$*)

# ── appliance/raw — persistent disk image, dd-able (hosts/_appliance-disk) ────
appliance/raw:
	$(call box_disk,_appliance-disk,diskoImagesDir,disko.imageBuilder.imageFormat = "raw";,)
appliance/raw/%:
	$(call box_disk,_appliance-disk,diskoImagesDir,disko.imageBuilder.imageFormat = "raw";,$*)

# ── fmt / fmt/check / lint — format & lint Nix + shell via treefmt ────────────
# All three drive the flake's `nix fmt` (treefmt) but select different tools
# with `-f` so formatting and linting stay separate (treefmt config lives in
# treefmt.nix):
#   * formatters: nixfmt, shfmt
#   * linters:    statix, deadnix, shellcheck
#
#   make fmt        format in place (writes files) — run before committing.
#   make fmt/check  format CHECK only (no writes); `--ci` fails with a diff if
#                   anything is unformatted. This is what the CI format job runs.
#   make lint       lint check only; `--ci` fails with a diff (statix/deadnix) or
#                   findings (shellcheck). This is what the CI lint job runs.
#
# `--ci` implies --no-cache + --fail-on-change, so the check targets never
# silently mutate the tree. Needs flakes + nix-command (the box_* helpers assume
# the same).
fmt:
	$(NIX) fmt -- -f nixfmt,shfmt
fmt/check:
	$(NIX) fmt -- --ci -f nixfmt,shfmt
lint:
	$(NIX) fmt -- --ci -f statix,deadnix,shellcheck
