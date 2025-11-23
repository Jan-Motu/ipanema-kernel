#!/usr/bin/env bash
set -euo pipefail

# Simple helper to ensure required tools exist before we start.
require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command '$1' is not available." >&2
        exit 1
    fi
}

require_command git
require_command make
require_command dpkg
require_command python3
require_command sudo
require_command nproc

usage() {
    cat <<'EOF'
Usage: build_install_ipanema.sh [--release] [--reuse-config]

    --release        Drop the "-test" suffix and produce a release build (e.g., 6.8.4-ipanema).
    --reuse-config   Skip copying the running kernel config and reusing the existing build .config.
EOF
}

RELEASE_MODE=0
REUSE_CONFIG=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            RELEASE_MODE=1
            shift
            ;;
        --reuse-config)
            REUSE_CONFIG=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
if (( RELEASE_MODE )); then
    LOCALVERSION_SUFFIX="-ipanema"
else
    LOCALVERSION_SUFFIX="-ipanema-test"
fi
BUILD_DIR="${REPO_ROOT}/build-${LOCALVERSION_SUFFIX#-}"
DEB_DEST="${BUILD_DIR}/debs"
JOBS="${JOBS:-$(( $(nproc) + 1 ))}"
HOST_CONFIG="/boot/config-$(uname -r)"

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "This script must live inside the ipanema kernel git repository (git metadata not accessible)." >&2
    exit 1
fi

BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" == "bugfix/repair-ipanema-policy-counters" ]]; then
    echo "On branch ${BRANCH}; pulling latest changes..."
    git -C "$REPO_ROOT" pull --ff-only
fi

if [[ ! -f "$HOST_CONFIG" ]]; then
    echo "Unable to locate the current kernel config at ${HOST_CONFIG}." >&2
    exit 1
fi

mkdir -p "$BUILD_DIR" "$DEB_DEST"

if (( REUSE_CONFIG )); then
    if [[ -f "$BUILD_DIR/.config" ]]; then
        echo "Reusing existing configuration at ${BUILD_DIR}/.config"
    elif [[ -f "$REPO_ROOT/.config" ]]; then
        echo "--reuse-config requested but ${BUILD_DIR}/.config missing; copying ${REPO_ROOT}/.config..."
        cp "$REPO_ROOT/.config" "$BUILD_DIR/.config"
        echo "Reusing configuration from ${REPO_ROOT}/.config"
    else
        echo "--reuse-config was specified but neither ${BUILD_DIR}/.config nor ${REPO_ROOT}/.config exist." >&2
        echo "Create or copy your desired config first, or omit --reuse-config." >&2
        exit 1
    fi
else
    echo "Copying running kernel config from ${HOST_CONFIG}..."
    cp "$HOST_CONFIG" "$BUILD_DIR/.config"

    echo "Refreshing configuration using oldconfig (interactive)..."
    make -C "$REPO_ROOT" O="$BUILD_DIR" oldconfig
fi

if [[ ! -f "$BUILD_DIR/include/config/auto.conf" || ! -f "$BUILD_DIR/include/generated/autoconf.h" ]]; then
    echo "Kernel autoconf metadata missing; running oldconfig to regenerate (you may be prompted)..."
    make -C "$REPO_ROOT" O="$BUILD_DIR" oldconfig
fi

CONFIG_TOOL="$REPO_ROOT/scripts/config"
if [[ ! -x "$CONFIG_TOOL" ]]; then
    echo "Expected helper $CONFIG_TOOL not found or not executable." >&2
    exit 1
fi

echo "Clearing CONFIG_SYSTEM_TRUSTED_KEYS to avoid distro-provided certificate paths..."
"$CONFIG_TOOL" --file "$BUILD_DIR/.config" --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""

echo "Clearing CONFIG_SYSTEM_REVOCATION_KEYS to avoid distro revocation bundles..."
"$CONFIG_TOOL" --file "$BUILD_DIR/.config" --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""

