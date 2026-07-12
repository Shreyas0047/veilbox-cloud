# Veilbox Cloud

Minimal cloud DevOps image — Debian Trixie with Docker, Kubernetes tooling, and cloud CLIs pre-installed. Built for headless cloud VMs (AWS, Azure, GCP, any x86/ARM64 provider).

## Quick Start

Download the qcow2 image from [Releases](https://github.com/Shreyas0047/veilbox-cloud/releases).

### QEMU/KVM (amd64)

```bash
qemu-system-x86_64 -m 2048 -smp 2 -enable-kvm \
  -drive file=veilbox-cloud-trixie-amd64.qcow2,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net,netdev=net0 \
  -nographic -serial mon:stdio
```

### QEMU/KVM (arm64)

```bash
qemu-system-aarch64 -m 2048 -smp 2 -enable-kvm \
  -cpu host -M virt \
  -drive file=veilbox-cloud-trixie-arm64.qcow2,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net,netdev=net0 \
  -nographic -serial mon:stdio
```

### SSH access

After boot, logs will show the IP. SSH:

```bash
ssh admin@<ip>
# or via local QEMU port forward:
ssh admin@localhost -p 2222
```

> SSH keys are configured via cloud-init; provide your public key or use the console to set up.

## Included Tooling

| Tool | Purpose |
|------|---------|
| Docker CE + containerd | Container runtime |
| kubectl | Kubernetes CLI |
| Helm | Kubernetes package manager |
| k9s | Kubernetes TUI dashboard |
| stern | Multi-pod log tailing |
| kind | Local Kubernetes clusters |
| kustomize | Kubernetes config management |
| Terraform | Infrastructure provisioning |
| AWS CLI v2 | Amazon Web Services |
| GitHub CLI | GitHub operations |
| yq | YAML/JSON processor |
| dive | Docker layer inspector |
| jq | JSON processor |
| tmux, htop, iotop, iftop | System utilities |
| cloud-init | First-boot provisioning |
| UFW + AppArmor + auditd | Security hardening |

## Build from Source

```bash
# Install dependencies
sudo apt install debootstrap qemu-utils parted rsync dosfstools \
  grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed shim-signed

# Build amd64
sudo bash build.sh
# Output: output/veilbox-cloud-trixie-amd64.qcow2

# Build arm64
sudo ARCH=arm64 bash build.sh
# Output: output/veilbox-cloud-trixie-arm64.qcow2
```

Or use the Makefile:

```bash
make build-amd64   # or: make build-arm64
make all           # both architectures
make release       # build + upload to GitHub Releases
```

### Smoke test

```bash
sudo apt install qemu-system-x86 ssh
sudo QEMU_IMAGE=output/veilbox-cloud-trixie-amd64.qcow2 bash tests/smoke.sh
```

## Image Details

- **Base**: Debian Trixie (cloud kernel)
- **Disk**: qcow2 format, BIOS+EFI boot (amd64), EFI-only (arm64)
- **Partitioning**: GPT with FAT32 ESP + ext4 root
- **Default user**: `admin` (created by cloud-init, SSH key only)
- **First-boot**: UFW enabled, AppArmor active, auditd running
- **Build info**: `/etc/veilbox/build-info` contains version, date, and arch

## Included Tooling

| Tool | Version | Purpose |
|------|---------|---------|
| Docker CE | 29.x | Container runtime |
| kubectl | 1.36.2 | Kubernetes CLI |
| Helm | 4.2.2 | Kubernetes package manager |
| k9s | 0.40.10 | Kubernetes TUI dashboard |
| stern | 1.32.0 | Multi-pod log tailing |
| kind | 0.27.0 | Local Kubernetes clusters |
| kustomize | 5.6.0 | Kubernetes config management |
| Terraform | 1.11.0 | Infrastructure provisioning |
| AWS CLI v2 | latest | Amazon Web Services |
| GitHub CLI | 2.68.0 | GitHub operations |
| yq | 4.45.1 | YAML/JSON processor |
| dive | 0.12.0 | Docker layer inspector |

Plus: python3, git, jq, tmux, htop, iotop, iftop

## Security

- Root locked (`passwd -l root`), SSH key-only auth
- UFW enabled (deny incoming, allow SSH)
- AppArmor + auditd + haveged
- unattended-upgrades for security patches
- cloud-init for first-boot provisioning (user creation, SSH keys)

## License

GPL v2.0
