# terraform-binary.nix — fetches the official HashiCorp Terraform release zip
# instead of building from source.
#
# WHY: Terraform is BSL-licensed, so cache.nixos.org does NOT distribute it —
# `pkgs.terraform` builds the multi-GB Go project from source on every install.
# On the small-RAM/disk live USB that source build exhausts the build tmpdir
# ("no space left on device" while compiling). The official release binary is
# a single statically-linked Go executable (like the coder binary), so we fetch
# and install it directly — no compiler, no scratch space, works on arm64 too.
#
# This is wired in via a nixpkgs overlay in configuration.nix so every
# `pkgs.terraform` reference (coder's PATH wrapper, systemPackages, the
# template-deploy scripts) uses the prebuilt binary.
#
# Update: bump `version` and refresh both per-arch hashes with
#   nix store prefetch-file https://releases.hashicorp.com/terraform/<ver>/terraform_<ver>_linux_<arch>.zip

{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:

let
  # Keep in lockstep with the nixpkgs terraform version so behaviour matches
  # what the from-source package would have provided.
  version = "1.14.0";

  # GitHub/HashiCorp release asset arch suffix, keyed by Nix system.
  arch =
    {
      "x86_64-linux" = "amd64";
      "aarch64-linux" = "arm64";
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "terraform-binary.nix: unsupported system ${stdenvNoCC.hostPlatform.system}");

  hashes = {
    amd64 = "sha256-M6whdFi6i0TOKBNVMIO8EyyaB+QaecLjYnl3aC0oMJM=";
    arm64 = "sha256-I9Xps/QBTxj4XiQqWou69tMbBYox2TWA5f5dpkS/gBM=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "terraform";
  inherit version;

  src = fetchurl {
    url = "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_linux_${arch}.zip";
    hash = hashes.${arch};
  };

  nativeBuildInputs = [ unzip ];

  # The zip contains just `terraform` and `LICENSE.txt` — no subdirectory.
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    unzip "$src" -d "$TMPDIR/tf"
    install -Dm755 "$TMPDIR/tf/terraform" "$out/bin/terraform"
    runHook postInstall
  '';

  # Release binary is statically linked and stripped; don't touch it.
  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "Tool for building, changing, and versioning infrastructure (official release binary)";
    homepage = "https://www.terraform.io/";
    license = lib.licenses.bsl11;
    mainProgram = "terraform";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
