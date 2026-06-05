terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

variable "coder_hostname" {
  type        = string
  default     = "coder-thinkcentre"
  description = "Hostname of the Coder server (used for hostAliases inside pods)."
}

variable "coder_lan_ip" {
  type        = string
  default     = ""
  description = "LAN IP of the Coder server host, injected into pod hostAliases so workspaces can resolve the hostname without mDNS. Set via services.coder-nixos.lanIp in the host's local.nix."
}

# ── Provider config ───────────────────────────────────────────────────
provider "kubernetes" {
  config_path = "/etc/rancher/k3s/k3s.yaml"
}

provider "coder" {}

# ── Workspace data ───────────────────────────────────────────────────
data "coder_provisioner"     "me" {}
data "coder_workspace"       "me" {}
data "coder_workspace_owner" "me" {}

locals {
  namespace = "coder-workspaces"
  owner     = lower(data.coder_workspace_owner.me.name)
  ws_name   = lower(data.coder_workspace.me.name)
  prefix    = "coder-${data.coder_workspace.me.id}"
  pod_name  = "${local.prefix}-pod"
  kubectl   = "/run/current-system/sw/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
}

# ── Parameters ────────────────────────────────────────────────────
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

# ── Coder agent ─────────────────────────────────────────────────────
resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  env = {
    CODER_AGENT_URL     = "http://10.42.0.1:3000"
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
    DOCKER_HOST         = "unix:///var/run/docker.sock"
  }

  startup_script = <<-EOT
    set -e

    # Start dockerd via sudo.
    # sysbox provides an isolated user namespace — root inside is unprivileged on host.
    if ! pgrep -x dockerd > /dev/null; then
      sudo dockerd > /tmp/dockerd.log 2>&1 &
    fi

    # Wait for Docker socket (up to 30 s)
    for i in $(seq 1 30); do
      [ -S /var/run/docker.sock ] && break
      sleep 1
    done
    echo "Docker socket: $(ls -la /var/run/docker.sock 2>&1)"

    # First-run setup
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~/ 2>/dev/null || true
      touch ~/.init_done
    fi

    # Clone git repo if provided
    REPO_URL="${data.coder_parameter.repo_url.value}"
    if [ -n "$REPO_URL" ]; then
      REPO_DIR=$(basename "$REPO_URL" .git)
      if [ ! -d ~/$"$REPO_DIR" ]; then
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
    display_name = "Memory Usage (Host)"
    key          = "4_mem_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "5_load_host"
    script       = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval     = 60
    timeout      = 1
  }
}

# ── VS Code Web ────────────────────────────────────────────────────────
module "vscode-web" {
  count          = data.coder_workspace.me.start_count
  source         = "registry.coder.com/coder/vscode-web/coder"
  version    = "~> 1.0"
  agent_id   = coder_agent.main.id
  display_name   = "VS Code Web"
  slug           = "vscode-web"
  subdomain      = true
  accept_license = true
  folder     = "/home/coder"
  order          = 1
}

# ── Cursor ───────────────────────────────────────────────────────────
module "cursor" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/cursor/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  folder   = "/home/coder"
  order    = 2
}

# ── JetBrains (Toolbox) ──────────────────────────────────────────────────────
module "jetbrains" {
  count          = data.coder_workspace.me.start_count
  source     = "registry.coder.com/coder/jetbrains/coder"
  version    = "~> 1.0"
  agent_id   = coder_agent.main.id
  agent_name = "main"
  folder     = "/home/coder"
  options    = ["IU", "PY", "WS", "GO", "RR", "CL"]
  default    = []
  coder_app_order = 3
}

# ── Persistent home PVC ───────────────────────────────────────────────
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
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = { storage = "${data.coder_parameter.home_disk_size.value}Gi" }
    }
  }
}

# ── Workspace pod (kubectl) ────────────────────────────────────────────────
#
# kubernetes_pod_v1 lacks hostUsers (needed for sysbox user-namespace isolation).
# kubernetes_manifest has a provider bug (TF #2818) that errors on volumes after apply.
#
# Workaround: use terraform_data + local-exec to kubectl apply/delete the pod.
# Store kubectl + pod_name in triggers_replace so destroy provisioner can access them.
#
# hostUsers: false  — kubelet user-namespace isolation (sysbox-runc 0.7.0+).
# runtimeClassName  — sysbox-runc provides inner Docker at /var/run/docker.sock.
# No runAsUser      — runs as uid 1000 (coder); dockerd started via sudo.
resource "terraform_data" "workspace" {
  count = data.coder_workspace.me.start_count

  depends_on = [kubernetes_persistent_volume_claim_v1.home]

  lifecycle {
    replace_triggered_by = [coder_agent.main.token]
  }

  # Store values needed by destroy provisioner (can't access locals in destroy).
  triggers_replace = [
    local.kubectl,
    local.pod_name,
    local.namespace,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    # POD_JSON is set via environment{} so no shell heredoc needed.
    # printf is used (not echo) to handle the JSON safely without newline issues.
    command = "printf '%s' \"$POD_JSON\" | ${local.kubectl} apply -f -"
    environment = {
      POD_JSON = jsonencode({
        apiVersion = "v1"
        kind       = "Pod"
        metadata = {
          name      = local.pod_name
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
        spec = {
          runtimeClassName = "sysbox-runc"
          hostUsers        = false
          restartPolicy    = "OnFailure"
          hostname         = "${local.owner}-${local.ws_name}"
          hostAliases = length(var.coder_lan_ip) > 0 ? [{
            ip        = var.coder_lan_ip
            hostnames = [var.coder_hostname]
          }] : []
          containers = [{
            name             = "workspace"
            image            = data.coder_parameter.image.value
            imagePullPolicy  = "IfNotPresent"
            command          = ["sh", "-c", coder_agent.main.init_script]
            env = [
              { name = "CODER_AGENT_TOKEN", value = coder_agent.main.token },
              { name = "CODER_AGENT_URL",   value = "http://10.42.0.1:3000" },
              { name = "DOCKER_HOST",       value = "unix:///var/run/docker.sock" },
            ]
            resources = {
              requests = { cpu = "250m", memory = "512Mi" }
              limits = {
                cpu    = data.coder_parameter.cpu.value
                memory = "${data.coder_parameter.memory.value}Gi"
              }
            }
            volumeMounts = [{
              name      = "home"
              mountPath = "/home/coder"
              readOnly  = false
            }]
          }]
          volumes = [{
            name = "home"
            persistentVolumeClaim = {
              claimName = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
              readOnly  = false
            }
          }]
        }
      })
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/sh", "-c"]
    # triggers_replace[0]=kubectl, [1]=pod_name, [2]=namespace
    command     = "${self.triggers_replace[0]} delete pod ${self.triggers_replace[1]} -n ${self.triggers_replace[2]} --ignore-not-found=true --wait=false"
  }
}
