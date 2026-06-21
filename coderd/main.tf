terraform {
  required_providers {
    coderd = {
      source  = "coder/coderd"
      version = "~> 0.0.16"
    }
  }

  # State path is set explicitly so the activation script doesn't need -state flag.
  backend "local" {
    path = "/var/lib/coder/template-sync/terraform.tfstate"
  }
}

variable "coder_url" {
  type        = string
  description = "URL of the Coder server (e.g. http://coder-thinkcentre.local:3000)"
}

variable "coder_session_token" {
  type      = string
  sensitive = true
}

variable "hostname" {
  type        = string
  description = "Machine hostname, passed to workspace templates as coder_hostname for agent URL resolution"
}

variable "coder_lan_ip" {
  type        = string
  default     = ""
  description = "LAN IP of this machine. Injected into workspace pod hostAliases so pods can resolve the Coder server hostname without mDNS. Set via services.coder-nixos.lanIp in the host's local.nix."
}

variable "version_name" {
  type    = string
  default = "latest"
}

# Secret for the workshop admin Wall-of-Fame display. Sourced from the box's
# gitignored local.nix via the coder-template-sync activation script. Default
# empty so other machines / a missing value simply disable the admin stack.
#
# NOTE: the Anthropic key is NOT passed here. AI access (attendee Claude Code
# AND the admin PR-review bot) goes through Coder's AI Gateway, authenticated
# with the user's Coder token. The provider key lives once in the deployment
# (CODER_AIBRIDGE_ANTHROPIC_KEY from local.nix) and never flows through
# Terraform. See hosts/coderbox/templates/workshop/main.tf.
variable "workshop_admin_token" {
  type      = string
  default   = ""
  sensitive = true
}

variable "workshop_keycloak_url" {
  type        = string
  default     = ""
  description = "Base URL of the Keycloak (Railway) instance brokering GitHub for the workshop. Sourced from local.nix. The workshop template uses it to fetch the owner's repo-scoped GitHub token via the OIDC broker."
}

provider "coderd" {
  url   = var.coder_url
  token = var.coder_session_token
}

# ── Machine-specific locals ────────────────────────────────────────────────────
# Templates under hosts/<hostname>/templates/ are only deployed when
# var.hostname matches the machine name. Use count = local.is_<machine> ? 1 : 0
# on each machine-specific coderd_template resource.

locals {
  is_thinkcentre = var.hostname == "coder-thinkcentre"
  is_coderbox    = var.hostname == "coderbox" || var.hostname == "coderbox-dallas"

  # Workspace lifecycle policy (applied to all templates)
  # Autostop: workspace stops 24h after last activity bump.
  # Autodelete: handled by the coder-workspace-reaper systemd timer (OSS-compatible).
  #   time_til_dormant_ms / time_til_dormant_autodelete_ms are Enterprise-only fields
  #   and cannot be set on an unlicensed deployment.
  autostop_ms = 24 * 60 * 60 * 1000 # 86_400_000 ms = 24 h
}

# ── Shared templates (deployed to all machines) ────────────────────────────────

resource "coderd_template" "k3s-podman" {
  name         = "k3s-podman"
  display_name = "Container Workspace (Podman)"
  description  = "Advanced: Docker-compatible workspace via the host rootless Podman socket."
  icon         = "/icon/k8s.png"

  default_ttl_ms = local.autostop_ms

  versions = [{
    name      = var.version_name
    directory = "${path.module}/templates/k3s-podman"
    active    = true
    tf_vars   = [{
      name  = "coder_hostname"
      value = var.hostname
    }, {
      name  = "coder_lan_ip"
      value = var.coder_lan_ip
    }]
  }]
}

resource "coderd_template" "k3s-sysbox" {
  name         = "k3s-sysbox"
  display_name = "Isolated Docker Path"
  description  = "Build and run containers inside your workspace with hardened isolation, no privileged mode, no host access."
  icon         = "/icon/docker.png"

  default_ttl_ms = local.autostop_ms

  versions = [{
    name      = var.version_name
    directory = "${path.module}/templates/k3s-sysbox"
    active    = true
    tf_vars = [{
      name  = "coder_hostname"
      value = var.hostname
    }, {
      name  = "coder_lan_ip"
      value = var.coder_lan_ip
    }]
  }]
}

