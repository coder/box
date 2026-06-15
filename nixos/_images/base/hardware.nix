# Broad driver/firmware set so an image boots on arbitrary real hardware or
# virtual machines. Single source of `all-hardware.nix` for the _images tree:
# imported by both base/iso.nix and ../box-turnkey.nix. This replaces the
# per-host facter.json / hardware-configuration.nix that installed hosts rely
# on (image hosts ship neither).
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/all-hardware.nix") ];
}
