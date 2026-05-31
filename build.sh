#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Orange Pi 5 Plus Arch Linux ARM Image Builder
# From-scratch build of U-Boot, Linux kernel, and complete system image
# =============================================================================
#
# Usage:
#   ./build.sh                         Full build (all stages)
#   ./build.sh --target sd             Build SD card image (U-Boot on image, default)
#   ./build.sh --target nvme           Build NVMe disk image (U-Boot on SPI flash)
#   ./build.sh --stage N               Run from stage N (0-7) onward
#   ./build.sh --clean                 Remove all build artifacts
#   ./build.sh --no-kernel             Skip kernel build (testing only)
#   ./build.sh --packages-only         Build kernel packages only (no rootfs/image)
#   ./build.sh --help                  Show detailed usage
#
# Stages:
#   0: Environment check               4: Build U-Boot
#   1: Cross-compilation toolchain     5: Build Linux kernel
#   2: Get rkbin (DDR init blob)       6: Prepare root filesystem
#   3: Build TF-A (BL31)               7: Assemble disk image
#                                      8: Package kernel as .pkg.tar.zst
#
# Environment variables (optional):
#   CROSS_COMPILE   Cross-compiler prefix (default: aarch64-linux-gnu-)
#   BUILD_JOBS      Parallel build jobs (default: nproc)
#   ROOT_FSTYPE     Root filesystem (xfs or ext4, default: xfs)
#   ALARM_MIRROR    Arch Linux ARM mirror (default: mirrors.tuna.tsinghua.edu.cn)
#
# =============================================================================

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
BOARD="orangepi-5-plus"
UBOOT_DEFCONFIG="orangepi-5-plus-rk3588_defconfig"

TARGET="${TARGET:-sd}"                # sd, emmc, or nvme (SPI flash boot)
IMAGE_SIZE_MB=8192
BOOT_SIZE_MB=512
BOOT_START_MB=1
ROOT_START_MB=$((BOOT_START_MB + BOOT_SIZE_MB))
ROOT_SIZE_MB=$((IMAGE_SIZE_MB - ROOT_START_MB))
ROOT_FSTYPE="${ROOT_FSTYPE:-xfs}"     # xfs or ext4

# ---------------------------------------------------------------------------
# Mirror sources: auto-detect GitHub Actions vs local (China) build
# ---------------------------------------------------------------------------
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    # GitHub Actions: use official upstream sources (fast from GitHub infra)
    ALARM_MIRROR="http://os.archlinuxarm.org"
    UBOOT_REPO="https://source.denx.de/u-boot/u-boot.git"
    LINUX_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
    TFA_REPO="https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git"
    RKBIN_REPO="https://github.com/armbian/rkbin.git"
    RKBIN_TARBALL="https://github.com/armbian/rkbin/archive/refs/heads/master.tar.gz"
    TOOLCHAIN_VERSION="15.2.rel1"
    TOOLCHAIN_URL="https://developer.arm.com/-/media/Files/downloads/gnu/${TOOLCHAIN_VERSION}/binrel/arm-gnu-toolchain-${TOOLCHAIN_VERSION}-x86_64-aarch64-none-linux-gnu.tar.xz"
    TOOLCHAIN_URL_FALLBACK="$TOOLCHAIN_URL"
else
    # Local build (China): use Chinese mirrors for faster downloads
    ALARM_MIRROR="${ALARM_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm}"
    UBOOT_REPO="https://gitee.com/u-boot/u-boot.git"
    LINUX_REPO="https://mirrors.ustc.edu.cn/linux.git"
    TFA_REPO="https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git"
    RKBIN_REPO="https://github.com/armbian/rkbin.git"
    RKBIN_TARBALL="https://github.com/armbian/rkbin/archive/refs/heads/master.tar.gz"
    TOOLCHAIN_VERSION="15.2.rel1"
    TOOLCHAIN_URL="https://mirrors.huaweicloud.com/arm-gnu-toolchain/${TOOLCHAIN_VERSION}/binrel/arm-gnu-toolchain-${TOOLCHAIN_VERSION}-x86_64-aarch64-none-linux-gnu.tar.xz"
    TOOLCHAIN_URL_FALLBACK="https://developer.arm.com/-/media/Files/downloads/gnu/${TOOLCHAIN_VERSION}/binrel/arm-gnu-toolchain-${TOOLCHAIN_VERSION}-x86_64-aarch64-none-linux-gnu.tar.xz"
fi

ALARM_ROOTFS_URL="${ALARM_MIRROR}/os/ArchLinuxARM-aarch64-latest.tar.gz"
TOOLCHAIN_DIRNAME="arm-gnu-toolchain-${TOOLCHAIN_VERSION}-x86_64-aarch64-none-linux-gnu"

CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

# ---------------------------------------------------------------------------
# PATHS
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
CACHE_DIR="${SCRIPT_DIR}/cache"
OUTPUT_DIR="${SCRIPT_DIR}/output"
SOURCES_DIR="${BUILD_DIR}/sources"
export PATH="${BUILD_DIR}/toolchain/bin:${PATH}"

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[*]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
header(){ echo -e "\n${BLUE}==== $1 ====${NC}"; }
sub()   { echo -e "  ${GREEN}->${NC} $1"; }
chkcmd(){ command -v "$1" >/dev/null 2>&1 || error "Missing: $1"; }
ensure_dir(){ for d in "$@"; do mkdir -p "$d"; done }
git_clone_commit() { local d="$1" r="$2" c="$3"; git init "$d"; git -C "$d" remote add origin "$r"; GIT_SSL_NO_VERIFY=1 git -C "$d" fetch --depth 1 origin "$c" 2>/dev/null || git -C "$d" fetch --depth 1 origin "$c"; git -C "$d" checkout FETCH_HEAD; }
export GIT_SSL_NO_VERIFY=1

# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
usage() {
    cat << 'EOF'
Usage: ./build.sh [OPTIONS]

Options:
  --target MODE       Target mode: sd, emmc, or nvme (SPI boot, default: sd)
  --stage N           Start from stage N (0-8)
  --clean             Remove all build artifacts and cached sources
  --no-kernel         Skip kernel build (for testing bootloader/rootfs only)
  --packages-only     Build kernel and packages (stages 0-5+8, skip rootfs/image)
  --force-latest      Force fetch latest U-Boot and kernel sources (ignore cache)
  --kernel-version V  Use specific kernel version (e.g., 7.1-rc5, v7.0.10)
  --kernel-lts        Use latest LTS kernel (e.g., 6.12.x, 6.6.x)
  --kernel-rc         Use latest RC kernel (e.g., 7.1-rc5)
  --kernel-stable     Use latest stable kernel (default)
  --help, -h          Show this help message

Output:
  sd:   output/orangepi5-plus-sd-YYYYMMDD.img.zst    — Compressed SD card image
  emmc: output/orangepi5-plus-emmc-YYYYMMDD.img.zst  — Compressed eMMC image
  nvme: output/orangepi5-plus-nvme-YYYYMMDD.img.zst  — Compressed NVMe image
  all:  output/linux-op5p-*.pkg.tar.zst              — Arch Linux kernel packages
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# CLEAN
# ---------------------------------------------------------------------------
clean_all() {
    warn "Cleaning all build artifacts..."
    rm -rf "$BUILD_DIR" "$CACHE_DIR" "$OUTPUT_DIR"
    info "Clean complete"
}

# ---------------------------------------------------------------------------
# STAGE 0 — Environment check
# ---------------------------------------------------------------------------
stage_00_env() {
    header "Stage 0: Checking build environment"
    info "Host: $(uname -m), Jobs: ${BUILD_JOBS}"

    [[ $(uname -m) == "x86_64" ]] || warn "Designed for x86_64 hosts (detected: $(uname -m))"

    for cmd in git make wget bsdtar xz dd parted sfdisk mkfs.vfat mkfs.${ROOT_FSTYPE} \
               blkid mcopy mmd stat guestfish; do
        chkcmd "$cmd"
    done

    for pkg in bc flex bison; do
        command -v "$pkg" >/dev/null 2>&1 || warn "Optional (kernel build): $pkg"
    done

    info "Environment check passed"
}

# ---------------------------------------------------------------------------
# STAGE 1 — Cross-compilation toolchain
# ---------------------------------------------------------------------------
stage_01_toolchain() {
    header "Stage 1: Cross-compilation toolchain"

    if command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
        info "Using system toolchain: ${CROSS_COMPILE}gcc"
        sub "$("${CROSS_COMPILE}gcc" --version | head -1)"
        return
    fi

    if command -v "aarch64-none-linux-gnu-gcc" >/dev/null 2>&1; then
        CROSS_COMPILE="aarch64-none-linux-gnu-"
        info "Using system toolchain: aarch64-none-linux-gnu-gcc"
        return
    fi

    if [[ -f "${BUILD_DIR}/toolchain/bin/${CROSS_COMPILE}gcc" ]] || \
       [[ -f "${BUILD_DIR}/toolchain/bin/aarch64-none-linux-gnu-gcc" ]]; then
        info "Using cached toolchain in build/toolchain"
        export PATH="${BUILD_DIR}/toolchain/bin:${PATH}"
        local gcc_path
        gcc_path=$(command -v "${CROSS_COMPILE}gcc" 2>/dev/null || \
            command -v "aarch64-none-linux-gnu-gcc" 2>/dev/null)
        sub "$("$gcc_path" --version | head -1)"
        [[ "$CROSS_COMPILE" != "aarch64-none-linux-gnu-" ]] && CROSS_COMPILE="aarch64-none-linux-gnu-"
        return
    fi

    info "Downloading ARM GNU toolchain ${TOOLCHAIN_VERSION}..."
    ensure_dir "$BUILD_DIR" "$CACHE_DIR"
    local tc_tarball="${CACHE_DIR}/${TOOLCHAIN_DIRNAME}.tar.xz"

    if [[ ! -f "$tc_tarball" ]]; then
        local mirrors=("$TOOLCHAIN_URL" "$TOOLCHAIN_URL_FALLBACK")
        local downloaded=0
        for mirror_url in "${mirrors[@]}"; do
            sub "Trying: ${mirror_url}"
            wget -c "$mirror_url" -O "$tc_tarball" 2>&1 | tail -3 || {
                rm -f "$tc_tarball"
                continue
            }
            # Validate: must be >50MB and recognized as xz/compressed data
            local fsize
            fsize=$(stat -c%s "$tc_tarball" 2>/dev/null || echo 0)
            if [[ "$fsize" -lt 50000000 ]]; then
                warn "Downloaded file too small (${fsize} bytes), likely not a real toolchain"
                rm -f "$tc_tarball"
                continue
            fi
            if ! file "$tc_tarball" | grep -qi "xz\|compressed"; then
                warn "Downloaded file is not xz format"
                rm -f "$tc_tarball"
                continue
            fi
            downloaded=1
            break
        done
        if [[ "$downloaded" -eq 0 ]]; then
            error "Toolchain download failed from all mirrors. Install aarch64-linux-gnu-gcc via your package manager."
        fi
    fi

    info "Extracting toolchain..."
    rm -rf "${BUILD_DIR}/toolchain"
    tar xf "$tc_tarball" -C "$BUILD_DIR" || {
        rm -f "$tc_tarball"
        error "Toolchain extraction failed — corrupted download"
    }
    mv "${BUILD_DIR}/${TOOLCHAIN_DIRNAME}" "${BUILD_DIR}/toolchain"
    rm -f "$tc_tarball"
    CROSS_COMPILE="aarch64-none-linux-gnu-"
    export PATH="${BUILD_DIR}/toolchain/bin:${PATH}"

    "${CROSS_COMPILE}gcc" --version >/dev/null 2>&1 || error "Toolchain installation broken"
    info "Toolchain ready: $("${CROSS_COMPILE}gcc" --version | head -1)"
}

# ---------------------------------------------------------------------------
# STAGE 2 — rkbin (proprietary DDR init blob from Rockchip)
# ---------------------------------------------------------------------------
stage_02_rkbin() {
    header "Stage 2: Getting rkbin (DDR init blob)"

    if [[ ! -d "${SOURCES_DIR}/rkbin" ]]; then
        # Try git clone first, fall back to tarball if GitHub TLS fails
        if GIT_SSL_NO_VERIFY=1 git clone --depth 1 "$RKBIN_REPO" "${SOURCES_DIR}/rkbin" 2>/dev/null; then
            info "rkbin cloned via git"
        else
            warn "Git clone failed, downloading rkbin tarball..."
            local rkbin_tarball="${CACHE_DIR}/rkbin-master.tar.gz"
            wget -c "$RKBIN_TARBALL" -O "$rkbin_tarball" || error "rkbin download failed"
            mkdir -p "${SOURCES_DIR}/rkbin"
            tar xf "$rkbin_tarball" -C "${SOURCES_DIR}/rkbin" --strip-components=1
            rm -f "$rkbin_tarball"
        fi
    fi

    DDR_BLOB=$(find "${SOURCES_DIR}/rkbin/rk35" \
        -name 'rk3588_ddr_lp4_2112MHz_lp5_2400MHz_*.bin' \
        | sort -V | tail -1)

    [[ -f "$DDR_BLOB" ]] || error "No RK3588 DDR blob found in rkbin"
    export ROCKCHIP_TPL="$DDR_BLOB"
    info "DDR init blob: $(basename "${DDR_BLOB}")"
}

# ---------------------------------------------------------------------------
# STAGE 3 — Build ARM Trusted Firmware BL31
# ---------------------------------------------------------------------------
stage_03_tfa() {
    header "Stage 3: Building ARM Trusted Firmware-A BL31"

    if [[ -f "${BUILD_DIR}/bl31.elf" ]]; then
        export BL31="${BUILD_DIR}/bl31.elf"
        info "Using cached BL31 ($(wc -c < "$BL31") bytes)"
        return
    fi

    if [[ ! -d "${SOURCES_DIR}/arm-trusted-firmware" ]]; then
        git clone --depth 1 "$TFA_REPO" "${SOURCES_DIR}/arm-trusted-firmware"
    fi

    make -C "${SOURCES_DIR}/arm-trusted-firmware" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLAT=rk3588 \
        AR="${CROSS_COMPILE}ar" \
        -j "$BUILD_JOBS" \
        bl31 2>&1 | tail -5

    export BL31="${SOURCES_DIR}/arm-trusted-firmware/build/rk3588/release/bl31/bl31.elf"
    [[ -f "$BL31" ]] || error "BL31 build failed"
    cp "$BL31" "${BUILD_DIR}/bl31.elf"
    info "BL31 built: $(wc -c < "$BL31") bytes"
}

# ---------------------------------------------------------------------------
# STAGE 4 — Build U-Boot
# ---------------------------------------------------------------------------
stage_04_uboot() {
    header "Stage 4: Building U-Boot"

    if [[ -f "${BUILD_DIR}/u-boot-rockchip.bin" ]]; then
        export UBOOT_BIN="${BUILD_DIR}/u-boot-rockchip.bin"
        info "Using cached U-Boot ($(wc -c < "$UBOOT_BIN") bytes)"
        return
    fi

    # Resolve cached artifacts when stages were skipped
    if [[ -z "${CROSS_COMPILE:-}" || ! -f "${BUILD_DIR}/toolchain/bin/${CROSS_COMPILE}gcc" ]]; then
        if [[ -f "${BUILD_DIR}/toolchain/bin/aarch64-none-linux-gnu-gcc" ]]; then
            CROSS_COMPILE="aarch64-none-linux-gnu-"
            export PATH="${BUILD_DIR}/toolchain/bin:${PATH}"
            info "Resolved toolchain: ${CROSS_COMPILE}"
        fi
    fi
    if [[ -z "${BL31:-}" && -f "${BUILD_DIR}/bl31.elf" ]]; then
        export BL31="${BUILD_DIR}/bl31.elf"
        info "Resolved BL31 from cache"
    fi
    if [[ -z "${ROCKCHIP_TPL:-}" ]]; then
        local rkbin_ddr; rkbin_ddr=$(find "${SOURCES_DIR}/rkbin/rk35" \
            -name 'rk3588_ddr_lp4_2112MHz_lp5_2400MHz_*.bin' \
            | sort -V | tail -1 2>/dev/null || true)
        if [[ -n "$rkbin_ddr" ]]; then
            export ROCKCHIP_TPL="$rkbin_ddr"
            info "Resolved ROCKCHIP_TPL from rkbin cache: $(basename "$rkbin_ddr")"
        fi
    fi

    local uboot_tag uboot_commit uboot_ref
    uboot_ref=$(git ls-remote --tags --refs "$UBOOT_REPO" 2>/dev/null \
        | grep -oP 'refs/tags/v20\d{2}\.\d+$' \
        | sort -V | tail -1)
    uboot_ref="${uboot_ref:-$(git ls-remote --tags --refs "$UBOOT_REPO" 2>/dev/null \
        | grep -oP 'refs/tags/v20\d{2}\.\d+-rc\d+$' \
        | sort -V | tail -1)}"

    if [[ -z "$uboot_ref" ]]; then
        uboot_commit=master
        uboot_tag=master
    else
        uboot_tag="${uboot_ref#refs/tags/}"
        # git ls-remote uses tab separator between hash and ref
        uboot_commit=$(git ls-remote --tags --refs "$UBOOT_REPO" 2>/dev/null \
            | grep "$(printf '\t')${uboot_ref}$" | awk '{print $1}')
    fi

    if [[ -d "${SOURCES_DIR}/u-boot" ]]; then
        local current_commit
        current_commit=$(git -C "${SOURCES_DIR}/u-boot" rev-parse HEAD 2>/dev/null || true)
        if [[ "$FORCE_LATEST" -eq 1 ]]; then
            warn "Force update: removing U-Boot cache"
            rm -rf "${SOURCES_DIR}/u-boot"
        elif [[ "$current_commit" == "$uboot_commit" ]] || [[ -n "$current_commit" && "$uboot_commit" == "master" ]]; then
            info "U-Boot source already at ${uboot_tag}, skipping clone"
        else
            warn "Updating U-Boot from ${current_commit:0:8}... to ${uboot_tag}"
            rm -rf "${SOURCES_DIR}/u-boot"
        fi
    fi

    if [[ ! -d "${SOURCES_DIR}/u-boot" ]]; then
        info "Cloning U-Boot ${uboot_tag}..."
        if [[ "$uboot_commit" == "master" ]]; then
            GIT_SSL_NO_VERIFY=1 git clone --depth 1 "$UBOOT_REPO" "${SOURCES_DIR}/u-boot"
        else
            git_clone_commit "${SOURCES_DIR}/u-boot" "$UBOOT_REPO" "$uboot_commit"
        fi
    fi

    local uboot_src="${SOURCES_DIR}/u-boot"
    info "Using U-Boot: ${uboot_tag}"

    [[ -f "${uboot_src}/configs/${UBOOT_DEFCONFIG}" ]] || \
        error "Defconfig not found: ${UBOOT_DEFCONFIG}"

    # U-Boot ARM64 build uses ARCH=arm (the arch/arm/ tree supports both
    # 32-bit ARM and AArch64 via cpu/armv8). ARCH=arm64 is NOT a valid
    # U-Boot Kconfig target; it would require unavailable arch/arm64/ stubs.
    make -C "$uboot_src" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" "${UBOOT_DEFCONFIG}"

    make -C "$uboot_src" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
        BL31="$BL31" \
        ROCKCHIP_TPL="$ROCKCHIP_TPL" \
        NO_PYTHON=1 \
        -j "$BUILD_JOBS" 2>&1 | tail -10

    export UBOOT_BIN="${uboot_src}/u-boot-rockchip.bin"
    [[ -f "$UBOOT_BIN" ]] || error "U-Boot build produced no u-boot-rockchip.bin"

    cp "$UBOOT_BIN" "${BUILD_DIR}/u-boot-rockchip.bin"
    info "U-Boot built: $(wc -c < "$UBOOT_BIN") bytes"
}

# ---------------------------------------------------------------------------
# STAGE 5 — Build Linux kernel
# ---------------------------------------------------------------------------
stage_05_kernel() {
    header "Stage 5: Building Linux kernel"

    # Resolve toolchain from cache when stages were skipped
    if [[ -z "${CROSS_COMPILE:-}" || ! -f "${BUILD_DIR}/toolchain/bin/${CROSS_COMPILE}gcc" ]]; then
        if [[ -f "${BUILD_DIR}/toolchain/bin/aarch64-none-linux-gnu-gcc" ]]; then
            CROSS_COMPILE="aarch64-none-linux-gnu-"
            export PATH="${BUILD_DIR}/toolchain/bin:${PATH}"
            info "Resolved toolchain: ${CROSS_COMPILE}"
        fi
    fi

    if [[ "${SKIP_KERNEL:-0}" -eq 1 ]]; then
        warn "Kernel build skipped (--no-kernel). Image will not boot."
        return
    fi

    if [[ -f "${BUILD_DIR}/kernel/arch/arm64/boot/Image" ]] && \
       [[ -f "${BUILD_DIR}/kernel/arch/arm64/boot/dts/rockchip/rk3588-orangepi-5-plus.dtb" ]]; then
        if [[ "${CLEAN_BUILD:-0}" -eq 1 ]]; then
            rm -rf "${BUILD_DIR}/kernel"
        else
            export KERNEL_IMAGE="${BUILD_DIR}/kernel/arch/arm64/boot/Image"
            export DTBS_DIR="${BUILD_DIR}/kernel/arch/arm64/boot/dts/rockchip"
            export KERNEL_VERSION
            KERNEL_VERSION=$(cat "${BUILD_DIR}/kernel/.kernelrelease" 2>/dev/null || echo "unknown")
            info "Using cached kernel (${KERNEL_VERSION})"
            return
        fi
    fi

    local kernel_tag
    # Use specific kernel version if set, otherwise use kernel mode
    if [[ -n "${KERNEL_VERSION:-}" ]]; then
        kernel_tag="$KERNEL_VERSION"
        # Remove 'v' prefix if present
        kernel_tag="${kernel_tag#v}"
    else
        case "$KERNEL_MODE" in
            lts)
                # Find latest LTS kernel (even major.minor versions)
                kernel_tag=$(git ls-remote --tags --refs "$LINUX_REPO" 2>/dev/null \
                    | grep -oP 'refs/tags/v\K[0-9]+\.[0-9]+\.[0-9]+$' \
                    | awk -F. '{if ($2 % 2 == 0) print}' \
                    | sort -V | tail -1)
                ;;
            rc)
                # Find latest RC kernel
                kernel_tag=$(git ls-remote --tags --refs "$LINUX_REPO" 2>/dev/null \
                    | grep -oP 'refs/tags/v\K[0-9]+\.[0-9]+-rc[0-9]+$' \
                    | sort -V | tail -1)
                ;;
            stable|*)
                # Find latest stable kernel
                kernel_tag=$(git ls-remote --tags --refs "$LINUX_REPO" 2>/dev/null \
                    | grep -oP 'refs/tags/v\K[0-9]+\.[0-9]+\.[0-9]+$' \
                    | sort -V | tail -1)
                ;;
        esac
        kernel_tag="${kernel_tag#refs/tags/}"
        kernel_tag="${kernel_tag:-master}"
    fi

    if [[ -d "${SOURCES_DIR}/linux" ]]; then
        local current_tag; current_tag=$(git -C "${SOURCES_DIR}/linux" describe --tags --exact-match 2>/dev/null || true)
        if [[ "$FORCE_LATEST" -eq 1 ]]; then
            warn "Force update: removing kernel cache"
            rm -rf "${SOURCES_DIR}/linux"
        elif [[ "$current_tag" == "$kernel_tag" ]]; then
            info "Kernel source already at ${kernel_tag}, skipping clone"
        else
            warn "Updating kernel from ${current_tag:-unknown} to ${kernel_tag}"
            rm -rf "${SOURCES_DIR}/linux"
        fi
    fi

    if [[ ! -d "${SOURCES_DIR}/linux" ]]; then
        info "Cloning Linux kernel ${kernel_tag}..."
        if [[ "$kernel_tag" == "master" ]]; then
            GIT_SSL_NO_VERIFY=1 git clone --depth 1 --single-branch \
                "$LINUX_REPO" "${SOURCES_DIR}/linux"
        else
            # For tags, use git clone without --branch, then checkout the tag
            GIT_SSL_NO_VERIFY=1 git clone --depth 1 \
                "$LINUX_REPO" "${SOURCES_DIR}/linux"
            git -C "${SOURCES_DIR}/linux" fetch --depth 1 origin tag "v${kernel_tag}" 2>/dev/null || \
                git -C "${SOURCES_DIR}/linux" fetch --depth 1 origin tag "$kernel_tag" 2>/dev/null || \
                error "Failed to fetch kernel tag: ${kernel_tag}"
            git -C "${SOURCES_DIR}/linux" checkout FETCH_HEAD
        fi
    fi

    local kernel_src="${SOURCES_DIR}/linux"
    info "Using kernel: ${kernel_tag}"

    local kernel_build="${BUILD_DIR}/kernel"
    ensure_dir "$kernel_build"

    make -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
        O="$kernel_build" distclean
    make -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
        O="$kernel_build" defconfig

    # Populate build output scripts/ for ./scripts/config to work
    make -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
        O="$kernel_build" scripts_basic 2>&1 | tail -3

    cd "$kernel_build"

    # Trim kernel config: disable debug/tracing/XEN/unnecessary drivers
        "${kernel_src}/scripts/config" --disable DEBUG_INFO
        "${kernel_src}/scripts/config" --disable FRAME_POINTER
        "${kernel_src}/scripts/config" --disable FUNCTION_TRACER
        "${kernel_src}/scripts/config" --disable STACK_TRACER
        "${kernel_src}/scripts/config" --disable FTRACE
        "${kernel_src}/scripts/config" --disable PRINTK_TIME
        "${kernel_src}/scripts/config" --disable XEN
        "${kernel_src}/scripts/config" --enable WIRELESS
        "${kernel_src}/scripts/config" --enable CFG80211
        "${kernel_src}/scripts/config" --enable MAC80211
        "${kernel_src}/scripts/config" --disable DVB_CORE
        "${kernel_src}/scripts/config" --disable MEDIA_DIGITAL_TV_SUPPORT
        "${kernel_src}/scripts/config" --disable MEDIA_ANALOG_TV_SUPPORT
        "${kernel_src}/scripts/config" --disable DRM_RCAR_DW_HDMI
        "${kernel_src}/scripts/config" --disable DRM_MESON_DW_HDMI

    # Disable unused Rockchip drivers from defconfig
        "${kernel_src}/scripts/config" --disable SCSI_UFS_ROCKCHIP
        "${kernel_src}/scripts/config" --disable ROCKCHIP_INNO_HDMI
        "${kernel_src}/scripts/config" --disable ROCKCHIP_LVDS
        "${kernel_src}/scripts/config" --disable ROCKCHIP_DW_MIPI_DSI
        "${kernel_src}/scripts/config" --disable ROCKCHIP_DW_HDMI

    # Enable filesystem support
        "${kernel_src}/scripts/config" --enable XFS_FS

    # Enable essential Orange Pi 5 Plus drivers
        "${kernel_src}/scripts/config" --enable ROCKCHIP_VOP2
        "${kernel_src}/scripts/config" --enable DRM_DW_HDMI
        "${kernel_src}/scripts/config" --module DRM_PANTHOR
        "${kernel_src}/scripts/config" --enable PHY_ROCKCHIP_USBDP
        "${kernel_src}/scripts/config" --enable PHY_ROCKCHIP_PCIE
        "${kernel_src}/scripts/config" --enable PHY_ROCKCHIP_SNPS_PCIE3
        "${kernel_src}/scripts/config" --enable PHY_ROCKCHIP_SAMSUNG_HDPTX
        "${kernel_src}/scripts/config" --enable TYPEC_FUSB302
        "${kernel_src}/scripts/config" --enable USB_DWC3
        "${kernel_src}/scripts/config" --enable R8169
        "${kernel_src}/scripts/config" --enable BLK_DEV_NVME
        "${kernel_src}/scripts/config" --enable AHCI_DWC
        "${kernel_src}/scripts/config" --enable PWM_ROCKCHIP
        "${kernel_src}/scripts/config" --enable SENSORS_PWM_FAN
        "${kernel_src}/scripts/config" --module SND_SOC_ES8328_I2C
        "${kernel_src}/scripts/config" --enable I2C_RK3X
        "${kernel_src}/scripts/config" --enable DW_WATCHDOG

    # Enable Landlock for pacman 7.x sandbox support
        "${kernel_src}/scripts/config" --enable SECURITY_LANDLOCK

    # Enable USB RNDIS host for Android phone USB tethering
        "${kernel_src}/scripts/config" --module USB_NET_RNDIS_HOST

    # Build DRM_ROCKCHIP as built-in (not module) for reliable HDMI init
        "${kernel_src}/scripts/config" --enable DRM_ROCKCHIP

    # Enable Qualcomm QCNFA765 WiFi 6E (ath11k PCI)
        "${kernel_src}/scripts/config" --module ATH11K
        "${kernel_src}/scripts/config" --module ATH11K_PCI

    # -------------------------------------------------------------------------
    # RK3588: Video hardware decoding (V4L2 media platform drivers)
    # -------------------------------------------------------------------------
        "${kernel_src}/scripts/config" --enable MEDIA_PLATFORM_SUPPORT
        "${kernel_src}/scripts/config" --enable V4L_PLATFORM_DRIVERS
        "${kernel_src}/scripts/config" --enable MEDIA_CONTROLLER
        "${kernel_src}/scripts/config" --module V4L2_MEM2MEM_DEV

    # RK3588 hardware video decoder (H.264, H.265/HEVC, VP9, AVS2)
        "${kernel_src}/scripts/config" --module VIDEO_ROCKCHIP_VDEC
        "${kernel_src}/scripts/config" --module VIDEO_ROCKCHIP_RGA
        "${kernel_src}/scripts/config" --module VIDEO_ROCKCHIP_ISP1
        "${kernel_src}/scripts/config" --module VIDEO_ROCKCHIP_CIF
    # Hantro G1/G2 VPU (legacy video decode)
        "${kernel_src}/scripts/config" --module VIDEO_HANTRO
        "${kernel_src}/scripts/config" --enable VIDEO_HANTRO_ROCKCHIP
        "${kernel_src}/scripts/config" --enable VIDEO_HANTRO_HEVC_RFC

    # -------------------------------------------------------------------------
    # RK3588: Display subsystem
    # -------------------------------------------------------------------------
    # HDMI 2.1 Quad-Pixel (RK3588 HDMI TX)
        "${kernel_src}/scripts/config" --enable ROCKCHIP_DW_HDMI_QP
    # VOP1 display controller (complements VOP2)
        "${kernel_src}/scripts/config" --enable ROCKCHIP_VOP
    # DisplayPort / CDN DP
        "${kernel_src}/scripts/config" --enable ROCKCHIP_CDN_DP
        "${kernel_src}/scripts/config" --enable ROCKCHIP_ANALOGIX_DP
    # MIPI DSI v2 (RK3588 MIPI display output)
        "${kernel_src}/scripts/config" --enable ROCKCHIP_DW_MIPI_DSI2

    # -------------------------------------------------------------------------
    # RK3588: PHY (physical layer) interfaces
    # -------------------------------------------------------------------------
    # Naneng combo PHY — critical for PCIe/SATA/USB3 on RK3588
        "${kernel_src}/scripts/config" --enable PHY_ROCKCHIP_NANENG_COMBO_PHY
    # USB PHYs
        "${kernel_src}/scripts/config" --enable PHY_ROCKCHIP_INNO_USB2
        "${kernel_src}/scripts/config" --enable PHY_ROCKCHIP_TYPEC
        "${kernel_src}/scripts/config" --enable PHY_ROCKCHIP_USB
    # DisplayPort PHY
        "${kernel_src}/scripts/config" --enable PHY_ROCKCHIP_DP
    # MIPI CSI/DSI PHYs (cameras, MIPI display)
        "${kernel_src}/scripts/config" --enable PHY_ROCKCHIP_DPHY_RX0
        "${kernel_src}/scripts/config" --enable PHY_ROCKCHIP_INNO_CSIDPHY

    # -------------------------------------------------------------------------
    # RK3588: Power, thermal, IO control, crypto
    # -------------------------------------------------------------------------
    # IO domain voltage control (required — prevents IO voltage mismatches)
        "${kernel_src}/scripts/config" --enable ROCKCHIP_IODOMAIN
    # IOMMU for VPU/GPU DMA
        "${kernel_src}/scripts/config" --enable ROCKCHIP_IOMMU
    # Thermal sensor and throttling
        "${kernel_src}/scripts/config" --enable ROCKCHIP_THERMAL
    # SARADC (for buttons / sensors)
        "${kernel_src}/scripts/config" --enable ROCKCHIP_SARADC
    # Hardware crypto accelerator (RK3588)
        "${kernel_src}/scripts/config" --module CRYPTO_DEV_ROCKCHIP

    # NPU accelerator (RK3588) — via DRM accel framework, userspace driver in Mesa3D (rocket)
        "${kernel_src}/scripts/config" --enable DRM_ACCEL
        "${kernel_src}/scripts/config" --module DRM_ACCEL_ROCKET

    # -------------------------------------------------------------------------
    # RK3588: Audio (I2S, SPDIF — complements ES8388 codec)
    # -------------------------------------------------------------------------
        "${kernel_src}/scripts/config" --module SND_SOC_ROCKCHIP
        "${kernel_src}/scripts/config" --module SND_SOC_ROCKCHIP_I2S_TDM
        "${kernel_src}/scripts/config" --module SND_SOC_ROCKCHIP_SPDIF

    # -------------------------------------------------------------------------
    # Performance tuning
    # -------------------------------------------------------------------------
    # 1000Hz timer tick for better responsiveness (disable 250Hz default)
        "${kernel_src}/scripts/config" --enable HZ_1000
        "${kernel_src}/scripts/config" --disable HZ_250
    # Multi-core scheduling awareness (important for RK3588 4+4 big.LITTLE)
        "${kernel_src}/scripts/config" --enable SCHED_MC
    # Preemptible kernel for lower scheduling latency
        "${kernel_src}/scripts/config" --enable PREEMPT
    # Explicitly set 8 cores for RK3588
        "${kernel_src}/scripts/config" --set-val NR_CPUS 8
    # Transparent HugePages for memory performance
        "${kernel_src}/scripts/config" --enable TRANSPARENT_HUGEPAGE
    # BBR congestion control for better network throughput
        "${kernel_src}/scripts/config" --module TCP_CONG_BBR
        "${kernel_src}/scripts/config" --set-str DEFAULT_TCP_CONG bbr

    cd "$SCRIPT_DIR"

    make -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
        O="$kernel_build" olddefconfig 2>/dev/null

    info "Building kernel Image + dtbs + modules (this takes ~30-60 minutes)..."

    # Enable ccache for kernel compilation if available
    if command -v ccache &>/dev/null; then
        local ccache_dir="${CCACHE_DIR:-${SCRIPT_DIR}/cache/ccache}"
        local max_size="${CCACHE_MAX_SIZE:-2G}"

        # Auto-detect: use tmpfs if /dev/shm has >= 2GB free (unless user set CCACHE_DIR explicitly)
        if [[ -z "${CCACHE_DIR:-}" ]] && [[ -d /dev/shm ]]; then
            local shm_free_kb
            shm_free_kb=$(df --output=avail /dev/shm 2>/dev/null | tail -1)
            if [[ -n "$shm_free_kb" ]] && [[ "$shm_free_kb" -ge 2097152 ]]; then
                ccache_dir="/dev/shm/ccache"
                # Cap cache to 50% of available tmpfs
                local auto_max=$((shm_free_kb / 2 / 1024))
                if [[ "$auto_max" -gt 0 ]]; then
                    max_size="${auto_max}M"
                fi
            fi
        fi
        # CCACHE_IN_MEM=1 forces tmpfs regardless
        if [[ "${CCACHE_IN_MEM:-0}" -eq 1 ]]; then
            ccache_dir="/dev/shm/ccache"
        fi

        mkdir -p "$ccache_dir"
        export CCACHE_DIR="$ccache_dir"
        ccache -M "$max_size" &>/dev/null || true
        info "ccache enabled (${ccache_dir}, max ${max_size})"

        # Create ccache symlinks so the kernel build uses ccache transparently
        local ccache_bin="${BUILD_DIR}/ccache-bin"
        mkdir -p "$ccache_bin"
        ln -sf "$(command -v ccache)" "$ccache_bin/${CROSS_COMPILE}gcc"
        ln -sf "$(command -v ccache)" "$ccache_bin/${CROSS_COMPILE}g++"
        export PATH="${ccache_bin}:${PATH}"
    fi

    make -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
        O="$kernel_build" -j "$BUILD_JOBS" Image dtbs modules 2>&1 | tail -20

    export KERNEL_VERSION
    KERNEL_VERSION=$(make -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
        O="$kernel_build" -s kernelrelease 2>/dev/null)
    echo "$KERNEL_VERSION" > "${kernel_build}/.kernelrelease"

    export KERNEL_IMAGE="${kernel_build}/arch/arm64/boot/Image"
    export DTBS_DIR="${kernel_build}/arch/arm64/boot/dts/rockchip"

    [[ -f "$KERNEL_IMAGE" ]] || error "Kernel Image not found — build failed"
    [[ -f "${DTBS_DIR}/rk3588-orangepi-5-plus.dtb" ]] || \
        warn "rk3588-orangepi-5-plus.dtb not found in kernel DTBs"

    info "Kernel ${KERNEL_VERSION} built: $(wc -c < "$KERNEL_IMAGE") bytes"
}

