# coder-binary.nix — fetches the official Coder release tarball from GitHub.
# Statically linked Go (no glibc, no autoPatchelf), embeds the React frontend
# and slim CLI binaries for every workspace-agent platform.
#
# Use coder-from-source.nix if you need reproducibility, patching, or AGPL.

{ lib
, stdenvNoCC
, fetchurl
, installShellFiles
, makeBinaryWrapper
, terraform
, channel ? "stable"
}:

let
  # GitHub release asset arch suffix, keyed by Nix system. Coder publishes
  # `linux_amd64` and `linux_arm64` tarballs; map hostPlatform to the matching
  # one so the same channel definition builds on x86_64 and aarch64.
  arch =
    {
      "x86_64-linux"  = "amd64";
      "aarch64-linux" = "arm64";
    }.${stdenvNoCC.hostPlatform.system}
      or (throw "coder-binary.nix: unsupported system ${stdenvNoCC.hostPlatform.system}");

  # Per-channel version + per-arch tarball hash. Update hashes with:
  #   nix store prefetch-file https://github.com/coder/coder/releases/download/v<ver>/coder_<ver>_linux_<arch>.tar.gz
  channels = {
    stable = {
      version = "2.31.11";
      hashes  = {
        amd64 = "sha256-Ms8U7uzJYZDbxmtpZaO91WPq7MDYEaaQ4eC2WChISXk=";
        arm64 = "sha256-dnh5+xfN+BrdDLu4nUD/m/dxuEEh5fiV3o+rSnKm9wI=";
      };
    };
    mainline = {
      version = "2.33.1";
      hashes  = {
        amd64 = "sha256-OXNXEgb3GkyPQeiAwZZ++2DRd24x2SShernMGxpcCd0=";
        arm64 = "sha256-AKSt3Yh6mw/TIKK+4FKzquo69JtOvigfSyJK43f048g=";
      };
    };
    rc = {
      version = "2.34.0-rc.0";
      hashes  = {
        amd64 = "sha256-xAsy3ocdspSiJkdSBuHMva296hCCbbIL32bwvm2foR8=";
        arm64 = "sha256-2RlTQL9YiUjx2x2IlfBmM6bLz8MpQceA64PJ4URE4wU=";
      };
    };
  };
  inherit (channels.${channel}) version;
  hash = channels.${channel}.hashes.${arch};
in
stdenvNoCC.mkDerivation {
  pname   = "coder";
  inherit version;

  src = fetchurl {
    url  = "https://github.com/coder/coder/releases/download/v${version}/coder_${version}_linux_${arch}.tar.gz";
    inherit hash;
  };

  nativeBuildInputs = [ installShellFiles makeBinaryWrapper ];

  # Tarball layout: ./coder ./LICENSE ./LICENSE.enterprise ./README.md
  unpackPhase = ''
    runHook preUnpack
    tar -xzf $src
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 coder $out/bin/coder
    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion --cmd coder \
      --bash <($out/bin/coder completion bash) \
      --fish <($out/bin/coder completion fish) \
      --zsh  <($out/bin/coder completion zsh)
    wrapProgram $out/bin/coder \
      --prefix PATH : ${lib.makeBinPath [ terraform ]}
  '';

  # The release binary is already statically linked and stripped; running
  # patchelf or strip on it just slows the build and changes the BuildID.
  dontStrip    = true;
  dontPatchELF = true;

  meta = {
    description = "Provision remote development environments via Terraform";
    homepage    = "https://coder.com";
    license     = lib.licenses.unfreeRedistributable;
    mainProgram = "coder";
    platforms   = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
