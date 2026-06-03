# nook-android — TRMNL Nook Simple Touch Dev Environment

Workspace for building the [trmnl-nook-simple-touch](https://github.com/usetrmnl/trmnl-nook-simple-touch) Android app — a TRMNL e-ink display client for the Barnes & Noble Nook Simple Touch.

## Toolchain

| Component | Version / Detail |
|---|---|
| JDK | Eclipse Temurin 8 |
| Android SDK | ADT bundle 2014-07-02 (android-20 platform, api-7 target) |
| Build system | Apache Ant 1.8.3 (bundled with ADT) |
| TLS libs | SpongyCastle 1.58.0.0 (TLS 1.2 on Android 2.1) |
| ADT arch | 32-bit x86 ELFs — run via qemu-i386 binfmt on the host |

## How It Works

The image is pre-built on the thinkcentre host by the `nook-android-image-build` NixOS service, then imported into k3s containerd as `localhost/nook-android:latest`. The pod uses `imagePullPolicy: Never` so it never tries to fetch from a remote registry.

On workspace start the startup script:
1. Clones the repo into `~/trmnl-nook-simple-touch` (first run only)
2. Runs `.devcontainer/setup.sh` to download SpongyCastle JARs and write `local.properties`
3. Runs `$ANT -Dbuild.compiler=modern clean <build_type>` (unless "No auto-build" is selected)

## Build Commands

```sh
# Debug APK (default)
$ANT -Dbuild.compiler=modern clean debug

# Release APK (needs a keystore configured in ant.properties)
$ANT -Dbuild.compiler=modern clean release

# Output
ls bin/*.apk
```

## ADB / Flashing

Connect the Nook via USB to the thinkcentre. The Podman socket is bind-mounted into the workspace as `/var/run/docker.sock` but ADB requires direct USB access — use the host's ADB or run it from the workspace if USB passthrough is configured.

```sh
# Check connected devices (from workspace, if USB forwarded)
$ANDROID_HOME/platform-tools/adb devices

# Install debug APK
$ANDROID_HOME/platform-tools/adb install bin/NookSimpleTouch-debug.apk
```

## Host Requirements (thinkcentre only)

- `boot.binfmt.emulatedSystems = ["i686-linux"]` in `configuration.nix` — registers qemu-i386 so ADT's 32-bit binaries run transparently
- `nook-android-image-build.service` — builds and imports the image on first boot / after config changes
