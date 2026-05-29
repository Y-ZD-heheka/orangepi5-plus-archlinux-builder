# Orange Pi 5 Plus — 内核编译优化指南

> 基于当前系统配置：`7.1.0-rc3-bleedingedge-rockchip64`，Armbian bleedingedge 分支  
> 硬件：RK3588 (4×A55 + 4×A76) / 16GB RAM / NVMe SSD  
> 编译器：Clang 23 / GCC 15.2 (cross: aarch64-linux-gnu-gcc)

---

## 一、当前配置概要

### CPU/调度
| 选项 | 当前值 | 说明 |
|------|--------|------|
| PREEMPT | `PREEMPT` | 全抢占（适合桌面） |
| HZ | `250` | 适中，可提升至 1000 |
| 调度器 | EEVDF | Linux 6.6+ 默认 |
| cpufreq gov | `schedutil` | 默认ondemand，实际建议schedutil |
| EAS | ❌ 关闭 | `ENERGY_MODEL=n` |

### 内存
| 选项 | 当前值 |
|------|--------|
| PAGE_SIZE | 4KB |
| THP | `MADVISE` |
| ZSWAP | 开启 (zstd) |
| KSM | 开启 |
| SLUB_DEBUG | 开启 |
| CMA | 128MB |

### 调试
| 选项 | 当前值 | 影响 |
|------|--------|------|
| DEBUG_INFO (DWARF5) | 开启 | 内核体积 +30%，编译慢 |
| DEBUG_INFO_BTF | 开启 | 几十 MB BTF 数据 |
| DEBUG_FS | 开启 | 安全暴露 |
| FRAME_POINTER | 开启 | 约 1-3% 性能损失 |
| FUNCTION_TRACER | 开启 | 每个函数入口 NOP，I-cache 占用 |
| DYNAMIC_DEBUG | 开启 | pr_debug 表 ~1.5MB |
| SLUB_DEBUG | 开启 | slab 分配 ~2-5% 开销 |

### 冗余驱动
- XEN（虚拟机全套，RK3588 无需）
- 大量 USB/WiFi/BT 驱动模块（3370 个模块中大量无用）

---

## 二、推荐优化项 (按收益排序)

### P0 — 纯性能收益，无风险

```diff
# ---- 调试膨胀 ----
- CONFIG_DEBUG_INFO=y
- CONFIG_DEBUG_INFO_DWARF5=y
- CONFIG_DEBUG_INFO_BTF=y
- CONFIG_DEBUG_INFO_BTF_MODULES=y
- CONFIG_DEBUG_FS=y
- CONFIG_SLUB_DEBUG=y
- CONFIG_DYNAMIC_DEBUG=y
- CONFIG_FRAME_POINTER=y
- CONFIG_FUNCTION_TRACER=y
- CONFIG_FUNCTION_GRAPH_TRACER=y
- CONFIG_FTRACE_SYSCALLS=y
- CONFIG_TRACING=y

# ---- 内存 ----
- CONFIG_ZSWAP=y
- CONFIG_ZSWAP_DEFAULT_ON=y
- CONFIG_KSM=y

# ---- 编译器 ----
# 保持 CONFIG_LTO_CLANG_THIN=y（已开启）
# 保持 CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y（已开启）
```

### P1 — 需测试兼容性

```diff
# ---- 大页 ----
- CONFIG_ARM64_4K_PAGES=y
+ CONFIG_ARM64_64K_PAGES=y
# 收益：TLB 覆盖提升 16x，内存密集负载 5-15%
# 风险：需确认所有用户态程序兼容（Docker/OCI 镜像含 4K 页 ELF 不影响）

# ---- THP always ----
- CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
+ CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y
# 收益：大页对更多应用透明生效

# ---- HZ 提升 ----
- CONFIG_HZ_250=y
- CONFIG_HZ=250
+ CONFIG_HZ_1000=y
+ CONFIG_HZ=1000
# 收益：桌面/交互响应更平滑
```

