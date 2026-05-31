# Orange Pi 5 Plus: SPI Flash + NVMe Boot

## 为什么用 SPI + NVMe？

Orange Pi 5 Plus 的 BootROM **不支持从 PCIe/NVMe 直接启动**。启动流程是：

```
BootROM → SPI Flash (TPL+SPL+BL31+U-Boot) → NVMe (extlinux → kernel + rootfs)
```

优势：

- **NVMe 速度** — 比 SD 卡快 5-10 倍
- **SPI 只写一次** — U-Boot 刷入 SPI 后不再需要 SD 卡
- **启动更快** — SPI 读取比 SD 卡初始化快得多

## 前提条件

- Orange Pi 5 Plus 主板（板载 32MB SPI NOR flash）
- NVMe SSD（M.2 M-key 2230/2242/2280）
- USB 转 TTL 串口调试线（3.3V，ttyS2, 1500000 baud）
- **方法一需要**：SD 卡（任意大小，用于启动后刷写 SPI）
- **方法二需要**：USB-A 转 A 线 + `rkdeveloptool`

### 构建产物

```bash
./build.sh --target nvme
```

完成后在 `output/` 和 U-Boot 源码目录中得到：

| 文件 | 用途 |
|------|------|
| `output/orangepi5-plus-nvme-YYYYMMDD.img.zst` | NVMe 磁盘镜像（GPT + FAT32 boot + XFS root） |
| `build/sources/u-boot/u-boot-rockchip-spi.bin` | SPI flash 镜像（~1.5MB，刷入 SPI NOR） |

## 方法一：通过 SD 卡刷写（推荐）

### 步骤 1：准备 SD 卡启动

最简单的办法是用完整 SD 镜像启动：

```bash
./build.sh --target sd
zstdcat output/orangepi5-plus-sd-YYYYMMDD.img.zst | sudo dd of=/dev/sdX bs=4M status=progress
```

也可以制作最小启动卡（仅含 U-Boot + kernel + dtb）：

```bash
BOOT_SD=/dev/sdX   # 替换为你的 SD 卡设备

# 写入 U-Boot（BootROM 从 LBA-64 读取）
sudo dd if=build/sources/u-boot/u-boot-rockchip.bin of=$BOOT_SD bs=512 seek=64 conv=notrunc

# 创建并挂载 FAT32 分区
sudo sfdisk ${BOOT_SD} << 'EOF'
label: gpt
start=16M, size=256M, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
EOF
sudo mkfs.vfat "${BOOT_SD}1" -n ALARMBOOT
sudo mount "${BOOT_SD}1" /mnt

# 写入 extlinux.conf
sudo mkdir -p /mnt/extlinux
sudo tee /mnt/extlinux/extlinux.conf << 'EXTLINUX'
label Arch Linux ARM
    linux /Image
    fdt /dtbs/rk3588-orangepi-5-plus.dtb
    append console=ttyS2,1500000n8 earlycon root=PARTUUID=ROOTPARTUUID rw rootwait
EXTLINUX

# 复制内核和 DTB
sudo cp build/kernel/arch/arm64/boot/Image /mnt/
sudo mkdir -p /mnt/dtbs
sudo cp build/kernel/arch/arm64/boot/dts/rockchip/rk3588-orangepi-5-plus.dtb /mnt/dtbs/
sudo umount /mnt
```

### 步骤 2：从 SD 卡启动，刷写 SPI

1. 插入 NVMe SSD 到 M.2 插槽
2. 插入 SD 卡
3. 连接串口调试线
4. 上电，**在 U-Boot 命令行按任意键中断启动**

```bash
# ===== 在 U-Boot 命令行中执行 =====

# 检查 SPI flash
=> sf probe
=> sf info
# 应显示 32MB SPI NOR flash（XM25QH256C 或 GD25B256E）

# 从 SD 卡（mmc 1）加载 SPI 镜像到内存
# mmc 0 = eMMC（如有），mmc 1 = SD 卡
=> load mmc 1:1 $kernel_addr_r u-boot-rockchip-spi.bin
# 如果使用完整 SD 镜像（build.sh --target sd），文件在 FAT32 分区
# 如果使用最小启动卡，文件需要额外拷贝到 boot 分区

# 擦除 SPI flash 前 2MB（SPI 镜像约 1.5MB）
=> sf erase 0 0x200000

# 写入 SPI 镜像
=> sf write $kernel_addr_r 0 0x180000

# 校验
=> sf read $loadaddr 0 0x180000
=> cmp.b $kernel_addr_r $loadaddr 0x180000
# 返回 "Total of 1572864 byte(s) were the same" 说明成功
```

