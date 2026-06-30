# packages/sysbox-ce — sysbox-mgr and sysbox-fs extracted from the Sysbox CE .deb.
#
# Sysbox v0.6.7 CE is the latest released .deb (May 2025). It ships sysbox-mgr
# and sysbox-fs; sysbox-runc is built separately from source (see
# packages/sysbox-runc) because 0.7.0 is needed for the containerd 2.x
# `features` subcommand.
#
# nestybox publishes both linux_amd64 and linux_arm64 .debs; the one matching the
# build platform is selected automatically. Update hashes with:
#   nix store prefetch-file https://github.com/nestybox/sysbox/releases/download/v0.6.7/sysbox-ce_0.6.7.linux_<arch>.deb

{
  lib,
  stdenvNoCC,
  fetchurl,
  dpkg,
}:

let
  version = "0.6.7";

  arch =
    {
      "x86_64-linux" = "amd64";
      "aarch64-linux" = "arm64";
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "packages/sysbox-ce: unsupported system ${stdenvNoCC.hostPlatform.system}");

  debHashes = {
    amd64 = "sha256-t6w4nloZWSyt8W4Mow5AkZUWEo9uG3+Z4ctP9kVUFy4=";
    arm64 = "sha256-FtgBI7pTBYz5D1poaG4pdiHql5QmAmguNLM1J4OQj5E=";
  };

  deb = fetchurl {
    url = "https://github.com/nestybox/sysbox/releases/download/v${version}/sysbox-ce_${version}.linux_${arch}.deb";
    hash = debHashes.${arch};
  };

in

stdenvNoCC.mkDerivation {
  pname = "sysbox-ce";
  inherit version;

  src = deb;

  nativeBuildInputs = [ dpkg ];

  unpackPhase = ''
    dpkg-deb --extract $src unpacked
  '';

  installPhase = ''
    mkdir -p $out/bin
    install -m 0755 unpacked/usr/bin/sysbox-mgr  $out/bin/sysbox-mgr
    install -m 0755 unpacked/usr/bin/sysbox-fs   $out/bin/sysbox-fs
  '';

  # Binaries are statically linked — verified with readelf -d (no dynamic section).
  dontStrip = true;
  dontAutoPatchelf = true;

  meta = {
    description = "Sysbox CE ${version} — sysbox-mgr, sysbox-fs";
    homepage = "https://github.com/nestybox/sysbox";
    license = lib.licenses.asl20;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
