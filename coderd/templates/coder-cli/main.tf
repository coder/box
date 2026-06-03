terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
    null = {
      source = "hashicorp/null"
    }
  }
}

provider "coder" {}
provider "docker" {}
provider "null" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_provisioner" "me" {}

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

data "coder_parameter" "image" {
  name         = "image"
  display_name = "Workspace image"
  description  = "The Coder dogfood image already ships with coder CLI, terraform, git, gh, docker CLI, node, go, and the kitchen sink."
  type         = "string"
  default      = "codercom/oss-dogfood:latest"
  mutable      = false
  option {
    name  = "Ubuntu 22.04 (oss-dogfood:latest)"
    value = "codercom/oss-dogfood:latest"
    icon  = "/icon/coder.svg"
  }
  option {
    name  = "Ubuntu 26.04 (oss-dogfood:26.04)"
    value = "codercom/oss-dogfood:26.04"
    icon  = "/icon/coder.svg"
  }
  option {
    name  = "Nix dogfood (experimental)"
    value = "codercom/oss-dogfood-nix:latest"
    icon  = "/icon/nix.svg"
  }
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU cores"
  type         = "number"
  default      = "2"
  mutable      = true
  validation {
    min = 1
    max = 16
  }
}

data "coder_parameter" "memory_gb" {
  name         = "memory_gb"
  display_name = "Memory (GB)"
  type         = "number"
  default      = "4"
  mutable      = true
  validation {
    min = 1
    max = 64
  }
}

data "coder_parameter" "git_repo_url" {
  name         = "git_repo_url"
  display_name = "Git repository to clone (optional)"
  description  = "If set, cloned into ~/projects on first start. Leave blank to skip."
  type         = "string"
  default      = ""
  mutable      = true
}

data "coder_parameter" "enable_claude_code" {
  name         = "enable_claude_code"
  display_name = "Install Claude Code"
  description  = "Install the Claude Code CLI via the official module. Authenticates against Coder AI Gateway by default."
  type         = "bool"
  default      = "false"
  mutable      = true
}

# ---------------------------------------------------------------------------
# Coder agent
# ---------------------------------------------------------------------------

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  dir  = "/home/coder"

  startup_script_behavior = "blocking"

  startup_script = <<-EOT
    set -eu
    mkdir -p "$HOME/projects"
    cat > "$HOME/.coder-welcome" <<'BANNER'
    ────────────────────────────────────────────────────────────────
     Coder CLI workspace (dogfood image)
    ────────────────────────────────────────────────────────────────
     You are auto-logged-in via the coder-login module.
       coder templates list
       coder templates push <name> --directory .
       coder workspaces list
       coder ssh <workspace>
    ────────────────────────────────────────────────────────────────
    BANNER
    if ! grep -q '.coder-welcome' "$HOME/.bashrc" 2>/dev/null; then
      echo 'cat $HOME/.coder-welcome 2>/dev/null || true' >> "$HOME/.bashrc"
    fi
  EOT

  metadata {
    display_name = "CPU usage"
    key          = "cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Memory usage"
    key          = "mem_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Home disk"
    key          = "home_disk"
    script       = "coder stat disk --path $HOME"
    interval     = 60
    timeout      = 1
  }
}

# ---------------------------------------------------------------------------
# Registry modules
# ---------------------------------------------------------------------------

module "coder-login" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/coder-login/coder"
  version  = "1.1.1"
  agent_id = coder_agent.main.id
}

module "git-clone" {
  count    = data.coder_workspace.me.start_count != 0 && data.coder_parameter.git_repo_url.value != "" ? 1 : 0
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "1.2.3"
  agent_id = coder_agent.main.id
  url      = data.coder_parameter.git_repo_url.value
  base_dir = "/home/coder/projects"
}

module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"
  version  = "1.4.4"
  agent_id = coder_agent.main.id
  folder   = "/home/coder/projects"
}

module "claude-code" {
  count    = data.coder_workspace.me.start_count != 0 && data.coder_parameter.enable_claude_code.value ? 1 : 0
  source   = "registry.coder.com/coder/claude-code/coder"
  version  = "5.1.0"
  agent_id = coder_agent.main.id
  workdir  = "/home/coder/projects"
}

# ---------------------------------------------------------------------------
# Docker volume + container
# ---------------------------------------------------------------------------

resource "docker_volume" "home" {
  name = "coder-${data.coder_workspace.me.id}-home"
  lifecycle {
    ignore_changes = all
  }
}

data "docker_registry_image" "workspace" {
  name = data.coder_parameter.image.value
}

resource "docker_image" "workspace" {
  name          = data.coder_parameter.image.value
  pull_triggers = [data.docker_registry_image.workspace.sha256_digest]
  keep_locally  = true
}

# Fix /home/coder ownership BEFORE the workspace container starts.
#
# Root cause: In rootless Podman the user namespace maps
#   container uid 0 (root)  -> host uid 991  (coder system user)
#   container uid 1000      -> host uid 100999 (subuid range 100000+999)
# The oss-dogfood image has /home/coder owned by root (uid 0) in the image
# layer. When Podman initialises a fresh named volume by copying that directory,
# the volume files end up owned by host uid 100999. Inside the container this
# maps back to uid 1000 — however the coder agent's `dir` is /home/coder and
# the startup script runs as uid 1000 (coder), so the directory *appears*
# writable — but the directory itself (mode 750, uid 100999) is not accessible
# by the coder user (uid 1000 inside container = uid 100999 on host), because
# 100999 != 991 and is not in the coder group. Effectively /home/coder is
# owned by an unmapped uid.
#
# Fix: run a throwaway container before the real workspace container. Inside
# this throwaway container, uid 0 = host uid 991 (coder user), which has
# write access to the volume storage path. We chown /home/coder to 1000:1000
# (which on the host becomes 100999:100999 = correct subuid mapping).
# The real container then starts with a correctly-owned home directory.
resource "null_resource" "fix_home_owner" {
  count = data.coder_workspace.me.start_count

  triggers = {
    volume_name = docker_volume.home.name
    image       = docker_image.workspace.image_id
  }

  provisioner "local-exec" {
    command = "/run/current-system/sw/bin/podman run --rm --user root -v ${docker_volume.home.name}:/home/coder --entrypoint sh ${docker_image.workspace.image_id} -c 'chown -R 1000:1000 /home/coder && chmod 750 /home/coder'"
  }

  depends_on = [docker_volume.home, docker_image.workspace]
}

resource "docker_container" "workspace" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.workspace.image_id
  name     = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  hostname = lower(data.coder_workspace.me.name)

  entrypoint = ["sh", "-c", coder_agent.main.init_script]
  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    # Pasta's --map-gw maps 169.254.1.2 (host.docker.internal) to the host
    # loopback, so Coder is reachable at http://host.docker.internal:3000
    # regardless of what LAN IP the host has.
    "CODER_AGENT_URL=http://host.docker.internal:3000",
    # Override binary download URL — tunnel URL is not reachable from inside Podman.
    "BINARY_URL=http://host.docker.internal:3000/bin/coder-linux-amd64",
  ]

  # pasta:--map-gw tells Podman's pasta network backend to map the container
  # gateway (169.254.1.2 / host.docker.internal) to the host's loopback.
  # This makes the Coder server reachable without any hardcoded IP.
  network_mode = "pasta:--map-gw"

  cpu_shares = data.coder_parameter.cpu.value * 1024
  memory     = data.coder_parameter.memory_gb.value * 1024

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home.name
    read_only      = false
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }

  depends_on = [null_resource.fix_home_owner]
}