### P2 — 按需权衡

```diff
# ---- EAS (能耗调度) ----
+ CONFIG_ENERGY_MODEL=y
# 需要 DT 中有 dynamic-power-coefficient，有则调度器会按功耗主动选核

# ---- PREEMPT 模式 ----
# 当前: PREEMPT (全抢占) —— 适合桌面低延时
# 若主要跑编译/服务器: 
- CONFIG_PREEMPT=y
+ CONFIG_PREEMPT_VOLUNTARY=y  # 减少抢占开销

# ---- XEN 虚拟化 ----
- CONFIG_XEN=y
- CONFIG_XEN_DOM0=y
- CONFIG_PARAVIRT=y
- CONFIG_PARAVIRT_TIME_ACCOUNTING=y
# (所有 CONFIG_XEN_* 均关)
```

---

## 三、交叉编译方法

### 方式 A：使用 Armbian 构建系统（推荐）

```bash
# 1. 克隆你的 Armbian 构建仓库
git clone https://gitee.com/yzd990612/build.git
cd build

# 2. 创建 kernel 配置补丁
# 将优化后的 .config 放入:
#   config/kernel/linux-rockchip64-edge.config
# 或在编译菜单中选择后保存

# 3. 一键编译内核（自动处理 DTBs、initrd、deb 打包）
# 交叉编译（在 x86 上）:
./compile.sh \
  BOARD=orangepi5-plus \
  BRANCH=bleedingedge \
  BUILD_DESKTOP=no \
  KERNEL_CONFIGURE=yes \
  KERNEL_ONLY=yes \
  COMPRESS_OUTPUTIMAGE=no

# 或使用你已配置好的跨编译器:
./compile.sh \
  BOARD=orangepi5-plus \
  BRANCH=bleedingedge \
  KERNEL_ONLY=yes \
  EXTERNAL_NEW=prebuilt \
  TOOLCHAIN=prebuilt

# 4. 输出 deb 包位置:
#   output/debs/linux-image-*.deb
#   output/debs/linux-dtb-*.deb
#   output/debs/linux-headers-*.deb

# 5. 在 Orange Pi 5 Plus 上安装:
sudo dpkg -i linux-image-*.deb linux-dtb-*.deb linux-headers-*.deb
sudo reboot
```

### 方式 B：手动交叉编译

#### 前提

当前主机（本机即为 aarch64，也能直接 native 编译；以下流程在 x86 主机上同样适用）：

```bash
# 安装交叉编译器（Debian/Ubuntu x86-64）
sudo apt install gcc-aarch64-linux-gnu

# 已安装版本:
aarch64-linux-gnu-gcc (Debian 15.2.0-17) 15.2.0
```

#### 步骤

```bash
# 1. 获取内核源码
# Armbian 的 rockchip64 edge 内核基于:
git clone https://github.com/armbian/linux -b v7.1-rc3-rockchip64 ~/linux-rockchip
cd ~/linux-rockchip

# 2. 获取当前系统的 .config（作为基础）
# 保存本机配置:
zcat /proc/config.gz > .config

# 或从 Armbian 构建系统提取:
#   config/kernel/linux-rockchip64-edge.config

# 3. 配置内核 (应用上述优化)
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig

# 4. 编译
make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  -j$(nproc) \
  Image modules dtbs

# 5. 编译模块
make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  INSTALL_MOD_PATH=/tmp/kernel-modules \
  modules_install

# 6. 制作 .deb 包
make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  bindeb-pkg

# 会在上级目录生成:
#   linux-image-*.deb
#   linux-headers-*.deb
#   linux-dtb-*.deb
#   linux-libc-dev-*.deb

# 7. 拷贝到 Orange Pi 上安装:
sudo dpkg -i linux-image-*.deb linux-dtb-*.deb linux-headers-*.deb
sudo reboot
```

### 方式 C：本机 Native 编译

既然本机已经是 aarch64，Native 编译更简单（但比交叉编译慢）：

