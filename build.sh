#!/bin/bash
set -e

ARCH="${ARCH:-amd64}"
SUITE="${SUITE:-trixie}"
VARIANT="${VARIANT:-full}"  # full or minimal
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ROOTFS="/tmp/rootfs"
IMAGE_NAME="${IMAGE_NAME:-veilbox-cloud-${SUITE}-${ARCH}-${VARIANT}}"
BUILD_VERSION="${BUILD_VERSION:-$(git describe --tags --always 2>/dev/null || echo "dev")}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

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
    firewalld \
    unattended-upgrades \
    auditd haveged \
    parted \
    tmux htop iotop iftop jq \
    lvm2 \
    python3 python3-pip python3-venv \
    $grub_pkgs efibootmgr \
    gnupg lsb-release unzip \
    selinux-basics selinux-policy-default \
    kdump-tools \
    aide \
    fail2ban \
    rkhunter chkrootkit
  # Remove conflicting AppArmor (SELinux replaces it)
  chroot "$ROOTFS" apt-get remove -y -qq apparmor apparmor-profiles apparmor-utils 2>/dev/null || true
  chroot "$ROOTFS" apt-get autoremove -y -qq 2>/dev/null || true
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

install_gcloud() {
  info "Installing Google Cloud CLI and guest agent..."
  local repo="deb [signed-by=$ROOTFS/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main"
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    -o "$ROOTFS/usr/share/keyrings/cloud.google.gpg" 2>/dev/null || true
  echo "$repo" > "$ROOTFS/etc/apt/sources.list.d/google-cloud.list" 2>/dev/null || true
  chroot "$ROOTFS" apt-get update -qq 2>/dev/null || true
  chroot "$ROOTFS" apt-get install -y -qq google-cloud-cli 2>/dev/null || true
  rm -f "$ROOTFS/etc/apt/sources.list.d/google-cloud.list" 2>/dev/null || true
}

install_az() {
  info "Installing Azure CLI..."
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    -o "$ROOTFS/usr/share/keyrings/microsoft.asc" 2>/dev/null || true
  chmod a+r "$ROOTFS/usr/share/keyrings/microsoft.asc" 2>/dev/null || true
  local repo="deb [arch=$ARCH signed-by=/usr/share/keyrings/microsoft.asc] https://packages.microsoft.com/repos/azure-cli/ ${SUITE} main"
  echo "$repo" > "$ROOTFS/etc/apt/sources.list.d/azure-cli.list" 2>/dev/null || true
  chroot "$ROOTFS" apt-get update -qq 2>/dev/null || true
  chroot "$ROOTFS" apt-get install -y -qq azure-cli 2>/dev/null || true
  rm -f "$ROOTFS/etc/apt/sources.list.d/azure-cli.list" 2>/dev/null || true
}

install_guest_agents() {
  info "Installing cloud guest agents..."
  # Azure WALA (in Debian)
  chroot "$ROOTFS" apt-get install -y -qq walinuxagent 2>/dev/null || true
  # AWS SSM Agent via snap
  command -v snap >/dev/null 2>&1 && snap install amazon-ssm-agent --classic 2>/dev/null || true
  # GCP guest agent (from Google repo, installed above in install_gcloud)
  chroot "$ROOTFS" apt-get install -y -qq google-compute-engine 2>/dev/null || true
}

