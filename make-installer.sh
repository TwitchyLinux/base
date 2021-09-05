#!/bin/bash
set -e

if [[ $(whoami) == "root" ]]; then
  echo "Cannot be run as root"
  exit 1
fi

# Nix
NIX_TOPLEVEL_PATH=$(nix-user-chroot /scratch/nix-store/ bash -l -c 'nix-build --max-jobs 4 --cores 8 -A toplevel installer')
NIX_ROOTFS_PATH=$(nix-user-chroot /scratch/nix-store/ bash -l -c 'nix-build --max-jobs 4 --cores 8 -A rootfsImage installer')
NIX_ROOTFS_PATH="/scratch/nix-store/${NIX_ROOTFS_PATH:4}"
kernel_params=$(nix-user-chroot /scratch/nix-store/ cat "${NIX_TOPLEVEL_PATH}/kernel-params")

# Globals
SCRIPT_BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
IMG_FILE="/tmp/twl-installer.img"
IMG_DEV=""
BOOT_IMG_MOUNT_POINT=""



init_image () {
  dd if=/dev/zero "of=${IMG_FILE}" bs=1 count=0 seek=16G
  sudo losetup /dev/loop0 ${IMG_FILE}
  IMG_DEV='/dev/loop0'

  echo "Creating partition table..."
  sudo parted --script "${IMG_DEV}" mklabel gpt            \
         mkpart fat32 1MiB 512MiB                          \
         mkpart ext4  512MiB 100%                          \
         set 1 boot on
  sudo partprobe $IMG_DEV
  sleep 2

  echo "Creating fat32 filesystem on ${IMG_DEV}p1..."
  sudo mkfs.fat -F32 -n SYSTEM-EFI "${IMG_DEV}p1"
  sleep 2

  BOOT_PART_UUID=`lsblk -nr -o UUID ${IMG_DEV}p1`
  mkdir -p /tmp/tmp_boot_mnt || true
  sudo mount -o uid=$(id -u) "${IMG_DEV}p1" /tmp/tmp_boot_mnt
  BOOT_IMG_MOUNT_POINT="/tmp/tmp_boot_mnt"

  echo "Copying rootfs to ${IMG_DEV}p2..."
  sudo dd status=progress if=${NIX_ROOTFS_PATH} "of=${IMG_DEV}p2"
}

setup_boot () {
  sudo bootctl "--path=${BOOT_IMG_MOUNT_POINT}" --no-variables install

cat > ${BOOT_IMG_MOUNT_POINT}/loader/entries/installer.conf <<EOF
title TwitchyLinux Installer
version test v 1
linux /efi/kernel
initrd /efi/initrd
options OPTS_LINE
EOF

  sed -i "s*OPTS_LINE*${kernel_params}*g" ${BOOT_IMG_MOUNT_POINT}/loader/entries/installer.conf

  nix-user-chroot /scratch/nix-store install "${NIX_TOPLEVEL_PATH}/kernel" -m 0755 /tmp/twlinst_kernel
  nix-user-chroot /scratch/nix-store install "${NIX_TOPLEVEL_PATH}/initrd" -m 0755 /tmp/twlinst_initrd
  cp -v /tmp/twlinst_kernel ${BOOT_IMG_MOUNT_POINT}/efi/kernel
  cp -v /tmp/twlinst_initrd ${BOOT_IMG_MOUNT_POINT}/efi/initrd
}


unmount_img () {
  sudo losetup -d "${IMG_DEV}"
  IMG_DEV=''
}

on_exit () {
  if [[ "${BOOT_IMG_MOUNT_POINT}" != "" ]]; then
    echo "Unmounting $BOOT_IMG_MOUNT_POINT"
    sudo umount $BOOT_IMG_MOUNT_POINT
    BOOT_IMG_MOUNT_POINT=""
  fi

  if [[ "${IMG_DEV}" != "" ]]; then
    unmount_img
  fi
}





trap 'on_exit $LINENO' ERR EXIT
init_image
setup_boot

# sudo apt-get install ovmf
#
# qemu-system-x86_64 -bios /usr/share/ovmf/OVMF.fd -soundhw hda -device virtio-rng-pci -vga virtio -enable-kvm -cpu host -smp 4 -m 4G -drive format=raw,file=/tmp/twl-installer.img
