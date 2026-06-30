# treefmt configuration — single source of truth for formatting and linting,
# consumed by the flake's `formatter` (`nix fmt`) and `checks.formatting`
# (`nix flake check`) outputs. See flake.nix.
#
# Nix:   nixfmt (RFC-style formatter) + statix (anti-pattern lints, autofixed)
#        + deadnix (dead-code removal).
# Shell: shfmt (formatter, 2-space indent to match the existing scripts) +
#        shellcheck (lint, check-only).
_: {
  # Anchors the project root for treefmt's file discovery.
  projectRootFile = "flake.nix";

  programs = {
    # Nix formatting (the official RFC 166 style).
    nixfmt.enable = true;
    # Nix linters. statix can autofix, deadnix prunes unused bindings/args.
    statix.enable = true;
    deadnix.enable = true;

    # Shell formatting. The existing scripts use 2-space indentation; keep it so
    # turning this on doesn't reflow everything to tabs.
    shfmt = {
      enable = true;
      indent_size = 2;
    };
    # Shell linting (check-only; does not modify files).
    shellcheck.enable = true;
  };

  settings.global.excludes = [
    # VCS / tooling metadata.
    ".git/**"
    # Generated / vendored lockfiles that must not be reformatted.
    "flake.lock"
    "*.terraform.lock.hcl"
    # Vendored archives and binary blobs.
    "*.tar.gz"
    "*.iso"
    "*.qcow2"
    "*.raw"
  ];
}