# ---------------------------------------------------------------------------
# STAGE 6 — Prepare root filesystem
# ---------------------------------------------------------------------------
stage_06_rootfs() {
    header "Stage 6: Preparing Arch Linux ARM root filesystem"

    local rootfs_dir="${CACHE_DIR}/rootfs"
    local tarball="${CACHE_DIR}/ArchLinuxARM-aarch64-latest.tar.gz"

    if [[ ! -f "$tarball" ]]; then
        info "Downloading ALARM rootfs..."
        wget -c "$ALARM_ROOTFS_URL" -O "$tarball" || { rm -f "$tarball"; error "Download failed"; }
    fi

    if [[ ! -f "${rootfs_dir}/.extracted" ]]; then
        info "Extracting root filesystem..."
        ensure_dir "$rootfs_dir"
        (bsdtar -xpf "$tarball" -C "$rootfs_dir" 2>&1 || true) | grep -v "Cannot restore extended attributes" || true
        touch "${rootfs_dir}/.extracted"
    fi

    if [[ "${SKIP_KERNEL:-0}" -eq 0 ]] && [[ -n "${KERNEL_VERSION:-}" ]]; then
        info "Installing kernel modules..."
        make -C "${SOURCES_DIR}/linux" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
            O="${BUILD_DIR}/kernel" INSTALL_MOD_PATH="$rootfs_dir" \
            modules_install 2>&1 | tail -5
    fi

    if [[ -d "${DTBS_DIR:-}" ]]; then
        ensure_dir "${rootfs_dir}/boot/dtbs"
        cp -r "$DTBS_DIR" "${rootfs_dir}/boot/dtbs/"
    fi

    [[ -f "${KERNEL_IMAGE:-}" ]] && cp "$KERNEL_IMAGE" "${rootfs_dir}/boot/"

    echo "orangepi5-plus" > "${rootfs_dir}/etc/hostname"

    cat > "${rootfs_dir}/etc/hosts" << 'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   orangepi5-plus.localdomain orangepi5-plus
EOF

    cat > "${rootfs_dir}/etc/fstab" << 'FSTAB'
# Root filesystem UUID is set dynamically during image assembly.
FSTAB

    local systemd_dir="${rootfs_dir}/etc/systemd/system/multi-user.target.wants"
    ensure_dir "$systemd_dir"
    [[ -f "${rootfs_dir}/usr/lib/systemd/system/sshd.service" ]] && \
        ln -sf /usr/lib/systemd/system/sshd.service "${systemd_dir}/sshd.service" 2>/dev/null || true

    local sgetty_dir="${rootfs_dir}/etc/systemd/system/serial-getty@ttyS2.service.d"
    ensure_dir "$sgetty_dir"
    cat > "${sgetty_dir}/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root -8 -w -s ttyS2 1500000 linux
EOF
    ensure_dir "${rootfs_dir}/etc/systemd/system/getty.target.wants"
    ln -sf /usr/lib/systemd/system/serial-getty@.service \
        "${rootfs_dir}/etc/systemd/system/getty.target.wants/serial-getty@ttyS2.service" 2>/dev/null || true

    cat > "${rootfs_dir}/etc/systemd/network/20-wired.network" << 'EOF'
[Match]
Name=eth*
[Network]
DHCP=yes
EOF

    # -------------------------------------------------------------------------
    # First-boot partition auto-resize (expand root to fill SD/USB/NVMe)
    # -------------------------------------------------------------------------
    cat > "${rootfs_dir}/etc/systemd/system/resize-filesystem.service" << 'EOSVC'
[Unit]
Description=Resize root partition to fill available disk space
After=local-fs.target
ConditionPathExists=!/var/lib/resize-filesystem-done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/resize-filesystem
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOSVC

    cat > "${rootfs_dir}/usr/local/sbin/resize-filesystem" << 'EOSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Detect root partition device
ROOT_DEV=$(findmnt -n -o SOURCE /)
DISK=$(echo "$ROOT_DEV" | sed 's/[0-9]*$//')
PART_NUM=${ROOT_DEV##*[!0-9]}

# Get partition start and current size from sfdisk
SFDISK_LINE=$(sfdisk -l -o Device,Start,Sectors "$DISK" 2>/dev/null \
    | grep "^${DISK}${PART_NUM}" | head -1)
[[ -n "$SFDISK_LINE" ]] || exit 0

START_SECTOR=$(echo "$SFDISK_LINE" | awk '{print $2}')
END_SECTOR=$(( START_SECTOR + $(echo "$SFDISK_LINE" | awk '{print $3}') - 1 ))

# Get total disk sectors
TOTAL_SECTORS=$(blockdev --getsz "$DISK" 2>/dev/null || echo 0)
(( TOTAL_SECTORS > 0 )) || exit 0

# Reserve 34 sectors at end for GPT backup
FREE_SECTORS=$(( TOTAL_SECTORS - END_SECTOR - 34 ))

if (( FREE_SECTORS > 2048 )); then
    echo "Resizing partition ${DISK}${PART_NUM} — ${FREE_SECTORS} free sectors"
    # sfdisk: start sector, size=0 means fill to max
    echo "${START_SECTOR}," | sfdisk -N "$PART_NUM" "$DISK" --force --no-reread 2>/dev/null
    udevadm settle

    FSTYPE=$(findmnt -n -o FSTYPE /)
    case "$FSTYPE" in
        xfs)  xfs_growfs / ;;
        ext4) resize2fs "$ROOT_DEV" ;;
        *)    echo "Unsupported fstype: $FSTYPE"; exit 1 ;;
    esac
    echo "Filesystem resized successfully"
