# Coder box — appliance image build targets.
#
# An "appliance" is the box prebuilt as a bootable image (no nixos/install.sh):
# it boots straight into the fully-configured Coder box. Three formats:
#
#   make appliance/iso        # live ISO  (tmpfs overlay; state wiped on reboot)
#   make appliance/qcow2      # disk image (persistent; boots in QEMU/libvirt)
#   make appliance/raw        # disk image (persistent; dd-able to a drive)
#
# Each format also takes an architecture suffix; short names are normalized to
# a *-linux triple (e.g. aarch64 -> aarch64-linux):
#
#   make appliance/iso/x86_64-linux
#   make appliance/qcow2/aarch64-linux
#   make appliance/raw/aarch64
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

# Normalize an arch token to a *-linux triple: $(call norm_arch,aarch64) -> aarch64-linux
norm_arch = $(if $(filter %-linux,$(1)),$(1),$(1)-linux)

# Single build helper used by every target. extendModules lets us override
# nixpkgs.hostPlatform (per-arch) and the disko image format from one recipe,
# so adding a format/arch is just a thin target below — no duplicated nix
# plumbing.
#   $(1) = host (nixosConfigurations.<host>)
#   $(2) = system.build.<attr>  (isoImage | diskoImages)
#   $(3) = extra module fields  (nix attrset body, may be empty)
#   $(4) = arch token           (empty = builder's native arch)
define box_build
	$(NIX) build --impure --no-write-lock-file --print-out-paths --expr \
	  'let f = builtins.getFlake (toString ./.); in (f.nixosConfigurations.$(1).extendModules { modules = [ { $(if $(4),nixpkgs.hostPlatform = "$(call norm_arch,$(4))"; ) $(3) } ]; }).config.system.build.$(2)'
endef

.PHONY: appliance/iso appliance/qcow2 appliance/raw

# ── appliance/iso — live ephemeral ISO (hosts/live) ──────────────────────────
appliance/iso:
	$(call box_build,live,isoImage,,)
appliance/iso/%:
	$(call box_build,live,isoImage,,$*)

# ── appliance/qcow2 — persistent disk image (hosts/persistent-disk) ──────────
appliance/qcow2:
	$(call box_build,persistent-disk,diskoImages,disko.imageBuilder.imageFormat = "qcow2";,)
appliance/qcow2/%:
	$(call box_build,persistent-disk,diskoImages,disko.imageBuilder.imageFormat = "qcow2";,$*)

# ── appliance/raw — persistent disk image, dd-able (hosts/persistent-disk) ────
appliance/raw:
	$(call box_build,persistent-disk,diskoImages,disko.imageBuilder.imageFormat = "raw";,)
appliance/raw/%:
	$(call box_build,persistent-disk,diskoImages,disko.imageBuilder.imageFormat = "raw";,$*)
