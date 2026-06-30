# Shared disk-image mechanics for every Coder box image that ships as a
# persistent disk image (qcow2 / raw). Mirrors base/iso.nix: that module bundles
# each ISO with a .sha256 sidecar in the (immutable) /nix/store; this one does
# the same for disko's disk images, so every shipped image — ISO or disk — gets
# a checksum the same way.
#
# Consumes disko's `config.system.build.diskoImages` (a store directory holding
# one `<imageName>.<format>` file per disk, see hosts/_appliance-disk) and
# exposes `config.system.build.diskoImagesDir`.
{ config, lib, pkgs, ... }:
{
  # A store output that bundles each disk image together with its SHA-256
  # checksum, so the checksum lives in the (immutable) /nix/store right beside
  # the image — exactly like base/iso.nix's isoImageDir does for ISOs. A plain
  # `nix build --out-link out/<target>` then surfaces both. The image is
  # symlinked (not copied) to avoid duplicating the multi-GB image; the
  # interpolation registers it as a runtime dependency so it is GC-rooted along
  # with this output. The checksum is written with the bare basename so
  # `sha256sum -c <name>.sha256` verifies the image sitting next to it, and a
  # single `cp -L out/<target>/*` copies image + sidecar together.
  system.build.diskoImagesDir = pkgs.runCommand "coder-box-disk-with-checksum" { } ''
    mkdir -p "$out"
    for img in ${config.system.build.diskoImages}/*; do
      base=$(basename "$img")
      ln -s "$img" "$out/$base"
      ( cd "$out" && sha256sum "$base" > "$base.sha256" )
    done
  '';
}
