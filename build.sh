#!/bin/bash
set -e

ARCH="${ARCH:-amd64}"
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ROOTFS="/tmp/rootfs"
IMAGE_NAME="${IMAGE_NAME:-veilbox-cloud-${SUITE}-${ARCH}}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

cleanup() {
  trap '' INT TERM
  for d in dev proc sys; do
    mountpoint -q "$ROOTFS/$d" 2>/dev/null && umount -l "$ROOTFS/$d" 2>/dev/null || true
  done
  [ -d "$ROOTFS" ] && rm -rf "$ROOTFS" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

check_deps() {
  for cmd in debootstrap chroot qemu-img parted losetup mkfs.ext4 rsync curl wget unzip; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing dependency: $cmd"
  done
}

install_packages() {
  info "Installing packages..."
  local grub_pkgs
  if [ "$ARCH" = "amd64" ]; then
    grub_pkgs="grub-pc grub-efi-${ARCH}-bin grub-efi-${ARCH}-signed shim-signed"
  else
    grub_pkgs="grub-efi-${ARCH}-bin grub-efi-${ARCH}-signed shim-signed efibootmgr"
  fi

  chroot "$ROOTFS" apt-get update -qq
  # shellcheck disable=SC2086
  chroot "$ROOTFS" apt-get install -y -qq \
    linux-image-cloud-${ARCH} \
    systemd systemd-sysv dbus \
    openssh-server cloud-init cloud-guest-utils \
    sudo ca-certificates curl wget git \
    ufw apparmor apparmor-profiles apparmor-utils \
    unattended-upgrades apt-listchanges \
    auditd haveged needrestart \
    parted lvm2 \
    tmux htop iotop iftop jq \
    python3 python3-pip python3-venv \
    $grub_pkgs efibootmgr \
    cryptsetup cryptsetup-initramfs \
    gnupg lsb-release unzip
  chroot "$ROOTFS" apt-get clean -qq
}

install_docker() {
  info "Installing Docker CE..."
  curl -fsSL https://download.docker.com/linux/debian/gpg -o "$ROOTFS/etc/apt/keyrings/docker.asc"
  chmod a+r "$ROOTFS/etc/apt/keyrings/docker.asc"
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${SUITE} stable" \
    > "$ROOTFS/etc/apt/sources.list.d/docker.list"
  chroot "$ROOTFS" apt-get update -qq 2>/dev/null || true
  chroot "$ROOTFS" apt-get install -y -qq docker-ce docker-ce-cli containerd.io 2>/dev/null || true
  rm -f "$ROOTFS/etc/apt/sources.list.d/docker.list"
}

install_binary() {
  local name="$1" url="$2"
  local dest="/usr/local/bin/$name"
  if curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$ROOTFS$dest" 2>/dev/null; then
    chmod +x "$ROOTFS$dest"
    echo "  $name installed"
  else
    echo "  [WARN] $name skipped"
  fi
}

install_tarball() {
  local name="$1" url="$2" binary="${3:-$1}"
  local dest="/usr/local/bin/$name"
  local tmp=$(mktemp -d)
  if curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$tmp/pkg" 2>/dev/null; then
    case "$url" in
      *.zip)
        unzip -q "$tmp/pkg" -d "$tmp" 2>/dev/null
        ;;
      *)
        tar xzf "$tmp/pkg" -C "$tmp" 2>/dev/null || true
        ;;
    esac
    find "$tmp" -name "$binary" -type f ! -name "*.tar.gz" ! -name "*.zip" -exec cp {} "$ROOTFS$dest" \; 2>/dev/null
    if [ ! -f "$ROOTFS$dest" ]; then
      # Fallback: find the largest file in tmp
      local best=$(find "$tmp" -maxdepth 3 -type f -executable -o -type f -name "$binary" 2>/dev/null | head -1)
      [ -n "$best" ] && cp "$best" "$ROOTFS$dest" 2>/dev/null || true
    fi
    chmod +x "$ROOTFS$dest" 2>/dev/null || true
    if [ -f "$ROOTFS$dest" ]; then
      echo "  $name installed"
    else
      echo "  [WARN] $name extraction failed"
    fi
  else
    echo "  [WARN] $name download failed"
  fi
  rm -rf "$tmp"
}

