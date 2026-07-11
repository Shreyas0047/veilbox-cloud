# Veilbox Cloud

Minimal cloud DevOps image — Debian Trixie with Docker, Kubernetes tooling, and cloud CLIs pre-installed. Built for headless cloud VMs (AWS, Azure, GCP, any x86/ARM64 provider).

## Quick Start

Download the qcow2 image from [Releases](https://github.com/Shreyas0047/veilbox-cloud/releases).

### QEMU/KVM

```bash
qemu-system-x86_64 -m 2048 -smp 2 -enable-kvm \
  -drive file=veilbox-cloud-trixie-amd64.qcow2,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net,netdev=net0 \
  -nographic -serial mon:stdio
```

### AWS (convert to RAW and upload as AMI)

```bash
qemu-img convert -f qcow2 -O raw veilbox-cloud-trixie-amd64.qcow2 disk.raw
# Upload to S3, import as snapshot, register as AMI
```

### Azure (convert to VHD)

```bash
qemu-img convert -f qcow2 -O vpc -o subformat=fixed veilbox-cloud-trixie-amd64.qcow2 disk.vhd
```

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

## Security

- Root locked (`passwd -l root`), SSH key-only auth
- UFW enabled (deny incoming, allow SSH)
- AppArmor + auditd + haveged
- unattended-upgrades for security patches
- cloud-init for first-boot provisioning (user creation, SSH keys)

## Build from Source

```bash
sudo apt install debootstrap qemu-utils parted rsync grub-pc-bin grub-efi
sudo bash build.sh
```

Output: `output/veilbox-cloud-trixie-amd64.qcow2`

## License

GPL v2.0