resource "coderd_template" "k3s-dev" {
  name         = "k3s-dev"
  display_name = "Polyglot Demo (advanced)"
  description  = "Advanced: pick a language (Python/Node/Go/Java/Rust) and get a running sample app."
  icon         = "/icon/code.svg"

  default_ttl_ms = local.autostop_ms

  versions = [{
    name      = var.version_name
    directory = "${path.module}/templates/k3s-dev"
    active    = true
    tf_vars   = [{
      name  = "coder_hostname"
      value = var.hostname
    }, {
      name  = "coder_lan_ip"
      value = var.coder_lan_ip
    }]
  }]
}

resource "coderd_template" "data-science" {
  count        = local.is_coderbox ? 1 : 0
  name         = "data-science"
  display_name = "Data Science Path"
  description  = "A specialized golden path: Python, JupyterLab, and common data libraries, ready to analyze."
  icon         = "/icon/jupyter.svg"

  default_ttl_ms = local.autostop_ms

  versions = [{
    name      = var.version_name
    directory = "${path.module}/../hosts/coderbox/templates/data-science"
    active    = true
    tf_vars   = [{
      name  = "coder_hostname"
      value = var.hostname
    }, {
      name  = "coder_lan_ip"
      value = var.coder_lan_ip
    }]
  }]
}

resource "coderd_template" "kindleframe-onboard" {
  count        = local.is_coderbox ? 1 : 0
  name         = "kindleframe-onboard"
  display_name = "Project: kindleframe-server"
  description  = "Onboard to a real private service: clone via GitHub auth, install, and run, with an AI agent guided by the repo's conventions."
  icon         = "/emojis/1f5bc.png"

  default_ttl_ms = local.autostop_ms

  versions = [{
    name      = var.version_name
    directory = "${path.module}/../hosts/coderbox/templates/kindleframe-onboard"
    active    = true
    tf_vars   = [{
      name  = "coder_hostname"
      value = var.hostname
    }, {
      name  = "coder_lan_ip"
      value = var.coder_lan_ip
    }]
  }]
}

resource "coderd_template" "workshop" {
  count        = local.is_coderbox ? 1 : 0
  name         = "workshop"
  display_name = "Workshop: Wall of Names"
  description  = "Say \"make my name blue\" — the agent forks the wall, adds your name, previews it, and opens a PR."
  icon         = "/emojis/1fa84.png"

  default_ttl_ms = local.autostop_ms

  versions = [{
    name      = var.version_name
    directory = "${path.module}/../hosts/coderbox/templates/workshop"
    active    = true
    tf_vars   = [{
      name  = "coder_hostname"
      value = var.hostname
    }, {
      name  = "coder_lan_ip"
      value = var.coder_lan_ip
    }, {
      name  = "admin_coder_token"
      value = var.workshop_admin_token
    }, {
      name  = "keycloak_url"
      value = var.workshop_keycloak_url
    }]
  }]
}

resource "coderd_template" "coder-cli" {
  name         = "coder-cli"
  display_name = "Universal Golden Path"
  description  = "The standard paved road for any developer: full toolchain, browser IDE, and an AI agent, ready in seconds."
  icon         = "/icon/coder.svg"

  default_ttl_ms = local.autostop_ms

  # coder-cli/main.tf declares no terraform variables (it only uses
  # coder_parameter data sources for workspace-time inputs), so don't pass
  # tf_vars here: the Coder server rejects an import with undeclared vars.
  versions = [{
    name      = var.version_name
    directory = "${path.module}/templates/coder-cli"
    active    = true
  }]
}

# ── coder-thinkcentre templates ───────────────────────────────────────────
# Templates in hosts/coder-thinkcentre/templates/ require hardware or
# services specific to that machine (qemu-i386 binfmt, pre-built images, etc.).

resource "coderd_template" "nook-android" {
  count        = local.is_thinkcentre ? 1 : 0
  name         = "nook-android"
  display_name = "Nook Android (TRMNL)"
  description  = "Build trmnl-nook-simple-touch for the B&N Nook Simple Touch, Java 8 + ADT 2014 + Ant"
  icon         = "/icon/java.svg"

  default_ttl_ms = local.autostop_ms

  versions = [{
    name      = var.version_name
    directory = "${path.module}/../hosts/coder-thinkcentre/templates/nook-android"
    active    = true
    tf_vars   = [{
      name  = "coder_hostname"
      value = var.hostname
    }, {
      name  = "coder_lan_ip"
      value = var.coder_lan_ip
    }]
  }]
}
