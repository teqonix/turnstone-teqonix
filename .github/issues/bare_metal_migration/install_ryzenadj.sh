#!/usr/bin/env bash
# =============================================================================
# RyzenAdj, ryzen_smu & TDP Systemd Service Installation Script
#
# Fetches, builds, and installs:
# 1. ryzen_smu: Linux kernel DKMS driver for AMD Ryzen SMU access
#    Upstream: https://gitlab.com/leogx9r/ryzen_smu.git
# 2. RyzenAdj: AMD Ryzen APU/CPU power management & TDP tuning utility
#    Upstream: https://github.com/FlyGoat/RyzenAdj.git
# 3. ryzen-tdp.service: Systemd service to enforce custom TDP limits on boot
# =============================================================================

set -euo pipefail

# Color Codes for Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

trap 'log_error "An error occurred on line $LINENO. Installation stopped."; exit 1' ERR

# Default Configuration
RYZENADJ_REPO="https://github.com/FlyGoat/RyzenAdj.git"
RYZENADJ_REF="main"
RYZEN_SMU_REPO="https://gitlab.com/leogx9r/ryzen_smu.git"
RYZEN_SMU_REF="master"

INSTALL_PREFIX="/usr/local"
BIN_DIR="${INSTALL_PREFIX}/bin"
INSTALL_SMU="true"
INSTALL_SERVICE="true"
CLEAN_BUILD="true"
SKIP_DEPS="false"

# Default TDP / Power Limits (Strix Halo / Ryzen AI APU defaults)
STAPM_LIMIT="90000"   # 90W Sustained Power
FAST_LIMIT="95000"    # 95W Fast PPT Limit
SLOW_LIMIT="85000"    # 85W Slow PPT Limit
TCTL_TEMP="85"        # 85°C Thermal Throttling Limit
SERVICE_NAME="ryzen-tdp.service"

usage() {
    cat << EOF
Usage: sudo $0 [OPTIONS]

Fetches, compiles, and installs RyzenAdj, ryzen_smu, and a systemd boot service.

Options:
  -p, --prefix <path>         Installation prefix for RyzenAdj (default: /usr/local)
  -b, --branch <ref>          Git branch/tag for RyzenAdj (default: main)
      --smu-repo <url>        Git repository for ryzen_smu (default: https://gitlab.com/leogx9r/ryzen_smu.git)
      --smu-branch <ref>      Git branch/tag for ryzen_smu (default: master)
      --skip-smu              Skip building and installing the ryzen_smu DKMS kernel module
      --skip-service          Skip creating and enabling the systemd TDP boot service
      --stapm <mW>            Sustained power limit in mW (default: 90000 -> 90W)
      --fast-limit <mW>       Fast PPT power limit in mW (default: 95000 -> 95W)
      --slow-limit <mW>       Slow PPT power limit in mW (default: 85000 -> 85W)
      --tctl-temp <°C>        Max temperature limit in °C (default: 85)
      --service-name <name>   Systemd service unit name (default: ryzen-tdp.service)
      --no-clean              Keep temporary build directories after installation
      --skip-deps             Skip automatic package manager dependency installation
  -h, --help                  Display this help message and exit

Examples:
  sudo $0
  sudo $0 --stapm 80000 --fast-limit 85000 --slow-limit 75000
  sudo $0 --skip-service
  sudo $0 --prefix /usr
EOF
    exit 0
}

# Parse Command-Line Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prefix)
            INSTALL_PREFIX="$2"
            BIN_DIR="${INSTALL_PREFIX}/bin"
            shift 2
            ;;
        -b|--branch|--tag|--ref)
            RYZENADJ_REF="$2"
            shift 2
            ;;
        --smu-repo)
            RYZEN_SMU_REPO="$2"
            shift 2
            ;;
        --smu-branch)
            RYZEN_SMU_REF="$2"
            shift 2
            ;;
        --skip-smu)
            INSTALL_SMU="false"
            shift
            ;;
        --skip-service)
            INSTALL_SERVICE="false"
            shift
            ;;
        --stapm|--stapm-limit)
            STAPM_LIMIT="$2"
            shift 2
            ;;
        --fast-limit)
            FAST_LIMIT="$2"
            shift 2
            ;;
        --slow-limit)
            SLOW_LIMIT="$2"
            shift 2
            ;;
        --tctl-temp)
            TCTL_TEMP="$2"
            shift 2
            ;;
        --service-name)
            SERVICE_NAME="$2"
            shift 2
            ;;
        --no-clean)
            CLEAN_BUILD="false"
            shift
            ;;
        --skip-deps)
            SKIP_DEPS="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}   AMD RyzenAdj, ryzen_smu & TDP Boot Service Installer          ${NC}"