### 步骤 3：写入 NVMe 镜像

保持 SD 卡启动，进入 Linux 系统后：

```bash
# 先解压 NVMe 镜像（zstd 压缩，~1GB → ~8GB）
zstd -d output/orangepi5-plus-nvme-YYYYMMDD.img.zst \
      -o /tmp/orangepi5-plus-nvme-YYYYMMDD.img

# 确认 NVMe 设备（通常是 /dev/nvme0n1）
lsblk | grep nvme

# 写入
sudo dd if=/tmp/orangepi5-plus-nvme-YYYYMMDD.img of=/dev/nvme0n1 \
        bs=4M status=progress conv=fsync

# 验证分区
sudo gdisk -l /dev/nvme0n1
```

> 如果不想占用 SD 卡的系统空间，也可以在 x86 编译机上直接用 USB 转 M.2 硬盘盒写入 NVMe，再插回 OP5P。

### 步骤 4：从 NVMe 启动

1. 断电
2. 移除 SD 卡
3. 上电

BootROM 检测到 SPI flash 中有 U-Boot → 加载 U-Boot → U-Boot 从 NVMe 读取 extlinux.conf → 加载 kernel + rootfs。

## 方法二：通过 Maskrom 模式刷写 SPI（无 SD 卡）

### 前提

安装 `rkdeveloptool`：

```bash
# Arch Linux
sudo pacman -S rkdeveloptool
```

### 步骤

1. 让 OP5P 进入 Maskrom 模式：
   - 断开电源
   - 短接 Maskrom 触点（或按住 Maskrom 按钮）
   - 用 USB-A 转 A 线连接 OP5P 的 USB 3.0 口到电脑
   - 上电

2. 确认设备：

```bash
lsusb | grep Rockchip
# 应显示: ID 2207:350a 或 2207:350b
```

3. 加载初始化固件并刷写 SPI：

```bash
# 加载 SPL 初始化固件
sudo rkdeveloptool db build/sources/rkbin/rk35/rk3588_spl_loader_v1.16.113.bin

# 擦除 SPI flash 前 2MB
sudo rkdeveloptool spi_erase 0 0x200000

# 写入 SPI 镜像
sudo rkdeveloptool spi_write build/sources/u-boot/u-boot-rockchip-spi.bin

# 重启
sudo rkdeveloptool rd 0
```

### 写入 NVMe 镜像

Maskrom 模式下不支持直接写 NVMe。刷完 SPI 后有两种方式写入 NVMe：

**A. 从 SD 卡启动后写入（同方法一步骤 3）**

**B. 在 x86 编译机上用 USB 硬盘盒写入：**

```bash
zstd -d output/orangepi5-plus-nvme-YYYYMMDD.img.zst \
      -o /tmp/orangepi5-plus-nvme-YYYYMMDD.img
sudo dd if=/tmp/orangepi5-plus-nvme-YYYYMMDD.img of=/dev/sdX \
        bs=4M status=progress conv=fsync
```

## 验证 SPI flash

通过串口观察启动日志，应看到：

```
U-Boot TPL 2026.04 (May 25 2026 - ...)
...
U-Boot SPL 2026.04 ...
...
U-Boot 2026.04 ...

Model: Orange Pi 5 Plus
...
MMC:   mmc@fe2c0000: 0, mmc@fe2e0000: 1
Loading environment from MMC... OK
...
 scanning bus for devices... 1 NVMe devices found
...
```

看到 `1 NVMe devices found` 说明 SPI 和 NVMe 都正常。

## 故障排除

| 现象 | 原因 | 解决 |
|------|------|------|
| 串口无输出 | 波特率/接线 | 确认 1500000 baud，交换 TX/RX |
| 卡在 `DDR init` | SPI 无有效镜像 | 重新刷写 SPI |
| `No NVMe devices` | NVMe 未插好/不兼容 | 检查 M.2 连接 |
| `Unrecognized filesystem` | GPT 损坏 | 重新 dd 写入 |
| `Can't find extlinux.conf` | boot 分区错误 | 检查 FAT32，dtbs/ 子目录 |
| U-Boot 启动但内核崩溃 | kernel/dtb 版本不匹配 | 使用同一版本的内核和 dtb |
| Maskrom 无法识别 | 驱动问题 | Windows 需驱动；Linux 检查 udev 规则 |

## 参考

- [Rockchip SPI 启动文档](https://opensource.rock-chips.com/wiki_Boot_option)
- [U-Boot Rockchip 支持](https://docs.u-boot.org/en/latest/board/rockchip/rockchip.html)
- [rkdeveloptool](https://github.com/rockchip-linux/rkdeveloptool)