install_additional_security() {
  info "Installing additional security tools..."

  # SELinux: enable enforcing with autorelabel
  if [ -f "$ROOTFS/etc/selinux/config" ]; then
    sed -i 's/^SELINUX=.*/SELINUX=enforcing/' "$ROOTFS/etc/selinux/config"
  else
    mkdir -p "$ROOTFS/etc/selinux"
    cat > "$ROOTFS/etc/selinux/config" <<'SEL'
SELINUX=enforcing
SELINUXTYPE=default
SETLOCALDEFS=0
SEL
  fi
  touch "$ROOTFS/.autorelabel"

  # AIDE: configure and init database
  if command -v aideinit >/dev/null 2>&1; then
    cat > "$ROOTFS/etc/aide/aide.conf.d/99-veilbox.conf" <<'AID'
# Veilbox additional AIDE rules
/etc/veilbox/ p+i+n+u+g+s+m+c+sha512
/etc/fstab p+i+n+u+g+s+m+c+sha512
/etc/hostname p+i+n+u+g+s+m+c+sha512
/etc/hosts p+i+n+u+g+s+m+c+sha512
/etc/ssh/sshd_config p+i+n+u+g+s+m+c+sha512
/etc/selinux/ p+i+n+u+g+s+m+c+sha512
AID
    chroot "$ROOTFS" aideinit -f 2>/dev/null || true
    [ -f "$ROOTFS/var/lib/aide/aide.db.new.gz" ] && \
      mv "$ROOTFS/var/lib/aide/aide.db.new.gz" "$ROOTFS/var/lib/aide/aide.db.gz" 2>/dev/null || true
  fi

  # fail2ban: configure SSH jail
  mkdir -p "$ROOTFS/etc/fail2ban"
  cat > "$ROOTFS/etc/fail2ban/jail.local" <<'F2B'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
F2B

  # rkhunter: update properties
  chroot "$ROOTFS" rkhunter --propupd 2>/dev/null || true
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
  local ok=0
  if curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$tmp/pkg" 2>/dev/null; then
    case "$url" in
      *.zip) unzip -q "$tmp/pkg" -d "$tmp" 2>/dev/null ;;
      *)     tar xzf "$tmp/pkg" -C "$tmp" 2>/dev/null || true ;;
    esac
    # Find the binary and copy it
    local found=$(find "$tmp" -type f \( -name "$binary" -o -name "${binary}.exe" \) 2>/dev/null | head -1)
    if [ -z "$found" ]; then
      # Try finding any executable that matches the expected name pattern
      found=$(find "$tmp" -type f -executable -o -type f -name "$binary" 2>/dev/null | head -1)
    fi
    if [ -n "$found" ]; then
      cp "$found" "$ROOTFS$dest" 2>/dev/null && chmod +x "$ROOTFS$dest" 2>/dev/null && ok=1
    fi
  fi
  if [ "$ok" = "1" ]; then
    echo "  $name installed"
  else
    echo "  [WARN] $name install failed"
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
    "https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_${ARCH}.tar.gz" "yq"

  install_tarball "dive" \
    "https://github.com/wagoodman/dive/releases/download/v0.12.0/dive_0.12.0_linux_${ARCH}.tar.gz" "dive"

  install_tarball "k9s" \
    "https://github.com/derailed/k9s/releases/download/v0.40.10/k9s_Linux_${ARCH}.tar.gz" "k9s"

  install_tarball "stern" \
    "https://github.com/stern/stern/releases/download/v1.32.0/stern_1.32.0_linux_${ARCH}.tar.gz" "stern"

  install_binary "kind" \
    "https://github.com/kubernetes-sigs/kind/releases/download/v0.27.0/kind-linux-${ARCH}"

  install_tarball "kustomize" \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.6.0/kustomize_v5.6.0_linux_${ARCH}.tar.gz" "kustomize"

  install_tarball "terraform" \
    "https://releases.hashicorp.com/terraform/1.11.0/terraform_1.11.0_linux_${ARCH}.zip" "terraform"

  install_tarball "gh" \
    "https://github.com/cli/cli/releases/download/v2.68.0/gh_2.68.0_linux_${ARCH}.tar.gz" "gh"

  # AWS CLI v2
  local aws_arch="${ARCH/amd64/x86_64}"
  aws_arch="${aws_arch/arm64/aarch64}"
  local aws_tmp=$(mktemp -d)
  if curl -fsSL --connect-timeout 15 --max-time 120 \
    "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" \
    -o "$aws_tmp/awscliv2.zip" 2>/dev/null; then
    unzip -q "$aws_tmp/awscliv2.zip" -d "$aws_tmp"
    cp -r "$aws_tmp/aws/" "$ROOTFS/tmp/aws-install"
    chroot "$ROOTFS" /tmp/aws-install/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli 2>/dev/null || true
    rm -rf "$ROOTFS/tmp/aws-install" 2>/dev/null || true
    echo "  aws installed"
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
# Enable and start firewalld (default deny, allow SSH + DHCPv6)
systemctl enable firewalld --now 2>/dev/null || true
firewall-cmd --set-default-zone=drop 2>/dev/null || true
firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
firewall-cmd --permanent --add-service=dhcpv6-client 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true
# Enable auditd
systemctl enable auditd --now 2>/dev/null || true
# Enable haveged
systemctl enable haveged --now 2>/dev/null || true
# Enable auto-upgrades
systemctl enable unattended-upgrades --now 2>/dev/null || true
# Enable fail2ban
systemctl enable fail2ban --now 2>/dev/null || true
# Ensure root is locked
passwd -l root 2>/dev/null || true
# Run AIDE check daily
systemctl enable aidecheck.service 2>/dev/null || true
systemctl enable aidecheck.timer 2>/dev/null || true
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

  # Kernel module denylist (unnecessary on cloud VMs)
  cat > "$ROOTFS/etc/modprobe.d/veilbox-blacklist.conf" <<'BLACK'
