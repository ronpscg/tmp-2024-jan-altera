set -a
ARCH=arm
#CROSS_COMPILE=arm-none-eabi-
CROSS_COMPILE=arm-linux-gnueabi-
set +
BUILD_DIR=$PWD/build/ramdisk
RAMDISK_WIP=$BUILD_DIR/wipramdisk
RAMDISK_GZ=$BUILD_DIR/ramdisk.gz
RAMDISK_UBOOT=$BUILD_DIR/uInitrd




fatalError() { echo -e "\x1b[41m$@\x1b[0m" ; exit 1 ; }
info() { echo -e "\x1b[32m$@\x1b[0m" ; }
warn() { echo -e "\x1b[33m$@\x1b[0m" ; }
dod() { $@ || fatalError "Failed to $@"; }


build_busybox() {
	: ${BUSYBOX_VERSION=busybox-1.36.1}
	: ${DEFCONFIG=defconfig}
	: ${JOBS=$(nproc)}


	fetch=true
	untar=true
	config=true
	build=true

	for arg in $@ ; do
		case $arg in
			dontfetch)      fetch=false     ;;
			dontuntar)      untar=false     ;;
			dontconfig)     config=false    ;;
			dontbuild)      build=false     ;;
		esac
	done

	if [ $fetch = true ] ; then
		wget https://busybox.net/downloads/${BUSYBOX_VERSION}.tar.bz2
		tar xf ${BUSYBOX_VERSION}.tar.bz2
	elif [ $untar = true ] ; then
		tar xf ${BUSYBOX_VERSION}.tar.bz2
	fi

	if [ $config = true ] ; then
		cd ${BUSYBOX_VERSION}/
		make $DEFCONFIG
		sed -i 's:# CONFIG_STATIC is not set:CONFIG_STATIC=y:' .config
		cd ..
	fi

	if [ $build = true ] ; then
		make -C $BUSYBOX_VERSION CONFIG_PREFIX=$RAMDISK_WIP install -j$JOBS
	fi

}

populate_init() {
	mkdir -p $RAMDISK_WIP/{lib,proc,sys,dev,mnt,xbin,newroot}

	cat > $RAMDISK_WIP/init << EOF
#!/bin/sh

#### Function definitions ####
do_switch_root() {
	# TODO: do unmounts etc., and preferably do in ramdisk, but there is a chance we don't get the privilege to update a ramdisk, so for this particular one we chroot
	# note that current loading is not with a ramdisk but with a minimal read-only fs
	#
	mount -o ro \$NEWROOT_DEVICE /newroot
	exec chroot newroot /sbin/init
}

info() { echo -e "\x1b[32m\$@\x1b[0m" ; }
error() { echo -e "\x1b[31m\$@\x1b[0m" ; }
warn() { echo -e "\x1b[33m\$@\x1b[0m" ; }
verbose_do() { echo -e "\x1b[35m\$@\x1b[0m" ; \$@ ; }

fsck_wrapper_check_by_partition_path() {
        local blockdev=\$1
        verbose_do e2fsck -p \$blockdev
        case \$? in
                0)
                        return 0
                        ;;
                1|2)
                        warn "fsck corrected errors for \$blockdev and returned with \$?"
                        return 0
                        ;;
		4)
                        error "fsck returned with \$?. you have serious errors in \$blockdev that could not be automagically corrected. "
			default_fsck_desperate_fallback_strategy="-y"

			e2fsck \$default_fsck_desperate_fallback_strategy \$blockdev || echo -e "\x1b[31m\$blockdev had errors, and auto fix returned \$?!\x1b[0m"
			warn "\x1b[33m\$blockdev had errors, and auto fix returned \$?!\x1b[0m"
			;;
                *)
                        error "fsck returned with \$?. you have serious errors that could not be automagically corrected"
                        return 2
                        ;;
        esac
}

dos_fsck_wrapper_check_by_partition_path() {
	# this is not really needed in most cases and systems. Note that -a -p -y are the same for the vfat fsck, and in general we should not be using it
        local blockdev=\$1
        verbose_do fsck.vfat -p \$blockdev
        case \$? in
                0)
                        return 0
                        ;;
		*)
                        warn "fsck tried to autocorrect errors for \$blockdev and returned with \$?"
                        return \$?
                        ;;
        esac
}


