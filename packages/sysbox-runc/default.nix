# packages/sysbox-runc — builds sysbox-runc 0.7.0 from the nestybox/sysbox monorepo.
#
# WHY NOT buildGoModule / go mod vendor FROM SCRATCH
# ───────────────────────────────────────────────────
# sysbox-runc's go.mod uses `replace` directives for sibling submodules
# (../sysbox-ipc, ../sysbox-libs/*). The sysbox-ipc module contains generated
# protobuf packages (sysboxFsProtobuf, sysboxMgrProtobuf) that are not
# registered in the Go module proxy — they only exist in the git tree.
# `go mod vendor` therefore fails in any sandboxed fixed-output derivation
# that fetches from the proxy.
#
# SOLUTION: vendor dir pre-built on the target machine and stored in the repo
# ─────────────────────────────────────────────────────────────────────────────
# The vendor dir was produced by running (on the target machine):
#
#   git clone --depth=1 https://github.com/nestybox/sysbox /tmp/sysbox-build
#   cd /tmp/sysbox-build
#   git submodule update --init sysbox-runc sysbox-libs sysbox-ipc
#   cd sysbox-runc
#   GOPATH=/tmp/gopath go mod vendor   # uses cached nestybox modules
#   cd .. && tar czf sysbox-runc-vendor-0.7.0.tar.gz sysbox-runc/vendor/
#
# The tarball is stored at packages/sysbox-runc/sysbox-runc-vendor-0.7.0.tar.gz (5.1 MB).
# It contains vendor/ and is extracted into sysbox-runc/ at build time.
#
# TO UPDATE FOR A NEW VERSION
# ────────────────────────────
#   1. Rebuild the vendor tarball on the target machine using the steps above.
#   2. Replace packages/sysbox-runc/sysbox-runc-vendor-<version>.tar.gz with the new tarball.
#   3. Update `version` and `src.rev` / `src.hash` below.
#   4. Run: sudo nixos-rebuild switch

{
  lib,
  stdenv,
  fetchFromGitHub,
  go,
  pkg-config,
  libseccomp,
  autoPatchelfHook,
}:

let
  version = "0.7.0";

  src = fetchFromGitHub {
    owner = "nestybox";
    repo = "sysbox";
    rev = "v${version}";
    hash = "sha256-zcN42LSBxBROPi49gdW+PPuIfnMHVmNhYzuBhs3Nc5U=";
    fetchSubmodules = true;
  };

  # Pre-built vendor directory stored in the repo to work around the Go module
  # proxy issue described above.  builtins.path copies it into the Nix store.
  vendorTarball = builtins.path {
    name = "sysbox-runc-vendor-0.7.0.tar.gz";
    path = ./sysbox-runc-vendor-0.7.0.tar.gz;
  };

in

stdenv.mkDerivation {
  pname = "sysbox-runc";
  inherit version src;

  nativeBuildInputs = [
    go
    pkg-config
    autoPatchelfHook
  ];
  buildInputs = [ libseccomp ];

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    export GOPATH=$TMPDIR/go

    # Extract pre-built vendor dir into sysbox-runc/ then build.
    tar xzf ${vendorTarball} -C sysbox-runc/
    cd sysbox-runc
    go build \
      -mod=vendor \
      -buildvcs=false \
      -trimpath \
      -tags "seccomp apparmor idmapped_mnt" \
      -ldflags "-X 'main.edition=CE' -X main.version=${version}" \
      -o ../sysbox-runc-bin \
      .
    cd ..
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 sysbox-runc-bin $out/bin/sysbox-runc
    runHook postInstall
  '';

  doCheck = false;

  meta = {
    description = "sysbox-runc ${version} — OCI runtime fork with features subcommand for containerd 2.x / user namespace support";
    homepage = "https://github.com/nestybox/sysbox";
    license = lib.licenses.asl20;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