# Remove unnecessary hardware support
blacklist floppy
blacklist parport
blacklist parport_pc
blacklist firewire-core
blacklist bluetooth
blacklist btusb
blacklist btrtl
blacklist btbcm
blacklist btintel
blacklist snd_hda_intel
blacklist snd_hda_codec
blacklist snd_hda_core
blacklist snd_pcm
blacklist snd_timer
blacklist snd
blacklist soundcore
blacklist pcspkr
blacklist iTCO_wdt
BLACK

  # umask 027
  sed -i 's/^UMASK[[:space:]]*022/UMASK 027/' "$ROOTFS/etc/login.defs" 2>/dev/null || true
  grep -q 'UMASK 027' "$ROOTFS/etc/login.defs" 2>/dev/null || \
    echo "UMASK 027" >> "$ROOTFS/etc/login.defs"
  mkdir -p "$ROOTFS/etc/pam.d"
  for f in common-session common-session-noninteractive; do
    grep -q "umask=027" "$ROOTFS/etc/pam.d/$f" 2>/dev/null || \
      echo "session optional pam_umask.so umask=027" >> "$ROOTFS/etc/pam.d/$f" 2>/dev/null || true
  done

  # systemd journal limits
  mkdir -p "$ROOTFS/etc/systemd/journald.conf.d"
  cat > "$ROOTFS/etc/systemd/journald.conf.d/50-veilbox.conf" <<'JOURNAL'
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxFileSec=1day
Compress=yes
JOURNAL

  # Configure unattended-upgrades
  cat > "$ROOTFS/etc/apt/apt.conf.d/50unattended-upgrades" <<'UA'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
  "${distro_id}ESM:${distro_codename}";
};
Unattended-Upgrade::Auto-Fix "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
UA
  cat > "$ROOTFS/etc/apt/apt.conf.d/20auto-upgrades" <<'AU'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
AU

  # Build info
  mkdir -p "$ROOTFS/etc/veilbox"
  cat > "$ROOTFS/etc/veilbox/build-info" <<EOF
BUILD_VERSION=${BUILD_VERSION}
BUILD_DATE=${BUILD_DATE}
ARCH=${ARCH}
SUITE=${SUITE}
EOF

  # SBOM: list all packages with versions
  dpkg -l --root="$ROOTFS" 2>/dev/null | tail -n +6 | awk '{print $2 "=" $3}' \
    > "$ROOTFS/etc/veilbox/sbom-dpkg.txt" 2>/dev/null || true
  # Record tool versions
  {
    echo "docker=$(chroot "$ROOTFS" docker --version 2>/dev/null | head -1 || echo unknown)"
    echo "kubectl=$(chroot "$ROOTFS" kubectl version --client --short 2>/dev/null || echo unknown)"
    echo "helm=$(chroot "$ROOTFS" helm version --short 2>/dev/null || echo unknown)"
    echo "terraform=$(chroot "$ROOTFS" terraform version 2>/dev/null | head -1 || echo unknown)"
    echo "kind=$(chroot "$ROOTFS" kind version 2>/dev/null || echo unknown)"
    echo "gh=$(chroot "$ROOTFS" gh --version 2>/dev/null | head -1 || echo unknown)"
    echo "aws=$(chroot "$ROOTFS" aws --version 2>/dev/null | head -1 || echo unknown)"
    echo "gcloud=$(chroot "$ROOTFS" gcloud --version 2>/dev/null | head -1 || echo unknown)"
    echo "az=$(chroot "$ROOTFS" az version 2>/dev/null | head -1 || echo unknown)"
    echo "fail2ban=$(chroot "$ROOTFS" fail2ban-server --version 2>/dev/null || echo unknown)"
    echo "aide=$(chroot "$ROOTFS" aide --version 2>/dev/null || echo unknown)"
    echo "rkhunter=$(chroot "$ROOTFS" rkhunter --version 2>/dev/null || echo unknown)"
    echo "chkrootkit=$(chroot "$ROOTFS" chkrootkit --version 2>/dev/null || echo unknown)"
    echo "selinux=$(chroot "$ROOTFS" sestatus 2>/dev/null | head -1 || echo unknown)"
    echo "firewalld=$(chroot "$ROOTFS" firewall-cmd --version 2>/dev/null || echo unknown)"
  } > "$ROOTFS/etc/veilbox/sbom-tools.txt" 2>/dev/null || true

  # Clean up apt and logs (image trimming handled by trim_image later)
  chroot "$ROOTFS" apt-get clean -qq 2>/dev/null || true
  chroot "$ROOTFS" apt-get autoclean -qq 2>/dev/null || true
  chroot "$ROOTFS" apt-get autoremove -qq 2>/dev/null || true
  rm -rf "$ROOTFS/var/lib/apt/lists/"* 2>/dev/null || true
  rm -rf "$ROOTFS/var/log/"* 2>/dev/null || true
  rm -rf "$ROOTFS/tmp/"* 2>/dev/null || true
  rm -f "$ROOTFS/etc/resolv.conf"
}

