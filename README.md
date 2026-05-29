# Orange Pi 5 Plus Arch Linux ARM 构建脚本

从零构建 Orange Pi 5 Plus 的 Arch Linux ARM 系统镜像。所有核心组件（TF-A、U-Boot、Linux 内核）均从**最新上游源码**编译。

## 目录结构

```
op5p_diy/
├── build.sh          # 主构建脚本（一键构建）
├── README.md         # 本文档
├── build/
│   ├── sources/      # 源码仓库（git clone）
│   │   ├── linux/                    # Linux 内核
│   │   ├── u-boot/                   # U-Boot
│   │   ├── arm-trusted-firmware/     # TF-A
│   │   └── rkbin/                    # Rockchip 二进制 blobs
│   ├── kernel/       # 内核编译输出（O=build/kernel）
│   └── toolchain/    # ARM 交叉编译工具链
├── cache/            # 缓存（rootfs tarball、rootfs 目录、中间镜像）
└── output/           # 最终输出
    └── orangepi5-plus-archlinux-YYYYMMDD.img
```

## 前置条件

- **x86_64 Linux** 宿主机（推荐 Arch Linux）
- **sudo** 权限（用于 loop mount 操作）
- 以下系统包：

```bash
# Arch Linux
sudo pacman -S base-devel git wget parted dosfstools mtools libarchive \
               bc flex bison xfsprogs libguestfs

# Ubuntu/Debian
sudo apt install build-essential git wget parted dosfstools mtools bsdtar \
                 bc flex bison pkg-config libssl-dev
```

- 约 **10GB** 磁盘空间（源码 + 编译输出 + 镜像）
- 良好的网络连接（首次构建需下载 ~2GB 数据）

## 快速开始

```bash
# 完整构建（所有 stage，约 30-90 分钟）
./build.sh
```

构建完成后输出：
```
output/orangepi5-plus-sd-YYYYMMDD.img.zst   # 压缩镜像（~2-3GB）
output/linux-op5p-*.pkg.tar.zst             # 内核安装包
```

## 分阶段构建

```bash
# 从特定阶段开始（跳过之前的阶段）
./build.sh --stage 4    # 从 U-Boot 构建开始

# 跳过内核编译（测试引导/根文件系统时使用）
./build.sh --no-kernel

# 清理所有构建产物并重新构建
./build.sh --clean
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
| 7 | 组装镜像 | 2-5分 | 创建 GPT 分区、写入引导、生成最终 .img 文件 |

## 刷入 SD 卡

```bash
# 确认 SD 卡设备
lsblk

# 直接刷入压缩镜像（无需先解压）
zstdcat output/orangepi5-plus-sd-YYYYMMDD.img.zst | sudo dd of=/dev/sdX bs=4M status=progress

# 或者用 zstd -d --stdout
zstd -d output/orangepi5-plus-sd-YYYYMMDD.img.zst --stdout | sudo dd of=/dev/sdX bs=4M status=progress
```

## 首次启动

1. 将 SD 卡插入 Orange Pi 5 Plus
2. 连接 **串口调试线** 到 3-pin UART 接口（ttyS2, 1500000 baud）
3. 上电启动
4. 默认凭据：**root / root**
5. （可选）连接 HDMI 显示器也会显示登录界面

### 首次启动自动操作

首次启动时会自动执行以下操作（仅执行一次）：

1. **展开根分区**：自动扩展根分区以填满整个 SD 卡
2. **解压内核源码树**：将 `/usr/src/linux-*.tar.zst` 解压到 `/usr/src/linux-*/`
   - 用于后续编译内核模块
   - 解压后自动删除压缩包节省空间

### 串口连接参数

| 参数 | 值 |
|------|-----|
| Baud | 1500000 |
| Data | 8 bit |
| Parity | None |
| Stop | 1 bit |
| Flow | None |

连接工具：`screen /dev/ttyUSB0 1500000` 或 `picocom -b 1500000 /dev/ttyUSB0`

## 进阶：自定义配置

编辑 `config.sh` 或直接修改 `build.sh` 开头的变量：

```bash
IMAGE_SIZE_MB=8192       # 镜像大小（8GB）
BOOT_SIZE_MB=512         # /boot 分区大小
ROOT_FSTYPE="xfs"        # 根文件系统（xfs 或 ext4）
UBOOT_DEFCONFIG="orangepi-5-plus-rk3588_defconfig"  # U-Boot 配置
```

## 构建原理

### 启动流程

```
BootROM → TPL(DDR init, 来自 rkbin) → SPL(U-Boot) → TF-A BL31(EL3)
    → U-Boot proper → extlinux → Linux 内核
```

### 镜像布局

| 偏移 | 内容 | 大小 |
|------|------|------|
| 0 | GPT header + MBR | 17KB |
| Sector 64 (32KB) | u-boot-rockchip.bin (TPL+SPL+BL31+U-Boot) | ~8MB |
| 1MB | FAT32 /boot (kernel, DTBs, extlinux.conf) | 512MB |
| 513MB | XFS / (Arch Linux ARM rootfs, 默认 `ROOT_FSTYPE=xfs`) | 剩余空间 |

> 文件系统类型可通过 `ROOT_FSTYPE=ext4 ./build.sh` 切换回 ext4。

### 组件来源

| 组件 | 源码 | 是否开源 |
|------|------|----------|
| DDR init (TPL) | armbian/rkbin | ❌ 闭源二进制 |
| TF-A (BL31) | trustedfirmware-a.git | ✅ 上游源码 |
| U-Boot | u-boot/u-boot.git | ✅ 上游源码 |
| Linux 内核 | torvalds/linux.git | ✅ 上游源码 |
| 根文件系统 | Arch Linux ARM (mirror) | ✅ |

## 常见问题

**Q: 内核编译太慢怎么办？**
A: 使用 `--stage 5 --clean` 单独构建内核，或者首次后使用缓存。

**Q: 如何更新内核源码到最新版本？**
A: 删除 `build/sources/linux` 目录重新克隆，或手动 `git pull`。

**Q: 需要联网吗？**
A: 首次构建需要下载工具链（~200MB）、rkbin（~100MB）、内核源码（~2GB）、rootfs（~200MB）。所有下载内容会缓存在 `cache/` 目录。

**Q: 支持其他 RK3588 开发板吗？**
A: 修改 `UBOOT_DEFCONFIG` 和对应的 DTB 名称即可。例如 Rock 5B：
   - `UBOOT_DEFCONFIG="rock-5b-rk3588_defconfig"`
   - DTB: `rk3588-rock-5b.dtb`

## 相关资源

- [U-Boot RK3588 文档](https://docs.u-boot.org/en/latest/board/rockchip/rockchip.html)
- [Armbian RK3588 构建](https://github.com/armbian/build)
- [Arch Linux ARM](https://archlinuxarm.org/)
- [Orange Pi 5 Plus 技术规格](http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/details/Orange-Pi-5-plus.html)