fi

# Mark done so this only runs once
mkdir -p /var/lib
touch /var/lib/resize-filesystem-done
EOSCRIPT
    chmod +x "${rootfs_dir}/usr/local/sbin/resize-filesystem"
    ensure_dir "${rootfs_dir}/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/resize-filesystem.service \
        "${rootfs_dir}/etc/systemd/system/multi-user.target.wants/resize-filesystem.service" 2>/dev/null || true

    ensure_dir "${rootfs_dir}/efi/extlinux"

    # Install kernel source tree for module compilation (if --no-kernel wasn't passed)
    # Compress with zstd and auto-decompress on first boot
    if [[ "${SKIP_KERNEL:-0}" -eq 0 && -n "${KERNEL_VERSION:-}" && -d "${SOURCES_DIR}/linux" ]]; then
        local ksrc_target="${rootfs_dir}/usr/src/linux-${KERNEL_VERSION}"
        local ksrc_tarball="${rootfs_dir}/usr/src/linux-${KERNEL_VERSION}.tar.zst"
        if [[ ! -d "$ksrc_target" && ! -f "$ksrc_tarball" ]]; then
            info "Preparing compressed kernel source tree..."
            local ksrc_staging="${CACHE_DIR}/kernel-src-staging"
            rm -rf "$ksrc_staging"
            mkdir -p "$ksrc_staging"

            # Strip-copy: exclude .git, Documentation, tools, samples, non-arm64 archs
            tar --exclude='.git' \
                --exclude='Documentation' \
                --exclude='tools' \
                --exclude='samples' \
                --exclude='arch/alpha' --exclude='arch/arc' \
                --exclude='arch/arm' --exclude='arch/avr32' \
                --exclude='arch/blackfin' --exclude='arch/c6x' \
                --exclude='arch/csky' --exclude='arch/h8300' \
                --exclude='arch/hexagon' --exclude='arch/ia64' \
                --exclude='arch/loongarch' --exclude='arch/m68k' \
                --exclude='arch/metag' --exclude='arch/microblaze' \
                --exclude='arch/mips' --exclude='arch/nios2' \
                --exclude='arch/openrisc' --exclude='arch/parisc' \
                --exclude='arch/powerpc' --exclude='arch/riscv' \
                --exclude='arch/s390' --exclude='arch/sh' \
                --exclude='arch/sparc' --exclude='arch/um' \
                --exclude='arch/xtensa' \
                -cf - -C "${SOURCES_DIR}/linux" . | tar -xf - -C "$ksrc_staging"

            # Copy .config and Module.symvers
            cp "${BUILD_DIR}/kernel/.config" "$ksrc_staging/.config"
            [[ -f "${BUILD_DIR}/kernel/Module.symvers" ]] && \
                cp "${BUILD_DIR}/kernel/Module.symvers" "$ksrc_staging/"

            # Run modules_prepare to build infrastructure
            make -C "${SOURCES_DIR}/linux" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
                O="$ksrc_staging" modules_prepare 2>/dev/null | tail -3

            # Compress with zstd
            info "Compressing kernel source tree with zstd..."
            ensure_dir "$(dirname "$ksrc_tarball")"
            tar --zstd -cf "$ksrc_tarball" -C "$ksrc_staging" .
            rm -rf "$ksrc_staging"

            local tarball_size
            tarball_size=$(du -sh "$ksrc_tarball" | cut -f1)
            info "Compressed kernel source tree: ${tarball_size}"

            # Create first-boot decompression service
            cat > "${rootfs_dir}/usr/local/sbin/decompress-kernel-src" << 'EOSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="__KERNEL_VERSION__"
