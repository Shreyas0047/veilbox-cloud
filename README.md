# Veilbox Cloud

Minimal cloud DevOps image — Debian Trixie with Docker, Kubernetes tooling, cloud CLIs, guest agents, and CIS-inspired hardening pre-installed. Built for headless cloud VMs (AWS, Azure, GCP, any x86/ARM64 provider).

## Quick Start

Download the compressed qcow2 image from [Releases](https://github.com/Shreyas0047/veilbox-cloud/releases), then decompress:

```bash
gunzip veilbox-cloud-trixie-amd64-full.qcow2.gz
# or for ARM64:
gunzip veilbox-cloud-trixie-arm64-full.qcow2.gz
```

### QEMU/KVM (amd64)

```bash
qemu-system-x86_64 -m 2048 -smp 2 -enable-kvm \
  -drive file=veilbox-cloud-trixie-amd64-full.qcow2,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net,netdev=net0 \
  -nographic -serial mon:stdio
```

### QEMU/KVM (arm64)

```bash
qemu-system-aarch64 -m 2048 -smp 2 -enable-kvm \
  -cpu host -M virt \
  -drive file=veilbox-cloud-trixie-arm64-full.qcow2,format=qcow2 \
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

## Variants

| Variant | Image | Description |
|---------|-------|-------------|
| **full** | `veilbox-cloud-trixie-<arch>-full.qcow2.gz` | All tools, CLIs, agents, and hardening |
| **minimal** | `veilbox-cloud-trixie-<arch>-minimal.qcow2.gz` | Base image without DevOps CLIs or cloud CLIs |

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
| Google Cloud CLI | Google Cloud Platform |
| Azure CLI | Microsoft Azure |
| GitHub CLI | GitHub operations |
| yq | YAML/JSON processor |
| dive | Docker layer inspector |
| jq | JSON processor |
| tmux, htop, iotop, iftop | System utilities |
| cloud-init | First-boot provisioning |
| fail2ban, rkhunter, chkrootkit | Intrusion detection |
| AIDE | File integrity monitoring |
| firewalld, SELinux, auditd | Security hardening |

## Build from Source

```bash
# Install dependencies
sudo apt install debootstrap qemu-utils parted rsync dosfstools \
  grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed shim-signed

# Build amd64 full
sudo bash build.sh
# Output: output/veilbox-cloud-trixie-amd64-full.qcow2

# Build arm64 full
sudo ARCH=arm64 bash build.sh
# Output: output/veilbox-cloud-trixie-arm64-full.qcow2

# Build minimal variant
sudo VARIANT=minimal bash build.sh
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
sudo QEMU_IMAGE=output/veilbox-cloud-trixie-amd64-full.qcow2 bash tests/smoke.sh
```

## Image Details

- **Base**: Debian Trixie (cloud kernel)
- **Disk**: qcow2 format, BIOS+EFI boot (amd64), EFI-only (arm64)
- **Partitioning**: GPT with FAT32 ESP + ext4 root
- **Default user**: `admin` (created by cloud-init, SSH key only)
- **First-boot**: firewalld (drop zone), SELinux enforcing (autorelabel), auditd, fail2ban, unattended-upgrades
- **Build info**: `/etc/veilbox/build-info` contains version, date, and arch
- **SBOM**: `/etc/veilbox/sbom-dpkg.txt` (all packages) and `sbom-tools.txt` (tool versions)
- **Checksums**: Release artifacts include `.SHA256SUMS` and GPG signature (`.asc`)

## Security

### Hardening applied

- **SELinux** enforcing mode (with autorelabel on first boot)
- **firewalld** default drop zone, only SSH and DHCPv6 allowed
- **SSH**: Protocol 2, key-only auth, restricted ciphers/kex/MACs, rate limited (MaxAuthTries 3, MaxStartups 10:30:60)
- **sysctl**: ASLR, rp_filter, kptr_restrict, dmesg_restrict, yama ptrace, TCP syncookies, RFC 1337, martian logging, protected hard/symlinks, suid_dumpable=0
- **auditd**: Rules monitoring sudoers, identity files, sshd_config, logins, kernel modules, Docker socket
- **Kernel module denylist**: floppy, parport, firewire, bluetooth, sound, PC speaker blocked
- **unattended-upgrades**: Auto-fix, auto-clean, auto-reboot at 03:00
- **umask 027**: Default for new files
- **fail2ban**: SSH jail (bantime 3600, maxretry 3)
- **AIDE** file integrity DB built and configured
- **rkhunter + chkrootkit** installed and configured
- **Root locked**, empty passwords denied
- **systemd journal**: 500M max, 7-day retention

### Cloud guest agents

| Agent | Purpose |
|-------|---------|
| cloud-init | First-boot provisioning (all clouds) |
| walinuxagent | Azure Linux Agent |
| amazon-ssm-agent | AWS Systems Manager |
| google-compute-engine | GCP guest environment |

### Vulnerability scanning

Trivy filesystem scan runs during every build. Results in `/etc/veilbox/vuln-report.json`.

## License

GPL v2.0