```bash
# 获取源码
git clone https://github.com/armbian/linux -b v7.1-rc3-rockchip64
cd linux

# 使用当前配置
zcat /proc/config.gz > .config
make menuconfig   # 应用优化

# 编译（利用所有核心）
make -j$(nproc) Image modules dtbs
make -j$(nproc) bindeb-pkg
sudo dpkg -i ../linux-image-*.deb ../linux-dtb-*.deb ../linux-headers-*.deb
sudo reboot
```

---

## 四、重要注意事项

### 启动参数优化

在 `/boot/armbianEnv.txt` 中添加:

```
extraargs=clocksource=arch_sys_counter elevator=none
```

- `elevator=none` — NVMe 最适，绕过 IO 调度器直接下发
- `clocksource=arch_sys_counter` — 强制 ARM arch timer（默认已选）

### 安装后验证

```bash
# 检查正在运行的内核
uname -r

# 检查配置生效
cat /boot/config-$(uname -r) | grep -E "CONFIG_(HZ_|PAGE_SIZE|ENERGY_MODEL|PREEMPT|DEBUG_INFO|FRAME_POINTER)"

# 检查 DTB 版本
cat /boot/armbianEnv.txt

# 查看实际频率/调度
lscpu
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
```

### 关于 64K 页的注意事项

**需要验证的项目：**
1. Docker 容器 — Docker daemon 默认无问题，但 `--cgroup-parent` 等需要关注
2. 大型数据库 / Java JVM — 64K 页对大内存应用通常**利好**，JVM 可调 `-XX:+UseTransparentHugePages`
3. 若遇到问题，可回退到 4K 页

### 64K 页 + THP 黑盒测试

```bash
# 编译后检查
getconf PAGE_SIZE            # 应输出 65536
cat /sys/kernel/mm/transparent_hugepage/enabled  # 应输出 [always] madvise never

# 性能对比（示例）
# 编译内核时间对比:
time make -j$(nproc) bindeb-pkg
```

---

## 五、完整 config diff

```diff
--- .config-orig	2026-05-23
+++ .config-optimized	2026-05-23

 # ========== 编译器 ==========
 CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y	# 保持
 CONFIG_LTO_CLANG_THIN=y		# 保持

+# ========== 调试关闭 ==========
-# CONFIG_DEBUG_INFO is not set
-# CONFIG_DEBUG_INFO_DWARF5 is not set
-# CONFIG_DEBUG_INFO_BTF is not set
-# CONFIG_DEBUG_INFO_BTF_MODULES is not set
-# CONFIG_DEBUG_FS is not set
-# CONFIG_SLUB_DEBUG is not set
-# CONFIG_DYNAMIC_DEBUG is not set
-# CONFIG_FRAME_POINTER is not set

+# ========== 追踪关闭 ==========
-# CONFIG_FUNCTION_TRACER is not set
-# CONFIG_FUNCTION_GRAPH_TRACER is not set
-# CONFIG_FTRACE_SYSCALLS is not set
-# CONFIG_TRACING is not set

+# ========== 内存 ==========
 CONFIG_PAGE_SIZE_4KB=y
-# CONFIG_ARM64_16K_PAGES is not set	# 保持
-# CONFIG_ARM64_64K_PAGES is not set
+# CONFIG_ARM64_4K_PAGES is not set
-CONFIG_ARM64_64K_PAGES=y		# 换到 64K（可选）
-CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y	# 而非 MADVISE

 # KSM / ZSWAP 关闭
-# CONFIG_KSM is not set
-# CONFIG_ZSWAP is not set

+# ========== CPU / 调度 ==========
 CONFIG_HZ_1000=y
 CONFIG_HZ=1000
+CONFIG_ENERGY_MODEL=y

 # ========== 驱动瘦身 ==========
-# CONFIG_XEN is not set
-# CONFIG_XEN_DOM0 is not set

 # ========== 模块签名（可选）==========
 CONFIG_MODULE_SIG=n			# 保持关闭
```

---

