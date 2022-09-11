#!/usr/bin/env bash

die() {
    echo $*
    exit 1
}

set -e

DEV=$1

echo -n "zpool name: "
read POOL

echo

echo -n "hostname: "
read HOST

echo

echo -n "zfs password: "
read -s POOL_PW
echo

echo -n "      repeat: "
read -s POOL_PW2
echo

echo

echo -n "root password: "
read -s ROOT_PW
echo

echo -n "       repeat: "
read -s ROOT_PW2
echo

if [ $POOL_PW != $POOL_PW2 ]; then
    die "zfs password missmatch"
fi

if [ $ROOT_PW != $ROOT_PW2 ]; then
    die "root password missmatch"
fi

wipefs -a ${DEV}
#sgdisk --zap-all ${DEV}

sed -e 's/\s*\([-+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk ${DEV}
  g       # create gpt table
  n       # new partition
  1       # partition nr 1
          # start at first sector
  -1024M  # leave 1G space for /boot/efi
  n       # new partition
  2       # partition nr 2
          # start at first free sector
          # take all empty space (1024MiB)
  t       # set partition type
  2       # parition nr 2
  1       # set to EFI type
  p       # print partition table
  w       # write partition table to disk
  q       # quit
EOF

#wipefs -a ${DEV}1
#wipefs -a ${DEV}2
sync
mkfs.vfat -F32 ${DEV}2

zpool create -f -o ashift=12 -o autotrim=on \
       -O acltype=posixacl -O canmount=off -O compression=lz4 \
       -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
       -O mountpoint=/ -R /mnt \
       -O encryption=aes-256-gcm -O keylocation=prompt -O keyformat=passphrase \
       ${POOL} ${DEV}1 << EOF
${POOL_PW}
${POOL_PW}
EOF

zfs set keylocation=file:///etc/zfs/${POOL}.key ${POOL}
zfs create -o canmount=off -o mountpoint=none   ${POOL}/ROOT
zfs create -o canmount=noauto -o mountpoint=/   ${POOL}/ROOT/void
zfs mount                                       ${POOL}/ROOT/void

zfs create                                      ${POOL}/home
zfs create -o mountpoint=/root                  ${POOL}/home/root
zfs create -o canmount=off                      ${POOL}/var
zfs create -o canmount=off                      ${POOL}/var/lib
zfs create -o com.sun:auto-snapshot=false       ${POOL}/var/lib/libvirt
zfs create -o com.sun:auto-snapshot=false       ${POOL}/var/lib/lxc
zfs create -o com.sun:auto-snapshot=false       ${POOL}/var/lib/docker
zfs create                                      ${POOL}/var/lib/AccountsService
zfs create                                      ${POOL}/var/lib/NetworkManager
zfs create                                      ${POOL}/var/log
zfs create                                      ${POOL}/var/db
zfs create                                      ${POOL}/var/spool
zfs create -o com.sun:auto-snapshot=false       ${POOL}/var/cache
zfs create -o com.sun:auto-snapshot=false       ${POOL}/var/tmp
zfs create -o canmount=off                      ${POOL}/usr
zfs create                                      ${POOL}/usr/local
chmod 700  /mnt/root
chmod 1777 /mnt/var/tmp

for i in dev proc sys; do mkdir -p /mnt/$i; mount --rbind /$i /mnt/$i; done
echo y | XBPS_ARCH=x86_64 xbps-install -S -R https://mirrors.tuna.tsinghua.edu.cn/voidlinux/current -r /mnt | grep '60:ae:0c:d6:f0:95:17:80:bc:93:46:7a:89:af:a3:2d' >/dev/null || die "invalid repo fingerprint"

XBPS_ARCH=x86_64 xbps-install -Sy -R https://mirrors.tuna.tsinghua.edu.cn/voidlinux/current -r /mnt base-system zfs neovim efibootmgr refind zfsbootmenu gptfdisk tmux htop neofetch git wget curl void-repo-nonfree opendoas fish-shell ntfs-3g xdg-user-dirs