echo -e "${CYAN}=================================================================${NC}"

# 1. Root / Sudo Verification
log_info "Step 1: Verifying root/sudo privileges..."
if [ "$EUID" -ne 0 ]; then
    log_warn "Installing kernel modules (DKMS), systemd services, and binaries requires root/sudo."
    log_warn "Re-running script with sudo..."
    exec sudo bash "$0" "$@"
fi
log_success "Root privileges verified."

# 2. Package Manager Dependency Installation
install_dependencies() {
    log_info "Step 2: Checking and installing build dependencies..."

    if [ "$SKIP_DEPS" = "true" ]; then
        log_info "Skipping automatic dependency installation (--skip-deps requested)."
        return 0
    fi

    local kernel_ver
    kernel_ver="$(uname -r)"

    if command -v apt-get &>/dev/null; then
        log_info "Detected Debian/Ubuntu-based system (apt-get)."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq

        local apt_packages=(
            git
            build-essential
            cmake
            libpci-dev
            pkg-config
        )
        if [ "$INSTALL_SMU" = "true" ]; then
            apt_packages+=(dkms "linux-headers-${kernel_ver}")
        fi

        apt-get install -y --no-install-recommends "${apt_packages[@]}" || {
            log_warn "Could not install linux-headers-${kernel_ver} directly; trying generic linux-headers-generic..."
            apt-get install -y --no-install-recommends dkms linux-headers-generic 2>/dev/null || true
        }

    elif command -v dnf &>/dev/null; then
        log_info "Detected Fedora/RHEL-based system (dnf)."
        local dnf_packages=(
            git
            gcc
            gcc-c++
            cmake
            make
            pciutils-devel
            pkgconf-pkg-config
        )
        if [ "$INSTALL_SMU" = "true" ]; then
            dnf_packages+=(dkms "kernel-devel-${kernel_ver}" kernel-headers)
        fi
        dnf install -y "${dnf_packages[@]}" || dnf install -y kernel-devel kernel-headers || true

    elif command -v yum &>/dev/null; then
        log_info "Detected CentOS/RHEL-based system (yum)."
        local yum_packages=(
            git
            gcc
            gcc-c++
            cmake
            make
            pciutils-devel
            pkgconfig
        )
        if [ "$INSTALL_SMU" = "true" ]; then
            yum_packages+=(dkms "kernel-devel-${kernel_ver}" kernel-headers)
        fi
        yum install -y "${yum_packages[@]}" || yum install -y kernel-devel kernel-headers || true

    elif command -v pacman &>/dev/null; then
        log_info "Detected Arch Linux system (pacman)."
        local pacman_packages=(
            git
            base-devel
            cmake
            pciutils
        )
        if [ "$INSTALL_SMU" = "true" ]; then
            pacman_packages+=(dkms linux-headers)
        fi
        pacman -Sy --needed --noconfirm "${pacman_packages[@]}"

    elif command -v zypper &>/dev/null; then
        log_info "Detected openSUSE system (zypper)."
        local zypper_packages=(
            git
            gcc
            gcc-c++
            cmake
            make
            pciutils-devel
            pkg-config
        )
        if [ "$INSTALL_SMU" = "true" ]; then
            zypper_packages+=(dkms kernel-default-devel)
        fi
        zypper --non-interactive install "${zypper_packages[@]}"

    elif command -v apk &>/dev/null; then
        log_info "Detected Alpine Linux system (apk)."
        apk add --no-cache \
            git \
            build-base \
            cmake \
            pciutils-dev \
            pkgconf \
            linux-headers
    else
        log_warn "Unrecognized package manager. Please ensure git, cmake, make, gcc, dkms, and kernel headers are installed."
    fi

    # Verify essential tools exist
    local missing_tools=()
    for tool in git cmake make gcc; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ "$INSTALL_SMU" = "true" ] && ! command -v dkms &>/dev/null; then
        missing_tools+=("dkms")
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required build tools: ${missing_tools[*]}."
        log_error "Please install them using your system package manager and retry."
        exit 1
    fi

    log_success "Build dependencies verified."
}

install_dependencies

# 3. Create Temporary Build Workspace
TMP_DIR="$(mktemp -d -t ryzen-build-XXXXXX)"
log_info "Step 3: Created temporary build directory: ${TMP_DIR}"

cleanup() {
    if [ "$CLEAN_BUILD" = "true" ] && [ -d "${TMP_DIR}" ]; then
        log_info "Cleaning up temporary build files in ${TMP_DIR}..."
        rm -rf "${TMP_DIR}"
    fi
}
trap cleanup EXIT