do_fsck_work() {
	echo -e "Doing root filesystem check"
	fsck_wrapper_check_by_partition_path \$PART_EXT_ROOTFS

	echo -e "Doing datarw filesystem check"
	fsck_wrapper_check_by_partition_path \$PART_EXT_RWDATA

	# read the inline comment in the next line
	dos_fsck_wrapper_check_by_partition_path \$PART_FAT_BOOTFAT # This is a prepration. The function implementation itself will just return as we don't need this.
}


#### main starts here #### 

# If ramdisk doesn't come with premade empty proc sys dev folders - you can mkdir them here.

mount -t proc none /proc
mount -t sysfs none /sys
mount -t debugfs none /sys/kernel/debug

echo -e "\n\033[0;32m The PSCG mini-linux\033[0m booted in \$(cut -d' ' -f1 /proc/uptime) seconds on \$(arch)\n"

# Enable sysfs / dev initial enumeration
mdev -s
# Enable hotplugging - without this, the kernel would expect /sbin/hotplug. For this you need CONFIG_UEVENT_HELPER=y in the kernel, and you can live without it if CONFIG_DEVTMPFS=y and CONFIG_DEVTMPFS_MOUNT=y (and of course, CONFIG_SYSFS=y)
# This line is used for other ramdisk generations with differnet illustration purposes, so don't worry if /proc/sys/kernel/hotplug doesn't exist, but /dev/mdev gets populated.
# echo /sbin/mdev >/proc/sys/kernel/hotplug

# allow doing "bashrc" style stuff like aliases etc.
# This can also be done by populating /etc/profile , however I am doing it in the following way for the sake of the example: 
# ronenv will be a file to be populated externally (if, nothing bad will happen if it's empty). 
# You can also just populate it yourself from your running shell e.g. # ' echo "alias ll='ls -l' > ronenv , then execute 'sh' and you will see that you will the alias in the other shell
export ENV=ronenv 

# get rid of annoying job control message - it is not really necessary.
# also this is tailored for our exact scenario where we use the console as ttyS0 - be careful if you copy it to another platform, or in a graphical mode!
# For a more elegant solution, use cttyhack; https://git.busybox.net/busybox/plain/shell/cttyhack.c?id=dcaed97
#exec setsid sh -c 'exec sh </dev/console >/dev/console 2>&1' # this will not work, although it is tempting to do so
#exec setsid sh -c 'exec sh </dev/ttyS0 >/dev/ttyS0 2>&1'     # use this for qemu with x86
#exec setsid sh -c 'exec sh </dev/ttyAMA0 > /dev/ttyAMA0 2>&1' # use this for qemu with aarch64 and virt

# Whatever is here will not run if you do not comment the previous line, because exec replaces the image.
# Extra notes for demonstration: Comment the above (setsid line) if you run qemu with graphical mode and you want to use the console. Otherwise, you will think the console gets stuck - while it doesn't.

if grep -q debugshell /proc/cmdline ; then
        exec setsid cttyhack sh
fi

# Storage parameters as per the partitions we have
STORAGE_DEVICE=/dev/mmcblk0
PART_EXT_ROOTFS=\${STORAGE_DEVICE}p6
PART_FAT_BOOTFAT=\${STORAGE_DEVICE}p2
PART_EXT_RWDATA=\${STORAGE_DEVICE}p7
PART_FAT_BOOTFAT=\${STORAGE_DEVICE}p2

# fsck routines for the planned systems (I recommended to reimplement writing strategy, they did not implement as per now which is why this code is being written)
do_fsck_work

NEWROOT_DEVICE=\$PART_EXT_ROOTFS
do_switch_root


EOF

	chmod +x $RAMDISK_WIP/init
}


repack_ramdisk() {
	cd $RAMDISK_WIP || exit 1
	pwd
	find . | cpio -ov --format=newc | gzip -9 > $RAMDISK_GZ || fatalError "Failed to compress ramdisk"
	cd -

}

pack_for_uboot() {
	mkimage \
        -A arm \
        -O linux \
        -T ramdisk \
        -C gzip \
	-n "altera ramdisk" \
	-d $RAMDISK_GZ \
	$RAMDISK_UBOOT \
	|| fatalError "Failed to create initrd in u-boot format (64 bytes of header followed by the compressed ramdisk)"

}

init_folders() {
	set -euo pipefail
	mkdir -p $BUILD_DIR
	if [ -d $RAMDISK_WIP ] ; then
		warn "Ramdisk already exists."
		rm -rf $RAMDISK_WIP
	fi
	mkdir $RAMDISK_WIP 

	set +euo pipefail
}

main() {
	dod init_folders
	dod build_busybox $@
	dod populate_init
	dod repack_ramdisk
	dod pack_for_uboot
}

main $@
