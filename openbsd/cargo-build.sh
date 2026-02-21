#!/bin/sh
# Build a Rust project on OpenBSD via SSH
#
# Syncs a local project folder to the VM, runs cargo build with the
# specified profile, and copies the resulting binary back to the host.
#
# Usage:
#   ./cargo-build.sh [--stop] [--profile <name>] <project-dir> [output-dir] [-- cargo args...]
#
# Options:
#   --stop             Shutdown the VM after a successful build
#   --profile <name>   Cargo build profile (default: release)
#                      Use "dev" for debug builds, or any custom profile
#
# Examples:
#   ./cargo-build.sh ~/src/myproject
#   ./cargo-build.sh --profile dev ~/src/myproject
#   ./cargo-build.sh --profile release-lto ~/src/myproject ./dist
#   ./cargo-build.sh --stop ~/src/myproject ./dist
#   ./cargo-build.sh ~/src/myproject ./dist -- -p mycrate --features foo
#
# The binary name is detected from Cargo.toml [[bin]] or package name.
# Requires: openbsd-builder entry in ~/.ssh/config (created by autoinstall.sh)
#
# Configuration (environment variables):
#   OPENBSD_SSH_HOST  SSH host alias       (default: openbsd-builder)

set -eu

SSH_HOST="${OPENBSD_SSH_HOST:-openbsd-builder}"

# ── Argument parsing ─────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [--stop] [--profile <name>] <project-dir> [output-dir] [-- cargo args...]"
    echo ""
    echo "  --stop             Shutdown the VM after a successful build"
    echo "  --profile <name>   Cargo build profile (default: release)"
    echo "  project-dir        Local Rust project directory (must contain Cargo.toml)"
    echo "  output-dir         Where to copy the binary (default: <project-dir>/target/openbsd)"
    echo "  cargo args         Extra arguments passed to cargo build (after --)"
    exit 1
}

STOP_VM=false
PROFILE="release"
while [ $# -gt 0 ]; do
    case "$1" in
        --stop)
            STOP_VM=true
            shift
            ;;
        --profile)
            [ $# -lt 2 ] && { echo "Error: --profile requires a value"; exit 1; }
            PROFILE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            break
            ;;
    esac
done

[ $# -lt 1 ] && usage

PROJECT_DIR="$(cd "$1" && pwd)"
shift

if [ ! -f "$PROJECT_DIR/Cargo.toml" ]; then
    echo "Error: No Cargo.toml in $PROJECT_DIR"
    exit 1
fi

# Output dir (optional, before --)
OUTPUT_DIR=""
EXTRA_CARGO_ARGS=""
if [ $# -gt 0 ] && [ "$1" != "--" ]; then
    OUTPUT_DIR="$1"
    shift
fi

# Extra cargo args (after --)
if [ $# -gt 0 ] && [ "$1" = "--" ]; then
    shift
    EXTRA_CARGO_ARGS="$*"
fi

PROJECT_NAME="$(basename "$PROJECT_DIR")"
REMOTE_DIR="/home/\$(whoami)/${PROJECT_NAME}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/target/openbsd}"

# ── Verify SSH connectivity ──────────────────────────────────────────────────

if ! ssh "$SSH_HOST" true 2>/dev/null; then
    echo "Error: Cannot reach $SSH_HOST via SSH"
    echo "Is the VM running? Try: ./autoinstall.sh --boot --daemon"
    exit 1
fi

REMOTE_USER=$(ssh "$SSH_HOST" whoami)
REMOTE_DIR="/home/${REMOTE_USER}/${PROJECT_NAME}"

# Cargo maps "dev" profile to target/debug, all others to target/<profile>
if [ "$PROFILE" = "dev" ]; then
    TARGET_SUBDIR="debug"
else
    TARGET_SUBDIR="$PROFILE"
fi

echo "==> Building ${PROJECT_NAME} on OpenBSD (${SSH_HOST}) [profile: ${PROFILE}]"

# ── Sync source ─────────────────────────────────────────────────────────────

echo "==> Syncing source to ${SSH_HOST}:${REMOTE_DIR}..."
ssh "$SSH_HOST" "mkdir -p $REMOTE_DIR"
rsync -az --delete \
    -e "ssh" \
    --exclude 'target/' \
    --exclude '.git/' \
    "$PROJECT_DIR/" \
    "${SSH_HOST}:${REMOTE_DIR}/"

# ── Build ────────────────────────────────────────────────────────────────────

echo "==> Running cargo build --profile ${PROFILE} ${EXTRA_CARGO_ARGS}..."
ssh "$SSH_HOST" "cd $REMOTE_DIR && cargo build --profile $PROFILE $EXTRA_CARGO_ARGS"

# ── Detect binary names ─────────────────────────────────────────────────────

BINARIES=$(ssh "$SSH_HOST" "cd $REMOTE_DIR/target/${TARGET_SUBDIR} && find . -maxdepth 1 -type f -perm -111 ! -name '*.so' ! -name '*.dylib' ! -name '*.d' -exec basename {} \;" 2>/dev/null) || true

if [ -z "$BINARIES" ]; then
    BINARIES=$(ssh "$SSH_HOST" "sed -n 's/^name = \"\(.*\)\"/\1/p' $REMOTE_DIR/Cargo.toml | head -1")
fi

# ── Copy binaries back ──────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"
echo "==> Copying binaries to ${OUTPUT_DIR}..."

for bin in $BINARIES; do
    REMOTE_PATH="$REMOTE_DIR/target/${TARGET_SUBDIR}/$bin"
    if ssh "$SSH_HOST" "test -f '$REMOTE_PATH'" 2>/dev/null; then
        scp "${SSH_HOST}:${REMOTE_PATH}" "$OUTPUT_DIR/$bin"
        echo "    $bin"
    fi
done

echo "==> Done. Binaries in ${OUTPUT_DIR}/"
ls -lh "$OUTPUT_DIR/"

if [ "$STOP_VM" = true ]; then
    echo "==> Shutting down VM..."
    ssh "$SSH_HOST" "doas shutdown -p now" 2>/dev/null || true
fi