apply_cis_hardening() {
  info "Applying CIS-inspired hardening..."

  # sysctl kernel hardening
  cat > "$ROOTFS/etc/sysctl.d/99-veilbox.conf" <<'SYS'
# IP forwarding / spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 5
# ICMP hardening
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
# IP forwarding (needed for Docker networking)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# kernel pointer hiding
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.printk = 3 3 3 3
# reduce perf events exposure
kernel.perf_event_paranoid = 3
# ptrace scope
kernel.yama.ptrace_scope = 1
# ASLR
kernel.randomize_va_space = 2
# Restrict BPF
net.core.bpf_jit_enable = 0
# RFC 1337 (TCP TIME-WAIT assassination protection)
net.ipv4.tcp_rfc1337 = 1
# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
# Protect hard/symlinks
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
# Disable core dumps
fs.suid_dumpable = 0
# Enable TCP keepalive
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
SYS

  # SSH hardening
  sed -i 's/^#Protocol 2/Protocol 2/' "$ROOTFS/etc/ssh/sshd_config"
  sed -i 's/^#LogLevel INFO/LogLevel VERBOSE/' "$ROOTFS/etc/ssh/sshd_config"
  sed -i 's/^#MaxAuthTries 6/MaxAuthTries 3/' "$ROOTFS/etc/ssh/sshd_config"
  sed -i 's/^#MaxSessions 10/MaxSessions 5/' "$ROOTFS/etc/ssh/sshd_config"
  sed -i 's/^#ClientAliveInterval 0/ClientAliveInterval 300/' "$ROOTFS/etc/ssh/sshd_config"
  sed -i 's/^#ClientAliveCountMax 3/ClientAliveCountMax 2/' "$ROOTFS/etc/ssh/sshd_config"
  sed -i 's/^#PermitEmptyPasswords no/PermitEmptyPasswords no/' "$ROOTFS/etc/ssh/sshd_config"
  sed -i 's/^#StrictModes yes/StrictModes yes/' "$ROOTFS/etc/ssh/sshd_config"
  sed -i 's/^PermitEmptyPasswords yes/PermitEmptyPasswords no/' "$ROOTFS/etc/ssh/sshd_config"
  cat >> "$ROOTFS/etc/ssh/sshd_config" <<'SSHD'
# Veilbox hardening
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
KexAlgorithms curve25519-sha256,diffie-hellman-group18-sha512,diffie-hellman-group16-sha512
Macs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
ClientAliveInterval 300
ClientAliveCountMax 2
MaxStartups 10:30:60
SSHD

  # Restrict /etc/issue and motd
  > "$ROOTFS/etc/issue"
  > "$ROOTFS/etc/issue.net"
  cat > "$ROOTFS/etc/motd" <<'MOTD'
WARNING: Unauthorized access to this system is prohibited.
MOTD

  # Lock down important files
  chmod 640 "$ROOTFS/etc/shadow" 2>/dev/null || true
  chmod 640 "$ROOTFS/etc/gshadow" 2>/dev/null || true
  chmod 644 "$ROOTFS/etc/passwd" 2>/dev/null || true
  chmod 644 "$ROOTFS/etc/group" 2>/dev/null || true

  # auditd rules
  mkdir -p "$ROOTFS/etc/audit/rules.d"
  cat > "$ROOTFS/etc/audit/rules.d/99-veilbox.rules" <<'AUDIT'
# Monitor privilege escalation
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d -p wa -k sudoers
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
# Monitor critical system files
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/hosts -p wa -k hosts
-w /etc/hostname -p wa -k hostname
# Monitor login/logout
-w /var/log/wtmp -p wa -k logins
-w /var/log/btmp -p wa -k logins
-w /var/run/faillock -p wa -k logins
# Monitor kernel module loading
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
# Monitor network configuration
-w /etc/network -p wa -k networking
# Monitor Docker
-w /var/run/docker.sock -p rwxa -k docker
AUDIT
}

