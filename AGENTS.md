# PROJECT KNOWLEDGE BASE

**Generated:** 2026-05-26
**Project:** Orange Pi 5 Plus Arch Linux ARM Image Builder

## OVERVIEW

Builds bootable Arch Linux ARM system images for Rockchip RK3588 (Orange Pi 5 Plus) from **upstream source** — TF-A, U-Boot, Linux kernel, ALARM rootfs. Single `build.sh` script orchestrates all 8 stages.

## STRUCTURE

```
op5p_diy/
├── build.sh          # Main build script (829 lines, all stages)
├── README.md         # Build/usage documentation
├── kernel-optimization-guide.md  # Kernel config tuning guide (438 lines)
├── docs/
│   └── spi-nvme-boot.md          # SPI flash + NVMe boot instructions
├── build/            # Build artifacts (git repos, toolchain, kernel output)
│   ├── sources/      # git repos: linux, u-boot, arm-trusted-firmware, rkbin
│   ├── kernel/       # Kernel build output (O=build/kernel)
│   └── toolchain/    # aarch64 cross-compiler (ARM GNU Toolchain 13.3)
├── cache/            # Rootfs tarball, extracted rootfs, intermediate files
└── output/           # Final .img.zst files (orangepi5-plus-{sd,nvme}-YYYYMMDD.img.zst)
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Full build | `build.sh` | Entry point, all stages |
| Kernel config | `build.sh#L347-L469` (stage_05_kernel) | `scripts/config` disables/enables options |
| U-Boot build | `build.sh#L251-L342` (stage_04_uboot) | Resolves latest tag, builds with BL31+ROCKCHIP_TPL |
| Image assembly | `build.sh#L610-L779` (stage_07_image) | guestfish for GPT/XFS, dd for U-Boot |
| SPI + NVMe boot | `docs/spi-nvme-boot.md` | Full guide for SPI flash + NVMe setup |
| Kernel tuning | `kernel-optimization-guide.md` | P0/P1 optimization recommendations |
| Rootfs config | `build.sh#L474-L605` (stage_06_rootfs) | systemd units, fstab, kernel modules |
| Toolchain | `build.sh#L140-L188` (stage_01_toolchain) | System GCC detection → ARM download fallback |

## CONVENTIONS

- **Bash**: `set -euo pipefail` (strict mode), POSIX + bashisms mixed
- **Functions**: `snake_case` stage functions (`stage_00_env`, `stage_05_kernel`)
- **Globals**: `UPPER_CASE` for config (`IMAGE_SIZE_MB`, `ROOT_FSTYPE`)
- **Helper logging**: `info()`, `warn()`, `error()`, `header()`, `sub()` wrappers
- **Paths**: `SCRIPT_DIR`-relative, never hardcoded absolute paths
- **Error handling**: `error()` calls `exit 1`, functions check preconditions before work
- **Git**: `git_clone_commit` helper for shallow fetch at specific ref; `GIT_SSL_NO_VERIFY=1` for Chinese network
- **Idempotency**: Each stage checks for cached output before re-doing work

## ANTI-PATTERNS (THIS PROJECT)

- No `config.sh` — config is inline at top of `build.sh`
- No CI/CD — single-machine build, no `.github/workflows/`
- No Makefile — everything is in `build.sh`
- No version lock — stages auto-resolve latest tags (U-Boot/kernel) on each build
- No containerized build — depends on host `guestfish`, `parted`, etc.

## COMMANDS

```bash
./build.sh                    # Full build (all stages, ~30-90 min)
./build.sh --target nvme      # Build NVMe image (U-Boot on SPI flash)
./build.sh --stage 5          # Resume from kernel build onward
./build.sh --clean            # Remove build/, cache/, output/
./build.sh --no-kernel        # Skip kernel build (bootloader/rootfs testing)
```

## NOTES

- **GitHub SSL failures in China**: `GIT_SSL_NO_VERIFY=1` on all git ops; rkbin has tarball fallback
- **U-Boot ARCH=arm**: U-Boot uses `ARCH=arm` (not `arm64`) for AArch64 — its `arch/arm/cpu/armv8/` handles 64-bit
- **guestfish dependency**: XFS root filesystem requires `libguestfs` for tar-in (no loop devices needed)
- **Build time**: Stage 5 (kernel) is 30-60 min dominant; others are 1-10 min each
- **NVMe boot**: BootROM cannot boot NVMe directly — U-Boot on SPI flash loads kernel from NVMe
- **Serial console**: ttyS2 at 1500000 baud, autologin root
