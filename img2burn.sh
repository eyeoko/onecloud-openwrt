#!/bin/bash
# 目标：仅使用当前目录下的文件，生成 burn.img.xz 烧录包。

# --- 0. 环境和文件检查 ---
#下载AmlImg
echo "下载AmlImg..."
wget -q -nc https://github.com/eyeoko/onecloud-openwrt/raw/refs/heads/main/AmlImg
# 确保 AmlImg 具有执行权限
chmod +x AmlImg 2>/dev/null
#解压安装镜像
gzip -dk ./*.img.gz

# --- 插入时间戳变量，用于输出文件名 ---
# 获取当前时间戳，格式为 YYYYMMDDHHMMSS
TIMESTAMP=$(date +%Y%m%d%H%M%S)
# ------------------------------------

# 固定最终输出文件名
# *** 修改此处：将时间戳加入文件名中 ***
BURN_IMG_NAME="burn-${TIMESTAMP}.img"
# ------------------------------------
BOOT_IMG_NAME="openwrt.img"
BOOT_MNT="xd"
ROOTFS_MNT="img"

# 查找 OpenWrt 基础镜像（排除 uboot.img 和 openwrt.img）
# 确保在当前目录下只存在一个待处理的 OpenWrt 镜像文件
DISK_IMG_LIST=$(ls -1 *.img 2>/dev/null | grep -v 'uboot.img' | grep -v "${BOOT_IMG_NAME}")
DISK_IMG=$(echo "$DISK_IMG_LIST" | head -n 1)

if [ -z "$DISK_IMG" ]; then
    echo "Error: 未找到 OpenWrt 基础镜像文件 (*.img)。请确保已解压 *.img.gz 文件。"
    exit 1
fi

echo "使用基础镜像文件: $DISK_IMG"

# --- 1. 准备目录和基础文件 ---
mkdir -p burn "${BOOT_MNT}" "${ROOTFS_MNT}"

# 下载 uboot.img (使用 -nc 避免重复下载)
echo "正在下载 uboot.img..."
wget -q -nc https://github.com/eyeoko/onecloud-openwrt/raw/refs/heads/main/uboot.img

# 解包 uboot.img 并解压所有 .gz 文件
./AmlImg unpack ./uboot.img burn/


# --- 2. 设置 Loop 设备 ---

# 设置 loop 设备并获取设备名 (如 /dev/loop0)
# 注意：使用 partscan 必须使用 sudo
loop=$(sudo losetup --find --show --partscan "$DISK_IMG" | sed 's/[^[:print:]]//g')

if [ -z "$loop" ]; then
  echo "Error: 无法设置 Loop 设备，请检查分区表是否正确或权限是否足够。"
  exit 1
fi
echo "已设置 Loop 设备: $loop"

# --- 3. 准备和复制文件系统 ---

# 创建新的 boot 镜像文件
dd if=/dev/zero of="${BOOT_IMG_NAME}" bs=1M count=600 status=progress
mkfs.ext4 "${BOOT_IMG_NAME}" || { echo "Error: 格式化 boot 镜像失败。"; exit 1; }

# 挂载分区并复制文件
sudo mount "${BOOT_IMG_NAME}" "${BOOT_MNT}" || { echo "Error: 挂载新的 boot 镜像失败。"; exit 1; }
sudo mount "${loop}p2" "${ROOTFS_MNT}" || { echo "Error: 挂载 rootfs 分区失败。"; exit 1; }

sudo cp -rp ${ROOTFS_MNT}/* "${BOOT_MNT}"
sudo sync

# --- 4. 清理挂载和创建稀疏镜像 ---

sudo umount "${BOOT_MNT}" || true
sudo umount "${ROOTFS_MNT}" || true

# *** 核心修复: 使用 $loop 变量访问分区 ***
# 转换 bootloader 分区 (loop设备p1) 为稀疏镜像
sudo img2simg "${loop}p1" burn/boot.simg || { echo "Error: 创建 boot.simg 失败。"; exit 1; }

# 转换新的 rootfs/boot 镜像 (openwrt.img) 为稀疏镜像
sudo img2simg "${BOOT_IMG_NAME}" burn/rootfs.simg || { echo "Error: 创建 rootfs.simg 失败。"; exit 1; }

# 清理 loop 设备和临时文件
sudo losetup -d "$loop" || true
sudo rm -f "${BOOT_IMG_NAME}"

# --- 5. 最终打包、校验和压缩 ---

printf "PARTITION:boot:sparse:boot.simg\nPARTITION:rootfs:sparse:rootfs.simg\n" >> burn/commands.txt

./AmlImg pack "${BURN_IMG_NAME}" burn/
sha256sum "${BURN_IMG_NAME}" > "${BURN_IMG_NAME}.sha"
xz -9 --threads=0 --compress "${BURN_IMG_NAME}"

# --- 6. 最终清理 ---
rm -rf burn "${BOOT_MNT}" "${ROOTFS_MNT}"
rm "${DISK_IMG}" 2>/dev/null
rm -f uboot.img AmlImg
# 最终输出文件名现在会包含时间戳，例如 burn-20251005104023.img.xz
echo "Script execution completed. Final file: ${BURN_IMG_NAME}.xz"