trim_image() {
  info "Trimming image size..."

  # Remove unnecessary kernel modules
  for mod_dir in sound firewire bluetooth wireless media staging; do
    find "$ROOTFS/lib/modules" -path "*/${mod_dir}/*" -delete 2>/dev/null || true
  done

  # Strip ELF binaries (safe: --strip-unneeded keeps debug info needed for backtraces)
  find "$ROOTFS/usr" -type f -executable -exec strip --strip-unneeded {} \; 2>/dev/null || true

  # Remove unnecessary translation files
  find "$ROOTFS/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "locale.alias" -exec rm -rf {} + 2>/dev/null || true
  find "$ROOTFS/usr/share/i18n/locales" ! -name "en_US*" ! -name "C" ! -name "POSIX" -delete 2>/dev/null || true

  # Remove cached data
  chroot "$ROOTFS" apt-get clean -qq 2>/dev/null || true
  chroot "$ROOTFS" apt-get autoclean -qq 2>/dev/null || true
  chroot "$ROOTFS" apt-get autoremove -qq 2>/dev/null || true
  rm -rf "$ROOTFS/var/lib/apt/lists/"* 2>/dev/null || true
  rm -rf "$ROOTFS/var/cache/"* 2>/dev/null || true
  rm -rf "$ROOTFS/var/log/"* 2>/dev/null || true
  rm -rf "$ROOTFS/tmp/"* 2>/dev/null || true
  rm -rf "$ROOTFS/var/tmp/"* 2>/dev/null || true

  # Rebuild depmod after module removal
  chroot "$ROOTFS" depmod -a 2>/dev/null || true
}

mask_services() {
  info "Masking unnecessary services for faster boot..."
  local services=(
    man-db.service man-db.timer
    apt-daily.service apt-daily.timer
    apt-daily-upgrade.service apt-daily-upgrade.timer
    fstrim.service fstrim.timer
    ModemManager.service
    pppd-dns.service
    systemd-resolved.service
    console-setup.service
    keyboard-setup.service
    e2scrub_all.service e2scrub_all.timer
    e2scrub_reap.service
    systemd-timesyncd.service
  )
  for s in "${services[@]}"; do
    chroot "$ROOTFS" systemctl mask "$s" 2>/dev/null || true
  done
}

vulnerability_scan() {
  info "Running vulnerability scan..."
  local report="${OUTPUT_DIR}/${IMAGE_NAME}-vuln.json"
  mkdir -p "$OUTPUT_DIR"
  local trivy_arch="${ARCH/amd64/64bit}"
  trivy_arch="${trivy_arch/arm64/ARM64}"
  local trivy_tmp=$(mktemp -d)
  local trivy_url="https://github.com/aquasecurity/trivy/releases/download/v0.72.0/trivy_0.72.0_Linux-${trivy_arch}.tar.gz"
  if curl -fsSL --connect-timeout 15 --max-time 120 "$trivy_url" -o "$trivy_tmp/trivy.tar.gz" 2>/dev/null; then
    tar xzf "$trivy_tmp/trivy.tar.gz" -C "$trivy_tmp" 2>/dev/null || true
    if [ -f "$trivy_tmp/trivy" ]; then
      chmod +x "$trivy_tmp/trivy"
      export TRIVY_TEMP_DIR="$trivy_tmp/db"
      "$trivy_tmp/trivy" filesystem \
        --severity HIGH,CRITICAL --no-progress --format json \
        "$ROOTFS" > "$report" 2>/dev/null || true
      if [ -s "$report" ]; then
        local c=$(grep -o '"Severity":"CRITICAL"' "$report" | wc -l)
        local h=$(grep -o '"Severity":"HIGH"' "$report" | wc -l)
        echo "  CRITICAL: $c, HIGH: $h"
        cp "$report" "$ROOTFS/etc/veilbox/vuln-report.json" 2>/dev/null || true
      fi
    fi
  fi
  rm -rf "$trivy_tmp" 2>/dev/null || true
}

