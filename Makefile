# Coder box — image build targets.
#
# Requires Nix with flakes enabled (nix-command + flakes). All image builds run
# on Linux only; cross-arch builds need a matching builder (native remote
# builder or binfmt/QEMU emulation).
#
#   make live-ephemeral-iso              # live ISO (tmpfs overlay; state wiped on reboot)
#   make persistent-disk/qcow2           # persistent qcow2 disk image (state persists)
#   make persistent-disk/raw             # persistent raw disk image (dd-able to a drive)
#
# Each target also takes an architecture suffix; short names are normalized to
# a *-linux triple (e.g. aarch64 -> aarch64-linux):
#
#   make live-ephemeral-iso/x86_64-linux
#   make persistent-disk/qcow2/aarch64-linux
#   make persistent-disk/raw/aarch64
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
# so adding a flavour is just a thin target below — no duplicated nix plumbing.
#   $(1) = host (nixosConfigurations.<host>)
#   $(2) = system.build.<attr>  (isoImage | diskoImages)
#   $(3) = extra module fields  (nix attrset body, may be empty)
#   $(4) = arch token           (empty = builder's native arch)
define box_build
	$(NIX) build --impure --no-write-lock-file --print-out-paths --expr \
	  'let f = builtins.getFlake (toString ./.); in (f.nixosConfigurations.$(1).extendModules { modules = [ { $(if $(4),nixpkgs.hostPlatform = "$(call norm_arch,$(4))"; ) $(3) } ]; }).config.system.build.$(2)'
endef

.PHONY: live-ephemeral-iso persistent-disk/qcow2 persistent-disk/raw

# ── Live ephemeral ISO (hosts/live) ─────────────────────────────────────────
live-ephemeral-iso:
	$(call box_build,live,isoImage,,)
live-ephemeral-iso/%:
	$(call box_build,live,isoImage,,$*)

# ── Persistent disk image (hosts/persistent-disk), qcow2 ─────────────────────
persistent-disk/qcow2:
	$(call box_build,persistent-disk,diskoImages,disko.imageBuilder.imageFormat = "qcow2";,)
persistent-disk/qcow2/%:
	$(call box_build,persistent-disk,diskoImages,disko.imageBuilder.imageFormat = "qcow2";,$*)

# ── Persistent disk image (hosts/persistent-disk), raw (dd-able) ─────────────
persistent-disk/raw:
	$(call box_build,persistent-disk,diskoImages,disko.imageBuilder.imageFormat = "raw";,)
persistent-disk/raw/%:
	$(call box_build,persistent-disk,diskoImages,disko.imageBuilder.imageFormat = "raw";,$*)