TARBALL="/usr/src/linux-${KERNEL_VERSION}.tar.zst"
TARGET="/usr/src/linux-${KERNEL_VERSION}"

[[ -f "$TARBALL" ]] || exit 0
[[ -d "$TARGET" ]] && exit 0

echo "Decompressing kernel source tree..."
mkdir -p "$TARGET"
tar --zstd -xf "$TARBALL" -C "$TARGET"
chown -R 0:0 "$TARGET" 2>/dev/null || true
rm -f "$TARBALL"

echo "Kernel source tree decompressed successfully"
mkdir -p /var/lib
touch /var/lib/decompress-kernel-src-done
EOSCRIPT
            sed -i "s/__KERNEL_VERSION__/${KERNEL_VERSION}/g" \
                "${rootfs_dir}/usr/local/sbin/decompress-kernel-src"
            chmod +x "${rootfs_dir}/usr/local/sbin/decompress-kernel-src"

            cat > "${rootfs_dir}/etc/systemd/system/decompress-kernel-src.service" << 'EOSVC'
[Unit]
Description=Decompress kernel source tree for module compilation
After=local-fs.target
ConditionPathExists=!/var/lib/decompress-kernel-src-done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/decompress-kernel-src
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOSVC
            ensure_dir "${rootfs_dir}/etc/systemd/system/multi-user.target.wants"
            ln -sf /etc/systemd/system/decompress-kernel-src.service \
                "${rootfs_dir}/etc/systemd/system/multi-user.target.wants/decompress-kernel-src.service" 2>/dev/null || true

            # Update /lib/modules symlinks (will be valid after first-boot decompression)
            local mod_dir="${rootfs_dir}/lib/modules/${KERNEL_VERSION}"
            if [[ -d "$mod_dir" ]]; then
                rm -f "${mod_dir}/build" "${mod_dir}/source"
                ln -sf "/usr/src/linux-${KERNEL_VERSION}" "${mod_dir}/build"
                ln -sf "/usr/src/linux-${KERNEL_VERSION}" "${mod_dir}/source"
            fi

            info "Compressed kernel source tree installed (${tarball_size}), will auto-decompress on first boot"
        else
            info "Kernel source tree already installed"
        fi
    fi

    info "Root filesystem prepared ($(du -sh "$rootfs_dir" | cut -f1))"
}

