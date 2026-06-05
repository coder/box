# Coder box — build targets for the live "Box" ISO (hosts/live).
#
# Requires Nix with flakes enabled (nix-command + flakes).
#
#   make live-iso                  # build the live ISO for this machine's arch
#   make live-iso/x86_64-linux     # build an x86_64 live ISO
#   make live-iso/aarch64-linux    # build an aarch64 live ISO (EFI-only)
#
# Short arch names work too: `make live-iso/aarch64`, `make live-iso/x86_64`.
# Cross-arch builds need a suitable builder (native, a remote builder, or
# binfmt emulation); without one Nix will refuse to build a non-native ISO.
#
# The finished image lands in ./result/iso/coder-box-live-*.iso (the build
# prints the out-path). Flash it with e.g.
#   sudo dd if=result/iso/coder-box-live-*.iso of=/dev/sdX bs=4M status=progress oflag=sync

NIX      ?= nix
FLAKE    ?= .
ISO_ATTR  = config.system.build.isoImage

.PHONY: live-iso
live-iso:
	$(NIX) build '$(FLAKE)#nixosConfigurations.live.$(ISO_ATTR)' --print-out-paths

# Architecture-specific live ISO. `$*` is the part after the slash, e.g.
# "aarch64-linux" (or the short "aarch64"). We override nixpkgs.hostPlatform on
# the `live` host via extendModules so the same config builds for the requested
# architecture without adding a separate flake output per arch.
.PHONY: live-iso/%
live-iso/%:
	@arch="$*"; case "$$arch" in *-linux) ;; *) arch="$$arch-linux" ;; esac; \
	echo "Building live ISO for $$arch ..."; \
	$(NIX) build --impure --print-out-paths --expr \
	  "let f = builtins.getFlake (toString ./.); in (f.nixosConfigurations.live.extendModules { modules = [ { nixpkgs.hostPlatform = \"$$arch\"; } ]; }).$(ISO_ATTR)"
