#!/bin/sh
# Autoinstall OpenBSD on QEMU
#
# Based on: https://www.skreutz.com/posts/autoinstall-openbsd-on-qemu/
#
# Usage:
#   ./autoinstall.sh                # Install OpenBSD (interactive console)
#   ./autoinstall.sh --boot         # Boot existing image (serial console)
#   ./autoinstall.sh --boot --daemon # Boot in background (daemonize)
#   ./autoinstall.sh --clean        # Remove work directory
#   ./autoinstall.sh --help         # Show help
#
# Configuration (environment variables with defaults):
#   OPENBSD_VERSION   OpenBSD version           (default: 7.7)
#   OPENBSD_MIRROR    Mirror base URL            (default: https://openbsd.c3sl.ufpr.br/pub/OpenBSD)
#   OPENBSD_CPUS      Number of CPUs             (default: 4)
#   OPENBSD_MEM       Memory size                (default: 4G)
#   OPENBSD_DISK      Disk size                  (default: 20G)
#   OPENBSD_SSH_KEY   Path to SSH public key     (default: ~/.ssh/id_ed25519.pub)
#   OPENBSD_USER      Username to create in VM   (default: current user)
#   OPENBSD_HOSTNAME  VM hostname                (default: openbsd)
#   OPENBSD_IMAGE     Output disk image path     (default: ~/vms/openbsd<ver>/openbsd<ver>.qcow2)
#   OPENBSD_SSH_PORT  Host port for SSH forward  (default: 7722)
#
# Prerequisites (Arch Linux):
#   pacman -S qemu-full python curl
#
# Port 80 access (one-time, needed for OpenBSD autoinstall discovery):
#   sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
#   # To make permanent: add to /etc/sysctl.d/99-local.conf
#
# After installation, connect with:
#   ssh -p 7722 <user>@127.0.0.1

set -eu

# ── Configuration ────────────────────────────────────────────────────────────

VERSION="${OPENBSD_VERSION:-7.7}"
MIRROR="${OPENBSD_MIRROR:-https://openbsd.c3sl.ufpr.br/pub/OpenBSD}"
CPUS="${OPENBSD_CPUS:-4}"
MEM="${OPENBSD_MEM:-4G}"
DISK_SIZE="${OPENBSD_DISK:-20G}"
SSH_KEY_FILE="${OPENBSD_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
VM_USER="${OPENBSD_USER:-$(whoami)}"
VM_HOSTNAME="${OPENBSD_HOSTNAME:-openbsd-builder.tesseras.local}"
SSH_PORT="${OPENBSD_SSH_PORT:-7722}"

VSHORT=$(echo "$VERSION" | tr -d '.')
ARCH="amd64"
IMAGE="${OPENBSD_IMAGE:-$HOME/vms/openbsd${VSHORT}/openbsd${VSHORT}.qcow2}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$SCRIPT_DIR/.autoinstall-work"

# ── Argument parsing ─────────────────────────────────────────────────────────

MODE="install"
DAEMON=false
for arg in "$@"; do
    case "$arg" in
        --boot)   MODE="boot" ;;
        --daemon) DAEMON=true ;;
        --clean)  MODE="clean" ;;
        --help|-h) MODE="help" ;;
    esac
done

# ── Help ─────────────────────────────────────────────────────────────────────

if [ "$MODE" = "help" ]; then
    sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"
    exit 0
fi

# ── Clean ────────────────────────────────────────────────────────────────────

if [ "$MODE" = "clean" ]; then
    echo "==> Removing work directory: $WORK_DIR"
    rm -rf "$WORK_DIR"
    echo "==> Done (disk image at $IMAGE was NOT removed)"
    exit 0
fi

# ── Boot existing image ─────────────────────────────────────────────────────

if [ "$MODE" = "boot" ]; then
    if [ ! -f "$IMAGE" ]; then
        echo "Error: disk image not found: $IMAGE"
        echo "Run ./autoinstall.sh first to install."
        exit 1
    fi

    DISPLAY_OPTS="-nodefaults -serial mon:stdio -nographic"
    if [ "$DAEMON" = true ]; then
        DISPLAY_OPTS="-nodefaults -serial null -display none -daemonize"
    fi

    echo "==> Booting OpenBSD ${VERSION} ($MEM RAM, $CPUS CPUs)"
    echo "    SSH: ssh -p ${SSH_PORT} ${VM_USER}@127.0.0.1"
    if [ "$DAEMON" = false ]; then
        echo "    Exit: Ctrl-A X"
    fi

    # shellcheck disable=SC2086
    qemu-system-x86_64 \
        -enable-kvm \
        -cpu host \
        -machine q35,accel=kvm \
        -smp "cpus=${CPUS}" \
        -m "$MEM" \
        -mem-prealloc \
        -boot c \
        -drive "file=${IMAGE},format=qcow2,if=virtio,cache=unsafe,aio=io_uring" \
        -device virtio-net-pci,netdev=net0 \
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
        $DISPLAY_OPTS

    if [ "$DAEMON" = true ]; then
        echo "    Waiting for SSH..."
        i=0
        while [ "$i" -lt 60 ]; do
            if ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${VM_USER}@127.0.0.1" true 2>/dev/null; then
                echo "    SSH ready!"
                exit 0
            fi
            i=$((i + 1))
            sleep 2
        done
        echo "    Warning: SSH not ready after 120s (VM may still be booting)"
    fi
    exit 0