install_devops_tools() {
  info "Installing DevOps CLI tools..."

  install_binary "kubectl" \
    "https://dl.k8s.io/release/v1.36.2/bin/linux/${ARCH}/kubectl"

  install_tarball "helm" \
    "https://get.helm.sh/helm-v4.2.2-linux-${ARCH}.tar.gz" "helm"

  install_tarball "yq" \
    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}.tar.gz" "yq"

  install_tarball "dive" \
    "https://github.com/wagoodman/dive/releases/latest/download/dive_0.12.0_linux_${ARCH}.tar.gz" "dive"

  install_tarball "k9s" \
    "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_${ARCH}.tar.gz" "k9s"

  install_tarball "stern" \
    "https://github.com/stern/stern/releases/latest/download/stern_1.32.0_linux_${ARCH}.tar.gz" "stern"

  install_binary "kind" \
    "https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-${ARCH}"

  install_tarball "kustomize" \
    "https://github.com/kubernetes-sigs/kustomize/releases/latest/download/kustomize_v5.6.0_linux_${ARCH}.tar.gz" "kustomize"

  install_tarball "terraform" \
    "https://releases.hashicorp.com/terraform/1.11.0/terraform_1.11.0_linux_${ARCH}.zip" "terraform"

  install_tarball "gh" \
    "https://github.com/cli/cli/releases/latest/download/gh_2.68.0_linux_${ARCH}.tar.gz" "gh"

  # AWS CLI v2
  local aws_tmp=$(mktemp -d)
  if curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o "$aws_tmp/awscliv2.zip" 2>/dev/null; then
    unzip -q "$aws_tmp/awscliv2.zip" -d "$aws_tmp"
    cp -r "$aws_tmp/aws/" "$ROOTFS/tmp/aws-install"
    chroot "$ROOTFS" /tmp/aws-install/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli 2>/dev/null || true
    rm -rf "$ROOTFS/tmp/aws-install" 2>/dev/null || true
  else
    echo "  [WARN] aws download failed"
  fi
  rm -rf "$aws_tmp" 2>/dev/null || true
}

configure_system() {
  info "Configuring system..."

  # Hostname
  echo "veilbox-cloud" > "$ROOTFS/etc/hostname"

  # fstab
  cat > "$ROOTFS/etc/fstab" <<'FSTAB'
LABEL=cloud-root / ext4 defaults 0 1
FSTAB

  # Serial console
  mkdir -p "$ROOTFS/etc/systemd/system/serial-getty@.service.d"
  cat > "$ROOTFS/etc/systemd/system/serial-getty@.service.d/autologin.conf" <<'SERIAL'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' --noclear --autologin root %I $TERM
SERIAL

  # SSH: key-only auth
  sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' "$ROOTFS/etc/ssh/sshd_config"
  sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$ROOTFS/etc/ssh/sshd_config"
  sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' "$ROOTFS/etc/ssh/sshd_config"

  # cloud-init
  cat > "$ROOTFS/etc/cloud/cloud.cfg.d/10_veilbox.cfg" <<'CLOUD'
system_info:
  default_user:
    name: admin
    lock_passwd: true
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
  ssh_svcname: ssh
disable_root: true
ssh_pwauth: false
package_update: false
package_upgrade: false
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
resize_rootfs: true
CLOUD

  # Disable cloud-init networking config (use DHCP)
  cat > "$ROOTFS/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" <<'NET'
network:
  config: disabled
NET

  # First-boot hardening service
  cat > "$ROOTFS/etc/systemd/system/veilbox-firstboot.service" <<'SVC'
[Unit]
Description=Veilbox first-boot hardening
ConditionFirstBoot=true
After=cloud-init.target
Wants=cloud-init.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/veilbox/firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC

  mkdir -p "$ROOTFS/usr/local/lib/veilbox"
  cat > "$ROOTFS/usr/local/lib/veilbox/firstboot.sh" <<'FB'
#!/bin/bash
set -e
# Enable and start AppArmor
systemctl enable apparmor --now 2>/dev/null || true
# Enable auditd
systemctl enable auditd --now 2>/dev/null || true
# Enable haveged
systemctl enable haveged --now 2>/dev/null || true
# Enable auto-upgrades
systemctl enable unattended-upgrades --now 2>/dev/null || true
# Enable UFW (default deny incoming, allow SSH)
ufw --force enable 2>/dev/null || true
ufw default deny incoming 2>/dev/null || true
ufw allow ssh 2>/dev/null || true
# Ensure root is locked
passwd -l root 2>/dev/null || true
# Expand partition if needed (growpart handled by cloud-init)
true
FB
  chmod +x "$ROOTFS/usr/local/lib/veilbox/firstboot.sh"

  # Enable services
  chroot "$ROOTFS" systemctl enable veilbox-firstboot.service 2>/dev/null || true
  chroot "$ROOTFS" systemctl enable cloud-init.service 2>/dev/null || true
  chroot "$ROOTFS" systemctl enable docker.service 2>/dev/null || true
  chroot "$ROOTFS" systemctl enable haveged.service 2>/dev/null || true
  chroot "$ROOTFS" systemctl enable auditd.service 2>/dev/null || true

  # Docker group
  chroot "$ROOTFS" groupadd -f docker 2>/dev/null || true

  # Clean up
  chroot "$ROOTFS" apt-get clean -qq 2>/dev/null || true
  rm -rf "$ROOTFS/var/lib/apt/lists/*" 2>/dev/null || true
  rm -rf "$ROOTFS/tmp/*" 2>/dev/null || true
  rm -f "$ROOTFS/etc/resolv.conf"
}