## 六、模块瘦身 — 可以删除的模块

当前内核共 **3370 个模块**，以下对 Orange Pi 5 Plus 完全无用。

### 🗑️ 按分类可删除的模块组

| 分类 | 模块列表 | 数量 | 理由 |
|------|----------|------|------|
| **Xen 虚拟化** | `CONFIG_XEN_*` 全部 | ~30 | RK3588 非虚拟机 |
| **老旧网卡** | `CONFIG_BNXT`, `BNA`, `CXGB`, `ENIC`, `MLX*`, `QED`, `QLC*`, `BEFSRR`, `ACENIC`, `NET_VENDOR_MELLANOX/CHELSIO/CISCO/EMULEX/BROCADE/QLOGIC/INTEL/SOLARFLARE/HUAWEI/PENSANDO/NETRONOME` | ~50 | 企业级网卡，RK3588 用不到 |
| **老旧无线** | `ATH9K`, `ATH10K`, `B43`, `B43LEGACY`, `BRCMSMAC`, `IWLWIFI`, `IWLMVM`, `LIBERTAS`, `MWL8K`, `RTL8180/8187/8192*/8723*/8821*`, `RTW88` 系列, `MWIFIEX`, `MT7601U`, `MT76*`(不含 7921) | ~80 | RK3588 只有 PCIe WiFi（ath11k），其他的都用不到 |
| **蓝牙** | `BT_INTEL`, `BT_BCM`, `BT_RTL`, `BT_QCA`, `BT_MTK` 等 vendor 驱动 | ~15 | RK3588 蓝牙已由 `btusb` + `btrtl` 驱动 |
| **老旧 SCSI/RAID** | `SCSI_MPT2SAS`, `SCSI_MPT3SAS`, `SCSI_ISCSI_ATTRS`, `ISCSI_TCP`, `SCSI_LPFC`, `SCSI_QLA*` | ~15 | NVMe 专用，无需 SAS/FC |
| **MD/RAID/DM** | `MD_RAID0/1/10/456`, `DM_*` (保留 `DM_CRYPT` 和 `DM_VERITY` 按需) | ~30 | 单 NVMe，无软 RAID |
| **老旧协议** | `X25`, `LAPB`, `ATM`, `RDS`, `TIPC`, `PHONET`, `DECNET`, `IPX`, `APPLETALK` | ~10 | 已淘汰协议 |
| **DVB 电视** | `DVB_*` 全部 | ~120 | Orange Pi 无电视卡 |
| **老旧代码c** | `VIDEO_GO7007`, `VIDEO_PVRUSB2`, `VIDEO_EM28XX`, `VIDEO_CX88`, `VIDEO_BT848`, `VIDEO_SAA7134`, `VIDEO_CX18`, `VIDEO_IVTV` | ~15 | 老旧 USB 采集卡 |
| **电池/充电** | `BATTERY_*`, `CHARGER_*` 全部 | ~30 | 开发板无电池 |
| **触摸屏** | `TOUCHSCREEN_*` 全部 | ~50 | 开发板无触摸屏 |
| **USB 串口** | `USB_SERIAL_*`（保留 CP210X/CH340/FTDI/PL2303） | ~45 | 只需常用 USB 串口 |
| **老旧文件系统** | `JFS`, `GFS2`, `OCFS2`, `ZONEFS`, `ORANGEFS`, `ADFS`, `AFFS`, `HFS`, `HFSPLUS`, `BEFS`, `BFS`, `EFS`, `JFFS2`, `CRAMFS`, `MINIX`, `HPFS`, `NTFS3`(可选) | ~18 | 不用的老旧 FS |
| **网络隧道** | `PPP*`, `SLIP`, `L2TP`, `IPIP`, `GRE`, `SIT` | ~15 | 按需保留 `WIREGUARD`/`VXLAN`/`GENEVE` |
| **输入设备** | `JOYSTICK_*`（部分） | ~5 | 除非你接游戏手柄 |
| **看门狗传感器** | `SENSORS_*` 中大量 X86 专用型号 | ~40 | ARM 开发板不适合 |
| **硬件监控** | `F71808E`, `IT87`, `NCT6775` 等 Super I/O | ~10 | x86 专用硬件监控 |
| **USB gadget** | `USB_OTG_FSM`, `USB_F_*`, `USB_CONFIGFS_*` | ~20 | 除非用作 USB gadget |
| **全部模块总数** | — | **~580** | 可安全移除 |