#cp -v root_on_zfs_post_install.sh /mnt/

chroot /mnt /usr/bin/env -i         \
       DEV=${DEV}                   \
       HOST=${HOST}                 \
       POOL=${POOL}                 \
       POOL_PW=${POOL_PW}           \
       ROOT_PW=${ROOT_PW}           \
       PS1='(void chroot) \u:\w\$ ' \
       /bin/bash --login << CHROOT
echo "${POOL_PW}" > /etc/zfs/${POOL}.key
chmod 0000 /etc/zfs/${POOL}.key

cat << EOF > /etc/hostname
${HOST}
EOF

cat << EOF >> /etc/resolv.conf
nameserver 10.0.1.254
EOF

cat << EOF >> /etc/rc.conf
KEYMAP="us"
TIMEZONE="Asia/Shanghai"
HARDWARECLOCK="UTC"
EOF

cat << EOF >> /etc/default/libc-locales
en_US.UTF-8 UTF-8
zh_CN.UTF-8 UTF-8
EOF
xbps-reconfigure -f glibc-locales

zpool set cachefile=/etc/zfs/${POOL}.cache ${POOL}
zpool set bootfs=${POOL}/ROOT/void ${POOL}

cat << EOF > /etc/dracut.conf.d/zol.conf
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
install_items+=" /etc/zfs/${POOL}.key "
EOF

xbps-reconfigure -f $(xbps-query linux | grep -oP 'linux\d+\.\d+')

zgenhostid

zfs set org.zfsbootmenu:commandline="spl_hostid=$(hostid) zfs.zfs_arc_min=268435456 zfs.zfs_arc_max=536870912 ro quiet" ${POOL}/ROOT

cat << EOF >> /etc/fstab
UUID=$(blkid | grep ${DEV}2 | sed -En 's/.*? UUID="([0-9a-zA-Z\-]+)".*/\1/p') /boot/efi vfat defaults,noauto 0 0
EOF
mkdir -p /boot/efi
mount /boot/efi

refind-install
rm /boot/refind_linux.conf

sed -i 's/ManageImages: false/ManageImages: true/' /etc/zfsbootmenu/config.yaml
xbps-reconfigure -f zfsbootmenu

cat << EOF > /boot/efi/EFI/void/refind_linux.conf
"Boot default"  "zfsbootmenu:ROOT=${POOL} spl_hostid=$(hostid) zfs.zfs_arc_min=268435456 zfs.zfs_arc_max=536870912 timeout=0 ro quiet loglevel=5 nowatchdog"
"Boot to menu"  "zfsbootmenu:ROOT=${POOL} spl_hostid=$(hostid) zfs.zfs_arc_min=268435456 zfs.zfs_arc_max=536870912 timeout=-1 ro quiet loglevel=5 nowatchdog"
EOF

chsh -s /usr/bin/fish root
passwd << EOF
${ROOT_PW}
${ROOT_PW}
EOF

zfs create ${POOL}/home/sysops
useradd -G wheel,users -s /bin/bash sysops
cp -a /etc/skel/. /home/sysops
chsh -s /usr/bin/fish sysops
passwd sysops << EOF
sysops
sysops
EOF

cat << EOF > /etc/doas.conf
permit persist keepenv :wheel
EOF

cat << EOF >> /etc/rc.local
#ip link set dev enp34s0 up
#ip addr add 10.0.1.126/24 brd + dev enp34s0
#ip route add default via 10.0.1.253
EOF

cat << EOF > /etc/xbps.d/00-repository-main.conf
repository=https://mirrors.tuna.tsinghua.edu.cn/voidlinux/current
EOF
xbps-query -L

CHROOT

chown -R sysops:sysops /mnt/home/sysops

#umount -Rl /mnt
#zpool export ${POOL}
