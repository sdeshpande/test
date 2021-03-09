#!/bin/bash
# WARNING: this script will destroy data on the selected disk.
# This script can be run by executing the following:
#   curl -sL https://git.io/vNxbN | bash
pacman -Sy dialog --noconfirm
set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

### Get infomation from user ###
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(dialog --stdout --inputbox "Enter admin username" 0 0) || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(dialog --stdout --passwordbox "Enter admin password" 0 0) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(dialog --stdout --passwordbox "Enter admin password again" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1
clear

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

timedatectl set-ntp true

### Setup the disk and partitions ###
swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
swap_end=$(( $swap_size + 129 + 1 ))MiB

parted --script "${device}" -- mklabel gpt \
  mkpart ESP fat32 1Mib 129MiB \
  set 1 boot on \
  mkpart primary linux-swap 129MiB ${swap_end} \
  mkpart primary ext4 ${swap_end} 100%

# Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1
# but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
part_swap="$(ls ${device}* | grep -E "^${device}p?2$")"
part_root="$(ls ${device}* | grep -E "^${device}p?3$")"

wipefs "${part_boot}"
wipefs "${part_swap}"
wipefs "${part_root}"

mkfs.vfat -F32 "${part_boot}"
mkswap "${part_swap}"
mkfs.ext4 "${part_root}"

swapon "${part_swap}"
mount "${part_root}" /mnt
mkdir /mnt/boot
mount "${part_boot}" /mnt/boot

# ### Install and configure the basic system ###

pacstrap /mnt base base-devel
genfstab -t PARTUUID /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<- EOF
ln -s /usr/share/zoneinfo/America/New_York > /etc/localtime
hwclock –systohc –utc
sed -e 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' -i /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
export LANG=en_US.UTF-8
EOF

echo "${hostname}" > /mnt/etc/hostname

if [ -d /sys/firmware/efi/efivars/ ]; then #install systemd-boot bootloader
	arch-chroot /mnt bootctl install 
	cat <<EOF > /mnt/boot/loader/loader.conf
default	arch
EOF 

pacstrap /mnt intel-ucode

cat <<EOF > /mnt/boot/loader/entries/arch.conf
title    Arch Linux
linux    /vmlinuz-linux
initrd   /intel-ucode.img
initrd   /initramfs-linux.img
options  root=PARTUUID=$(blkid -s PARTUUID -o value "$part_root") rw
EOF

else #install grub
  echo "install grub"

fi

echo "root:$password" | arch-chroot /mnt chpasswd --root
arch-chroot /mnt useradd -mU -s /bin/bash -G wheel,uucp,video,audio,storage,games,input "$user"
echo "$user:$password" | arch-chroot /mnt chpasswd --root

#arch-chroot /mnt chsh -s /bin/bash

# echo "$user:$password" | chpasswd --root /mnt
# echo "root:$password" | chpasswd --root /mnt

pacstrap /mnt plasma-meta kde-applications-meta kde-utilities sddm sddm-kcm
pacstrap /mnt network-manager-applet networkmanager bluez bluez-utils
pacstrap /mnt bash-completion xf86-video-intel rsync firefox ttf-dejavu cifs-utils exfat-utils
arch-chroot /mnt /bin/bash <<- EOF
systemctl enable sddm.service
systemctl enable NetworkManager.service
systemctl enable bluetooth.service
EOF
arch-chroot /mnt bootctl update
