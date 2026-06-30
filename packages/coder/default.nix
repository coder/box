# coder — picks between the prebuilt release binary (default, fast) and
# a from-source build (slower, reproducible, supports patches and AGPL).
#
# fromSource=true forces buildGoModule. agplLicensed=true switches the
# subpackage to cmd/coder (AGPL) and implies fromSource since Coder only
# ships the enterprise binary on GitHub.
#
# Examples (in configuration.nix):
#
#   pkgs.callPackage ./packages/coder { channel = "mainline"; }
#   pkgs.callPackage ./packages/coder { channel = "mainline"; fromSource = true; }
#   pkgs.callPackage ./packages/coder { channel = "mainline"; agplLicensed = true; }
#
# Call ../coder-from-source directly to override buildGoModule / Go toolchain.

{
  callPackage,
  channel ? "stable",
  fromSource ? false,
  agplLicensed ? false,
}:

if fromSource || agplLicensed then
  callPackage ../coder-from-source { inherit channel agplLicensed; }
else
  callPackage ../coder-binary { inherit channel; }
