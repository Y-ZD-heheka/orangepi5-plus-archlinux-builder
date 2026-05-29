# linux-op5p EFI 分区内核同步方案

## 问题

Orange Pi 5 Plus 的 U-Boot 从 `/efi/` 分区（vfat）加载内核，但 `linux-op5p` 包将内核安装到 `/boot/`（根分区），导致安装后重启仍使用旧内核。

## 解决方案

### 方案 A：.install 脚本（推荐）

在 PKGBUILD 同目录创建 `linux-op5p.install`：

```bash
post_install() {
    cp /boot/Image /efi/Image
    cp /boot/dtbs/rk3588-orangepi-5-plus.dtb /efi/rk3588-orangepi-5-plus.dtb
}

post_upgrade() {
    post_install
}

post_remove() {
    echo "Warning: /efi/Image and /efi/rk3588-orangepi-5-plus.dtb were NOT removed."
    echo "Remove manually if needed."
}
```

PKGBUILD 中添加：

```diff
 pkgname=linux-op5p
+install=linux-op5p.install
```

### 方案 B：pacman hook（通用，不依赖 PKGBUILD）

在目标机器 `/etc/pacman.d/hooks/linux-op5p-efi.hook`：

```ini
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = linux-op5p

[Action]
Description = Copying Linux kernel to EFI partition...
When = PostTransaction
Exec = /bin/sh -c 'cp /boot/Image /efi/Image && cp /boot/dtbs/rk3588-orangepi-5-plus.dtb /efi/rk3588-orangepi-5-plus.dtb'
```

可将此 hook 文件加入 PKGBUILD 的 `package()` 中安装到 `/etc/pacman.d/hooks/`。

### 首次手动同步（立即生效）

```bash
cp /boot/Image /efi/Image
cp /boot/dtbs/rk3588-orangepi-5-plus.dtb /efi/rk3588-orangepi-5-plus.dtb
sync
reboot
```