# 4. Build and Install ryzen_smu Kernel Driver (DKMS)
install_ryzen_smu() {
    if [ "$INSTALL_SMU" != "true" ]; then
        log_info "Skipping ryzen_smu installation (--skip-smu specified)."
        return 0
    fi

    log_info "Step 4: Fetching and installing ryzen_smu DKMS kernel module..."
    log_info "Cloning ${RYZEN_SMU_REPO} (${RYZEN_SMU_REF})..."

    git clone --depth 1 --branch "${RYZEN_SMU_REF}" "${RYZEN_SMU_REPO}" "${TMP_DIR}/ryzen_smu" 2>/dev/null || \
    git clone "${RYZEN_SMU_REPO}" "${TMP_DIR}/ryzen_smu"

    cd "${TMP_DIR}/ryzen_smu"
    if [ "${RYZEN_SMU_REF}" != "master" ] && [ "${RYZEN_SMU_REF}" != "main" ]; then
        git checkout "${RYZEN_SMU_REF}" || log_warn "Using default branch for ryzen_smu."
    fi

    log_info "Installing ryzen_smu via DKMS..."

    # Check if a previous version of ryzen_smu DKMS module is registered and remove it cleanly if needed
    if dkms status ryzen_smu 2>/dev/null | grep -q "ryzen_smu"; then
        log_warn "Existing ryzen_smu DKMS registration detected. Refreshing via make dkms-install..."
        make dkms-remove 2>/dev/null || true
    fi

    make dkms-install

    log_info "Loading ryzen_smu kernel module..."
    modprobe ryzen_smu || {
        log_warn "modprobe ryzen_smu returned non-zero. Attempting with insmod or checking dmesg..."
    }

    # Configure module auto-load on boot
    if [ -d /etc/modules-load.d ]; then
        echo "ryzen_smu" > /etc/modules-load.d/ryzen_smu.conf
        log_success "Configured auto-load on boot: /etc/modules-load.d/ryzen_smu.conf"
    elif [ -f /etc/modules ]; then
        if ! grep -q "^ryzen_smu" /etc/modules; then
            echo "ryzen_smu" >> /etc/modules
            log_success "Added ryzen_smu to /etc/modules for auto-load on boot."
        fi
    fi

    # Verify SMU sysfs interface
    if lsmod | grep -q "^ryzen_smu"; then
        log_success "ryzen_smu kernel module loaded successfully!"
        if [ -d "/sys/kernel/ryzen_smu" ]; then
            log_info "SMU sysfs nodes available at /sys/kernel/ryzen_smu:"
            ls -la /sys/kernel/ryzen_smu || true
        fi
    else
        log_warn "ryzen_smu module not yet active in current session (a kernel reboot or header sync may be required)."
    fi
}

install_ryzen_smu

# 5. Clone and Build RyzenAdj
log_info "Step 5: Fetching and building RyzenAdj (${RYZENADJ_REF})..."
git clone --depth 1 --branch "${RYZENADJ_REF}" "${RYZENADJ_REPO}" "${TMP_DIR}/RyzenAdj" 2>/dev/null || \
git clone "${RYZENADJ_REPO}" "${TMP_DIR}/RyzenAdj"

cd "${TMP_DIR}/RyzenAdj"
if [ "${RYZENADJ_REF}" != "main" ] && [ "${RYZENADJ_REF}" != "master" ]; then
    git checkout "${RYZENADJ_REF}" || log_warn "Using default branch for RyzenAdj."
fi

log_info "Configuring and compiling RyzenAdj with CMake..."
mkdir -p build
cd build

NUM_CORES="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" ..
cmake --build . --parallel "${NUM_CORES}"

log_success "RyzenAdj compilation finished successfully."

# 6. Install to PATH
log_info "Step 6: Installing binary and libraries to ${INSTALL_PREFIX}..."
mkdir -p "${BIN_DIR}"

if cmake --install . --prefix "${INSTALL_PREFIX}" 2>/dev/null; then
    log_info "CMake install target succeeded."
else
    log_warn "Standard cmake install target fallback: copying binaries manually..."
    if [ -f "ryzenadj" ]; then
        install -m 0755 ryzenadj "${BIN_DIR}/ryzenadj"
    elif [ -f "bin/ryzenadj" ]; then
        install -m 0755 bin/ryzenadj "${BIN_DIR}/ryzenadj"
    fi

    # Copy shared libraries if present
    if [ -d "${INSTALL_PREFIX}/lib" ]; then
        find . -maxdepth 2 -name "libryzenadj.so*" -exec cp -a {} "${INSTALL_PREFIX}/lib/" \; 2>/dev/null || true
    fi
fi

