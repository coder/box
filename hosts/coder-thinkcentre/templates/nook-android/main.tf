################################################################################
# Coder workspace template: nook-android
#
# A dev environment for building the trmnl-nook-simple-touch Android app for
# the Barnes & Noble Nook Simple Touch e-ink reader.
#
# Toolchain (baked into the pre-built image on the host):
#   - Eclipse Temurin JDK 8
#   - Legacy Android ADT bundle 2014 (android-20 SDK, 32-bit x86 tools)
#   - Apache Ant 1.8.3 (bundled with ADT)
#   - User: coder (uid 1000), passwordless sudo
#
# The image is pre-built on the thinkcentre host by the nook-android-image-build
# NixOS service and imported into k3s containerd as:
#   localhost/nook-android:latest
#
# binfmt: i686-linux (qemu-i386) is registered by boot.binfmt.emulatedSystems
# in configuration.nix so 32-bit ADT binaries run transparently inside the pod.
#
# Build command (inside workspace):
#   $ANT -Dbuild.compiler=modern clean debug
################################################################################

terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

# ── Providers ──────────────────────────────────────────────────────────────────

provider "kubernetes" {
  config_path = "/etc/rancher/k3s/k3s.yaml"
}

provider "coder" {}

# ── Data sources ───────────────────────────────────────────────────────────────

data "coder_provisioner"     "me" {}
data "coder_workspace"       "me" {}
data "coder_workspace_owner" "me" {}

# ── Variables ──────────────────────────────────────────────────────────────────

variable "coder_lan_ip" {
  type        = string
  default     = ""
  description = "LAN IP of the Coder server host, injected into pod hostAliases so workspaces can resolve the hostname without mDNS. Set via services.coder-nixos.lanIp in the host's local.nix."
}

variable "coder_hostname" {
  type        = string
  default     = "coder-thinkcentre"
  description = "Hostname of the Coder server (used for agent URL inside pods)."
}

# ── Parameters ─────────────────────────────────────────────────────────────────

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU cores"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true

  option {
    name  = "1 core"
    value = "1"
  }
  option {
    name  = "2 cores"
    value = "2"
  }
  option {
    name  = "4 cores"
    value = "4"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (GiB)"
  default      = "4"
  icon         = "/icon/memory.svg"
  mutable      = true

  option {
    name  = "2 GiB"
    value = "2"
  }
  option {
    name  = "4 GiB"
    value = "4"
  }
  option {
    name  = "8 GiB"
    value = "8"
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home disk (GiB)"
  default      = "10"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = false

  validation {
    min = 5
    max = 100
  }
}

# ── Locals ─────────────────────────────────────────────────────────────────────

locals {
  namespace = "coder-workspaces"
  owner     = lower(data.coder_workspace_owner.me.name)
  ws_name   = lower(data.coder_workspace.me.name)
  prefix    = "coder-${data.coder_workspace.me.id}"

  podman_socket_host = "/run/user/991/podman/podman.sock"
  docker_socket_pod  = "/var/run/docker.sock"

  coder_agent_url = "http://${var.coder_hostname}.local:3000"

  # Pre-built image tag — imported into k3s containerd by nook-android-image-build.service
  image = "localhost/nook-android:latest"

  # coder user home (uid 1000, matches other templates)
  home_dir = "/home/coder"

  # ADT environment (matches the Dockerfile ENV declarations)
  android_home = "/opt/adt/adt-bundle-linux-x86_64-20140702/sdk"
  ant_bin      = "/opt/adt/adt-bundle-linux-x86_64-20140702/eclipse/plugins/org.apache.ant_1.8.3.v201301120609/bin/ant"
}

# ── Coder agent ────────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  env = {
    CODER_AGENT_URL = local.coder_agent_url
    HOME            = local.home_dir
    ANDROID_HOME    = local.android_home
    ANT             = local.ant_bin

    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  startup_script = <<-EOT
    set -e

    # ── Expose coder binary (agent downloads it to a temp dir) ────────────────
    mkdir -p ~/.local/bin
    CODER_BIN=$(ls /tmp/coder.*/coder 2>/dev/null | head -1)
    if [ -n "$CODER_BIN" ]; then
      ln -sf "$CODER_BIN" ~/.local/bin/coder
    fi

    # ── Clone repo if not already present ─────────────────────────────────────
    if [ ! -d ~/trmnl-nook-simple-touch ]; then
      echo "Cloning trmnl-nook-simple-touch..."
      git clone --depth 1 https://github.com/usetrmnl/trmnl-nook-simple-touch.git \
        ~/trmnl-nook-simple-touch
    fi

    # ── Run setup.sh (idempotent: downloads SpongyCastle JARs + writes local.properties) ──
    if [ ! -f ~/trmnl-nook-simple-touch/libs/spongycastle-core-1.58.0.0.jar ]; then
      echo "Running setup.sh..."
      bash ~/trmnl-nook-simple-touch/.devcontainer/setup.sh
    fi

    echo "Ready. Build with: \$ANT -Dbuild.compiler=modern clean debug"
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "2_home_disk"
    script       = "coder stat disk --path ${local.home_dir}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "APK"
    key          = "3_apk"
    script       = "ls -sh ~/trmnl-nook-simple-touch/bin/*.apk 2>/dev/null | awk '{print $1}' || echo 'not built'"
    interval     = 60
    timeout      = 2
  }
}