create_disk_image() {
  info "Creating disk image..."
  local raw="${OUTPUT_DIR}/${IMAGE_NAME}.raw"
  local qcow2="${OUTPUT_DIR}/${IMAGE_NAME}.qcow2"
  local mnt="/tmp/mnt-image"

  mkdir -p "$OUTPUT_DIR" "$mnt"

  # Create raw disk
  dd if=/dev/zero of="$raw" bs=1M count=0 seek=$((4 * 1024)) status=progress

  # Setup loop device
  local loop=$(losetup --show -fP "$raw")

  # Partition
  local root_part
  if [ "$ARCH" = "amd64" ]; then
    parted -s "$raw" mklabel gpt
    parted -s "$raw" mkpart primary 1MB 2MB
    parted -s "$raw" set 1 bios_grub on
    parted -s "$raw" mkpart primary ext4 2MB 100%
    parted -s "$raw" set 2 boot on
    root_part="${loop}p2"
  else
    parted -s "$raw" mklabel gpt
    parted -s "$raw" mkpart primary ext4 1MB 100%
    parted -s "$raw" set 1 boot on
    root_part="${loop}p1"
  fi

  mkfs.ext4 -L cloud-root "$root_part"
  mount "$root_part" "$mnt"

  # Copy rootfs
  rsync -a "$ROOTFS/" "$mnt/"

  # Install GRUB based on architecture
  mkdir -p "$mnt/boot/efi"
  if [ "$ARCH" = "amd64" ]; then
    grub-install --target=i386-pc --boot-directory="$mnt/boot" "$loop"
    grub-install --target=x86_64-efi --efi-directory="$mnt/boot/efi" \
      --boot-directory="$mnt/boot" --removable
  else
    grub-install --target=arm64-efi --efi-directory="$mnt/boot/efi" \
      --boot-directory="$mnt/boot" --removable
  fi

  # Generate GRUB config
  mkdir -p "$mnt/boot/grub"
  cat > "$mnt/boot/grub/grub.cfg" <<'GRUB'
set default=0
set timeout=2
menuentry "Veilbox Cloud" {
  linux /boot/vmlinuz-* root=LABEL=cloud-root console=tty0 console=ttyS0,115200n8 quiet
  initrd /boot/initrd.img-*
}
GRUB

  # Clean up loop device
  umount "$mnt"
  losetup -d "$loop"

  # Convert to qcow2
  qemu-img convert -f raw -O qcow2 "$raw" "$qcow2"
  rm -f "$raw"

  info "Image created: $qcow2"
  ls -lh "$qcow2"
}

# --- Main ---
check_deps

info "Building Veilbox Cloud for ${ARCH} (${SUITE})"

# Clean
[ -d "$ROOTFS" ] && rm -rf "$ROOTFS"

# Bootstrap
info "Bootstrapping Debian ${SUITE} (${ARCH})..."
debootstrap --arch="$ARCH" --include=systemd,systemd-sysv,dbus,ca-certificates,apt \
  "$SUITE" "$ROOTFS" "$MIRROR"

# Set up resolv.conf for chroot
echo "nameserver 1.1.1.1" > "$ROOTFS/etc/resolv.conf"

# Mount virtual filesystems
mount --bind /dev "$ROOTFS/dev"
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"

# Prevent services from starting in chroot
cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

install_packages
install_docker
install_devops_tools
configure_system

# Remove policy-rc.d
rm -f "$ROOTFS/usr/sbin/policy-rc.d"

# Unmount virtual filesystems (but keep rootfs for disk image)
for d in dev proc sys; do
  mountpoint -q "$ROOTFS/$d" 2>/dev/null && umount -l "$ROOTFS/$d" 2>/dev/null || true
done

create_disk_image

cleanup

info "Build complete!"
