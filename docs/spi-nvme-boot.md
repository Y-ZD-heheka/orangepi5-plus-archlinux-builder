# Orange Pi 5 Plus: SPI Flash + NVMe Boot

## 为什么用 SPI + NVMe？

Orange Pi 5 Plus 的 BootROM **不支持从 PCIe/NVMe 直接启动**。启动流程是：

```
BootROM → SPI Flash (TPL+SPL+BL31+U-Boot) → NVMe (extlinux → kernel + rootfs)
```

这样做的优势：

- **NVMe 速度** — 比 SD 卡快 5-10 倍，根文件系统和内核加载极快
- **SPI 只写一次** — U-Boot 刷入 SPI 后不再需要 SD 卡，系统完全从 NVMe 启动
- **启动更快** — SPI 读取比 SD 卡初始化快得多

## 前提条件

- Orange Pi 5 Plus 主板
- 32MB SPI NOR flash（OP5P 板载，型号通常为 XM25QH256C 或 GD25B256E）
- NVMe SSD（任意 M.2 M-key 2230/2242/2280）
- USB 转 TTL 串口调试线（关注：3.3V 电平，使用 ttyS2）
- **可选**：USB-A 转 A 线（用于 Maskrom 模式刷写 SPI）

### 构建产物

执行 `./build.sh --target nvme` 后，在 `output/` 目录下得到：

| 文件 | 用途 |
|------|------|
| `orangepi5-plus-nvme-YYYYMMDD.img` | NVMe 磁盘镜像（GPT + FAT32 boot + XFS root） |
| `build/sources/u-boot/u-boot-rockchip-spi.bin` | SPI flash 镜像（~1.6MB，烧录到 SPI NOR） |
| `build/sources/u-boot/u-boot-rockchip.bin` | 完整镜像（含 SPI 内容，用于 SD 卡启动） |

## 方法一：通过 SD 卡首次启动刷写 SPI（推荐）

这是最简单的方案，不需要额外的硬件或工具。

### 步骤 1：准备 SD 卡

用 `--target sd` 构建含 U-Boot 的 SD 卡镜像：

```bash
./build.sh --target sd
```

或者直接使用 U-Boot 构建产物制作最小启动卡：

```bash
# 准备一张 FAT32 SD 卡
BOOT_SD=/dev/sdX   # 替换为你的 SD 卡设备

# 写入 U-Boot（跳过 GPT，BootROM 从 LBA-64 读取）
sudo dd if=build/sources/u-boot/u-boot-rockchip.bin of=$BOOT_SD bs=512 seek=64 conv=notrunc

# 写入 extlinux.conf、kernel 和 dtb（Fat32 分区）
sudo mkfs.vfat ${BOOT_SD}1 -n ALARMBOOT
sudo mount ${BOOT_SD}1 /mnt
sudo mkdir /mnt/extlinux
sudo bash -c 'cat > /mnt/extlinux/extlinux.conf << EXTLINUX
label Arch Linux ARM
    linux /Image
    fdt /rk3588-orangepi-5-plus.dtb
    append console=ttyS2,1500000n8 earlycon root=UUID=ROOTUUID rw rootwait
EXTLINUX'
sudo cp build/kernel/arch/arm64/boot/Image /mnt/
sudo cp build/kernel/arch/arm64/boot/dts/rockchip/rk3588-orangepi-5-plus.dtb /mnt/
sudo umount /mnt
```

### 步骤 2：从 SD 卡启动，刷写 SPI，写入 NVMe

1. 将 NVMe SSD 通过 M.2 M-key 插槽连接到 OP5P
2. 将 SD 卡插入 OP5P 的 SD 卡槽
3. 连接串口调试线（ttyS2, 1500000 baud）
4. 上电，在 U-Boot 命令行按任意键中断启动

```bash
# 在 U-Boot 命令行中：

# 检查 SPI flash
=> sf probe

# 确认 SPI flash 型号（应为 XM25QH256C 或兼容型号，32MB）
=> sf info

# 将 U-Boot 从 SD 卡加载到内存
=> load mmc 1:1 $kernel_addr_r u-boot-rockchip-spi.bin

# 如果 SD 卡上没有这个文件，可以用 tftp 或 usb 传输
# => tftp $kernel_addr_r u-boot-rockchip-spi.bin

# 擦除 SPI flash（32MB 全部擦除）
=> sf erase 0 0x200000

# 写入 U-Boot 到 SPI flash（从偏移 0 开始）
=> sf write $kernel_addr_r 0 0x180000

# 验证写入
=> sf read $loadaddr 0 0x180000
=> cmp.b $kernel_addr_r $loadaddr 0x180000
# 如果返回 "Total of 1572864 byte(s) were the same"，说明写入正确

# 接下来写入 NVMe 镜像
# 方法 A：通过 USB 从电脑传输
=> usb start
=> load usb 0:1 $kernel_addr_r orangepi5-plus-nvme-YYYYMMDD.img
# 写入 NVMe
=> nvme scan
=> nvme write $kernel_addr_r 0 0x100000   # 写入 512MB boot 分区

# 方法 B：直接在 Linux 中写入（更简单，推荐）
=> boot
```