fi

# ── Install mode ─────────────────────────────────────────────────────────────

# Check prerequisites
for cmd in qemu-system-x86_64 qemu-img python3 curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd not found. Install prerequisites first."
        exit 1
    fi
done

if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "Error: SSH public key not found: $SSH_KEY_FILE"
    echo "Set OPENBSD_SSH_KEY to your public key path."
    exit 1
fi
SSH_KEY=$(cat "$SSH_KEY_FILE")

if [ -f "$IMAGE" ]; then
    echo "Error: disk image already exists: $IMAGE"
    echo "Delete it first to reinstall, or use --boot to boot it."
    exit 1
fi

# Check port 80 access (SLIRP NAT forwards guest 10.0.2.2:80 → host 127.0.0.1:80)
if ! python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',80)); s.close()" 2>/dev/null; then
    echo "Error: Cannot bind to port 80 on 127.0.0.1"
    echo "The OpenBSD installer needs HTTP on port 80 via QEMU SLIRP NAT."
    echo ""
    echo "Fix with:"
    echo "  sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80"
    echo ""
    echo "To make permanent, add to /etc/sysctl.d/99-local.conf:"
    echo "  net.ipv4.ip_unprivileged_port_start=80"
    exit 1
fi

echo "==> OpenBSD ${VERSION} autoinstall on QEMU"
echo "    Mirror:   ${MIRROR}"
echo "    CPUs:     ${CPUS}"
echo "    Memory:   ${MEM}"
echo "    Disk:     ${DISK_SIZE}"
echo "    User:     ${VM_USER}"
echo "    Hostname: ${VM_HOSTNAME}"
echo "    Image:    ${IMAGE}"
echo "    SSH port: ${SSH_PORT}"
echo ""

# ── Create directory structure ───────────────────────────────────────────────

MIRROR_DIR="$WORK_DIR/mirror/pub/OpenBSD/${VERSION}/${ARCH}"
mkdir -p "$MIRROR_DIR"
mkdir -p "$WORK_DIR/site"
mkdir -p "$WORK_DIR/tftp/etc"

# ── Download sets ────────────────────────────────────────────────────────────

SETS="SHA256.sig bsd bsd.mp bsd.rd pxeboot"
SETS="$SETS base${VSHORT}.tgz comp${VSHORT}.tgz man${VSHORT}.tgz"
SETS="$SETS BUILDINFO"

echo "==> Downloading OpenBSD ${VERSION} sets..."
for f in $SETS; do
    if [ -f "$MIRROR_DIR/$f" ]; then
        echo "    $f (cached)"
    else
        echo "    $f"
        curl -# -f -o "$MIRROR_DIR/$f" "${MIRROR}/${VERSION}/${ARCH}/$f"
    fi
done

# ── Generate install.conf ───────────────────────────────────────────────────
# OpenBSD 7.x autoinstall: installer fetches http://<siaddr>/install.conf
# QEMU SLIRP NAT: guest 10.0.2.2:80 → host 127.0.0.1:80

echo "==> Generating install.conf..."
cat > "$WORK_DIR/mirror/install.conf" << EOF
Change the default console to com0 = yes
Which speed should com0 use = 115200
System hostname = ${VM_HOSTNAME}
Password for root = *************
Allow root ssh login = no
Setup a user = ${VM_USER}
Password for user = *************
Public ssh key for user = ${SSH_KEY}
What timezone are you in = UTC
Location of sets = http
HTTP Server = 10.0.2.2
Unable to connect using https. Use http instead = yes
URL to autopartitioning template for disklabel = http://10.0.2.2/disklabel
Set name(s) = -game${VSHORT}.tgz -xbase${VSHORT}.tgz -xfont${VSHORT}.tgz -xserv${VSHORT}.tgz -xshare${VSHORT}.tgz site${VSHORT}.tgz
Checksum test for site${VSHORT}.tgz failed. Continue anyway = yes
Unverified sets: site${VSHORT}.tgz. Continue without verification = yes
Fetching of BUILDINFO failed. Continue anyway = yes
EOF

# ── Generate disklabel (single / partition, full disk) ───────────────────────

echo "==> Generating disklabel..."
printf '/ *\n' > "$WORK_DIR/mirror/disklabel"

