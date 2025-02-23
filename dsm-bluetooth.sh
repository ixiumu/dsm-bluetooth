#!/bin/bash

set -e

# 参考
# https://github.com/kcsoft/synology-bluetooth
# https://blog.csdn.net/m0_72359111/article/details/142472320
# https://www.cnblogs.com/wanglouxiaozi/p/17832303.html

# 环境变量
# https://archive.synology.cn/download/ToolChain
LINUX_URL=${LINUX_URL:-"https://global.synologydownload.com/download/ToolChain/Synology%20NAS%20GPL%20Source/7.2-64570/armada37xx/linux-4.4.x.txz"}
TOOLCHAIN_URL=${TOOLCHAIN_URL:-"https://global.synologydownload.com/download/ToolChain/toolchain/7.2-72746/Marvell%20Armada%2037xx%20Linux%204.4.302/armada37xx-gcc1220_glibc236_armv8-GPL.txz"}
MODEL=${MODEL:-"armada37xx"}
ENABLE_RTL8761B_PATCH=${ENABLE_RTL8761B_PATCH:-"false"}
ARCH=${ARCH:-"arm64"}

# 下载依赖
apt-get update
apt-get install git fakeroot build-essential ncurses-dev xz-utils libssl-dev bc flex libelf-dev bison wget cifs-utils python2 python-pip python3

# 下载 Synology linux Source 和 toolchain
# Synology linux Source
if [ ! -f linux.txz ];then
  wget -O linux.txz $LINUX_URL
fi
# toolchain
if [ ! -f $MODEL.txz ];then
  wget -O $MODEL.txz $TOOLCHAIN_URL
fi

# 创建目录
if [ -d bluetooth-build ];then
  rm -rf bluetooth-build
fi
mkdir -p bluetooth-build bluetooth-build/linux bluetooth-build/$MODEL-gcc bluetooth-build/modules

# 解压文件
tar xJf $MODEL.txz --strip-components 1 -C bluetooth-build/$MODEL-gcc
tar xJf linux.txz --strip-components 1 -C bluetooth-build/linux

# 编译内核驱动
# 进入内核目录
cd bluetooth-build/linux

# 下载蓝牙补丁
if [ $ENABLE_RTL8761B_PATCH == "true" ];then
  mkdir -p ../firmware/rtl_bt
  wget -O drivers/bluetooth/btrtl.c https://raw.githubusercontent.com/torvalds/linux/refs/tags/v4.9/drivers/bluetooth/btrtl.c
  wget -O drivers/bluetooth/btrtl.h https://raw.githubusercontent.com/torvalds/linux/refs/tags/v4.9/drivers/bluetooth/btrtl.h
  wget -O ../firmware/rtl_bt/rtl8761b_config.bin https://raw.githubusercontent.com/Realtek-OpenSource/android_hardware_realtek/rtk1395/bt/rtkbt/Firmware/BT/rtl8761b_config
  wget -O ../firmware/rtl_bt/rtl8761b_fw.bin https://raw.githubusercontent.com/Realtek-OpenSource/android_hardware_realtek/rtk1395/bt/rtkbt/Firmware/BT/rtl8761b_fw
  patch -p0 < ../../patch/rtl8761b.patch
fi

# 复制群晖内核配置文件
cp synoconfigs/$MODEL .config

# 修改群晖内核版本
sed -i 's/EXTRAVERSION =/EXTRAVERSION = +/g' Makefile

# 配置蓝牙
cat >> .config << EOF
CONFIG_BT=m
CONFIG_BT_BREDR=y
# CONFIG_BT_RFCOMM is not set
# CONFIG_BT_BNEP is not set
# CONFIG_BT_HIDP is not set
CONFIG_BT_HS=y
CONFIG_BT_LE=y
# CONFIG_BT_SELFTEST is not set
# CONFIG_BT_DEBUGFS is not set
CONFIG_BT_INTEL=m
CONFIG_BT_BCM=m
CONFIG_BT_RTL=m
CONFIG_BT_HCIBTUSB=m
CONFIG_BT_HCIBTUSB_BCM=y
CONFIG_BT_HCIBTUSB_RTL=y
# CONFIG_BT_HCIUART is not set
# CONFIG_BT_HCIBCM203X is not set
# CONFIG_BT_HCIBFUSB is not set
# CONFIG_BT_HCIVHCI is not set
# CONFIG_BT_MRVL is not set
# CONFIG_BT_ATH3K is not set
EOF

# 编译
CROSS_NAME=$(find ../$MODEL-gcc/bin -type f -name *-gcc | xargs -i basename {} |awk -F "gcc" '{print $1}')
make -j $(nproc) CROSS_COMPILE=../$MODEL-gcc/bin/$CROSS_NAME prepare
make -j $(nproc) CROSS_COMPILE=../$MODEL-gcc/bin/$CROSS_NAME scripts
make -j $(nproc) CROSS_COMPILE=../$MODEL-gcc/bin/$CROSS_NAME -C . M=net/bluetooth/ modules
make -j $(nproc) CROSS_COMPILE=../$MODEL-gcc/bin/$CROSS_NAME -C . M=drivers/bluetooth modules

# 复制编译文件
cp net/bluetooth/*.ko ../modules/
cp drivers/bluetooth/*.ko ../modules/

# 创建bluetooth-modules.sh文件
cat >> ../bluetooth-modules.sh<< EOF
#!/bin/sh
case \$1 in
  start)
    insmod /lib/modules/bluetooth.ko > /dev/null 2>&1
    insmod /lib/modules/btintel.ko > /dev/null 2>&1
    insmod /lib/modules/btrtl.ko > /dev/null 2>&1
    insmod /lib/modules/btbcm.ko > /dev/null 2>&1
    insmod /lib/modules/btusb.ko > /dev/null 2>&1
    ;;
  stop)
    rmmod btusb.ko > /dev/null 2>&1
    rmmod btbcm.ko > /dev/null 2>&1
    rmmod btrtl.ko > /dev/null 2>&1
    rmmod btintel.ko > /dev/null 2>&1
    rmmod bluetooth.ko > /dev/null 2>&1
    ;;
  *)
    exit 0
    ;;
esac
EOF

# 创建install.sh文件
cat >> ../install.sh<< EOF
#!/bin/sh

cp -rf modules/* /lib/modules
chmod 755 /lib/modules/bluetooth.ko
chmod 755 /lib/modules/btintel.ko
chmod 755 /lib/modules/btrtl.ko
chmod 755 /lib/modules/btbcm.ko
chmod 755 /lib/modules/btusb.ko
cp -f bluetooth-modules.sh /usr/local/etc/rc.d
chmod 755 /usr/local/etc/rc.d/bluetooth-modules.sh
EOF

[[ $ENABLE_RTL8761B_PATCH == "true" ]] && cat >> ../install.sh<< EOF
cp -rf firmware/rtl_bt /lib/firmware
chmod -R 644 /lib/firmware/rtl_bt
EOF

# 创建uninstall.sh文件
cat >> ../uninstall.sh<< EOF
#!/bin/sh

/usr/local/etc/rc.d/bluetooth-modules.sh stop
rm -f /lib/modules/btusb.ko
rm -f /lib/modules/btbcm.ko
rm -f /lib/modules/btrtl.ko
rm -f /lib/modules/btintel.ko
rm -f /lib/modules/bluetooth.ko
rm -f /usr/local/etc/rc.d/bluetooth-modules.sh
EOF

[[ $ENABLE_RTL8761B_PATCH == "true" ]] && cat >> ../uninstall.sh<< EOF
rm -rf /lib/firmware/rtl_bt
EOF

echo "ok"
