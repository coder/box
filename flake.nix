{
  description = "NixOS configurations for Coder demo and workshop boxes.";

  inputs = {
    # Pinned nixpkgs release. Bump in lockstep with `nix flake update`.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # Declarative disk partitioning. The repo ships a single-disk UEFI
    # layout under nixos/disko-standard.nix that hosts can import.
    # install.sh runs `disko --mode disko` then `nixos-install`,
    # which builds the closure directly into /mnt/nix/store on the target
    # (avoids the tmpfs OOM that the `disko-install` one-shot hits on
    # small-RAM live USB sessions, see disko issue #942).
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Hardware detection. `nixos-facter -o facter.json` on the target writes
    # a JSON hardware report; nixos-facter-modules consumes it to set kernel
    # modules, microcode, GPU drivers, etc. Replaces hardware-configuration.nix
    # for common hardware.
    nixos-facter-modules.url = "github:nix-community/nixos-facter-modules";

    # One-stop formatter/linter runner. Drives nixfmt + statix + deadnix (Nix)
    # and shfmt + shellcheck (shell) from a single config (./treefmt.nix), and
    # exposes both `nix fmt` (apply) and a `nix flake check` formatting check
    # (verify). See treefmt.nix and .github/workflows/fmt.yml.
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      nixos-facter-modules,
      treefmt-nix,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      # treefmt config evaluated per system; drives `nix fmt` (the formatter
      # output) and the `formatting` flake check below.
      treefmtEval = forAllSystems (
        system: treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} ./treefmt.nix
      );

      # Architectures we expose install tooling (nixos-facter, disko) for.
      # install.sh invokes `nix run .#nixos-facter` / `.#disko`, which
      # resolve to the LIVE USB's own architecture. If that arch is missing
      # here the install aborts with e.g. "flake ... does not provide
      # attribute packages.aarch64-linux.nixos-facter". Keep both arm64 and
      # x86_64 so the repo installs on either.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;

      # ./hosts holds ONLY the hosts we manage centrally — our own real machines
      # plus the appliance/installer image builds we ship (see .gitignore, which
      # ignores user-dropped hosts). Each subdirectory that contains a default.nix
      # becomes a nixosConfigurations entry. For install hosts the folder name IS
      # the hostname, so `nixos-rebuild switch --flake .` auto-selects the right
      # config on the running box without needing `.#<attr>`. Adding a new host
      # means just creating ./hosts/<hostname>/default.nix; no flake.nix edit.
      # (Underscore-prefixed folders like _appliance-iso, _appliance-disk, and
      # _installer-iso are image builds that skip the folder-name hostname; see
      # mkHost below.)
      hostNames = lib.attrNames (
        lib.filterAttrs (
          name: type: type == "directory" && builtins.pathExists (./hosts + "/${name}/default.nix")
        ) (builtins.readDir ./hosts)
      );

      # The host's architecture is set via nixpkgs.hostPlatform (defaulted to
      # x86_64-linux in configuration.nix). An arm64 box just sets
      # `nixpkgs.hostPlatform = "aarch64-linux";` in its hosts/<name>/default.nix
      # (or local.nix) — no flake.nix edit needed.
      mkHost =
        hostname:
        lib.nixosSystem {
          specialArgs = { inherit inputs self; };
          modules = [
            ./configuration.nix
            disko.nixosModules.disko
            nixos-facter-modules.nixosModules.facter
            (./hosts + "/${hostname}")
          ]
          # Install hosts use their folder name as the hostname so
          # `nixos-rebuild switch --flake .` auto-selects the right config on the
          # running box. Underscore-prefixed folders (e.g. _appliance-iso,
          # _appliance-disk) are image/appliance builds whose names aren't valid
          # hostnames and aren't installed per-machine; they fall through to the
          # central default (networking.hostName = "coder-box" in
          # configuration.nix). mkDefault here (1000) overrides that central
          # mkOptionDefault (1500) for install hosts.
          ++ lib.optional (!lib.hasPrefix "_" hostname) { networking.hostName = lib.mkDefault hostname; };
        };
    in
    {
      nixosConfigurations = lib.genAttrs hostNames mkHost;

      # Re-exported so install.sh can invoke them via the flake's
      # pinned nixpkgs (one nixpkgs fetch on the live USB, used by every
      # nix command in the install). Avoids the tmpfs OOM that comes from
      # `nix run nixpkgs#...` fetching the channel's nixpkgs in parallel.
      # Exposed per-arch so the install works on both x86_64 and aarch64
      # live USBs.
      packages = forAllSystems (system: {
        inherit (nixpkgs.legacyPackages.${system}) nixos-facter;
        inherit (disko.packages.${system}) disko;
      });

      # `nix fmt` formats/lints the whole tree (nixfmt + statix + deadnix +
      # shfmt; shellcheck runs as a check-only step). Config lives in
      # ./treefmt.nix.
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      # `nix flake check` verifies the tree is already formatted/lint-clean
      # (fails with a diff if not). CI runs this; see .github/workflows/fmt.yml.
      checks = forAllSystems (system: {
        formatting = treefmtEval.${system}.config.build.check self;
      });
    };
}
