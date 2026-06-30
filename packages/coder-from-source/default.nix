# coder-from-source.nix — build Coder from upstream source via buildGoModule.
# Slower than coder-binary.nix and needs ~16 GiB RAM (or swap) for the vite
# frontend bundle, but reproducible from a git rev. coder.nix selects this
# path when fromSource = true or agplLicensed = true.
#
# agplLicensed = false  →  enterprise/cmd/coder  +  unfreeRedistributable
# agplLicensed = true   →  cmd/coder            +  AGPL-3.0

{
  agplLicensed ? false,
  buildGoModule,
  channel ? "stable",
  fetchFromGitHub,
  fetchPnpmDeps,
  installShellFiles,
  lib,
  makeBinaryWrapper,
  nodejs_22,
  pnpmConfigHook,
  pnpm,
  stdenvNoCC,
  terraform,
  zstd,
}:

let
  pnpm_nodejs_22 = pnpm.override {
    nodejs = nodejs_22;
  };
  channels = {
    stable = rec {
      version = "2.31.11";
      src = fetchFromGitHub {
        owner = "coder";
        repo = "coder";
        rev = "v${version}";
        hash = "sha256-w174ZOgoeXloVBBLGm3cW75OxHHUemdmE2RBcDJyDqw=";
      };
      vendorHash = "sha256-mQOSe6xim6YH8zYPCJ8ncHKfYUImsb6oc4zk5B77oo8=";
      pnpmDepsHash = "sha256-JlbjDBeBtz7vA9Ol+NmUdNYROzop9C6vnoDEsJTp0W8=";
    };
    mainline = rec {
      version = "2.33.1";
      src = fetchFromGitHub {
        owner = "coder";
        repo = "coder";
        rev = "v${version}";
        hash = "sha256-wNPCwEvqB2mx/XN7Rm5E/jomcAWf70bWXjCTSo3CoV8=";
      };
      vendorHash = "sha256-3bLyx/lHLQKfx6902+pyM8f1IDNA1iuNk3FcQyKCUL4=";
      pnpmDepsHash = "sha256-6hES7O2SXmMuE4d2Yj5isQati9pMiv+O6C32AtH3PCI=";
    };
    rc = rec {
      version = "2.34.0-rc.0";
      src = fetchFromGitHub {
        owner = "coder";
        repo = "coder";
        rev = "v${version}";
        hash = "sha256-ibaR0ps+luMCtUpLf1KgDhwsrexC4MD+ZGKY7NG2Xmg=";
      };
      vendorHash = "sha256-3bLyx/lHLQKfx6902+pyM8f1IDNA1iuNk3FcQyKCUL4=";
      pnpmDepsHash = "sha256-6hES7O2SXmMuE4d2Yj5isQati9pMiv+O6C32AtH3PCI=";
    };
  };
  subPackage = if agplLicensed then "cmd/coder" else "enterprise/cmd/coder";
  omitTags = [
    "ts_omit_aws"
    "ts_omit_bird"
    "ts_omit_tap"
    "ts_omit_kube"
  ];
  mkSlimBinary =
    {
      goos,
      goarch,
      goarm,
      ...
    }:
    (buildGoModule rec {
      pname = "coder-slim-${goos}-${if goarm == "" then goarch else "${goarch}v${goarm}"}";
      inherit (channels.${channel}) version;
      inherit (channels.${channel}) src;
      inherit (channels.${channel}) vendorHash;
      subPackages = [ subPackage ];
      ldflags = [
        "-s"
        "-w"
        "-X=github.com/coder/coder/v2/buildinfo.tag=${version}"
      ]
      ++ lib.optional agplLicensed "-X=github.com/coder/coder/v2/buildinfo.agpl=true";
      tags = [ "slim" ] ++ omitTags;
      env = {
        GOOS = goos;
        GOARCH = goarch;
        GOARM = goarm;
        CGO_ENABLED = "0";
      };
      postBuild =
        lib.optionalString
          (
            goos != stdenvNoCC.hostPlatform.go.GOOS
            || goarch != stdenvNoCC.hostPlatform.go.GOARCH
            || goarm != stdenvNoCC.hostPlatform.go.GOARM
          )
          ''
            dir=$GOPATH/bin/''${GOOS}_''${GOARCH}
            if [[ -n "$(shopt -s nullglob; echo $dir/*)" ]]; then mv $dir/* $dir/..; fi
            if [[ -d $dir ]]; then rmdir $dir; fi
          '';
      doCheck = false;
    }).overrideAttrs
      (
        _: prev: {
          env = prev.env // {
            GOOS = goos;
            GOARCH = goarch;
            GOARM = goarm;
          };
        }
      );
  slimTargets = [
    "windows_amd64"
    "windows_arm64"
    "linux_amd64"
    "linux_arm64"
    "linux_arm_7"
    "darwin_amd64"
    "darwin_arm64"
  ];
  slimBinaries = map (
    target:
    let
      parts = lib.splitString "_" target;
      goos = builtins.elemAt parts 0;
      goarch = builtins.elemAt parts 1;
      goarm = lib.optionalString (builtins.length parts > 2) (builtins.elemAt parts 2);
    in
    rec {
      inherit target;
      extension = lib.optionalString (goos == "windows") ".exe";
      binary = "coder${extension}";
      outputPath = "coder-${goos}-${if goarm == "" then goarch else "${goarch}v${goarm}"}${extension}";
      pkg = mkSlimBinary { inherit goos goarch goarm; };
    }
  ) slimTargets;
  bundle = stdenvNoCC.mkDerivation {
    pname = "coder-slim-bundle";
    inherit (channels.${channel}) version;
    nativeBuildInputs = [ zstd ];
    unpackPhase = lib.concatStringsSep "\n" (
      [ "runHook preUnpack" ]
      ++ map (e: "cp ${e.pkg}/bin/${e.binary} ./${e.outputPath}") slimBinaries
      ++ [ "runHook postUnpack" ]
    );
    buildPhase = ''
      runHook preBuild
      sha1sum -b coder-* | tee coder.sha1
      tar cf coder.tar coder-*
      zstd -22 --ultra --force --long --no-progress -o coder.tar.zst coder.tar
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/share
      cp coder.{sha1,tar.zst} $out/share
      runHook postInstall
    '';
  };
in
buildGoModule rec {
  pname = "coder";
  inherit (channels.${channel}) version;
  inherit (channels.${channel}) src;

  frontend = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "coder-frontend";
    inherit version;
    src = "${src}/site";
    nativeBuildInputs = [
      nodejs_22
      pnpmConfigHook
      pnpm_nodejs_22
    ];
    buildPhase = ''
      runHook preBuild
      NODE_OPTIONS=--max-old-space-size=4096 pnpm build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp -r out $out
      runHook postInstall
    '';
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pnpm_nodejs_22;
      fetcherVersion = 3;
      hash = channels.${channel}.pnpmDepsHash;
    };
  });

  nativeBuildInputs = [
    installShellFiles
    makeBinaryWrapper
  ];
  inherit (channels.${channel}) vendorHash;
  subPackages = [ subPackage ];
  ldflags = [
    "-s"
    "-w"
    "-X=github.com/coder/coder/v2/buildinfo.tag=${version}"
  ]
  ++ lib.optional agplLicensed "-X=github.com/coder/coder/v2/buildinfo.agpl=true";
  tags = [ "embed" ] ++ omitTags;
  preBuild = ''
    cp -r ${frontend}/* site/out
    cp -r ${bundle}/share/* site/out/bin
  '';
  postInstall = ''
    installShellCompletion --cmd coder \
      --bash <($out/bin/coder completion bash) \
      --fish <($out/bin/coder completion fish) \
      --zsh  <($out/bin/coder completion zsh)
    wrapProgram $out/bin/coder \
      --prefix PATH : ${lib.makeBinPath [ terraform ]}
  '';
  doCheck = false;
  meta = {
    description = "Provision remote development environments via Terraform";
    homepage = "https://coder.com";
    license = if agplLicensed then lib.licenses.agpl3Only else lib.licenses.unfreeRedistributable;
    mainProgram = "coder";
    maintainers = with lib.maintainers; [
      ghuntley
      kylecarbs
    ];
  };
}
