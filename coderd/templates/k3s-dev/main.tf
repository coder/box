################################################################################
# Coder workspace template: k3s-dev
#
# Demo-focused workspace. Choose a language and either:
#   • Demo app (default) — auto-starts a real web app for that language
#   • Your repo         — clones a git URL instead, no demo app started
#
# Demo apps per language:
#   Python  → FastAPI "Hello World" on port 8000
#   Node.js → Next.js scaffolded app on port 3000
#   Go      → mikestefanello/pagoda (SQLite) on port 8000
#   Java    → Spring PetClinic (H2 in-memory) on port 8080
#   Rust    → rustypaste file-paste server on port 8000
#
# Built on k3s + Podman socket.
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

data "coder_parameter" "language" {
  name         = "language"
  display_name = "Language"
  description  = "Container image and language toolchain for the workspace."
  default      = "python"
  icon         = "/icon/code.svg"
  mutable      = false
  order        = 1

  option {
    icon  = "/icon/python.svg"
    name  = "Python"
    value = "python"
  }
  option {
    icon  = "/icon/node.svg"
    name  = "Node.js"
    value = "nodejs"
  }
  option {
    icon  = "/icon/go.svg"
    name  = "Go"
    value = "go"
  }
  option {
    icon  = "/icon/java.svg"
    name  = "Java"
    value = "java"
  }
  option {
    icon  = "/icon/rust.svg"
    name  = "Rust"
    value = "rust"
  }
}

data "coder_parameter" "use_demo_app" {
  name         = "use_demo_app"
  display_name = "Start demo app"
  description  = "Auto-start the demo web app for the selected language. Uncheck to clone your own repo instead."
  type         = "bool"
  default      = "true"
  icon         = "/emojis/1f680.png"
  mutable      = false
  order        = 2
}

data "coder_parameter" "repo_url" {
  count        = data.coder_parameter.use_demo_app.value == "true" ? 0 : 1
  name         = "repo_url"
  display_name = "Repository URL"
  description  = "Git repository to clone into ~/repo. Cloned when 'Start demo app' is unchecked."
  type         = "string"
  default      = ""
  icon         = "/icon/git.svg"
  mutable      = false
  order        = 3
  form_type    = "input"
}

data "coder_parameter" "show_advanced" {
  name         = "show_advanced"
  display_name = "Show advanced options"
  description  = "Expose CPU, memory, and disk size controls."
  type         = "bool"
  default      = "false"
  icon         = "/emojis/1f6e0-fe0f.png"
  mutable      = true
  order        = 4
}