echo "Propagating certificate config updates with olddefconfig..."
make -C "$REPO_ROOT" O="$BUILD_DIR" olddefconfig >/dev/null

echo "Determining target kernel release..."
kernel_release="$(make -C "$REPO_ROOT" O="$BUILD_DIR" -s kernelrelease LOCALVERSION="$LOCALVERSION_SUFFIX")"

echo "Building Debian packages for ${kernel_release} with ${JOBS} parallel jobs..."
KDEB_DESTDIR="$DEB_DEST" \
    LOCALVERSION="$LOCALVERSION_SUFFIX" \
    make -C "$REPO_ROOT" O="$BUILD_DIR" -j "$JOBS" bindeb-pkg

candidate_dirs=("$DEB_DEST" "$REPO_ROOT" "$(dirname "$REPO_ROOT")")
find_package() {
    local pattern="$1"
    shift
    local match search_dir
    for search_dir in "$@"; do
        [[ -d "$search_dir" ]] || continue
        match=$(find "$search_dir" -maxdepth 1 -type f -name "$pattern" -print 2>/dev/null | sort | tail -n1)
        if [[ -n "$match" ]]; then
            printf '%s\n' "$match"
            return 0
        fi
    done
    return 1
}

image_deb="$(find_package "linux-image-${kernel_release}_*.deb" "${candidate_dirs[@]}" || true)"
headers_deb="$(find_package "linux-headers-${kernel_release}_*.deb" "${candidate_dirs[@]}" || true)"

if [[ -z "$image_deb" ]]; then
    echo "Failed to locate linux-image package for ${kernel_release} in ${DEB_DEST}." >&2
    exit 1
fi
if [[ -z "$headers_deb" ]]; then
    echo "Failed to locate linux-headers package for ${kernel_release} in ${DEB_DEST}." >&2
    exit 1
fi

echo "Installing ${headers_deb} and ${image_deb}..."
sudo dpkg -i "$headers_deb" "$image_deb"

echo "Attempting to set ${kernel_release} as the default GRUB entry..."
menu_entry="$(sudo python3 - "$kernel_release" <<'PY'
import sys
kernel = sys.argv[1]
stack = []
try:
    fh = open("/boot/grub/grub.cfg")
except FileNotFoundError:
    sys.exit(2)
for raw in fh:
    stripped = raw.strip()
    if stripped.startswith("submenu '"):
        name = stripped.split("'", 2)[1]
        stack.append(name)
    elif stripped.startswith("}") and stack:
        stack.pop()
    elif stripped.startswith("menuentry '"):
        name = stripped.split("'", 2)[1]
        if kernel in name and "recovery mode" not in name:
            if stack:
                print(">".join(stack + [name]))
            else:
                print(name)
            break
else:
    sys.exit(1)
PY
)"

if [[ -z "$menu_entry" ]]; then
    echo "Could not detect the GRUB menu entry for ${kernel_release}." >&2
    echo "Please set the default kernel manually before rebooting." >&2
else
    if command -v grubby >/dev/null 2>&1; then
        echo "Using grubby to set default kernel..."
        sudo grubby --set-default "/boot/vmlinuz-${kernel_release}"
    elif command -v grub2-set-default >/dev/null 2>&1; then
        echo "Using grub2-set-default for entry: ${menu_entry}"
        sudo grub2-set-default "$menu_entry"
    elif command -v grub-set-default >/dev/null 2>&1; then
        echo "Using grub-set-default for entry: ${menu_entry}"
        sudo grub-set-default "$menu_entry"
    else
        echo "No grub default-setting tool available. Selected entry: ${menu_entry}" >&2
        echo "Use your distribution's grub tooling to make it default." >&2
    fi
fi

echo "Kernel ${kernel_release} installed. Reboot when ready (e.g., run 'sudo reboot')."