# ---------------------------------------------------------------------------
# STAGE 7 — Assemble disk image
# ---------------------------------------------------------------------------
stage_07_image() {
    header "Stage 7: Assembling bootable disk image"

    local timestamp; timestamp=$(date +%Y%m%d)
    local image_file
    case "$TARGET" in
        nvme) image_file="${OUTPUT_DIR}/orangepi5-plus-nvme-${timestamp}.img" ;;
        emmc) image_file="${OUTPUT_DIR}/orangepi5-plus-emmc-${timestamp}.img" ;;
        *)    image_file="${OUTPUT_DIR}/orangepi5-plus-sd-${timestamp}.img" ;;
    esac
    local boot_img="${CACHE_DIR}/boot.img"
    local rootfs_tar="${CACHE_DIR}/rootfs.tar"
    local rootfs_dir="${CACHE_DIR}/rootfs"
    ensure_dir "$OUTPUT_DIR"

    if [[ "${ROOT_FSTYPE}" == "xfs" ]]; then
        command -v mkfs.xfs >/dev/null || error "xfsprogs not installed (ROOT_FSTYPE=xfs)"
        command -v guestfish >/dev/null || error "libguestfs not installed (needed for XFS image creation)"
    fi

    # Step 1: Create sparse disk image
    dd if=/dev/zero of="$image_file" bs=1M seek="$IMAGE_SIZE_MB" count=0 status=none

    # Step 2: Create boot partition (FAT32)
    info "Creating FAT32 boot partition..."
    rm -f "$boot_img"
    mkfs.vfat -C "$boot_img" $((BOOT_SIZE_MB * 1024)) -n ALARMBOOT 2>&1 | tail -1
    [[ -f "${KERNEL_IMAGE:-}" ]] && mcopy -i "$boot_img" "$KERNEL_IMAGE" ::/Image
    mmd -i "$boot_img" /extlinux
    if [[ -d "${DTBS_DIR:-}" ]]; then
        mmd -i "$boot_img" /dtbs 2>/dev/null || true
        mcopy -i "$boot_img" "$DTBS_DIR"/*.dtb ::/dtbs/ 2>/dev/null || true
    fi
    # extlinux.conf with placeholder (final PARTUUID updated after root partition creation)
    cat > "${CACHE_DIR}/extlinux.conf" << 'EXTLINUX'
label Arch Linux ARM (mainline kernel)
    linux /Image
    fdt /dtbs/rk3588-orangepi-5-plus.dtb
    append console=ttyS2,1500000n8 earlycon root=PARTUUID=PARTUUID rw rootwait
EXTLINUX
    mcopy -i "$boot_img" "${CACHE_DIR}/extlinux.conf" ::/extlinux/extlinux.conf

    # Step 3: Write U-Boot at sector 64 (SD card target only)
    if [[ "$TARGET" != "nvme" ]]; then
        if [[ -f "${UBOOT_BIN:-}" ]]; then
            info "Writing U-Boot at sector 64..."
            dd if="$UBOOT_BIN" of="$image_file" bs=512 seek=64 conv=notrunc status=none
            sub "$(wc -c < "$UBOOT_BIN") bytes written"
        else
            warn "U-Boot binary missing — image will not boot"
        fi
    else
        info "Skipping U-Boot write (NVMe target — U-Boot expected on SPI flash)"
    fi

    # Step 4: Create root partition via guestfish (no loop device needed)
    info "Creating ${ROOT_FSTYPE} root partition (${ROOT_SIZE_MB} MB)..."
    rm -f "$rootfs_tar"
    tar cf "$rootfs_tar" -C "$rootfs_dir" . 2>/dev/null
    chmod 644 "$rootfs_tar"

    local guestfish_script; guestfish_script=$(cat << GF
add-drive $image_file format:raw
launch
part-init /dev/sda gpt
part-add /dev/sda p 2048 1050623
part-add /dev/sda p 1050624 $((IMAGE_SIZE_MB * 2048 - 2049))
part-set-bootable /dev/sda 1 true
mkfs vfat /dev/sda1 label:ALARMBOOT
mkfs $ROOT_FSTYPE /dev/sda2 label:ALARMROOT
mount /dev/sda2 /
tar-in $rootfs_tar /
umount /dev/sda2
vfs-uuid /dev/sda2
part-get-gpt-guid /dev/sda 2
GF
)
    local uuids
    uuids=$(guestfish 2>/dev/null <<< "$guestfish_script" | grep -v '^[[:space:]]*$' | tail -2)
    local root_uuid part_uuid
    root_uuid=$(echo "$uuids" | sed -n '1p' | tr -d '[:space:]')
    part_uuid=$(echo "$uuids" | sed -n '2p' | tr -d '[:space:]')

    if [[ -z "$root_uuid" ]] || [[ -z "$part_uuid" ]]; then
        error "Failed to create root filesystem or get UUIDs"
    fi
    info "Root UUID (fstab): ${root_uuid}"
    info "Partition UUID (kernel): ${part_uuid}"

    # Step 5: Update fstab with UUID
    local fstab_tmp="${CACHE_DIR}/fstab-$$.txt"
    printf 'UUID=%s / %s defaults 0 1\n' "${root_uuid}" "${ROOT_FSTYPE}" > "$fstab_tmp"
    printf 'LABEL=ALARMBOOT /efi vfat defaults 0 2\n' >> "$fstab_tmp"
    printf 'tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0\n' >> "$fstab_tmp"
    guestfish > /dev/null 2>&1 << GF
add-drive $image_file format:raw
launch
mount /dev/sda2 /
upload $fstab_tmp /etc/fstab
umount-all
GF
    rm -f "$fstab_tmp"

    # Step 6: Update extlinux.conf with PARTUUID
    sed "s|root=PARTUUID=PARTUUID|root=PARTUUID=${part_uuid}|" "${CACHE_DIR}/extlinux.conf" > "${CACHE_DIR}/extlinux.conf.final"
    mcopy -o -i "$boot_img" "${CACHE_DIR}/extlinux.conf.final" ::/extlinux/extlinux.conf
    rm -f "${CACHE_DIR}/extlinux.conf.final"

    # Step 7: Write boot partition into image
    dd if="$boot_img" of="$image_file" bs=1M seek="$BOOT_START_MB" conv=notrunc status=none
    sync

    # Step 8: Cleanup
    rm -f "$boot_img" "$rootfs_tar"
    rm -f "${CACHE_DIR}/extlinux.conf"

    local img_size; img_size=$(stat -c%s "$image_file")
    info "Image: $((img_size / 1024 / 1024)) MB"

    if sfdisk -l "$image_file" >/dev/null 2>&1; then
        local partitions
        partitions=$(sfdisk -l "$image_file" 2>/dev/null | grep -c "^${image_file}")
        info "${partitions} partitions verified"
    else
        warn "GPT partition table corrupted"
    fi

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  BUILD COMPLETE${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo "  Image: ${image_file}"
    echo "  Size:  $((img_size / 1024 / 1024)) MB"
    echo "  Target: ${TARGET}"
    echo "  Root:  ${ROOT_FSTYPE} (PARTUUID: ${part_uuid}, fstab UUID: ${root_uuid})"
    echo ""

    case "$TARGET" in
        nvme)
        echo "  This image goes on NVMe. U-Boot must be flashed to SPI flash separately."
        echo "  See docs/spi-nvme-boot.md for instructions."
        echo ""
        echo "  Flash to NVMe (via USB adapter or on-board after boot):"
        echo "    dd if=${image_file} of=/dev/nvme0n1 bs=4M status=progress"
        echo ""
        echo "  First boot: U-Boot on SPI → kernel+rootfs on NVMe"
        echo "  extlinux.conf on FAT32 boot partition, root filesystem on XFS partition"
        ;;
        emmc)
        echo "  Flash to eMMC module (e.g. /dev/mmcblk1 on OP5P):"
        echo "    dd if=${image_file} of=/dev/mmcblk1 bs=4M status=progress"
        echo ""
        echo "  Boot: BootROM → TPL(SPI) → SPL(eMMC) → BL31 → U-Boot proper → kernel"
        echo "  extlinux.conf on FAT32 boot partition, root filesystem on ${ROOT_FSTYPE} partition"
        ;;
        *)
        echo "  Flash to SD card:"
        echo "    dd if=${image_file} of=/dev/sdX bs=4M status=progress"
        echo ""
        echo "  Boot: BootROM → TPL(SPI) → SPL(SD) → BL31 → U-Boot proper → kernel"
        echo "  extlinux.conf on FAT32 boot partition, root filesystem on ${ROOT_FSTYPE} partition"
        ;;
    esac
    echo ""
    echo "  Default login (serial console ttyS2, 1500000 baud):"
    echo "    root / root"
    echo ""

    # Compress image with zstd for distribution
    info "Compressing image with zstd (this may take a few minutes)..."
    local compressed_file="${image_file}.zst"
    rm -f "$compressed_file"
    zstd -T0 -19 --rm "$image_file" -o "$compressed_file" 2>&1 | tail -3
    local compressed_size
    compressed_size=$(du -sh "$compressed_file" | cut -f1)
    info "Compressed image: ${compressed_size}"

    cat > "${OUTPUT_DIR}/image-info.txt" << EOF
Orange Pi 5 Plus ${TARGET^^} Image
Built: $(date)
Kernel: ${KERNEL_VERSION:-unknown}
Image: $(basename "${compressed_file}")
Target: ${TARGET}
Root PARTUUID (kernel): ${part_uuid}
Root UUID (fstab): ${root_uuid}
Root filesystem: ${ROOT_FSTYPE}
EOF

    echo ""
    echo "  Compressed: ${compressed_file}"
    echo "  Size: ${compressed_size}"
    echo ""
    echo "  To flash:"
    echo "    zstdcat ${compressed_file} | dd of=/dev/sdX bs=4M status=progress"
    echo "    # or"
    echo "    zstd -d ${compressed_file} --stdout | dd of=/dev/sdX bs=4M status=progress"
    echo ""
}

# ---------------------------------------------------------------------------
# STAGE 8 — Package kernel as Arch Linux .pkg.tar.zst
# ---------------------------------------------------------------------------
stage_08_packages() {
    header "Stage 8: Packaging kernel as Arch Linux packages"

    if [[ "${SKIP_KERNEL:-0}" -eq 1 ]] || [[ -z "${KERNEL_VERSION:-}" ]]; then
        error "Kernel must be built before packaging"
    fi

    local pkgver="${KERNEL_VERSION#v}"
    pkgver="${pkgver//-/_}"  # pacman uses last '-' to split pkgver/pkgrel
    pkgver="${pkgver}-1"
    local epoch; epoch=$(date +%s)
    local kernel_src="${SOURCES_DIR}/linux"
    local kernel_build="${BUILD_DIR}/kernel"

    # -----------------------------------------------------------------------
    # Package 1: linux-op5p (kernel Image + modules + DTBs)
    # -----------------------------------------------------------------------
    info "Creating linux-op5p ${pkgver} package..."

    local pkg_kernel; pkg_kernel=$(mktemp -d)
    local pkgfile_kernel="${OUTPUT_DIR}/linux-op5p-${pkgver}-aarch64.pkg.tar.zst"

    # Kernel Image - install to /efi/ for U-Boot
    install -Dm644 "${kernel_build}/arch/arm64/boot/Image" \
        "${pkg_kernel}/efi/Image"

    # Device Tree Blobs - install to /efi/dtbs/ for U-Boot
    local dtb_dir="${kernel_build}/arch/arm64/boot/dts/rockchip"
    if [[ -d "$dtb_dir" ]]; then
        ensure_dir "${pkg_kernel}/efi/dtbs"
        cp "$dtb_dir"/*.dtb "${pkg_kernel}/efi/dtbs/"
    fi

    # Also install to /boot/ for compatibility
    install -Dm644 "${kernel_build}/arch/arm64/boot/Image" \
        "${pkg_kernel}/boot/Image"
    if [[ -d "$dtb_dir" ]]; then
        ensure_dir "${pkg_kernel}/boot/dtbs"
        cp "$dtb_dir"/*.dtb "${pkg_kernel}/boot/dtbs/"
    fi

    # Kernel modules (install fresh into package dir)
    make -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
        O="$kernel_build" INSTALL_MOD_PATH="${pkg_kernel}/usr" \
        modules_install 2>&1 | tail -3

    # Depmod
    depmod -b "${pkg_kernel}/usr" -a "$KERNEL_VERSION" 2>/dev/null || true

    # .PKGINFO
    local pkg_size_kernel
    pkg_size_kernel=$(find "${pkg_kernel}" -type f -exec stat -c%s {} + 2>/dev/null | paste -sd+ | bc || echo 0)
    cat > "${pkg_kernel}/.PKGINFO" << EOF
pkgname = linux-op5p
pkgver = ${pkgver}
pkgdesc = Linux kernel ${KERNEL_VERSION} for Orange Pi 5 Plus (RK3588)
url = https://kernel.org
builddate = ${epoch}
packager = op5p-diy-builder
size = ${pkg_size_kernel}
arch = aarch64
license = GPL2
EOF

    # Create .install script for post-install sync to EFI partition
    cat > "${pkg_kernel}/.INSTALL" << 'EOF'
post_install() {
    echo "Syncing kernel to EFI partition..."
    cp -f /boot/Image /efi/Image 2>/dev/null || true
    cp -f /boot/dtbs/rk3588-orangepi-5-plus.dtb /efi/dtbs/rk3588-orangepi-5-plus.dtb 2>/dev/null || true
    sync
    echo "Kernel synced to EFI partition."
}

post_upgrade() {
    post_install
}

post_remove() {
    echo "Note: /efi/Image and /efi/dtbs/ were NOT removed."
    echo "Remove manually if needed."
}
EOF

    # Package
    rm -f "$pkgfile_kernel"
    bsdtar -cf "$pkgfile_kernel" --zstd -C "$pkg_kernel" \
        $(cd "$pkg_kernel" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||') 2>/dev/null
    rm -rf "$pkg_kernel"
    info "  -> $(basename "$pkgfile_kernel") ($(du -h "$pkgfile_kernel" | cut -f1))"

    # -----------------------------------------------------------------------
    # Package 2: linux-op5p-headers (kernel source tree + headers)
    # -----------------------------------------------------------------------
    info "Creating linux-op5p-headers ${pkgver} package..."

    local pkg_headers; pkg_headers=$(mktemp -d)
    local pkgfile_headers="${OUTPUT_DIR}/linux-op5p-headers-${pkgver}-aarch64.pkg.tar.zst"

    # Strip-copy kernel source tree and compress with zstd
    local hsrc_staging="${CACHE_DIR}/kernel-src-headers-staging"
    rm -rf "$hsrc_staging"
    mkdir -p "$hsrc_staging"
    tar --exclude='.git' \
        --exclude='Documentation' \
        --exclude='tools' \
        --exclude='samples' \
        --exclude='arch/alpha' --exclude='arch/arc' \
        --exclude='arch/arm' --exclude='arch/avr32' \
        --exclude='arch/blackfin' --exclude='arch/c6x' \
        --exclude='arch/csky' --exclude='arch/h8300' \
        --exclude='arch/hexagon' --exclude='arch/ia64' \
        --exclude='arch/loongarch' --exclude='arch/m68k' \
        --exclude='arch/metag' --exclude='arch/microblaze' \
        --exclude='arch/mips' --exclude='arch/nios2' \
        --exclude='arch/openrisc' --exclude='arch/parisc' \
        --exclude='arch/powerpc' --exclude='arch/riscv' \
        --exclude='arch/s390' --exclude='arch/sh' \
        --exclude='arch/sparc' --exclude='arch/um' \
        --exclude='arch/xtensa' \
        -cf - -C "$kernel_src" . | tar -xf - -C "$hsrc_staging"

    # Copy .config and Module.symvers
    cp "${kernel_build}/.config" "${hsrc_staging}/.config"
    [[ -f "${kernel_build}/Module.symvers" ]] && \
        cp "${kernel_build}/Module.symvers" "${hsrc_staging}/"

    # modules_prepare to build the scaffolding
    make -C "$kernel_src" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
        O="$hsrc_staging" modules_prepare 2>/dev/null | tail -3

    # Compress with zstd
    local hsrc_tarball="${pkg_headers}/usr/src/linux-${KERNEL_VERSION}.tar.zst"
    ensure_dir "$(dirname "$hsrc_tarball")"
    tar --zstd -cf "$hsrc_tarball" -C "$hsrc_staging" .
    rm -rf "$hsrc_staging"

    # Create first-boot decompression service for headers package
    ensure_dir "${pkg_headers}/usr/local/sbin" "${pkg_headers}/etc/systemd/system" "${pkg_headers}/etc/systemd/system/multi-user.target.wants"
    cat > "${pkg_headers}/usr/local/sbin/decompress-kernel-src" << 'EOSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="__KERNEL_VERSION__"
TARBALL="/usr/src/linux-${KERNEL_VERSION}.tar.zst"
TARGET="/usr/src/linux-${KERNEL_VERSION}"

[[ -f "$TARBALL" ]] || exit 0
[[ -d "$TARGET" ]] && exit 0

echo "Decompressing kernel source tree..."
mkdir -p "$TARGET"
tar --zstd -xf "$TARBALL" -C "$TARGET"
chown -R 0:0 "$TARGET" 2>/dev/null || true
rm -f "$TARBALL"

echo "Kernel source tree decompressed successfully"
mkdir -p /var/lib
touch /var/lib/decompress-kernel-src-done
EOSCRIPT
    sed -i "s/__KERNEL_VERSION__/${KERNEL_VERSION}/g" \
        "${pkg_headers}/usr/local/sbin/decompress-kernel-src"
    chmod +x "${pkg_headers}/usr/local/sbin/decompress-kernel-src"

    cat > "${pkg_headers}/etc/systemd/system/decompress-kernel-src.service" << 'EOSVC'
[Unit]
Description=Decompress kernel source tree for module compilation
After=local-fs.target
ConditionPathExists=!/var/lib/decompress-kernel-src-done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/decompress-kernel-src
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOSVC
    ln -sf /etc/systemd/system/decompress-kernel-src.service \
        "${pkg_headers}/etc/systemd/system/multi-user.target.wants/decompress-kernel-src.service" 2>/dev/null || true

    # Create /usr/lib/modules/<ver>{build,source} symlinks
    local mod_dir="${pkg_headers}/usr/lib/modules/${KERNEL_VERSION}"
    mkdir -p "$mod_dir"
    ln -sf "/usr/src/linux-${KERNEL_VERSION}" "${mod_dir}/build"
    ln -sf "/usr/src/linux-${KERNEL_VERSION}" "${mod_dir}/source"

    # .PKGINFO
    local pkg_size_headers
    pkg_size_headers=$(find "${pkg_headers}" -type f -exec stat -c%s {} + 2>/dev/null | paste -sd+ | bc || echo 0)
    cat > "${pkg_headers}/.PKGINFO" << EOF
pkgname = linux-op5p-headers
pkgver = ${pkgver}
pkgdesc = Linux kernel ${KERNEL_VERSION} headers and source for Orange Pi 5 Plus
url = https://kernel.org
builddate = ${epoch}
packager = op5p-diy-builder
size = ${pkg_size_headers}
arch = aarch64
license = GPL2
EOF

    rm -f "$pkgfile_headers"
    bsdtar -cf "$pkgfile_headers" --zstd -C "$pkg_headers" \
        $(cd "$pkg_headers" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||') 2>/dev/null
    rm -rf "$pkg_headers"
    info "  -> $(basename "$pkgfile_headers") ($(du -h "$pkgfile_headers" | cut -f1))"

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  PACKAGES BUILD COMPLETE${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo "  ${OUTPUT_DIR}/"
    echo "    $(basename "$pkgfile_kernel")"
    echo "    $(basename "$pkgfile_headers")"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
CLEAN_BUILD=0
SKIP_KERNEL=0
START_STAGE=0
PACKAGES_ONLY=0
FORCE_LATEST=0
KERNEL_VERSION=""
KERNEL_MODE="stable"  # stable, lts, rc
TARGET="${TARGET:-sd}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage ;;
        --target) TARGET="$2"; shift 2 ;;
        --clean) CLEAN_BUILD=1; shift ;;
        --no-kernel) SKIP_KERNEL=1; shift ;;
        --stage) START_STAGE="$2"; shift 2 ;;
        --packages-only) PACKAGES_ONLY=1; shift ;;
        --force-latest) FORCE_LATEST=1; shift ;;
        --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
        --kernel-lts) KERNEL_MODE="lts"; shift ;;
        --kernel-rc) KERNEL_MODE="rc"; shift ;;
        --kernel-stable) KERNEL_MODE="stable"; shift ;;
        *) error "Unknown: $1 (use --help)" ;;
    esac
done

case "$TARGET" in
    sd|emmc|nvme) ;;
    *) error "Invalid target: $TARGET (use sd, emmc, or nvme)" ;;
esac

[[ $CLEAN_BUILD -eq 1 ]] && clean_all

ensure_dir "$BUILD_DIR" "$CACHE_DIR" "$OUTPUT_DIR" "$SOURCES_DIR" \
    "${BUILD_DIR}/toolchain" 2>/dev/null || true

ALL_STAGES=(stage_00_env stage_01_toolchain stage_02_rkbin \
            stage_03_tfa stage_04_uboot stage_05_kernel)

if [[ $PACKAGES_ONLY -eq 0 ]]; then
    ALL_STAGES+=(stage_06_rootfs stage_07_image)
fi
ALL_STAGES+=(stage_08_packages)

if [[ $START_STAGE -gt 0 ]]; then
    for stage_func in "${ALL_STAGES[@]}"; do
        local_num="${stage_func#stage_}"
        local_num="${local_num%%_*}"
        local_num=$((10#$local_num))
        [[ $local_num -ge $START_STAGE ]] && $stage_func
    done
    exit 0
fi

for stage_func in "${ALL_STAGES[@]}"; do
    $stage_func
done