data "coder_parameter" "cpu" {
  count        = data.coder_parameter.show_advanced.value == "true" ? 1 : 0
  name         = "cpu"
  display_name = "CPU cores"
  description  = "CPU limit for the workspace pod."
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  order        = 5

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

# Non-Java memory (default 4 GiB)
data "coder_parameter" "memory" {
  count        = data.coder_parameter.show_advanced.value == "true" && data.coder_parameter.language.value != "java" ? 1 : 0
  name         = "memory"
  display_name = "Memory (GiB)"
  description  = "Memory limit for the workspace pod."
  default      = "4"
  icon         = "/icon/memory.svg"
  mutable      = true
  order        = 6

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

# Java memory — higher default + extra option to accommodate Maven + JVM
data "coder_parameter" "memory_java" {
  count        = data.coder_parameter.show_advanced.value == "true" && data.coder_parameter.language.value == "java" ? 1 : 0
  name         = "memory_java"
  display_name = "Memory (GiB)"
  description  = "Memory limit for the workspace pod. Java/Maven needs more headroom — 6 GiB recommended."
  default      = "6"
  icon         = "/icon/memory.svg"
  mutable      = true
  order        = 6

  option {
    name  = "4 GiB"
    value = "4"
  }
  option {
    name  = "6 GiB"
    value = "6"
  }
  option {
    name  = "8 GiB"
    value = "8"
  }
}

data "coder_parameter" "home_disk_size" {
  count        = data.coder_parameter.show_advanced.value == "true" ? 1 : 0
  name         = "home_disk_size"
  display_name = "Home disk (GiB)"
  description  = "Persistent home volume size."
  default      = "20"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = true
  order        = 7

  validation {
    min       = 5
    max       = 200
    monotonic = "increasing"
  }
}

# ── Locals — per-language config ───────────────────────────────────────────────

locals {
  namespace = "coder-workspaces"
  owner     = lower(data.coder_workspace_owner.me.name)
  ws_name   = lower(data.coder_workspace.me.name)
  prefix    = "coder-${data.coder_workspace.me.id}"

  podman_socket_host = "/run/user/991/podman/podman.sock"
  docker_socket_pod  = "/var/run/docker.sock"

  coder_agent_url = "http://10.42.0.1:3000"

  use_demo = data.coder_parameter.use_demo_app.value == "true"

  repo_url = local.use_demo ? "" : (length(data.coder_parameter.repo_url) > 0 ? data.coder_parameter.repo_url[0].value : "")

  cpu           = length(data.coder_parameter.cpu) > 0 ? data.coder_parameter.cpu[0].value : "2"
  memory        = (
    length(data.coder_parameter.memory_java) > 0 ? data.coder_parameter.memory_java[0].value :
    length(data.coder_parameter.memory)      > 0 ? data.coder_parameter.memory[0].value :
    data.coder_parameter.language.value == "java" ? "6" : "4"
  )
  home_disk_gib = length(data.coder_parameter.home_disk_size) > 0 ? data.coder_parameter.home_disk_size[0].value : "20"

  # Map language → container image
  image = {
    python = "mcr.microsoft.com/devcontainers/python:3.12"
    nodejs = "mcr.microsoft.com/devcontainers/javascript-node:20"
    go     = "mcr.microsoft.com/devcontainers/go:1.24"
    java   = "mcr.microsoft.com/devcontainers/java:21"
    rust   = "mcr.microsoft.com/devcontainers/rust:latest"
  }[data.coder_parameter.language.value]

  # Map language → home directory (node image uses /home/node; rest use /home/vscode)
  home_dir = (
    data.coder_parameter.language.value == "nodejs" ? "/home/node" :
    "/home/vscode"
  )

  # Map language → demo app port
  app_port = {
    python = 8000
    nodejs = 3000
    go     = 8000
    java   = 8080
    rust   = 8000
  }[data.coder_parameter.language.value]

  # Map language → icon
  app_icon = {
    python = "/icon/python.svg"
    nodejs = "/icon/node.svg"
    go     = "/icon/go.svg"
    java   = "/icon/java.svg"
    rust   = "/icon/rust.svg"
  }[data.coder_parameter.language.value]

  # Map language → display name
  app_name = {
    python = "FastAPI App"
    nodejs = "Next.js App"
    go     = "Pagoda App"
    java   = "Spring PetClinic"
    rust   = "rustypaste"
  }[data.coder_parameter.language.value]

  # Map language → JetBrains IDE code
  jetbrains_ide = {
    python = "PY"
    nodejs = "WS"
    go     = "GO"
    java   = "IU"
    rust   = "RR"
  }[data.coder_parameter.language.value]
}

# ── Coder agent ────────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  env = {
    CODER_AGENT_URL     = local.coder_agent_url
    DOCKER_HOST         = "unix://${local.docker_socket_pod}"
    LANG                = "en_US.UTF-8"
    HOME                = local.home_dir

    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  startup_script = <<-EOT
    set -e

    # ── One-time init ──────────────────────────────────────────────────────────
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~/ 2>/dev/null || true
      grep -qxF "export DOCKER_HOST=unix://${local.docker_socket_pod}" ~/.bashrc \
        || echo "export DOCKER_HOST=unix://${local.docker_socket_pod}" >> ~/.bashrc
      touch ~/.init_done
    fi

    LANG_VAL="${data.coder_parameter.language.value}"
    USE_DEMO="${data.coder_parameter.use_demo_app.value}"
    REPO_URL="${local.repo_url}"

    if [ "$USE_DEMO" = "true" ]; then
      # ── Demo app startup ────────────────────────────────────────────────────

      if [ "$LANG_VAL" = "python" ]; then
        ########################################################################
        # Python — FastAPI hello world
        ########################################################################
        if [ ! -f ~/demo-app/main.py ]; then
          mkdir -p ~/demo-app
          cat > ~/demo-app/main.py << 'PYEOF'
from fastapi import FastAPI

app = FastAPI()

@app.get("/")
def root():
    return {"message": "Hello from Coder!", "language": "Python", "framework": "FastAPI"}

@app.get("/health")
def health():
    return {"status": "ok"}
PYEOF
        fi
        cd ~/demo-app
        pip install --quiet "fastapi[standard]" 2>&1 | tail -5
        echo "Starting FastAPI on port 8000..."
        nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 >> ~/demo-app/server.log 2>&1 &

      elif [ "$LANG_VAL" = "nodejs" ]; then
        ########################################################################
        # Node.js — Next.js scaffolded app
        ########################################################################
        if [ ! -d ~/demo-app ]; then
          echo "Scaffolding Next.js app..."
          cd ~
          npx --yes create-next-app@latest demo-app \
            --typescript --tailwind --eslint \
            --app --no-src-dir --no-import-alias \
            --no-turbopack 2>&1 | tail -10
        fi
        cd ~/demo-app
        npm install --silent 2>&1 | tail -5
        echo "Starting Next.js on port 3000..."
        nohup npm run dev -- --hostname 0.0.0.0 --port 3000 >> ~/demo-app/server.log 2>&1 &

      elif [ "$LANG_VAL" = "go" ]; then
        ########################################################################
        # Go — mikestefanello/pagoda (SQLite, no external DB)
        ########################################################################
        if [ ! -d ~/demo-app ]; then
          echo "Cloning pagoda..."
          git clone --depth 1 https://github.com/mikestefanello/pagoda.git ~/demo-app
        fi
        cd ~/demo-app
        if [ -f config/config.yaml ]; then
          sed -i 's/host: 127\.0\.0\.1/host: 0.0.0.0/' config/config.yaml || true
          sed -i 's/host: localhost/host: 0.0.0.0/' config/config.yaml || true
        fi
        echo "Downloading Go modules..."
        go mod download 2>&1 | tail -5
        echo "Starting Pagoda on port 8000..."
        nohup go run cmd/web/main.go >> ~/demo-app/server.log 2>&1 &

      elif [ "$LANG_VAL" = "java" ]; then
        ########################################################################
        # Java — Spring PetClinic (H2 in-memory DB)
        ########################################################################
        if [ ! -d ~/demo-app ]; then
          echo "Cloning Spring PetClinic..."
          git clone --depth 1 https://github.com/spring-projects/spring-petclinic.git ~/demo-app
        fi
        cd ~/demo-app
        echo "Building Spring PetClinic (this takes ~2 min on first run)..."
        chmod +x mvnw
        nohup ./mvnw -q spring-boot:run -Dspring-boot.run.arguments="--server.address=0.0.0.0 --server.port=8080" >> ~/demo-app/server.log 2>&1 &

      elif [ "$LANG_VAL" = "rust" ]; then
        ########################################################################
        # Rust — rustypaste (minimal file-paste server)
        ########################################################################
        if [ ! -d ~/demo-app ]; then
          echo "Cloning rustypaste..."
          git clone --depth 1 https://github.com/orhun/rustypaste.git ~/demo-app
        fi
        cd ~/demo-app
        if [ -f config.toml ]; then
          sed -i 's/127\.0\.0\.1/0.0.0.0/g' config.toml
        fi
        mkdir -p upload
        echo "Building rustypaste (first run compiles Rust; ~5 min)..."
        cargo build --release 2>&1 | tail -5
        echo "Starting rustypaste on port 8000..."
        nohup ./target/release/rustypaste >> ~/demo-app/server.log 2>&1 &
      fi

      echo "Demo app startup complete."

    else
      echo "Demo app disabled — repo will be cloned by git-clone module."
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
}

# ── Demo app (only when use_demo_app = true) ───────────────────────────────────

resource "coder_app" "demo" {
  count        = data.coder_workspace.me.start_count == 1 && local.use_demo ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "demo"
  display_name = local.app_name
  url          = "http://localhost:${local.app_port}"
  icon         = local.app_icon
  share        = "public"
  subdomain    = true

  healthcheck {
    url       = "http://localhost:${local.app_port}"
    interval  = 10
    threshold = 30
  }
}

# ── Git clone (only when use_demo_app = false and repo_url is set) ─────────────

module "git-clone" {
  count    = local.use_demo ? 0 : 1
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  url      = local.repo_url
  base_dir = "~"
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
  folder         = local.home_dir
  order          = 1
}

# ── Cursor ─────────────────────────────────────────────────────────────────────

module "cursor" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/cursor/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  folder   = local.home_dir
  order    = 2
}

# ── JetBrains (Toolbox) ───────────────────────────────────────────────────────

module "jetbrains" {
  count          = data.coder_workspace.me.start_count
  source         = "registry.coder.com/coder/jetbrains/coder"
  version        = "~> 1.0"
  agent_id       = coder_agent.main.id
  agent_name     = "main"
  folder         = local.home_dir

  options        = [local.jetbrains_ide]
  default        = [local.jetbrains_ide]
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
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "${local.home_disk_gib}Gi"
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
      run_as_user  = 1000
      run_as_group = 1000
      fs_group     = 1000
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

    container {
      name              = "workspace"
      image             = local.image
      image_pull_policy = "IfNotPresent"

      command = ["sh", "-c", coder_agent.main.init_script]

      security_context {
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
      env {
        name  = "HOME"
        value = local.home_dir
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
          cpu    = "250m"
          memory = "512Mi"
        }
        limits = {
          cpu    = "${local.cpu}"
          memory = "${local.memory}Gi"
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
