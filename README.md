# Orange Pi 5 Plus Arch Linux ARM Image Builder

从零构建 Orange Pi 5 Plus 的 Arch Linux ARM 系统镜像。所有核心组件（TF-A、U-Boot、Linux 内核）均从**最新上游源码**编译。

## 目录结构

```
op5p_diy/
├── build.sh          # 主构建脚本（一键构建，8 个 stage）
├── README.md         # 本文档
├── build/
│   ├── sources/      # 源码仓库（git clone）
│   ├── kernel/       # 内核编译输出（O=build/kernel）
│   └── toolchain/    # ARM 交叉编译工具链
├── cache/            # 缓存（rootfs tarball、ccache）
└── output/           # 最终输出
    ├── orangepi5-plus-{sd,emmc,nvme}-YYYYMMDD.img.zst
    └── linux-op5p-*-aarch64.pkg.tar.zst
```

## 前置条件

### 系统要求

- **x86_64 Linux** 宿主机（推荐 Arch Linux）
- **sudo** 权限（用于 guestfish 操作）
- **内存**：见下方自动分级

| 内存 | 可行性 | ccache 位置 | 编译产物位置 | 磁盘写入 |
|:---:|:------:|:----------:|:----------:|:-------:|
| ≥ 32GB | ✅ 舒适 | **tmpfs** | **tmpfs** | **零写入** |
| 16GB | ✅ 推荐 | **tmpfs** | 磁盘 | 仅编译产物 |
| 8GB | ✅ 可行 | **tmpfs** | 磁盘 | 仅编译产物 |
| 4GB | ⚠️ 勉强 | 磁盘 | 磁盘 | 全部（建议 `-j 2`） |

> 脚本自动检测 `/dev/shm` 大小并选择最优策略，无需手动配置。

### 系统包

```bash
# Arch Linux
sudo pacman -S base-devel git wget parted dosfstools mtools libarchive \
               bc flex bison xfsprogs libguestfs ccache

# Ubuntu/Debian
sudo apt install build-essential git wget parted dosfstools mtools bsdtar \
                 bc flex bison pkg-config libssl-dev ccache
```

### 磁盘空间

- **首次构建**：约 10-15GB（源码 + 编译输出 + 镜像）
- **后续构建**：约 5-8GB（缓存命中后减少）
- 如使用 tier 1（全内存），磁盘需求减半

## 快速开始

```bash
# 完整构建 SD 卡镜像（默认）
./build.sh

# 构建 NVMe 镜像（U-Boot 写入 SPI 闪存）
./build.sh --target nvme

# 构建 eMMC 镜像
./build.sh --target emmc
```

构建完成后输出：
```
output/
├── orangepi5-plus-sd-20260531.img.zst       # 压缩镜像（~1GB）*
├── orangepi5-plus-nvme-20260531.img.zst
├── orangepi5-plus-emmc-20260531.img.zst
├── linux-op5p-7.0.10-1-aarch64.pkg.tar.zst  # 内核安装包
└── linux-op5p-headers-7.0.10-1-aarch64.pkg.tar.zst  # 内核头文件包
```

\* 镜像大小 = `IMAGE_SIZE_MB`（默认 8192MB），zstd 压缩后约 1GB。

## 分阶段构建

```bash
# 从特定阶段开始
./build.sh --stage 4     # 从 U-Boot 构建开始

# 跳过内核编译（测试 U-Boot / rootfs 时使用）
./build.sh --no-kernel

# 只编译内核包（跳过 rootfs 和镜像组装）
./build.sh --packages-only

# 清理所有构建产物
./build.sh --clean

# 强制拉取最新源码（定时任务用）
./build.sh --force-latest
```

### Stage 说明

| Stage | 内容 | 耗时 | 说明 |
|-------|------|------|------|
| 0 | 环境检查 | 5秒 | 验证依赖工具是否存在 |
| 1 | 交叉编译工具链 | 2-5分 | 检测系统 GCC 或下载 ARM GNU Toolchain |
| 2 | rkbin (DDR blob) | 1-2分 | 从 armbian/rkbin 获取闭源 DDR 初始化二进制 |
| 3 | TF-A BL31 | 3-5分 | 从源码编译 ARM Trusted Firmware (PLAT=rk3588) |
| 4 | U-Boot | 5-10分 | 从源码编译主线上游 U-Boot |
| 5 | Linux 内核 | 30-60分 | 从源码编译最新主线内核（最长的阶段） |
| 6 | 根文件系统 | 5-10分 | 下载并配置 Arch Linux ARM rootfs |
| 7 | 组装镜像 | 2-5分 | GPT 分区 + extlinux + guestfish 写入 rootfs |
| 8 | 内核包打包 | 1-2分 | 生成 .pkg.tar.zst 安装包 |

## 刷入镜像

### SD 卡

```bash
zstdcat output/orangepi5-plus-sd-YYYYMMDD.img.zst | sudo dd of=/dev/sdX bs=4M status=progress
```

### eMMC 模块（MaskROM 模式）

