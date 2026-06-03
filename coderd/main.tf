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
  display_name = "Kubernetes (Podman)"
  description  = "k3s + rootless Podman, Podman socket bind-mounted as /var/run/docker.sock"
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
  display_name = "Kubernetes (Docker)"
  description  = "k3s + sysbox-runc, each workspace gets an isolated Docker daemon, no privileged mode needed"
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
  display_name = "Dev Environment (Demo)"
  description  = "Language-specific workspaces with real demo apps, Python, Node.js, Go, Java, Rust"
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

resource "coderd_template" "coder-cli" {
  name         = "coder-cli"
  display_name = "Coder CLI Sandbox"
  description  = "Docker workspace on codercom/oss-dogfood: docker CLI, terraform, gh, go, node. For Coder agent / CLI work."
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