# Ensure executable permissions
chmod 0755 "${BIN_DIR}/ryzenadj"

# Refresh dynamic linker cache if installed to system library path
if [ -d "${INSTALL_PREFIX}/lib" ] && command -v ldconfig &>/dev/null; then
    ldconfig 2>/dev/null || true
fi

# 7. Verify Installation & PATH Availability
log_info "Step 7: Verifying installation and PATH availability..."

if ! command -v ryzenadj &>/dev/null; then
    if [ -f "${BIN_DIR}/ryzenadj" ]; then
        log_warn "Binary installed at ${BIN_DIR}/ryzenadj, but '${BIN_DIR}' is not in active PATH."
        log_warn "Add the following line to your shell profile (~/.bashrc or /etc/profile):"
        echo -e "    ${YELLOW}export PATH=\"${BIN_DIR}:\$PATH\"${NC}"
    else
        log_error "ryzenadj binary not found after installation."
        exit 1
    fi
else
    INSTALLED_PATH="$(command -v ryzenadj)"
    log_success "ryzenadj successfully located in PATH at: ${INSTALLED_PATH}"
fi

# 8. Install and Enable Systemd TDP Power Limit Service
install_systemd_service() {
    if [ "$INSTALL_SERVICE" != "true" ]; then
        log_info "Skipping systemd TDP service installation (--skip-service specified)."
        return 0
    fi

    if ! command -v systemctl &>/dev/null; then
        log_warn "systemctl not found on this system. Skipping systemd service configuration."
        return 0
    fi

    log_info "Step 8: Installing and configuring systemd TDP power limit service..."

    local service_path="/etc/systemd/system/${SERVICE_NAME}"
    local calculated_wattage=$(( FAST_LIMIT / 1000 ))

    log_info "Writing ${service_path} (Target Power: ~${calculated_wattage}W)..."

    cat << EOF > "${service_path}"
[Unit]
Description=Set AMD APU TDP Power Limit to ${calculated_wattage}W
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${BIN_DIR}/ryzenadj --stapm-limit=${STAPM_LIMIT} --fast-limit=${FAST_LIMIT} --slow-limit=${SLOW_LIMIT} --tctl-temp=${TCTL_TEMP}

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "${service_path}"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"

    log_info "Starting ${SERVICE_NAME} to apply TDP limits immediately..."
    if systemctl restart "${SERVICE_NAME}"; then
        log_success "${SERVICE_NAME} enabled and successfully started."
    else
        log_warn "Could not immediately start ${SERVICE_NAME}. Check 'journalctl -u ${SERVICE_NAME}' for details."
    fi
}

install_systemd_service

# 9. Print Summary and Quick Usage
echo ""
echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}      RyzenAdj & TDP Boot Service Installation Complete!         ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "RyzenAdj Binary:  ${CYAN}${BIN_DIR}/ryzenadj${NC}"
if [ "$INSTALL_SMU" = "true" ]; then
    SMU_STATUS="$(lsmod | grep -q ryzen_smu && echo -e "${GREEN}Loaded${NC}" || echo -e "${YELLOW}Installed (DKMS)${NC}")"
    echo -e "ryzen_smu Driver:  ${SMU_STATUS} (/sys/kernel/ryzen_smu)"
fi
if [ "$INSTALL_SERVICE" = "true" ] && command -v systemctl &>/dev/null; then
    echo -e "Systemd Service:   ${GREEN}Enabled${NC} (/etc/systemd/system/${SERVICE_NAME})"
    echo -e "Enforced Limits:   STAPM=${STAPM_LIMIT}mW (~$(( STAPM_LIMIT / 1000 ))W) | Fast=${FAST_LIMIT}mW (~$(( FAST_LIMIT / 1000 ))W) | Slow=${SLOW_LIMIT}mW (~$(( SLOW_LIMIT / 1000 ))W) | Temp=${TCTL_TEMP}°C"
fi
echo ""
echo -e "${BLUE}Useful Commands:${NC}"
echo -e "  ${CYAN}sudo ryzenadj -i${NC}                                     # Inspect live power/thermal metrics"
echo -e "  ${CYAN}sudo systemctl status ${SERVICE_NAME}${NC}                       # Check TDP service status"
echo -e "  ${CYAN}sudo systemctl restart ${SERVICE_NAME}${NC}                      # Re-apply configured boot TDP limits"
if [ "$INSTALL_SMU" = "true" ]; then
    echo -e "  ${CYAN}cat /sys/kernel/ryzen_smu/smu_version${NC}                  # Check SMU firmware version"
    echo -e "  ${CYAN}dkms status ryzen_smu${NC}                                    # Check DKMS kernel driver status"
fi
echo ""