# ── code-server module ─────────────────────────────────────────────────────────

module "code-server" {
  count   = data.coder_workspace.me.start_count
  source  = "registry.coder.com/coder/code-server/coder"
  version = "~> 1.0"

  agent_id = coder_agent.main.id
  order    = 1
}

# ── Persistent home PVC ────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "${local.prefix}-home"
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/name"    = "coder-pvc"
      "app.kubernetes.io/part-of" = "coder"
      "com.coder.resource"        = "true"
      "com.coder.workspace.id"    = data.coder_workspace.me.id
      "com.coder.workspace.name"  = data.coder_workspace.me.name
      "com.coder.user.id"         = data.coder_workspace_owner.me.id
      "com.coder.user.username"   = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  wait_until_bound = false

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }

  lifecycle {
    ignore_changes = all
  }
}

# ── Workspace pod ──────────────────────────────────────────────────────────────

resource "kubernetes_pod_v1" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "${local.prefix}-pod"
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/name"    = "coder-workspace"
      "app.kubernetes.io/part-of" = "coder"
      "com.coder.resource"        = "true"
      "com.coder.workspace.id"    = data.coder_workspace.me.id
      "com.coder.workspace.name"  = data.coder_workspace.me.name
      "com.coder.user.id"         = data.coder_workspace_owner.me.id
      "com.coder.user.username"   = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  spec {
    hostname = "${local.owner}-${local.ws_name}"

    security_context {
      run_as_user     = 1000
      run_as_group    = 1000
      fs_group        = 1000
      run_as_non_root = true
    }

    toleration {
      key      = "node-role.kubernetes.io/control-plane"
      operator = "Exists"
      effect   = "NoSchedule"
    }
    toleration {
      key      = "node-role.kubernetes.io/master"
      operator = "Exists"
      effect   = "NoSchedule"
    }

    host_aliases {
      ip        = var.coder_lan_ip != "" ? var.coder_lan_ip : "127.0.0.1"
      hostnames = ["coder-thinkcentre.local", "${var.coder_hostname}.local"]
    }

    # ── Volumes ────────────────────────────────────────────────────────────────

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
        read_only  = false
      }
    }

    volume {
      name = "podman-socket"
      host_path {
        path = local.podman_socket_host
        type = "Socket"
      }
    }

    # ── Container ──────────────────────────────────────────────────────────────

    container {
      name  = "workspace"
      image = local.image
      # Always use the locally-imported image — never pull from a remote registry
      image_pull_policy = "Never"

      command = ["sh", "-c", coder_agent.main.init_script]

      security_context {
        allow_privilege_escalation = false
        run_as_user                = 1000
        run_as_group               = 1000
        run_as_non_root            = true
      }

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      env {
        name  = "CODER_AGENT_URL"
        value = local.coder_agent_url
      }
      env {
        name  = "HOME"
        value = local.home_dir
      }
      env {
        name  = "ANDROID_HOME"
        value = local.android_home
      }
      env {
        name  = "ANT"
        value = local.ant_bin
      }

      volume_mount {
        name       = "home"
        mount_path = local.home_dir
        read_only  = false
      }

      volume_mount {
        name       = "podman-socket"
        mount_path = local.docker_socket_pod
        read_only  = false
      }

      resources {
        requests = {
          cpu    = "500m"
          memory = "1Gi"
        }
        limits = {
          cpu    = "${data.coder_parameter.cpu.value}"
          memory = "${data.coder_parameter.memory.value}Gi"
        }
      }
    }

    restart_policy = "OnFailure"
  }

  depends_on = [
    kubernetes_persistent_volume_claim_v1.home,
  ]
}
