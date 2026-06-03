################################################################################
# Coder workspace template: k3s + Podman socket (docker-in-workspaces)
#
# How it works:
#   1. k3s (enabled by k3s-podman.nix) schedules workspace pods on the local
#      node using its built-in containerd runtime.
#   2. The host's rootless Podman socket (/run/user/991/podman/podman.sock) is
#      bind-mounted into each workspace pod as /var/run/docker.sock.
#   3. DOCKER_HOST is set inside the pod so `docker` CLI "just works".
#   4. No privileged mode required.
#
# Prerequisites on the host (handled by k3s-podman.nix + configuration.nix):
#   - services.coder-nixos.k3s.enable = true   (in the host's local.nix)
#   - imports = [ ./k3s-podman.nix ]           (in configuration.nix)
#   - KUBECONFIG=/etc/rancher/k3s/k3s.yaml readable by coder group
#   - /run/user/991/podman/podman.sock chmod 0666 (coder-podman-socket-fix)
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
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

# ── Providers ──────────────────────────────────────────────────────────────────

provider "kubernetes" {
  # k3s-podman.nix injects KUBECONFIG into coder.service environment.
  # Explicit path also works when running `terraform plan` from CLI.
  config_path = "/etc/rancher/k3s/k3s.yaml"
}

provider "coder" {}

# ── Data sources ───────────────────────────────────────────────────────────────

data "coder_provisioner"    "me" {}
data "coder_workspace"      "me" {}
data "coder_workspace_owner" "me" {}

# ── Parameters ─────────────────────────────────────────────────────────────────

data "coder_parameter" "image" {
  name         = "image"
  display_name = "Container image"
  description  = "Base image for the workspace. Rebuild required to change."
  default      = "codercom/enterprise-base:ubuntu"
  icon         = "/icon/docker.svg"
  mutable      = false

  option {
    icon  = "/icon/coder.svg"
    name  = "Universal (Coder base)"
    value = "codercom/enterprise-base:ubuntu"
  }
  option {
    icon  = "/icon/python.svg"
    name  = "Python 3.12"
    value = "mcr.microsoft.com/devcontainers/python:3.12"
  }
  option {
    icon  = "/icon/go.svg"
    name  = "Go 1.22"
    value = "mcr.microsoft.com/devcontainers/go:1.22"
  }
  option {
    icon  = "/icon/java.svg"
    name  = "Java 21"
    value = "mcr.microsoft.com/devcontainers/java:21"
  }
  option {
    icon  = "/icon/node.svg"
    name  = "Node.js 20"
    value = "mcr.microsoft.com/devcontainers/javascript-node:20"
  }
  option {
    icon  = "/icon/rust.svg"
    name  = "Rust (latest)"
    value = "mcr.microsoft.com/devcontainers/rust:latest"
  }
}

data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Git repository URL"
  description  = "Repository to clone into the home directory on first start. Leave blank to skip."
  default      = ""
  icon         = "/icon/git.svg"
  mutable      = true
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU cores"
  description  = "CPU limit for the workspace pod."
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
  option {
    name  = "8 cores"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (GiB)"
  description  = "Memory limit for the workspace pod."
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
  option {
    name  = "12 GiB"
    value = "12"
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home disk (GiB)"
  description  = "Persistent home volume size."
  default      = "20"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = false

  validation {
    min = 5
    max = 200
  }
}

# ── Locals ─────────────────────────────────────────────────────────────────────

locals {
  namespace  = "coder-workspaces"
  owner      = lower(data.coder_workspace_owner.me.name)
  ws_name    = lower(data.coder_workspace.me.name)
  prefix     = "coder-${data.coder_workspace.me.id}"

  # The rootless Podman socket path on the node (host UID 991 = coder user).
  podman_socket_host = "/run/user/991/podman/podman.sock"
  docker_socket_pod  = "/var/run/docker.sock"

  # Agent URL — pods can't use localhost; they resolve the host by hostname.
  coder_agent_url = "http://10.42.0.1:3000"
}

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


# ── Coder agent ────────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  env = {
    CODER_AGENT_URL = local.coder_agent_url
    DOCKER_HOST     = "unix://${local.docker_socket_pod}"

    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  startup_script = <<-EOT
    set -e
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~/ 2>/dev/null || true
      grep -qxF "export DOCKER_HOST=unix://${local.docker_socket_pod}" ~/.bashrc \
        || echo "export DOCKER_HOST=unix://${local.docker_socket_pod}" >> ~/.bashrc
      touch ~/.init_done
    fi

    # Clone git repo if provided
    REPO_URL="${data.coder_parameter.repo_url.value}"
    if [ -n "$REPO_URL" ]; then
      REPO_DIR=$(basename "$REPO_URL" .git)
      if [ ! -d ~/"$REPO_DIR" ]; then
        echo "Cloning $REPO_URL..."
        git clone "$REPO_URL" ~/"$REPO_DIR"
      fi
    fi
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
    script       = "coder stat disk --path $HOME"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "3_cpu_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage (Host)"
    key          = "4_ram_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "5_load_host"
    script       = <<-EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval     = 60
    timeout      = 1
  }
}

