# Coder box — appliance image build targets.
#
# An "appliance" is the box prebuilt as a bootable image (no install.sh):
# it boots straight into the fully-configured Coder box. Three formats:
#
#   make appliance/iso        # appliance ISO  (tmpfs overlay; state wiped on reboot)
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
# target, e.g. out/appliance-iso, out/appliance-raw-aarch64-linux). That's the
# native, non-copy way to surface the result in the repo: ./out/<link> points
# straight at the store path, and being a GC root it won't be garbage-collected.
# ./out is gitignored.
define box_build
	@mkdir -p out
	$(NIX) build --impure --no-write-lock-file --print-out-paths \
	  --out-link 'out/$(subst /,-,$@)' --expr \
	  'let f = builtins.getFlake (toString ./.); in (f.nixosConfigurations.$(1).extendModules { modules = [ { nixpkgs.hostPlatform = "$(if $(4),$(call norm_arch,$(4)),$${builtins.currentSystem})"; $(3) } ]; }).config.system.build.$(2)'
endef

.PHONY: appliance/iso appliance/qcow2 appliance/raw

# ── appliance/iso — ephemeral appliance ISO (hosts/_appliance_iso) ───────────
appliance/iso:
	$(call box_build,_appliance_iso,isoImage,,)
appliance/iso/%:
	$(call box_build,_appliance_iso,isoImage,,$*)

# ── appliance/qcow2 — persistent disk image (hosts/_appliance-disk) ──────────
appliance/qcow2:
	$(call box_build,_appliance-disk,diskoImages,disko.imageBuilder.imageFormat = "qcow2";,)
appliance/qcow2/%:
	$(call box_build,_appliance-disk,diskoImages,disko.imageBuilder.imageFormat = "qcow2";,$*)

# ── appliance/raw — persistent disk image, dd-able (hosts/_appliance-disk) ────
appliance/raw:
	$(call box_build,_appliance-disk,diskoImages,disko.imageBuilder.imageFormat = "raw";,)
appliance/raw/%:
	$(call box_build,_appliance-disk,diskoImages,disko.imageBuilder.imageFormat = "raw";,$*)
