# Lenovo ThinkCentre M70q Gen 2

**Lenovo part number:** 11N0S1AB00  
**Board:** Lenovo 31A7  
**[Product page](https://www.lenovo.com/us/en/p/desktops/thinkcentre/m-series-tiny/thinkcentre-m70q-gen-2/11n0s1ab00)**

## CPU

| Field | Value |
|-------|-------|
| Model | 11th Gen Intel Core i7-11700T |
| Cores / Threads | 8 cores / 16 threads |
| Base clock | 1.40 GHz |
| Boost clock | 4.60 GHz |
| TDP class | T-series (35 W) |
| Virtualization | VT-x (kvm-intel) |
| ISA extensions | AVX-512, AES-NI |

## Memory

| Field | Value |
|-------|-------|
| Total | 16 GB |

## Storage

| Device | Size | Type | Role |
|--------|------|------|------|
| nvme0n1 | 477 GB | NVMe SSD | Primary (/, /boot, swap) |
| sda | 233 GB | SATA HDD | Unpartitioned |

### Partition layout (nvme0n1)

| Partition | Size | FS | Mount |
|-----------|------|----|-------|
| nvme0n1p1 | 1 GB | vfat | /boot |
| nvme0n1p2 | 459 GB | ext4 | / |
| nvme0n1p3 | 16.8 GB | swap | [SWAP] |

## Network

| Interface | Type | Notes |
|-----------|------|-------|
| eno2 | 1 GbE (Intel I219) | Primary |
| wlo1 | Wi-Fi (Intel AX201) | Down by default |
| enp0s20f0u8 | USB Ethernet | — |

## NixOS

| Field | Value |
|-------|-------|
| nixpkgs | nixos-25.11 (pinned in flake.lock) |
| Nix | 2.31.4 |
| Hostname | coder-thinkcentre |
| User | coderbox |
| Desktop | GNOME (Wayland) / GDM |
| Repo path | /etc/nixos-repo |