```bash
# 进入 MaskROM 模式（按住 MaskROM 按钮上电）
sudo rkdeveloptool db build/sources/rkbin/rk35/rk3588_spl_loader_v1.16.113.bin
sudo rkdeveloptool wl 0 output/orangepi5-plus-emmc-YYYYMMDD.img.zst
sudo rkdeveloptool rd 0
```

### NVMe（需先刷 SPI 闪存）

NVMe 启动需要先将 U-Boot 写入 SPI 闪存，详见 `docs/spi-nvme-boot.md`。

## 首次启动

1. 插入 SD 卡 / eMMC 模块到 Orange Pi 5 Plus
2. 连接 **串口调试线**（ttyS2, 1500000 baud）或 HDMI 显示器
3. 上电启动
4. 默认凭据：**root / root**
5. 首次启动自动执行：
   - **扩展根分区**至填满整个存储设备
   - **解压内核源码树**到 `/usr/src/linux-*/`

### 串口参数

| 参数 | 值 |
|------|-----|
| Baud | 1500000 |
| Data | 8 bit |
| Parity | None |
| Stop | 1 bit |

## 自定义配置

编辑 `build.sh` 开头的变量：

```bash
IMAGE_SIZE_MB=8192       # 镜像大小（8GB）
BOOT_SIZE_MB=512         # /boot 分区大小
ROOT_FSTYPE="xfs"        # 根文件系统（xfs 或 ext4）
TARGET="sd"              # 目标设备（sd / emmc / nvme）
```

### 内核版本选择

```bash
# 选择特定内核版本
./build.sh --kernel-version 6.12

# 选择主线最新稳定版（默认）
KERNEL_MODE=stable ./build.sh

# 选择最新 LTS 版本
KERNEL_MODE=lts ./build.sh

# 选择最新 RC 版本
KERNEL_MODE=rc ./build.sh
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `BUILD_JOBS` | `nproc` | 并行编译线程数 |
| `CROSS_COMPILE` | `aarch64-linux-gnu-` | 交叉编译器前缀 |
| `ROOT_FSTYPE` | `xfs` | 根文件系统 (xfs/ext4) |
| `CCACHE_DIR` | 自动 | ccache 缓存目录 |
| `CCACHE_MAX_SIZE` | `2G` | ccache 最大大小 |
| `ALARM_MIRROR` | `mirrors.tuna.tsinghua.edu.cn` | Arch Linux ARM 镜像 |

## 构建原理

### 启动流程

```
BootROM → TPL(DDR init, rkbin) → SPL(U-Boot) → TF-A BL31(EL3)
    → U-Boot proper → extlinux → Linux 内核
```

### 镜像布局（SD/eMMC）

| 偏移 | 内容 | 大小 |
|------|------|------|
| Sector 64 | u-boot-rockchip.bin (TPL+SPL+BL31+U-Boot) | ~8MB |
| 1MB | FAT32 /boot (kernel, DTBs, extlinux.conf) | 512MB |
| 513MB | XFS / root (Arch Linux ARM) | 剩余空间 |

### 镜像布局（NVMe）

NVMe 镜像不含 U-Boot，U-Boot 需刷入 SPI 闪存。

### 组件来源

| 组件 | 源码 | 许可 |
|------|------|------|
| DDR init (TPL) | armbian/rkbin | 闭源二进制 |
| TF-A (BL31) | trustedfirmware-a.git | BSD-3-Clause |
| U-Boot | u-boot/u-boot.git | GPL-2.0 |
| Linux 内核 | torvalds/linux.git | GPL-2.0 |
| 根文件系统 | Arch Linux ARM | GPL/各种 |

## 常见问题

**Q: 内核编译太慢怎么办？**
A: 首次编译需要 30-60 分钟。ccache 会在后续编译中自动缓存，将时间缩短到 5-15 分钟。也可用 `KERNEL_MODE=lts` 选择更小更快的 LTS 内核。

**Q: 内存不够怎么办？**
A: 脚本自动检测并降级（最低 4GB 可跑）。如内存紧张，设置 `BUILD_JOBS=2` 减少并行编译压力。

**Q: 如何更新到最新内核？**
A: 删除 `build/sources/linux` 并重新运行 `./build.sh --stage 5`，或使用 `--force-latest` 标志。

**Q: 支持其他 RK3588 开发板吗？**
A: 修改 `UBOOT_DEFCONFIG` 和对应 DTB。例如 Rock 5B：
   - `UBOOT_DEFCONFIG="rock-5b-rk3588_defconfig"`
   - DTB: `rk3588-rock-5b.dtb`

**Q: 生成的 .img.zst 还需要解压吗？**
A: 不需要。`zstdcat | dd` 直接刷入，zstd 支持管道解压。

## 相关资源

- [U-Boot RK3588 文档](https://docs.u-boot.org/en/latest/board/rockchip/rockchip.html)
- [Armbian RK3588 构建](https://github.com/armbian/build)
- [Arch Linux ARM](https://archlinuxarm.org/)
- [Orange Pi 5 Plus 技术规格](http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/details/Orange-Pi-5-plus.html)
- [QCNFA765 WiFi 6E 驱动](https://github.com/kvalo/ath11k-firmware)
