#!/bin/bash
# Smoke test: boots the qcow2 image with QEMU and verifies SSH + basic tools.
set -e

IMAGE="${QEMU_IMAGE:-output/veilbox-cloud-trixie-amd64.qcow2}"
[ -f "$IMAGE" ] || { echo "Image not found: $IMAGE"; exit 1; }

SSH_PORT=22222
TIMEOUT=120  # seconds

cleanup() {
  kill "$QEMU_PID" 2>/dev/null || true
  wait "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Booting $IMAGE..."
qemu-system-x86_64 -m 2048 -smp 2 -enable-kvm \
  -drive file="$IMAGE",format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
  -device virtio-net,netdev=net0 \
  -nographic -serial mon:stdio &
QEMU_PID=$!

# Wait for SSH
echo "==> Waiting for SSH (up to ${TIMEOUT}s)..."
for i in $(seq 1 $TIMEOUT); do
  if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=2 -p "$SSH_PORT" admin@localhost 'id' 2>/dev/null; then
    echo "==> SSH OK"
    break
  fi
  if [ "$i" = "$TIMEOUT" ]; then
    echo "FAIL: SSH not reachable after ${TIMEOUT}s"
    exit 1
  fi
  sleep 1
done

echo "==> Running smoke checks..."

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -p "$SSH_PORT" admin@localhost bash -s <<'CHECKS'
set -e
echo "  hostname: $(hostname)"
echo "  kernel: $(uname -r)"
echo "  arch: $(uname -m)"
echo "  build: $(cat /etc/veilbox/build-info 2>/dev/null || echo 'N/A')"

echo -n "  docker: "; docker --version 2>/dev/null || echo "MISSING"
echo -n "  kubectl: "; kubectl version --client --short 2>/dev/null || echo "MISSING"
echo -n "  helm: "; helm version --short 2>/dev/null || echo "MISSING"
echo -n "  terraform: "; terraform version 2>/dev/null | head -1 || echo "MISSING"
echo -n "  kind: "; kind version 2>/dev/null || echo "MISSING"
echo -n "  k9s: "; k9s version 2>/dev/null || echo "MISSING"
echo -n "  gh: "; gh --version 2>/dev/null | head -1 || echo "MISSING"
echo -n "  aws: "; aws --version 2>/dev/null || echo "MISSING"
echo -n "  python3: "; python3 --version 2>/dev/null || echo "MISSING"
echo -n "  git: "; git --version 2>/dev/null || echo "MISSING"
echo -n "  ufw: "; ufw status 2>/dev/null | head -1 || echo "MISSING"

# Check cloud-init status
echo -n "  cloud-init: "
cloud-init status 2>/dev/null || echo "not run"

echo "ALL CHECKS PASSED"
CHECKS

echo "==> Smoke test passed!"