# ── VS Code Web ────────────────────────────────────────────────────────────────
module "vscode-web" {
  count          = data.coder_workspace.me.start_count
  source         = "registry.coder.com/coder/vscode-web/coder"
  version        = "~> 1.0"
  agent_id       = coder_agent.main.id
  display_name   = "VS Code Web"
  slug           = "vscode-web"
  subdomain      = true
  accept_license = true
  folder         = "/home/coder"
  order          = 1
}

# ── Cursor ─────────────────────────────────────────────────────────────────────
module "cursor" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/cursor/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  folder   = "/home/coder"
  order    = 2
}

# ── JetBrains (Toolbox) ───────────────────────────────────────────────────────
module "jetbrains" {
  count      = data.coder_workspace.me.start_count
  source     = "registry.coder.com/coder/jetbrains/coder"
  version    = "~> 1.0"
  agent_id   = coder_agent.main.id
  agent_name = "main"
  folder     = "/home/coder"
  options    = ["IU", "PY", "WS", "GO", "RR", "CL"]
  default    = []
  coder_app_order = 3
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
    storage_class_name = "local-path"   # k3s default provisioner
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

    # Pod-level security: run as the coder user (UID 1000 in enterprise-base).
    security_context {
      run_as_user  = 1000
      run_as_group = 1000
      fs_group     = 1000
    }

    # k3s single-node: control-plane is also a worker; tolerate its taint.
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

    # Resolve the Coder server hostname inside the pod.

    # ── Volumes ──────────────────────────────────────────────────────────────

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
        read_only  = false
      }
    }

    # Bind-mount the host's rootless Podman socket so `docker` works inside
    # the pod without privileged mode.  chmod 0666 is set by coder-podman-
    # socket-fix (k3s-podman.nix).
    volume {
      name = "podman-socket"
      host_path {
        path = local.podman_socket_host
        type = "Socket"
      }
    }

    # ── Container ────────────────────────────────────────────────────────────

    container {
      name              = "workspace"
      image             = data.coder_parameter.image.value
      image_pull_policy = "IfNotPresent"

      command = ["sh", "-c", coder_agent.main.init_script]

      security_context {
        # allow_privilege_escalation needed for the coder agent to fork.
        allow_privilege_escalation = true
        run_as_user                = 1000
        run_as_group               = 1000
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
        name  = "DOCKER_HOST"
        value = "unix://${local.docker_socket_pod}"
      }

      volume_mount {
        name       = "home"
        mount_path = "/home/coder"
        read_only  = false
      }

      volume_mount {
        name       = "podman-socket"
        mount_path = local.docker_socket_pod
        read_only  = false
      }

      resources {
        requests = {
          cpu    = "250m"
          memory = "512Mi"
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

  lifecycle {
    replace_triggered_by = [coder_agent.main.token]
  }
}