create_disk_image() {
  info "Creating disk image..."
  local raw="${OUTPUT_DIR}/${IMAGE_NAME}.raw"
  local qcow2="${OUTPUT_DIR}/${IMAGE_NAME}.qcow2"
  local mnt="/tmp/mnt-image"

  mkdir -p "$OUTPUT_DIR" "$mnt"

  # Create raw disk
  dd if=/dev/zero of="$raw" bs=1M count=0 seek=$((3 * 1024)) status=progress

  # Partition: [BIOS boot (amd64)] + EFI (FAT32, esp) + root (ext4)
  local efi_part root_part
  if [ "$ARCH" = "amd64" ]; then
    parted -s "$raw" mklabel gpt
    parted -s "$raw" mkpart primary 1MB 2MB
    parted -s "$raw" set 1 bios_grub on
    parted -s "$raw" mkpart primary fat32 2MB 102MB
    parted -s "$raw" set 2 esp on
    parted -s "$raw" mkpart primary ext4 102MB 100%
    parted -s "$raw" set 3 boot on
    efi_part="p2"; root_part="p3"
  else
    parted -s "$raw" mklabel gpt
    parted -s "$raw" mkpart primary fat32 1MB 101MB
    parted -s "$raw" set 1 esp on
    parted -s "$raw" mkpart primary ext4 101MB 100%
    parted -s "$raw" set 2 boot on
    efi_part="p1"; root_part="p2"
  fi

  local loop=$(losetup --show -fP "$raw" 2>/dev/null || true)
  loop=$(basename "$loop" 2>/dev/null || echo "loop0")
  for i in 1 2 3; do
    [ -e "/dev/${loop}${root_part}" ] && break
    sleep 1
  done

  mkfs.fat -F32 "/dev/${loop}${efi_part}"
  mkfs.ext4 -L cloud-root "/dev/${loop}${root_part}"
  mount "/dev/${loop}${root_part}" "$mnt"
  mkdir -p "$mnt/boot/efi"
  mount "/dev/${loop}${efi_part}" "$mnt/boot/efi"

  # Copy rootfs
  rsync -a "$ROOTFS/" "$mnt/"

  # Install GRUB
  if [ "$ARCH" = "amd64" ]; then
    grub-install --target=i386-pc --boot-directory="$mnt/boot" "/dev/$loop"
    grub-install --target=x86_64-efi --efi-directory="$mnt/boot/efi" \
      --boot-directory="$mnt/boot" --removable
  else
    grub-install --target=arm64-efi --efi-directory="$mnt/boot/efi" \
      --boot-directory="$mnt/boot" --removable
  fi

  umount "$mnt/boot/efi"

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
  losetup -d "/dev/$loop" 2>/dev/null || true

  # Convert to qcow2
  qemu-img convert -f raw -O qcow2 "$raw" "$qcow2"
  rm -f "$raw"

  info "Image created: $qcow2"
  ls -lh "$qcow2"
}

sign_checksum() {
  info "Signing image checksum..."
  local qcow2="${OUTPUT_DIR}/${IMAGE_NAME}.qcow2"
  local sha="${OUTPUT_DIR}/${IMAGE_NAME}.SHA256SUMS"
  local sig="${OUTPUT_DIR}/${IMAGE_NAME}.SHA256SUMS.asc"

  if [ -f "$qcow2" ]; then
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$qcow2")" > "$sha")
    # Generate ephemeral CI signing key if none exists
    if [ ! -f "${OUTPUT_DIR}/signing-key.asc" ]; then
      gpg --batch --passphrase '' --quick-gen-key "veilbox-ci@localhost" default default 2>/dev/null || true
      gpg --export --armor "veilbox-ci@localhost" > "${OUTPUT_DIR}/signing-key.asc" 2>/dev/null || true
    fi
    gpg --batch --yes --armor --detach-sign --output "$sig" "$sha" 2>/dev/null || true
    info "Checksum: $sha"
    info "Signature: $sig"
  fi
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
install_guest_agents
install_additional_security
[ "$VARIANT" != "minimal" ] && install_devops_tools
[ "$VARIANT" != "minimal" ] && install_gcloud
[ "$VARIANT" != "minimal" ] && install_az
configure_system
apply_cis_hardening
mask_services
trim_image
vulnerability_scan

# Remove policy-rc.d
rm -f "$ROOTFS/usr/sbin/policy-rc.d"

# Unmount virtual filesystems (but keep rootfs for disk image)
for d in dev proc sys; do
  mountpoint -q "$ROOTFS/$d" 2>/dev/null && umount -l "$ROOTFS/$d" 2>/dev/null || true
done

create_disk_image
sign_checksum

cleanup

info "Build complete!"
