# coderd-provider.nix — packages the pre-built terraform-provider-coderd binary
# from GitHub releases into a filesystem-mirror layout that Terraform understands.
#
# The derivation installs the binary at (arch matches the build platform):
#   $out/registry.terraform.io/coder/coderd/0.0.16/linux_<amd64|arm64>/terraform-provider-coderd_v0.0.16
#
# This path matches Terraform's filesystem_mirror convention so that no network
# access is needed during `terraform init`.
#
# To update a hash, prefetch the matching arch zip:
#   nix store prefetch-file \
#     https://github.com/coder/terraform-provider-coderd/releases/download/v0.0.16/terraform-provider-coderd_0.0.16_linux_<arch>.zip
# and replace the corresponding entry in `hashes` below.

{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:

let
  version = "0.0.16";

  # GitHub release asset arch suffix, keyed by Nix system. The provider ships
  # `linux_amd64` and `linux_arm64` zips; map hostPlatform to the matching one
  # so the same definition builds on x86_64 and aarch64. The Terraform
  # filesystem_mirror directory must also match the running platform.
  arch =
    {
      "x86_64-linux" = "amd64";
      "aarch64-linux" = "arm64";
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "coderd-provider.nix: unsupported system ${stdenvNoCC.hostPlatform.system}");

  # Per-arch zip hash. Update with:
  #   nix store prefetch-file https://github.com/coder/terraform-provider-coderd/releases/download/v<ver>/terraform-provider-coderd_<ver>_linux_<arch>.zip
  hashes = {
    amd64 = "sha256-5jeh6fDyHSCpSGsUovFPbERTGWrC+Zvl/dG/IUogFuM=";
    arm64 = "sha256-nVrDr8+LEzy46z0sGqojnxd6uakWZOT6jln+ugS+cmo=";
  };

  providerDir = "registry.terraform.io/coder/coderd/${version}/linux_${arch}";
  binaryName = "terraform-provider-coderd_v${version}";
in
stdenvNoCC.mkDerivation {
  pname = "terraform-provider-coderd";
  inherit version;

  src = fetchurl {
    url = "https://github.com/coder/terraform-provider-coderd/releases/download/v${version}/terraform-provider-coderd_${version}_linux_${arch}.zip";
    hash = hashes.${arch};
  };

  nativeBuildInputs = [ unzip ];

  # The zip contains just the binary — no subdirectory.
  # Disable the default unpack phase and handle it manually.
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    unzip "$src" -d "$TMPDIR/provider"
    install -Dm755 "$TMPDIR/provider/${binaryName}" \
      "$out/${providerDir}/${binaryName}"
    runHook postInstall
  '';

  meta = {
    description = "Terraform provider for managing Coder deployments";
    homepage = "https://github.com/coder/terraform-provider-coderd";
    license = lib.licenses.asl20;
  };
}
