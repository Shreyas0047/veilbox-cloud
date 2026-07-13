# Veilbox Cloud

Minimal cloud DevOps image — Debian Trixie with Docker, Kubernetes tooling, cloud CLIs, guest agents, cloud networking, and full hardening pre-installed. Built for headless cloud VMs (AWS, Azure, GCP, any x86/ARM64 provider).

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
| **full** | `veilbox-cloud-trixie-<arch>-full.qcow2.gz` | All tools, CLIs, agents, profiling, and hardening |
| **minimal** | `veilbox-cloud-trixie-<arch>-minimal.qcow2.gz` | Base image without DevOps/cloud CLIs or visual tools |

## Included Tooling

### Containers & Orchestration
- Docker CE + containerd — container runtime
- kubectl, Helm, k9s, stern, kind, kustomize — Kubernetes tooling
- Pre-pulled images: alpine, busybox, ubuntu:24.04, debian:stable-slim, nginx:alpine, python:alpine, node:lts-alpine, golang:alpine

### Cloud CLIs
- AWS CLI v2, Google Cloud CLI, Azure CLI, GitHub CLI

### Infrastructure
- Terraform, yq, dive, jq

### Networking & Time
- NetworkManager + netplan — DHCP everywhere
- chrony — cloud-aware NTP (GCP, Azure, AWS metadata sources)
- WireGuard — VPN tunnels
- firewalld — default drop zone

### Performance & Monitoring
- tuned — virtual-guest profile
- perf, bpftrace, sysdig — deep observability
- sysstat (sar/sadc) — historical performance data
- rasdaemon — EDAC/RAS memory error reporting
- softdog watchdog — system hang detection
- systemd-oomd — proactive OOM management

### System & Utilities
- Vim, nano, build-essential, gcc, make
- tmux, htop, iotop, iftop
- pipx — isolated Python CLI tool management
- tmuxp / byobu — session persistence

### Security
- SELinux enforcing — Mandatory Access Control
- firewalld — default drop, only SSH + DHCPv6
- SSH hardened — Protocol 2, key-only, restricted ciphers/kex/MACs, rate limited
- fail2ban — SSH brute-force protection
- auditd — 15+ file/event monitoring rules
- AIDE — file integrity DB pre-built
- rkhunter + chkrootkit — rootkit detection
- unattended-upgrades — auto-security patches
- Kernel module denylist — floppy, firewire, bluetooth, sound, etc.
- systemd-oomd — proactive OOM kill
- ZRAM swap — compressed memory swap (lz4, up to half RAM)

### Cloud Guest Agents
- cloud-init, walinuxagent (Azure), amazon-ssm-agent (AWS), google-compute-engine (GCP)

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
- **First-boot**: firewalld (drop zone), SELinux enforcing (autorelabel), auditd, fail2ban, chrony, tuned, ZRAM swap, watchdog, rasdaemon, sysstat, unattended-upgrades
- **Build info**: `/etc/veilbox/build-info` contains version, date, and arch
- **SBOM**: `/etc/veilbox/sbom-dpkg.txt` (all packages) and `sbom-tools.txt` (tool versions)
- **Image trimming**: Kernel modules removed (sound, firewire, bluetooth, wireless, media, staging, hwmon, iio, leds, mtd, rtc, ufs, w1, usb, input, gpio); remaining modules compressed with xz; binaries/libraries stripped; Python bytecache removed; fonts/icons/themes/docs purged
- **Checksums**: Release artifacts include `.SHA256SUMS` and GPG signature (`.asc`)

## Hardening Summary

- SELinux enforcing (autorelabel on first boot)
- firewalld default drop zone (SSH + DHCPv6 only)
- SSH: key-only, restricted ciphers/kex/MACs, MaxAuthTries 3, MaxStartups 10:30:60
- Kernel: ASLR, rp_filter, kptr_restrict, dmesg_restrict, yama ptrace, TCP syncookies, RFC 1337, martian logging, protected hard/symlinks, suid_dumpable=0
- sysctl: vm.swappiness=10, vm.vfs_cache_pressure=50
- Boot params: transparent_hugepage=madvise, processor.max_cstate=1 (x86 only)
- auditd: rules for sudoers, identity files, sshd_config, logins, kernel modules, Docker
- Kernel module denylist: floppy, parport, firewire, bluetooth, sound, PC speaker
- Boot optimizations: systemd timeout 10s, network-wait-online/remote-fs masked
- Initramfs: zstd compression, modules compressed with xz
- unattended-upgrades: auto-fix, auto-clean, auto-reboot at 03:00
- umask 027: default for new files
- fail2ban: SSH jail (bantime 3600, maxretry 3)
- AIDE file integrity DB pre-built
- rkhunter + chkrootkit installed and configured
- Root locked, empty passwords denied
- systemd journal: 500M max, 7-day retention
- systemd-oomd: SwapUsedLimitPercent=90, MemoryPressureLimit=50%

## Vulnerability Scanning

Trivy filesystem scan runs during every build. Results in `/etc/veilbox/vuln-report.json`.

## License

GPL v2.0