# ── Generate install.site ───────────────────────────────────────────────────

echo "==> Generating install.site..."
cat > "$WORK_DIR/site/install.site" << SITEEOF
#!/bin/ksh
set -o errexit

# Package mirror
echo "${MIRROR}" > /etc/installurl

# Enable SMT for better build performance
echo "hw.smt=1" >> /etc/sysctl.conf

# Enable ACPI power button shutdown (for QEMU system_powerdown)
echo "machdep.pwraction=1" >> /etc/sysctl.conf

# doas permission for ${VM_USER}
echo "permit nopass keepenv ${VM_USER}" >> /etc/doas.conf

# Enable apmd for ACPI events, disable unnecessary daemons
rcctl enable apmd
rcctl disable sndiod
rcctl disable smtpd
rcctl disable slaacd
rcctl disable cron
rcctl disable pflogd
rcctl disable syslogd
rcctl disable ntpd
rcctl disable resolvd

# Install rust, rsync on first boot, then shutdown
cat >> /etc/rc.firsttime << 'FIRSTTIME'
pkg_add rust just rsync-- sqlite3
shutdown -p now
FIRSTTIME
SITEEOF
chmod +x "$WORK_DIR/site/install.site"

# Package site set
echo "==> Packaging site${VSHORT}.tgz..."
(cd "$WORK_DIR/site" && tar -czf "$MIRROR_DIR/site${VSHORT}.tgz" .)
(cd "$MIRROR_DIR" && ls -l > index.txt)

# ── Setup TFTP for PXE boot ─────────────────────────────────────────────────

echo "==> Setting up TFTP..."
ln -sf "$MIRROR_DIR/pxeboot" "$WORK_DIR/tftp/auto_install"
ln -sf "$MIRROR_DIR/bsd.rd" "$WORK_DIR/tftp/bsd.rd"

cat > "$WORK_DIR/tftp/etc/boot.conf" << 'EOF'
stty com0 115200
set tty com0
boot tftp:/bsd.rd
EOF

# ── Create disk image ───────────────────────────────────────────────────────

echo "==> Creating disk image ($DISK_SIZE)..."
mkdir -p "$(dirname "$IMAGE")"
qemu-img create -f qcow2 "$IMAGE" "$DISK_SIZE"

# ── Start HTTP server ───────────────────────────────────────────────────────
# Serves on port 80 — SLIRP NAT forwards guest 10.0.2.2:80 → host 127.0.0.1:80

echo "==> Starting HTTP server on 127.0.0.1:80..."
python3 -m http.server --directory "$WORK_DIR/mirror" --bind 127.0.0.1 80 &
HTTP_PID=$!
trap 'kill $HTTP_PID 2>/dev/null || true' EXIT INT TERM
sleep 1

if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "Error: HTTP server failed to start on port 80"
    exit 1
fi

# ── Launch QEMU ─────────────────────────────────────────────────────────────

echo "==> Installing OpenBSD ${VERSION}..."
echo "    This takes ~5-10 minutes. The VM will reboot after install."
echo "    On first boot, rc.firsttime installs packages then shuts down the VM."
echo ""

qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -machine q35,accel=kvm \
    -smp "cpus=${CPUS}" \
    -m "$MEM" \
    -mem-prealloc \
    -drive "file=${IMAGE},media=disk,if=virtio,cache=unsafe,aio=io_uring" \
    -device virtio-net-pci,netdev=n1 \
    -netdev "user,id=n1,hostname=${VM_HOSTNAME},tftp=$WORK_DIR/tftp,bootfile=auto_install,hostfwd=tcp::${SSH_PORT}-:22" \
    -nographic

echo ""
echo "==> Installation complete!"

# ── Add SSH config entry ────────────────────────────────────────────────────

SSH_CONFIG="$HOME/.ssh/config"
if [ -f "$SSH_CONFIG" ] && grep -q "^Host openbsd-builder$" "$SSH_CONFIG"; then
    echo "==> SSH config: openbsd-builder already exists"
else
    echo "==> Adding openbsd-builder to $SSH_CONFIG..."
    mkdir -p "$HOME/.ssh"
    cat >> "$SSH_CONFIG" << SSHEOF

Host openbsd-builder
	HostName 127.0.0.1
	Port ${SSH_PORT}
	User ${VM_USER}
	IdentityFile ${SSH_KEY_FILE%.pub}
	StrictHostKeyChecking no
	UserKnownHostsFile /dev/null
	LogLevel ERROR
SSHEOF
    chmod 600 "$SSH_CONFIG"
    echo "    ssh openbsd-builder"
fi

echo ""
echo "Boot the VM:"
echo "  ./autoinstall.sh --boot"
echo "  ./autoinstall.sh --boot --daemon   # background"
echo ""
echo "Connect:"
echo "  ssh openbsd-builder"