### 💡 建议保留的关键模块

```
# 网络（当前已加载的）
CONFIG_ATH11K=m               # PCIe WiFi（Orange Pi 5 Plus 内置）
CONFIG_R8169=m                 # Realtek 2.5GbE
CONFIG_BT=m, CONFIG_BTUSB=m    # 蓝牙
CONFIG_CFG80211=m, MAC80211=m  # WiFi 框架

# 图形
CONFIG_ROCKCHIPDRM=y           # DRM
CONFIG_DRM_PANTHOR=m           # Mali-G610 GPU
CONFIG_HANTRO_VPU=m            # 视频编码
CONFIG_ROCKCHIP_RGA=m           # 图形加速
CONFIG_ROCKCHIP_VDEC=m         # 视频解码

# 音频
CONFIG_SND_SOC_ROCKCHIP_I2S=y
CONFIG_SND_SOC_ES8328=m        # 板载音频 codec
CONFIG_SND_USB_AUDIO=m         # USB 音频

# 存储
CONFIG_BLK_DEV_NVME=y          # NVMe 内置
CONFIG_BTRFS_FS=m, XFS_FS=m, EXT4_FS=y  # 常用 FS
CONFIG_F2FS_FS=m               # 可选

# 网络功能（如果做路由器/NAS）
CONFIG_NETFILTER=m              # 防火墙
CONFIG_NF_TABLES=m              # nftables
CONFIG_WIREGUARD=m              # VPN
CONFIG_BRIDGE=m                 # 网桥
CONFIG_OPENVSWITCH=m            # 可选
```

### 🔧 可以添加的模块（当前未开启）

| 选项 | 说明 | 推荐场景 |
|------|------|----------|
| `CONFIG_ENERGY_MODEL=y` | EAS 能耗调度 | 开启后调度器感知功耗 |
| `CONFIG_PREEMPT_DYNAMIC=y` | 运行时切换 PREEMPT 模式 | 调试/调优用 |
| `CONFIG_ROCKCHIP_DMC` | 动态内存频率调节 | 省电（当前可能已由 firmware 控制） |
| `CONFIG_DEVFREQ_ROCKCHIP` | Rockchip 动态频率调节 | 配合 DMC |
| `CONFIG_USB_SERIAL_CP210X` (若已关) | USB 串口 | 开发调试 |
| `CONFIG_USB_SERIAL_CH341` (若已关) | USB 串口 | 开发调试 |
| `CONFIG_USB_SERIAL_FTDI_SIO` (若已关) | USB 串口 | 开发调试 |
| `CONFIG_DRM_PANEL_SIMPLE` | 简单 MIPI/EDP 屏幕 | 外接屏幕 |
| `CONFIG_I2C_CHARDEV` | /dev/i2c-N 接口 | 开发调试 |

---

## 附录：常用命令速查

| 用途 | 命令 |
|------|------|
| 查看当前 config | `zcat /proc/config.gz` |
| 查看内核版本 | `uname -r` |
| 查看 CPU 容量 | `cat /sys/devices/system/cpu/cpu*/cpu_capacity` |
| 查看 cpufreq 策略 | `cpupower frequency-info` |
| 查看当前 IO 调度器 | `cat /sys/block/nvme0n1/queue/scheduler` |
| 查看 THP 状态 | `cat /sys/kernel/mm/transparent_hugepage/enabled` |
| 查看页大小 | `getconf PAGE_SIZE` |
| 查看系统负载 | `htop` / `btm` / `s-tui` |