### 步骤 3：在 Linux 中写入 NVMe 镜像

启动到 SD 卡上的 Linux 后（或者任何 Linux 环境），将 NVMe 镜像写入 SSD：

```bash
# 确认 NVMe 设备
lsblk | grep nvme

# 写入镜像
sudo dd if=output/orangepi5-plus-nvme-YYYYMMDD.img of=/dev/nvme0n1 \
        bs=4M status=progress conv=fsync

# 验证分区
sudo sfdisk -l /dev/nvme0n1
```

### 步骤 4：从 NVMe 启动

1. 断电
2. 移除 SD 卡
3. 上电

BootROM 检测到 SPI flash 中有有效镜像 → 加载 U-Boot → U-Boot 从 NVMe 读取 extlinux.conf → 加载 kernel + rootfs。

## 方法二：通过 Maskrom 模式刷写 SPI（无 SD 卡）

如果手上没有 SD 卡，可以通过 Maskrom 模式直接刷写 SPI flash。

### 前提

- USB-A 转 A 线（公对公）
- 安装 `rkdeveloptool`：

```bash
# Arch Linux
sudo pacman -S rkdeveloptool

# 从源码编译
git clone https://github.com/rockchip-linux/rkdeveloptool
cd rkdeveloptool
autoreconf -i
./configure
make
sudo make install
```

### 步骤

1. 让 OP5P 进入 Maskrom 模式：
   - 断开电源
   - 短接主板上的 **Maskrom 触点**（靠近 USB-C 口的两个测试点，或按住板载按钮——取决于硬件版本）
   - 用 USB-A 转 A 线将 OP5P 的 USB 3.0 口连接到电脑
   - 上电

2. 确认设备已识别：

```bash
lsusb | grep Rockchip
# 应该看到: ID 2207:350a Rockchip
```

3. 下载并加载 RK3588 初始化固件：

```bash
# 下载 rk3588_spl_loader_v1.15.bin（从 rkbin 获取）
rkdeveloptool db rkbin/rk35/rk3588_spl_loader_v1.15.bin
```

4. 刷写 SPI flash：

```bash
# 写入 U-Boot SPI 镜像（先清除）
rkdeveloptool spi_erase 0 0x200000

# 写入
rkdeveloptool spi_write u-boot-rockchip-spi.bin
```

5. 重启：

```bash
rkdeveloptool rd
```

## 验证 SPI flash 已正确写入

通过串口观察启动日志：

```
U-Boot TPL 2026.04 (May 25 2026 - ...)
...
U-Boot SPL 2026.04 (May 25 2026 - ...)
...
U-Boot 2026.04 (May 25 2026 - ...)

Model: Orange Pi 5 Plus
...
MMC:   mmc@fe2c0000: 0, mmc@fe2e0000: 1
Loading environment from MMC... OK
...
 scanning bus for devices... 1 NVMe devices found
...
 scanning bus for storage devices... 0:0 (NVMe) 
** Unrecognized filesystem type **
...

=> nvme scan
Device 0: Vendor 0x.... Rev .... Serial....
            .... MB
```

如果看到 `NVMe devices found` 和正确的分区信息，说明一切正常。

## 故障排除

| 现象 | 原因 | 解决 |
|------|------|------|
| 串口无输出 | 波特率错误 / 接线反了 | 确认 1500000 baud，交换 TX/RX |
| 卡在 `DDR init` | SPI flash 中无有效镜像 | 重新刷写 SPI；或检查 Maskrom 模式 |
| `No NVMe devices found` | NVMe 未插好 / 不兼容 | 检查 M.2 连接，尝试其他 SSD |
| `Unrecognized filesystem` | GPT 分区表损坏 | 重新 `dd` 写入 NVMe 镜像 |
| `Can't find extlinux.conf` | boot 分区未正确写入 | 检查 FAT32 分区内容 |
| U-Boot 启动但内核崩溃 | kernel 与 dtb 不匹配 | 使用同一版本的内核和 dtb |

## 参考

- [Rockchip SPI 启动文档](https://opensource.rock-chips.com/wiki_Boot_option)
- [U-Boot Rockchip 支持](https://docs.u-boot.org/en/latest/board/rockchip/rockchip.html)
- [Orange Pi 5 Plus 原理图](http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/details/Orange-Pi-5-plus.html)
- [rkdeveloptool](https://github.com/rockchip-linux/rkdeveloptool)
