#!/bin/bash -e
#
# Copyright (c) 2009-2018 Robert Nelson <robertcnelson@gmail.com>
# Copyright (c) 2010 Mario Di Francesco <mdf-code@digitalexile.it>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# Latest can be found at:
# https://github.com/RobertCNelson/omap-image-builder/blob/master/tools/setup_sdcard.sh

#REQUIREMENTS:
#uEnv.txt bootscript support

BOOT_LABEL="BOOT"

unset USE_BETA_BOOTLOADER
unset USE_LOCAL_BOOT
unset LOCAL_BOOTLOADER

#Defaults
ROOTFS_TYPE=ext4
ROOTFS_LABEL=rootfs

DIR="$PWD"
TEMPDIR=$(mktemp -d)

keep_net_alive () {
	while : ; do
		echo "syncing media... $*"
		sleep 300
	done
}
keep_net_alive & KEEP_NET_ALIVE_PID=$!
cleanup_keep_net_alive () {
	[ -e /proc/$KEEP_NET_ALIVE_PID ] && kill $KEEP_NET_ALIVE_PID
}
trap cleanup_keep_net_alive EXIT

is_element_of () {
	testelt=$1
	for validelt in $2 ; do
		[ $testelt = $validelt ] && return 0
	done
	return 1
}

#########################################################################
#
#  Define valid "--rootfs" root filesystem types.
#
#########################################################################

VALID_ROOTFS_TYPES="ext2 ext3 ext4 btrfs"

is_valid_rootfs_type () {
	if is_element_of $1 "${VALID_ROOTFS_TYPES}" ] ; then
		return 0
	else
		return 1
	fi
}

check_root () {
	if ! [ $(id -u) = 0 ] ; then
		echo "$0 must be run as sudo user or root"
		exit 1
	fi
}

find_issue () {
	check_root

	ROOTFS=$(ls "${DIR}/" | grep rootfs)
	if [ "x${ROOTFS}" != "x" ] ; then
		echo "Debug: ARM rootfs: ${ROOTFS}"
	else
		echo "Error: no armel-rootfs-* file"
		echo "Make sure your in the right dir..."
		exit
	fi

	unset has_uenvtxt
	unset check
	check=$(ls "${DIR}/" | grep uEnv.txt | grep -v post-uEnv.txt | head -n 1)
	if [ "x${check}" != "x" ] ; then
		echo "Debug: image has pre-generated uEnv.txt file"
		has_uenvtxt=1
	fi

	unset has_post_uenvtxt
	unset check
	check=$(ls "${DIR}/" | grep post-uEnv.txt | head -n 1)
	if [ "x${check}" != "x" ] ; then
		echo "Debug: image has post-uEnv.txt file"
		has_post_uenvtxt="enable"
	fi
}

check_for_command () {
	if ! which "$1" > /dev/null ; then
		echo -n "You're missing command $1"
		NEEDS_COMMAND=1
		if [ -n "$2" ] ; then
			echo -n " (consider installing package $2)"
		fi
		echo
	fi
}

detect_software () {
	unset NEEDS_COMMAND

	check_for_command mkfs.vfat dosfstools
	check_for_command wget wget
	check_for_command git git
	check_for_command partprobe parted

	if [ "x${build_img_file}" = "xenable" ] ; then
		check_for_command kpartx kpartx
	fi

	if [ "${NEEDS_COMMAND}" ] ; then
		echo ""
		echo "Your system is missing some dependencies"
		echo "Debian/Ubuntu: sudo apt-get install dosfstools git-core kpartx wget parted"
		echo "Fedora: yum install dosfstools dosfstools git-core wget"
		echo "Gentoo: emerge dosfstools git wget"
		echo ""
		exit
	fi

	unset test_sfdisk
	test_sfdisk=$(LC_ALL=C sfdisk -v 2>/dev/null | grep 2.17.2 | awk '{print $1}')
	if [ "x${test_sdfdisk}" = "xsfdisk" ] ; then
		echo ""
		echo "Detected known broken sfdisk:"
		echo "See: https://github.com/RobertCNelson/netinstall/issues/20"
		echo ""
		exit
	fi

	unset wget_version
	wget_version=$(LC_ALL=C wget --version | grep "GNU Wget" | awk '{print $3}' | awk -F '.' '{print $2}' || true)
	case "${wget_version}" in
	12|13)
		#wget before 1.14 in debian does not support sni
		echo "wget: [`LC_ALL=C wget --version | grep \"GNU Wget\" | awk '{print $3}' || true`]"
		echo "wget: [this version of wget does not support sni, using --no-check-certificate]"
		echo "wget: [http://en.wikipedia.org/wiki/Server_Name_Indication]"
		dl="wget --no-check-certificate"
		;;
	*)
		dl="wget"
		;;
	esac

	dl_continue="${dl} -c"
	dl_quiet="${dl} --no-verbose"
}

local_bootloader () {
	echo ""
	echo "Using Locally Stored Device Bootloader"
	echo "-----------------------------"
	mkdir -p ${TEMPDIR}/dl/

	if [ "${spl_name}" ] ; then
		cp ${LOCAL_SPL} ${TEMPDIR}/dl/
		SPL=${LOCAL_SPL##*/}
		echo "SPL Bootloader: ${SPL}"
	fi

	if [ "${boot_name}" ] ; then
		cp ${LOCAL_BOOTLOADER} ${TEMPDIR}/dl/
		UBOOT=${LOCAL_BOOTLOADER##*/}
		echo "UBOOT Bootloader: ${UBOOT}"
	fi
}

dl_bootloader () {
	echo ""
	echo "Downloading Device's Bootloader"
	echo "-----------------------------"
	minimal_boot="1"

	mkdir -p ${TEMPDIR}/dl/${DIST}
	mkdir -p "${DIR}/dl/${DIST}"

	${dl_quiet} --directory-prefix="${TEMPDIR}/dl/" https://github.com/baorepo/update_boot/raw/master/beaglebone/MLO
	${dl_quiet} --directory-prefix="${TEMPDIR}/dl/" https://github.com/baorepo/update_boot/raw/master/beaglebone/u-boot.img
	${dl_quiet} --directory-prefix="${TEMPDIR}/dl/" https://github.com/baorepo/update_boot/raw/master/beaglebone/bootA.scr
	${dl_quiet} --directory-prefix="${TEMPDIR}/dl/" https://github.com/baorepo/update_boot/raw/master/beaglebone/bootB.scr
}

generate_soc () {
	echo "#!/bin/sh" > ${wfile}
	echo "format=1.0" >> ${wfile}
	echo "" >> ${wfile}
	if [ ! "x${conf_bootloader_in_flash}" = "xenable" ] ; then
		echo "board=${board}" >> ${wfile}
		echo "" >> ${wfile}
		echo "bootloader_location=${bootloader_location}" >> ${wfile}
		echo "bootrom_gpt=${bootrom_gpt}" >> ${wfile}
		echo "" >> ${wfile}
		echo "dd_spl_uboot_count=${dd_spl_uboot_count}" >> ${wfile}
		echo "dd_spl_uboot_seek=${dd_spl_uboot_seek}" >> ${wfile}
		if [ "x${build_img_file}" = "xenable" ] ; then
			echo "dd_spl_uboot_conf=notrunc" >> ${wfile}
		else
			echo "dd_spl_uboot_conf=${dd_spl_uboot_conf}" >> ${wfile}
		fi
		echo "dd_spl_uboot_bs=${dd_spl_uboot_bs}" >> ${wfile}
		echo "dd_spl_uboot_backup=/opt/backup/uboot/${spl_uboot_name}" >> ${wfile}
		echo "" >> ${wfile}
		echo "dd_uboot_count=${dd_uboot_count}" >> ${wfile}
		echo "dd_uboot_seek=${dd_uboot_seek}" >> ${wfile}
		if [ "x${build_img_file}" = "xenable" ] ; then
			echo "dd_uboot_conf=notrunc" >> ${wfile}
		else
			echo "dd_uboot_conf=${dd_uboot_conf}" >> ${wfile}
		fi
		echo "dd_uboot_bs=${dd_uboot_bs}" >> ${wfile}
		echo "dd_uboot_backup=/opt/backup/uboot/${uboot_name}" >> ${wfile}
	else
		echo "uboot_CONFIG_CMD_BOOTZ=${uboot_CONFIG_CMD_BOOTZ}" >> ${wfile}
		echo "uboot_CONFIG_SUPPORT_RAW_INITRD=${uboot_CONFIG_SUPPORT_RAW_INITRD}" >> ${wfile}
		echo "uboot_CONFIG_CMD_FS_GENERIC=${uboot_CONFIG_CMD_FS_GENERIC}" >> ${wfile}
		echo "zreladdr=${conf_zreladdr}" >> ${wfile}
	fi
	echo "" >> ${wfile}
	echo "boot_fstype=${conf_boot_fstype}" >> ${wfile}
	echo "conf_boot_startmb=${conf_boot_startmb}" >> ${wfile}
	echo "conf_boot_endmb=${conf_boot_endmb}" >> ${wfile}
	echo "sfdisk_fstype=${sfdisk_fstype}" >> ${wfile}
	echo "" >> ${wfile}

	if [ "x${uboot_efi_mode}" = "xenable" ] ; then
		echo "uboot_efi_mode=${uboot_efi_mode}" >> ${wfile}
		echo "" >> ${wfile}
	fi

	echo "boot_label=${BOOT_LABEL}" >> ${wfile}
	echo "rootfs_label=${ROOTFS_LABEL}" >> ${wfile}
	echo "" >> ${wfile}
	echo "#Kernel" >> ${wfile}
	echo "dtb=${dtb}" >> ${wfile}
	echo "serial_tty=${SERIAL}" >> ${wfile}
	echo "usbnet_mem=${usbnet_mem}" >> ${wfile}
	echo "" >> ${wfile}
	echo "#Advanced options" >> ${wfile}
	echo "#disable_ssh_regeneration=true" >> ${wfile}

	echo "" >> ${wfile}
}

drive_error_ro () {
	echo "-----------------------------"
	echo "Error: for some reason your SD card is not writable..."
	echo "Check: is the write protect lever set the locked position?"
	echo "Check: do you have another SD card reader?"
	echo "-----------------------------"
	echo "Script gave up..."

	exit
}


create_partitions () {

	media_boot_partition=12
	media_rootfsA_partition=3
	media_rootfsB_partition=5
	media_data_partition=1

	if [ "x${build_img_file}" = "xenable" ] ; then
		media_loop=$(losetup -f || true)
		if [ ! "${media_loop}" ] ; then
			echo "losetup -f failed"
			echo "Unmount some via: [sudo losetup -a]"
			echo "-----------------------------"
			losetup -a
			echo "sudo kpartx -d /dev/loopX ; sudo losetup -d /dev/loopX"
			echo "-----------------------------"
			exit
		fi

		losetup ${media_loop} "${media}"
		kpartx -av ${media_loop}
		sleep 1
		sync
		test_loop=$(echo ${media_loop} | awk -F'/' '{print $3}')
		if [ -e /dev/mapper/${test_loop}p${media_boot_partition} ] && [ -e /dev/mapper/${test_loop}p${media_rootfsA_partition} ] ; then
			media_prefix="/dev/mapper/${test_loop}p"
		else
			ls -lh /dev/mapper/
			echo "Error: not sure what to do (new feature)."
			exit
		fi
	else
		partprobe ${media}
	fi

}

populate_boot () {
	echo "Populating Boot Partition"
	echo "-----------------------------"

	if [ ! -d ${TEMPDIR}/boot ] ; then
		mkdir -p ${TEMPDIR}/boot
	fi

	partprobe ${media}
	if ! mount ${media_prefix}${media_boot_partition} ${TEMPDIR}/boot; then

		echo "-----------------------------"
		echo "BUG: [${media_prefix}${media_boot_partition}] was not available so trying to mount again in 5 seconds..."
		partprobe ${media}
		sync
		sleep 5
		echo "-----------------------------"

		if ! mount  ${media_prefix}${media_boot_partition} ${TEMPDIR}/boot; then
			echo "-----------------------------"
			echo "Unable to mount ${media_prefix}${media_boot_partition} at ${TEMPDIR}/disk to complete populating Boot Partition"
			echo "Please retry running the script, sometimes rebooting your system helps."
			echo "-----------------------------"
			exit
		fi
	fi

	lsblk | grep -v sr0
	echo "-----------------------------"

	cp -v ${TEMPDIR}/dl/MLO ${TEMPDIR}/boot/MLO
	echo "-----------------------------"

	cp -v ${TEMPDIR}/dl/u-boot.img ${TEMPDIR}/boot/u-boot.img
	echo "-----------------------------"

	cp -v ${TEMPDIR}/dl/bootA.scr ${TEMPDIR}/boot/boot.scr
	echo "-----------------------------"



	if [ -f "${DIR}/ID.txt" ] ; then
		cp -v "${DIR}/ID.txt" ${TEMPDIR}/boot/ID.txt
	fi


	cd ${TEMPDIR}/boot
	sync
	cd "${DIR}"/

	echo "Debug: Contents of Boot Partition"
	echo "-----------------------------"
	ls -lh ${TEMPDIR}/boot/
	du -sh ${TEMPDIR}/boot/
	echo "-----------------------------"

	sync
	sync

	umount ${TEMPDIR}/boot || true

	echo "Finished populating Boot Partition"
	echo "-----------------------------"
}

kernel_detection () {
	unset has_multi_armv7_kernel
	unset check
	check=$(ls "${dir_check}" | grep vmlinuz- | grep armv7 | grep -v lpae | head -n 1)
	if [ "x${check}" != "x" ] ; then
		armv7_kernel=$(ls "${dir_check}" | grep vmlinuz- | grep armv7 | grep -v lpae | head -n 1 | awk -F'vmlinuz-' '{print $2}')
		echo "Debug: image has: v${armv7_kernel}"
		has_multi_armv7_kernel="enable"
	fi

	unset has_multi_armv7_lpae_kernel
	unset check
	check=$(ls "${dir_check}" | grep vmlinuz- | grep armv7 | grep lpae | head -n 1)
	if [ "x${check}" != "x" ] ; then
		armv7_lpae_kernel=$(ls "${dir_check}" | grep vmlinuz- | grep armv7 | grep lpae | head -n 1 | awk -F'vmlinuz-' '{print $2}')
		echo "Debug: image has: v${armv7_lpae_kernel}"
		has_multi_armv7_lpae_kernel="enable"
	fi

	unset has_bone_kernel
	unset check
	check=$(ls "${dir_check}" | grep vmlinuz- | grep bone | head -n 1)
	if [ "x${check}" != "x" ] ; then
		bone_dt_kernel=$(ls "${dir_check}" | grep vmlinuz- | grep bone | head -n 1 | awk -F'vmlinuz-' '{print $2}')
		echo "Debug: image has: v${bone_dt_kernel}"
		has_bone_kernel="enable"
	fi

	unset has_ti_kernel
	unset check
	check=$(ls "${dir_check}" | grep vmlinuz- | grep ti | head -n 1)
	if [ "x${check}" != "x" ] ; then
		ti_dt_kernel=$(ls "${dir_check}" | grep vmlinuz- | grep ti | head -n 1 | awk -F'vmlinuz-' '{print $2}')
		echo "Debug: image has: v${ti_dt_kernel}"
		has_ti_kernel="enable"
	fi

	unset has_xenomai_kernel
	unset check
	check=$(ls "${dir_check}" | grep vmlinuz- | grep xenomai | head -n 1)
	if [ "x${check}" != "x" ] ; then
		xenomai_dt_kernel=$(ls "${dir_check}" | grep vmlinuz- | grep xenomai | head -n 1 | awk -F'vmlinuz-' '{print $2}')
		echo "Debug: image has: v${xenomai_dt_kernel}"
		has_xenomai_kernel="enable"
	fi
}

kernel_select () {
	unset select_kernel
	if [ "x${conf_kernel}" = "xarmv7" ] || [ "x${conf_kernel}" = "x" ] ; then
		if [ "x${has_multi_armv7_kernel}" = "xenable" ] ; then
			select_kernel="${armv7_kernel}"
		fi
	fi

	if [ "x${conf_kernel}" = "xarmv7_lpae" ] ; then
		if [ "x${has_multi_armv7_lpae_kernel}" = "xenable" ] ; then
			select_kernel="${armv7_lpae_kernel}"
		else
			if [ "x${has_multi_armv7_kernel}" = "xenable" ] ; then
				select_kernel="${armv7_kernel}"
			fi
		fi
	fi

	if [ "x${conf_kernel}" = "xbone" ] ; then
		if [ "x${has_ti_kernel}" = "xenable" ] ; then
			select_kernel="${ti_dt_kernel}"
		else
			if [ "x${has_bone_kernel}" = "xenable" ] ; then
				select_kernel="${bone_dt_kernel}"
			else
				if [ "x${has_multi_armv7_kernel}" = "xenable" ] ; then
					select_kernel="${armv7_kernel}"
				else
					if [ "x${has_xenomai_kernel}" = "xenable" ] ; then
						select_kernel="${xenomai_dt_kernel}"
					fi
				fi
			fi
		fi
	fi

	if [ "x${conf_kernel}" = "xti" ] ; then
		if [ "x${has_ti_kernel}" = "xenable" ] ; then
			select_kernel="${ti_dt_kernel}"
		else
			if [ "x${has_multi_armv7_kernel}" = "xenable" ] ; then
				select_kernel="${armv7_kernel}"
			fi
		fi
	fi

	if [ "${select_kernel}" ] ; then
		echo "Debug: using: v${select_kernel}"
	else
		echo "Error: [conf_kernel] not defined [armv7_lpae,armv7,bone,ti]..."
		exit
	fi
}

populate_rootfs () {
	echo "Populating rootfs Partition"
	echo "Please be patient, this may take a few minutes, as its transfering a lot of data.."
	echo "-----------------------------"

	if [ ! -d ${TEMPDIR}/disk ] ; then
		mkdir -p ${TEMPDIR}/disk
	fi
	if [ ! -d ${TEMPDIR}/data ] ; then
		mkdir -p ${TEMPDIR}/data
	fi
	partprobe ${media}
	if ! mount  ${media_prefix}${media_rootfsA_partition} ${TEMPDIR}/disk; then

		echo "-----------------------------"
		echo "BUG: [${media_prefix}${media_rootfsA_partition}] was not available so trying to mount again in 5 seconds..."
		partprobe ${media}
		sync
		sleep 5
		echo "-----------------------------"

		if ! mount ${media_prefix}${media_rootfsA_partition} ${TEMPDIR}/disk; then
			echo "-----------------------------"
			echo "Unable to mount ${media_prefix}${media_rootfsA_partition} at ${TEMPDIR}/disk to complete populating rootfs Partition"
			echo "Please retry running the script, sometimes rebooting your system helps."
			echo "-----------------------------"
			exit
		fi
		
	fi
	rm -rf  ${TEMPDIR}/disk/*

	if ! mount ${media_prefix}${media_data_partition} ${TEMPDIR}/data; then

		echo "-----------------------------"
		echo "BUG: [${media_prefix}${media_data_partition}] was not available so trying to mount again in 5 seconds..."
		partprobe ${media}
		sync
		sleep 5
		echo "-----------------------------"

		if ! mount ${media_prefix}${media_data_partition} ${TEMPDIR}/data; then
			echo "-----------------------------"
			echo "Unable to mount ${media_prefix}${media_data_partition} at ${TEMPDIR}/data to complete populating data Partition"
			echo "Please retry running the script, sometimes rebooting your system helps."
			echo "-----------------------------"
			exit
		fi
	fi
	rm -rf  ${TEMPDIR}/data/*
	mkdir -p ${TEMPDIR}/disk/home
	mkdir -p ${TEMPDIR}/disk/var
	if [ "x${enable_openssh}" = "xenable" ] ; then
		mkdir -p ${TEMPDIR}/disk/etc/ssh
	fi
	mkdir -p ${TEMPDIR}/disk/usr/local


	mkdir -p ${TEMPDIR}/disk/mnt/stateful_partition

	mkdir -p ${TEMPDIR}/data/home
	mkdir -p ${TEMPDIR}/data/var
	mkdir -p ${TEMPDIR}/data/local
	if [ "x${enable_openssh}" = "xenable" ] ; then
		mkdir -p ${TEMPDIR}/data/ssh
	fi

	mount --bind ${TEMPDIR}/data ${TEMPDIR}/disk/mnt/stateful_partition
	echo "-----------------------------"
	ls ${TEMPDIR}/disk/mnt/stateful_partition
	echo "-----------------------------"

	mount --bind  ${TEMPDIR}/disk/mnt/stateful_partition/home/ ${TEMPDIR}/disk/home
	mount --bind  ${TEMPDIR}/disk/mnt/stateful_partition/var/ ${TEMPDIR}/disk/var
	if [ "x${enable_openssh}" = "xenable" ] ; then
		mount --bind  ${TEMPDIR}/disk/mnt/stateful_partition/ssh/ ${TEMPDIR}/disk/etc/ssh
	fi
	mount --bind  ${TEMPDIR}/disk/mnt/stateful_partition/local/ ${TEMPDIR}/disk/usr/local
	echo "-----------------------------"
	echo "mount info"
	mount
	echo "-----------------------------"

	lsblk | grep -v sr0
	echo "-----------------------------"

	if [ -f "${DIR}/${ROOTFS}" ] ; then
		if which pv > /dev/null ; then
			pv "${DIR}/${ROOTFS}" | tar --numeric-owner --preserve-permissions -xf - -C ${TEMPDIR}/disk/
		else
			echo "pv: not installed, using tar verbose to show progress"
			tar --numeric-owner --preserve-permissions --verbose -xf "${DIR}/${ROOTFS}" -C ${TEMPDIR}/disk/
		fi

		echo "Transfer of data is Complete, now syncing data to disk..."
		echo "Disk Size"
		du -sh ${TEMPDIR}/disk/
		sync
		sync

		echo "-----------------------------"
		if [ -f /usr/bin/stat ] ; then
			echo "-----------------------------"
			echo "Checking [${TEMPDIR}/disk/] permissions"
			/usr/bin/stat ${TEMPDIR}/disk/
			echo "-----------------------------"
		fi

		echo "Setting [${TEMPDIR}/disk/] chown root:root"
		chown root:root ${TEMPDIR}/disk/
		echo "Setting [${TEMPDIR}/disk/] chmod 755"
		chmod 755 ${TEMPDIR}/disk/

		echo "Setting [${TEMPDIR}/data/] chown root:root"
		chown root:root ${TEMPDIR}/data/
		echo "Setting [${TEMPDIR}/data/] chmod 755"
		chmod 755 ${TEMPDIR}/data/

		if [ -f /usr/bin/stat ] ; then
			echo "-----------------------------"
			echo "Verifying [${TEMPDIR}/disk/] permissions"
			/usr/bin/stat ${TEMPDIR}/disk/
		fi
		echo "-----------------------------"

		if [ ! "x${oem_flasher_img}" = "x" ] ; then
			if [ ! -d "${TEMPDIR}/disk/opt/emmc/" ] ; then
				mkdir -p "${TEMPDIR}/disk/opt/emmc/"
			fi
			cp -v "${oem_flasher_img}" "${TEMPDIR}/disk/opt/emmc/"
			sync
			if [ ! "x${oem_flasher_eeprom}" = "x" ] ; then
				cp -v "${oem_flasher_eeprom}" "${TEMPDIR}/disk/opt/emmc/"
				sync
			fi
#			if [ ! "x${oem_flasher_job}" = "x" ] ; then
#				cp -v "${oem_flasher_job}" "${TEMPDIR}/disk/opt/emmc/job.txt"
#				sync
#				if [ ! "x${oem_flasher_eeprom}" = "x" ] ; then
#					echo "conf_eeprom_file=${oem_flasher_eeprom}" >> "${TEMPDIR}/disk/opt/emmc/job.txt"
#					if [ ! "x${conf_eeprom_compare}" = "x" ] ; then
#						echo "conf_eeprom_compare=${conf_eeprom_compare}" >> "${TEMPDIR}/disk/opt/emmc/job.txt"
#					else
#						echo "conf_eeprom_compare=335" >> "${TEMPDIR}/disk/opt/emmc/job.txt"
#					fi
#				fi
#			fi
#			echo "-----------------------------"
#			cat "${TEMPDIR}/disk/opt/emmc/job.txt"
#			echo "-----------------------------"
			echo "Disk Size, with *.img"
			du -sh ${TEMPDIR}/disk/
		fi

		echo "-----------------------------"
	fi

	dir_check="${TEMPDIR}/disk/boot/"
	kernel_detection
	kernel_select

	if [ ! "x${uboot_eeprom}" = "x" ] ; then
		echo "board_eeprom_header=${uboot_eeprom}" > "${TEMPDIR}/disk/boot/.eeprom.txt"
	fi

	wfile="${TEMPDIR}/disk/boot/uEnv.txt"
	echo "#Docs: http://elinux.org/Beagleboard:U-boot_partitioning_layout_2.0" > ${wfile}
	echo "" >> ${wfile}

	if [ "x${kernel_override}" = "x" ] ; then
		echo "uname_r=${select_kernel}" >> ${wfile}
	else
		echo "uname_r=${kernel_override}" >> ${wfile}
	fi

	if [ "${BTRFS_FSTAB}" ] ; then
		echo "mmcrootfstype=btrfs rootwait" >> ${wfile}
	fi

	echo "#uuid=" >> ${wfile}

	if [ ! "x${dtb}" = "x" ] ; then
		echo "dtb=${dtb}" >> ${wfile}
	else

		if [ ! "x${forced_dtb}" = "x" ] ; then
			echo "dtb=${forced_dtb}" >> ${wfile}
		else
			echo "#dtb=" >> ${wfile}
		fi

		if [ "x${conf_board}" = "xam335x_boneblack" ] || [ "x${conf_board}" = "xam335x_evm" ] || [ "x${conf_board}" = "xam335x_blank_bbbw" ] ; then

			echo "" >> ${wfile}
			echo "###U-Boot Overlays###" >> ${wfile}
			echo "###Documentation: http://elinux.org/Beagleboard:BeagleBoneBlack_Debian#U-Boot_Overlays" >> ${wfile}
			echo "###Master Enable" >> ${wfile}
			if [ "x${uboot_cape_overlays}" = "xenable" ] ; then
				echo "enable_uboot_overlays=1" >> ${wfile}
			else
				echo "#enable_uboot_overlays=1" >> ${wfile}
			fi
			echo "###" >> ${wfile}
			echo "###Overide capes with eeprom" >> ${wfile}
			echo "#uboot_overlay_addr0=/lib/firmware/<file0>.dtbo" >> ${wfile}
			echo "#uboot_overlay_addr1=/lib/firmware/<file1>.dtbo" >> ${wfile}
			echo "#uboot_overlay_addr2=/lib/firmware/<file2>.dtbo" >> ${wfile}
			echo "#uboot_overlay_addr3=/lib/firmware/<file3>.dtbo" >> ${wfile}
			echo "###" >> ${wfile}
			echo "###Additional custom capes" >> ${wfile}
			echo "#uboot_overlay_addr4=/lib/firmware/<file4>.dtbo" >> ${wfile}
			echo "#uboot_overlay_addr5=/lib/firmware/<file5>.dtbo" >> ${wfile}
			echo "#uboot_overlay_addr6=/lib/firmware/<file6>.dtbo" >> ${wfile}
			echo "#uboot_overlay_addr7=/lib/firmware/<file7>.dtbo" >> ${wfile}
			echo "###" >> ${wfile}
			echo "###Custom Cape" >> ${wfile}
			echo "#dtb_overlay=/lib/firmware/<file8>.dtbo" >> ${wfile}
			echo "###" >> ${wfile}
			echo "###Disable auto loading of virtual capes (emmc/video/wireless/adc)" >> ${wfile}
			echo "#disable_uboot_overlay_emmc=1" >> ${wfile}
			echo "#disable_uboot_overlay_video=1" >> ${wfile}
			echo "#disable_uboot_overlay_audio=1" >> ${wfile}
			echo "#disable_uboot_overlay_wireless=1" >> ${wfile}
			echo "#disable_uboot_overlay_adc=1" >> ${wfile}
			echo "###" >> ${wfile}
			echo "###PRUSS OPTIONS" >> ${wfile}
			unset use_pru_uio
			if [ "x${uboot_pru_rproc_44ti}" = "xenable" ] ; then
				echo "###pru_rproc (4.4.x-ti kernel)" >> ${wfile}
				echo "#uboot_overlay_pru=/lib/firmware/AM335X-PRU-RPROC-4-4-TI-00A0.dtbo" >> ${wfile}
				echo "###pru_rproc (4.14.x-ti kernel)" >> ${wfile}
				echo "#uboot_overlay_pru=/lib/firmware/AM335X-PRU-RPROC-4-14-TI-00A0.dtbo" >> ${wfile}
				echo "###pru_uio (4.4.x-ti, 4.14.x-ti & mainline/bone kernel)" >> ${wfile}
				echo "#uboot_overlay_pru=/lib/firmware/AM335X-PRU-UIO-00A0.dtbo" >> ${wfile}
				use_pru_uio="blocked"
			fi
			if [ "x${uboot_pru_rproc_414ti}" = "xenable" ] ; then
				echo "###pru_rproc (4.4.x-ti kernel)" >> ${wfile}
				echo "#uboot_overlay_pru=/lib/firmware/AM335X-PRU-RPROC-4-4-TI-00A0.dtbo" >> ${wfile}
				echo "###pru_rproc (4.14.x-ti kernel)" >> ${wfile}
				echo "#uboot_overlay_pru=/lib/firmware/AM335X-PRU-RPROC-4-14-TI-00A0.dtbo" >> ${wfile}
                ##echo "uboot_overlay_pru=/lib/firmware/univ-bbgw-EW-00A0.dtbo" >> ${wfile}
				echo "###pru_uio (4.4.x-ti, 4.14.x-ti & mainline/bone kernel)" >> ${wfile}
				echo "#uboot_overlay_pru=/lib/firmware/AM335X-PRU-UIO-00A0.dtbo" >> ${wfile}
				use_pru_uio="blocked"
			fi
			if [ "x${use_pru_uio}" = "x" ] ; then
				echo "###pru_rproc (4.4.x-ti kernel)" >> ${wfile}
				echo "#uboot_overlay_pru=/lib/firmware/AM335X-PRU-RPROC-4-4-TI-00A0.dtbo" >> ${wfile}
				echo "###pru_rproc (4.14.x-ti kernel)" >> ${wfile}
				echo "#uboot_overlay_pru=/lib/firmware/AM335X-PRU-RPROC-4-14-TI-00A0.dtbo" >> ${wfile}
				echo "###pru_uio (4.4.x-ti, 4.14.x-ti & mainline/bone kernel)" >> ${wfile}
				echo "#uboot_overlay_pru=/lib/firmware/AM335X-PRU-UIO-00A0.dtbo" >> ${wfile}
                ##echo "uboot_overlay_pru=/lib/firmware/univ-bbgw-EW-00A0.dtbo" >> ${wfile}
			fi
			echo "###" >> ${wfile}
			echo "###Cape Universal Enable" >> ${wfile}
			if [ "x${uboot_cape_overlays}" = "xenable" ] ; then
				echo "enable_uboot_cape_universal=1" >> ${wfile}
			else
				echo "#enable_uboot_cape_universal=1" >> ${wfile}
			fi
			echo "###" >> ${wfile}
			echo "###Debug: disable uboot autoload of Cape" >> ${wfile}
			echo "#disable_uboot_overlay_addr0=1" >> ${wfile}
			echo "#disable_uboot_overlay_addr1=1" >> ${wfile}
			echo "#disable_uboot_overlay_addr2=1" >> ${wfile}
			echo "#disable_uboot_overlay_addr3=1" >> ${wfile}
			echo "###" >> ${wfile}
			echo "###U-Boot fdt tweaks... (60000 = 384KB)" >> ${wfile}
			echo "#uboot_fdt_buffer=0x60000" >> ${wfile}
			echo "###U-Boot Overlays###" >> ${wfile}

			echo "" >> ${wfile}
		fi
	fi

	cmdline="coherent_pool=1M net.ifnames=0 quiet"
	if [ "x${enable_cape_universal}" = "xenable" ] ; then
		cmdline="${cmdline} cape_universal=enable"
	fi

	unset kms_video

	drm_device_identifier=${drm_device_identifier:-"HDMI-A-1"}
	drm_device_timing=${drm_device_timing:-"1024x768@60e"}
	if [ "x${drm_read_edid_broken}" = "xenable" ] ; then
		cmdline="${cmdline} video=${drm_device_identifier}:${drm_device_timing}"
		echo "cmdline=${cmdline}" >> ${wfile}
		echo "" >> ${wfile}
	else
		echo "cmdline=${cmdline}" >> ${wfile}
		echo "" >> ${wfile}

		echo "#In the event of edid real failures, uncomment this next line:" >> ${wfile}
		echo "#cmdline=${cmdline} video=${drm_device_identifier}:${drm_device_timing}" >> ${wfile}
		echo "" >> ${wfile}
	fi

	echo "#Use an overlayfs on top of a read-only root filesystem:" >> ${wfile}
	echo "#cmdline=${cmdline} overlayroot=tmpfs" >> ${wfile}
	echo "" >> ${wfile}

	if [ "x${conf_board}" = "xam335x_boneblack" ] || [ "x${conf_board}" = "xam335x_evm" ] || [ "x${conf_board}" = "xam335x_blank_bbbw" ] ; then
		if [ ! "x${has_post_uenvtxt}" = "x" ] ; then
			cat "${DIR}/post-uEnv.txt" >> ${wfile}
			echo "" >> ${wfile}
		fi

		if [ "x${usb_flasher}" = "xenable" ] ; then
			if [ ! "x${oem_flasher_script}" = "x" ] ; then
				echo "cmdline=init=/opt/scripts/tools/eMMC/${oem_flasher_script}" >> ${wfile}
			else
				echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-from-usb-media.sh" >> ${wfile}
			fi
		elif [ "x${emmc_flasher}" = "xenable" ] ; then
			echo "##enable Generic eMMC Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-v3.sh" >> ${wfile}
		elif [ "x${bbg_flasher}" = "xenable" ] ; then
			echo "##enable BBG: eMMC Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-v3-bbg.sh" >> ${wfile}
		elif [ "x${bbgw_flasher}" = "xenable" ] ; then
			echo "##enable BBG: eMMC Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-v3-bbgw.sh" >> ${wfile}
		elif [ "x${m10a_flasher}" = "xenable" ] ; then
			echo "##enable m10a: eMMC Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-v3-m10a.sh" >> ${wfile}
		elif [ "x${me06_flasher}" = "xenable" ] ; then
			echo "##enable me06: eMMC Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-v3-me06.sh" >> ${wfile}
		elif [ "x${bbbl_flasher}" = "xenable" ] ; then
			echo "##enable bbbl: eMMC Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-v3-bbbl.sh" >> ${wfile}
		elif [ "x${bbbw_flasher}" = "xenable" ] ; then
			echo "##enable bbbw: eMMC Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-v3-bbbw.sh" >> ${wfile}
		elif [ "x${bp00_flasher}" = "xenable" ] ; then
			echo "##enable bp00: eeprom Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-bp00.sh" >> ${wfile}
		elif [ "x${a335_flasher}" = "xenable" ] ; then
			echo "##enable a335: eeprom Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-a335.sh" >> ${wfile}
		else
			echo "##enable Generic eMMC Flasher:" >> ${wfile}
			echo "##make sure, these tools are installed: dosfstools rsync" >> ${wfile}
			echo "#cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-v3.sh" >> ${wfile}
		fi
		echo "" >> ${wfile}
	else
		if [ "x${usb_flasher}" = "xenable" ] ; then
			if [ ! "x${oem_flasher_script}" = "x" ] ; then
				echo "cmdline=init=/opt/scripts/tools/eMMC/${oem_flasher_script}" >> ${wfile}
			else
				echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-from-usb-media.sh" >> ${wfile}
			fi
		elif [ "x${emmc_flasher}" = "xenable" ] ; then
			echo "##enable Generic eMMC Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-v3-no-eeprom.sh" >> ${wfile}
		elif [ "x${bp00_flasher}" = "xenable" ] ; then
			echo "##enable bp00: eeprom Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-bp00.sh" >> ${wfile}
		elif [ "x${a335_flasher}" = "xenable" ] ; then
			echo "##enable a335: eeprom Flasher:" >> ${wfile}
			echo "cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-a335.sh" >> ${wfile}
		else
			if [ "x${conf_board}" = "xbeagle_x15" ] ; then
				echo "##enable x15: eMMC Flasher:" >> ${wfile}
				echo "##make sure, these tools are installed: dosfstools rsync" >> ${wfile}
				echo "#cmdline=init=/opt/scripts/tools/eMMC/init-eMMC-flasher-v3-no-eeprom.sh" >> ${wfile}
			fi
		fi
	fi

	#oob out of box experience:
	if [ ! "x${oobe_cape}" = "x" ] ; then
		echo "" >> ${wfile}
		echo "dtb=am335x-boneblack-overlay.dtb" >> ${wfile}
		echo "cape_enable=bone_capemgr.enable_partno=${oobe_cape}" >> ${wfile}
	fi

	#am335x_boneblack is a custom u-boot to ignore empty factory eeproms...
	if [ "x${conf_board}" = "xam335x_boneblack" ] ; then
		board="am335x_evm"
	else
		board=${conf_board}
	fi

	echo "/boot/uEnv.txt---------------"
	cat ${wfile}
	echo "-----------------------------"

	wfile="${TEMPDIR}/disk/boot/SOC.sh"
	generate_soc

	#RootStock-NG
	if [ -f ${TEMPDIR}/disk/etc/rcn-ee.conf ] ; then
		. ${TEMPDIR}/disk/etc/rcn-ee.conf

		mkdir -p ${TEMPDIR}/disk/boot/uboot || true

		wfile="${TEMPDIR}/disk/etc/fstab"
		echo "# /etc/fstab: static file system information." > ${wfile}
		echo "#" >> ${wfile}
		echo "# Auto generated by RootStock-NG: setup_sdcard.sh" >> ${wfile}
		echo "#" >> ${wfile}

		# if [ "x${option_ro_root}" = "xenable" ] ; then
		# 	echo "#With read only rootfs, we need to boot once as rw..." >> ${wfile}
		# 	echo "${rootfs_drive}  /  ext2  noatime,errors=remount-ro  0  1" >> ${wfile}
		# 	echo "#" >> ${wfile}
		# 	echo "#Switch to read only rootfs:" >> ${wfile}
		# 	echo "#${rootfs_drive}  /  ext2  noatime,ro,errors=remount-ro  0  1" >> ${wfile}
		# 	echo "#" >> ${wfile}
		# 	echo "${rootfs_var_drive}  /var  ${ROOTFS_TYPE}  noatime  0  2" >> ${wfile}
		# else
		# 	if [ "${BTRFS_FSTAB}" ] ; then
		# 		echo "${rootfs_drive}  /  btrfs  defaults,noatime  0  1" >> ${wfile}
		# 	else
		# 		echo "${rootfs_drive}  /  ${ROOTFS_TYPE}  noatime,errors=remount-ro  0  1" >> ${wfile}
		# 	fi
		# fi

		# if [ "x${uboot_efi_mode}" = "xenable" ] ; then
		# 	echo "${boot_drive}  /boot/efi vfat defaults 0 0" >> ${wfile}
		# fi

		
		echo "/dev/mmcblk0p1 /mnt/stateful_partition ext4 defaults 0 2" >> ${wfile}
		echo "/mnt/stateful_partition/home /home none defaults,bind 0 0" >> ${wfile}
		echo "/mnt/stateful_partition/var /var none defaults,bind 0 0" >> ${wfile}
		echo "/mnt/stateful_partition/local /usr/local none defaults,bind 0 0" >> ${wfile}
		if [ "x${enable_openssh}" = "xenable" ] ; then
			echo "/mnt/stateful_partition/ssh /etc/ssh none defaults,bind 0 0" >> ${wfile}
		fi
		echo "debugfs  /sys/kernel/debug  debugfs  defaults  0  0" >> ${wfile}

		if [ "x${DISABLE_ETH}" != "xskip" ] ; then
			wfile="${TEMPDIR}/disk/etc/network/interfaces"
			if [ -f ${wfile} ] ; then
				echo "# This file describes the network interfaces available on your system" > ${wfile}
				echo "# and how to activate them. For more information, see interfaces(5)." >> ${wfile}
				echo "" >> ${wfile}
				echo "# The loopback network interface" >> ${wfile}
				echo "auto lo" >> ${wfile}
				echo "iface lo inet loopback" >> ${wfile}
				echo "" >> ${wfile}
				echo "# The primary network interface" >> ${wfile}

				if [ "${DISABLE_ETH}" ] ; then
					echo "#auto eth0" >> ${wfile}
					echo "#iface eth0 inet dhcp" >> ${wfile}
				else
					echo "auto eth0"  >> ${wfile}
					echo "iface eth0 inet dhcp" >> ${wfile}
				fi

				#if we have systemd & wicd-gtk, disable eth0 in /etc/network/interfaces
				if [ -f ${TEMPDIR}/disk/lib/systemd/systemd ] ; then
					if [ -f ${TEMPDIR}/disk/usr/bin/wicd-gtk ] ; then
						sed -i 's/auto eth0/#auto eth0/g' ${wfile}
						sed -i 's/allow-hotplug eth0/#allow-hotplug eth0/g' ${wfile}
						sed -i 's/iface eth0 inet dhcp/#iface eth0 inet dhcp/g' ${wfile}
					fi
				fi

				#if we have connman, disable eth0 in /etc/network/interfaces
				if [ -f ${TEMPDIR}/disk/etc/init.d/connman ] ; then
					sed -i 's/auto eth0/#auto eth0/g' ${wfile}
					sed -i 's/allow-hotplug eth0/#allow-hotplug eth0/g' ${wfile}
					sed -i 's/iface eth0 inet dhcp/#iface eth0 inet dhcp/g' ${wfile}
				fi

				echo "# Example to keep MAC address between reboots" >> ${wfile}
				echo "#hwaddress ether DE:AD:BE:EF:CA:FE" >> ${wfile}

				echo "" >> ${wfile}

				echo "##connman: ethX static config" >> ${wfile}
				echo "#connmanctl services" >> ${wfile}
				echo "#Using the appropriate ethernet service, tell connman to setup a static IP address for that service:" >> ${wfile}
				echo "#sudo connmanctl config <service> --ipv4 manual <ip_addr> <netmask> <gateway> --nameservers <dns_server>" >> ${wfile}

				echo "" >> ${wfile}

				echo "##connman: WiFi" >> ${wfile}
				echo "#" >> ${wfile}
				echo "#connmanctl" >> ${wfile}
				echo "#connmanctl> tether wifi off" >> ${wfile}
				echo "#connmanctl> enable wifi" >> ${wfile}
				echo "#connmanctl> scan wifi" >> ${wfile}
				echo "#connmanctl> services" >> ${wfile}
				echo "#connmanctl> agent on" >> ${wfile}
				echo "#connmanctl> connect wifi_*_managed_psk" >> ${wfile}
				echo "#connmanctl> quit" >> ${wfile}

				echo "" >> ${wfile}

				echo "# Ethernet/RNDIS gadget (g_ether)" >> ${wfile}
				echo "# Used by: /opt/scripts/boot/autoconfigure_usb0.sh" >> ${wfile}
				echo "iface usb0 inet static" >> ${wfile}
				echo "    address 192.168.7.2" >> ${wfile}
				echo "    netmask 255.255.255.252" >> ${wfile}
				echo "    network 192.168.7.0" >> ${wfile}
				echo "    gateway 192.168.7.1" >> ${wfile}
			fi
		fi

		if [ -f ${TEMPDIR}/disk/var/www/index.html ] ; then
			rm -f ${TEMPDIR}/disk/var/www/index.html || true
		fi

		if [ -f ${TEMPDIR}/disk/var/www/html/index.html ] ; then
			rm -f ${TEMPDIR}/disk/var/www/html/index.html || true
		fi
		sync

	fi #RootStock-NG


	if [ ! -f ${TEMPDIR}/etc/udev/rules.d/60-omap-tty.rules ] ; then
		file="/etc/udev/rules.d/60-omap-tty.rules"
		echo "#from: http://arago-project.org/git/meta-ti.git?a=commit;h=4ce69eff28103778508d23af766e6204c95595d3" > ${TEMPDIR}/disk${file}
		echo "" > ${TEMPDIR}/disk${file}
		echo "# Backward compatibility with old OMAP UART-style ttyO0 naming" > ${TEMPDIR}/disk${file}
		echo "" >> ${TEMPDIR}/disk${file}
		echo "SUBSYSTEM==\"tty\", ATTR{uartclk}!=\"0\", KERNEL==\"ttyS[0-9]\", SYMLINK+=\"ttyO%n\"" >> ${TEMPDIR}/disk${file}
		echo "" >> ${TEMPDIR}/disk${file}
	fi

	if [ -f ${TEMPDIR}/disk/etc/init.d/cpufrequtils ] ; then
		sed -i 's/GOVERNOR="ondemand"/GOVERNOR="performance"/g' ${TEMPDIR}/disk/etc/init.d/cpufrequtils
	fi

	if [ ! -f ${TEMPDIR}/disk/opt/scripts/boot/generic-startup.sh ] ; then
		git clone https://github.com/RobertCNelson/boot-scripts ${TEMPDIR}/disk/opt/scripts/ --depth 1
		sudo chown -R 1000:1000 ${TEMPDIR}/disk/opt/scripts/
	else
		cd ${TEMPDIR}/disk/opt/scripts/
		git pull
		cd -
		sudo chown -R 1000:1000 ${TEMPDIR}/disk/opt/scripts/
	fi

	if [ "x${drm}" = "xomapdrm" ] ; then
		wfile="/etc/X11/xorg.conf"
		if [ -f ${TEMPDIR}/disk${wfile} ] ; then
			sudo sed -i -e 's:modesetting:omap:g' ${TEMPDIR}/disk${wfile}
			sudo sed -i -e 's:fbdev:omap:g' ${TEMPDIR}/disk${wfile}

			if [ "x${conf_board}" = "xomap3_beagle" ] ; then
				sudo sed -i -e 's:#HWcursor_false::g' ${TEMPDIR}/disk${wfile}
				sudo sed -i -e 's:#DefaultDepth::g' ${TEMPDIR}/disk${wfile}
			else
				sudo sed -i -e 's:#HWcursor_false::g' ${TEMPDIR}/disk${wfile}
			fi
		fi
	fi

	if [ "x${drm}" = "xetnaviv" ] ; then
		wfile="/etc/X11/xorg.conf"
		if [ -f ${TEMPDIR}/disk${wfile} ] ; then
			if [ -f ${TEMPDIR}/disk/usr/lib/xorg/modules/drivers/armada_drv.so ] ; then
				sudo sed -i -e 's:modesetting:armada:g' ${TEMPDIR}/disk${wfile}
				sudo sed -i -e 's:fbdev:armada:g' ${TEMPDIR}/disk${wfile}
			fi
		fi
	fi

	if [ "${usbnet_mem}" ] ; then
		echo "vm.min_free_kbytes = ${usbnet_mem}" >> ${TEMPDIR}/disk/etc/sysctl.conf
	fi

	if [ "${need_wandboard_firmware}" ] ; then
		http_brcm="https://raw.githubusercontent.com/Freescale/meta-fsl-arm-extra/master/recipes-bsp/broadcom-nvram-config/files/wandboard"
		${dl_quiet} --directory-prefix="${TEMPDIR}/disk/lib/firmware/brcm/" ${http_brcm}/brcmfmac4329-sdio.txt
		${dl_quiet} --directory-prefix="${TEMPDIR}/disk/lib/firmware/brcm/" ${http_brcm}/brcmfmac4330-sdio.txt
	fi

	if [ ! "x${new_hostname}" = "x" ] ; then
		echo "Updating Image hostname too: [${new_hostname}]"

		wfile="/etc/hosts"
		echo "127.0.0.1	localhost" > ${TEMPDIR}/disk${wfile}
		echo "127.0.1.1	${new_hostname}.localdomain	${new_hostname}" >> ${TEMPDIR}/disk${wfile}
		echo "" >> ${TEMPDIR}/disk${wfile}
		echo "# The following lines are desirable for IPv6 capable hosts" >> ${TEMPDIR}/disk${wfile}
		echo "::1     localhost ip6-localhost ip6-loopback" >> ${TEMPDIR}/disk${wfile}
		echo "ff02::1 ip6-allnodes" >> ${TEMPDIR}/disk${wfile}
		echo "ff02::2 ip6-allrouters" >> ${TEMPDIR}/disk${wfile}

		wfile="/etc/hostname"
		echo "${new_hostname}" > ${TEMPDIR}/disk${wfile}
	fi

	# setuid root ping+ping6 - capabilities does not survive tar
	if [ -x  ${TEMPDIR}/disk/bin/ping ] ; then
		echo "making ping/ping6 setuid root"
		chmod u+s ${TEMPDIR}/disk//bin/ping ${TEMPDIR}/disk//bin/ping6
	fi
	cp -v ${TEMPDIR}/dl/bootA.scr ${TEMPDIR}/disk/boot/bootA.scr
	cp -v ${TEMPDIR}/dl/bootB.scr ${TEMPDIR}/disk/boot/bootB.scr

	#${dl_quiet} --directory-prefix="${TEMPDIR}/dl/" http://192.168.4.48/BBG/clang+llvm-7.0.0-armv7a-linux-gnueabihf.tar.xz
	#tar xf ${TEMPDIR}/dl/clang+llvm-7.0.0-armv7a-linux-gnueabihf.tar.xz -C ${TEMPDIR}/disk/home/debian
	#git clone https://github.com/baorepo/update_engine ${TEMPDIR}/disk/home/debian/update_engine 
	sudo chown -R 1000:1000 ${TEMPDIR}/disk/home/seeed
	cd ${TEMPDIR}/disk/
	sync
	sync
	cd "${DIR}/"
	echo "unmount rootfs and data Partition"
	echo "-----------------------------"
	umount  ${TEMPDIR}/disk/home
	umount  ${TEMPDIR}/disk/var
	umount  ${TEMPDIR}/disk/usr/local
	
	if [ "x${enable_openssh}" = "xenable" ] ; then
		umount  ${TEMPDIR}/disk/etc/ssh
	fi
	umount  ${TEMPDIR}/disk/mnt/stateful_partition || true
	umount ${TEMPDIR}/disk || true
	umount ${TEMPDIR}/data || true
	
	echo "disable_rw_mount rootfs Partition"
	echo "-----------------------------"
	sudo blockdev --setrw ${media_prefix}${media_rootfsA_partition}; printf '\377' | sudo dd of=${media_prefix}${media_rootfsA_partition} seek=1127 conv=notrunc count=1 bs=1 status=none
	sudo blockdev --setrw ${media_prefix}${media_rootfsB_partition}; printf '\377' | sudo dd of=${media_prefix}${media_rootfsB_partition} seek=1127 conv=notrunc count=1 bs=1 status=none

	if [ "x${build_img_file}" = "xenable" ] ; then
		sync
		kpartx -d ${media_loop} || true
		losetup -d ${media_loop} || true
	fi

	echo "Finished populating rootfs Partition"
	echo "-----------------------------"

	echo "setup_sdcard.sh script complete"
	if [ -f "${DIR}/user_password.list" ] ; then
		echo "-----------------------------"
		echo "The default user:password for this image:"
		cat "${DIR}/user_password.list"
		echo "-----------------------------"
	fi
	if [ "x${build_img_file}" = "xenable" ] ; then
		echo "Image file: ${imagename}"
		echo "-----------------------------"

#		if [ "x${usb_flasher}" = "x" ] && [ "x${emmc_flasher}" = "x" ] ; then
#			wfile="${imagename}.xz.job.txt"
#			echo "abi=aaa" > ${wfile}
#			echo "conf_image=${imagename}.xz" >> ${wfile}
#			echo "conf_resize=enable" >> ${wfile}
#			echo "conf_partition1_startmb=${conf_boot_startmb}" >> ${wfile}
#
#			case "${conf_boot_fstype}" in
#			fat)
#				echo "conf_partition1_fstype=E" >> ${wfile}
#				;;
#			ext2|ext3|ext4|btrfs)
#				echo "conf_partition1_fstype=L" >> ${wfile}
#				;;
#			esac
#
#			if [ "x${media_rootfsA_partition}" = "x2" ] ; then
#				echo "conf_partition1_endmb=${conf_boot_endmb}" >> ${wfile}
#				echo "conf_partition2_fstype=L" >> ${wfile}
#			fi
#			echo "conf_root_partition=${media_rootfsA_partition}" >> ${wfile}
#		fi
	fi
}

check_mmc () {
	FDISK=$(LC_ALL=C fdisk -l 2>/dev/null | grep "Disk ${media}:" | awk '{print $2}')

	if [ "x${FDISK}" = "x${media}:" ] ; then
		echo ""
		echo "I see..."
		echo ""
		echo "lsblk:"
		lsblk | grep -v sr0
		echo ""
		unset response
		echo -n "Are you 100% sure, on selecting [${media}] (y/n)? "
		read response
		if [ "x${response}" != "xy" ] ; then
			exit
		fi
		echo ""
	else
		echo ""
		echo "Are you sure? I Don't see [${media}], here is what I do see..."
		echo ""
		echo "lsblk:"
		lsblk | grep -v sr0
		echo ""
		exit
	fi
}

process_dtb_conf () {
	if [ "${conf_warning}" ] ; then
		show_board_warning
	fi

	echo "-----------------------------"

	#defaults, if not set...
	case "${bootloader_location}" in
	fatfs_boot)
		conf_boot_startmb=${conf_boot_startmb:-"1"}
		;;
	dd_uboot_boot|dd_spl_uboot_boot)
		conf_boot_startmb=${conf_boot_startmb:-"4"}
		;;
	*)
		conf_boot_startmb=${conf_boot_startmb:-"4"}
		;;
	esac

	#https://wiki.linaro.org/WorkingGroups/KernelArchived/Projects/FlashCardSurvey
	conf_root_device=${conf_root_device:-"/dev/mmcblk0"}

	#error checking...
	if [ ! "${conf_boot_fstype}" ] ; then
		conf_boot_fstype="${ROOTFS_TYPE}"
	fi

	case "${conf_boot_fstype}" in
	fat)
		sfdisk_fstype="0xE"
		;;
	ext2|ext3|ext4|btrfs)
		sfdisk_fstype="L"
		;;
	*)
		echo "Error: [conf_boot_fstype] not recognized, stopping..."
		exit
		;;
	esac

	if [ "x${uboot_cape_overlays}" = "xenable" ] ; then
		echo "U-Boot Overlays Enabled..."
	fi
}

check_dtb_board () {
	error_invalid_dtb=1

	#/hwpack/${dtb_board}.conf
	unset leading_slash
	leading_slash=$(echo ${dtb_board} | grep "/" || unset leading_slash)
	if [ "${leading_slash}" ] ; then
		dtb_board=$(echo "${leading_slash##*/}")
	fi

	#${dtb_board}.conf
	dtb_board=$(echo ${dtb_board} | awk -F ".conf" '{print $1}')
	if [ -f "${DIR}"/hwpack/${dtb_board}.conf ] ; then
		. "${DIR}"/hwpack/${dtb_board}.conf

		boot=${boot_image}
		unset error_invalid_dtb
		process_dtb_conf
	else
		cat <<-__EOF__
			-----------------------------
			ERROR: This script does not currently recognize the selected: [--dtb ${dtb_board}] option..
			Please rerun $(basename $0) with a valid [--dtb <device>] option from the list below:
			-----------------------------
		__EOF__
		cat "${DIR}"/hwpack/*.conf | grep supported
		echo "-----------------------------"
		exit
	fi
}

usage () {
	echo "usage: sudo $(basename $0) --mmc /dev/sdX --dtb <dev board>"
	#tabed to match 
		cat <<-__EOF__
			-----------------------------
			Bugs email: "bugs at rcn-ee.com"

			Required Options:
			--mmc </dev/sdX> or --img <filename.img>

			--dtb <dev board>

			Additional Options:
			        -h --help

			--probe-mmc
			        <list all partitions: sudo ./setup_sdcard.sh --probe-mmc>

			__EOF__
	exit
}

checkparm () {
	if [ "$(echo $1|grep ^'\-')" ] ; then
		echo "E: Need an argument"
		usage
	fi
}

error_invalid_dtb=1

# parse commandline options
while [ ! -z "$1" ] ; do
	case $1 in
	-h|--help)
		usage
		media=1
		;;
	--hostname)
		checkparm $2
		new_hostname="$2"
		;;
	--probe-mmc)
		media="/dev/idontknow"
		check_root
		check_mmc
		;;
	--mmc)
		checkparm $2
		media="$2"
		media_prefix="${media}"
		echo ${media} | grep mmcblk >/dev/null && media_prefix="${media}p"
		check_root
		check_mmc
		;;
	--img|--img-[12468]gb)
		checkparm $2
		name=${2:-image}
		gsize=$(echo "$1" | sed -ne 's/^--img-\([[:digit:]]\+\)gb$/\1/p')
		# --img defaults to --img-2gb
		gsize=${gsize:-2}
		imagename=${name%.img}-${gsize}gb.img
		media="${DIR}/${imagename}"
		build_img_file="enable"
		check_root
		if [ -f "${media}" ] ; then
			rm -rf "${media}" || true
		fi
		#FIXME: (should fit most microSD cards)
		#eMMC: (dd if=/dev/mmcblk1 of=/dev/null bs=1M #MB)
		#Micron   3744MB (bbb): 3925868544 bytes -> 3925.86 Megabyte
		#Kingston 3688MB (bbb): 3867148288 bytes -> 3867.15 Megabyte
		#Kingston 3648MB (x15): 3825205248 bytes -> 3825.21 Megabyte (3648)
		#
		### seek=$((1024 * (700 + (gsize - 1) * 1000)))
		## 1000 1GB = 700 #2GB = 1700 #4GB = 3700
		##  990 1GB = 700 #2GB = 1690 #4GB = 3670
		#
		### seek=$((1024 * (gsize * 850)))
		## x 850 (85%) #1GB = 850 #2GB = 1700 #4GB = 3400
		#
		dd if=/dev/zero of="${media}" bs=1024 count=0 seek=$((1024 * (gsize * 850)))
		;;
	--base_img)
		check_root
		checkparm $2
		name=${2:-image}		
		imagename=${name%.img}.img
		media="${DIR}/${imagename}"
		if [ -f "${media}" ] ; then
			rm -rf "${media}" || true
		fi
		tar xvf base_image.img.tar.bz2
		mv base_image.img ${imagename}
		media="${DIR}/${imagename}"
		echo "media:  [${media}]"
		build_img_file="enable"
		;;
	--dtb)
		checkparm $2
		dtb_board="$2"
		dir_check="${DIR}/"
		kernel_detection
		check_dtb_board
		;;
	--ro)
		conf_var_startmb="2048"
		option_ro_root="enable"
		;;
	--rootfs)
		checkparm $2
		ROOTFS_TYPE="$2"
		;;
	--boot_label)
		checkparm $2
		BOOT_LABEL="$2"
		;;
	--rootfs_label)
		checkparm $2
		ROOTFS_LABEL="$2"
		;;
	--spl)
		checkparm $2
		LOCAL_SPL="$2"
		USE_LOCAL_BOOT=1
		;;
	--bootloader)
		checkparm $2
		LOCAL_BOOTLOADER="$2"
		USE_LOCAL_BOOT=1
		;;
	--use-beta-bootloader)
		USE_BETA_BOOTLOADER=1
		;;
	--a335-flasher)
		oem_blank_eeprom="enable"
		a335_flasher="enable"
		uboot_eeprom="bbb_blank"
		;;
	--bp00-flasher)
		oem_blank_eeprom="enable"
		bp00_flasher="enable"
		;;
	--bbg-flasher)
		oem_blank_eeprom="enable"
		bbg_flasher="enable"
		;;
	--bbgw-flasher)
		oem_blank_eeprom="enable"
		bbgw_flasher="enable"
		;;
	--m10a-flasher)
		oem_blank_eeprom="enable"
		m10a_flasher="enable"
		;;
	--me06-flasher)
		oem_blank_eeprom="enable"
		me06_flasher="enable"
		;;
	--bbb-usb-flasher|--usb-flasher|--oem-flasher)
		oem_blank_eeprom="enable"
		usb_flasher="enable"
		;;
	--bbb-flasher|--emmc-flasher)
		oem_blank_eeprom="enable"
		emmc_flasher="enable"
		uboot_eeprom="bbb_blank"
		;;
	--bbbl-flasher)
		oem_blank_eeprom="enable"
		bbbl_flasher="enable"
		uboot_eeprom="bbbl_blank"
		;;
	--bbbw-flasher)
		oem_blank_eeprom="enable"
		bbbw_flasher="enable"
		uboot_eeprom="bbbw_blank"
		;;
	--bbb-old-bootloader-in-emmc)
		bbb_old_bootloader_in_emmc="enable"
		;;
	--x15-force-revb-flash)
		x15_force_revb_flash="enable"
		;;
	--am57xx-x15-flasher)
		flasher_uboot="beagle_x15_flasher"
		;;
	--am57xx-x15-revc-flasher)
		flasher_uboot="beagle_x15_revc_flasher"
		;;
	--am571x-sndrblock-flasher)
		flasher_uboot="am571x_sndrblock_flasher"
		;;
	--oem-flasher-script)
		checkparm $2
		oem_flasher_script="$2"
		;;
	--oem-flasher-img)
		checkparm $2
		oem_flasher_img="$2"
		;;
	--oem-flasher-eeprom)
		checkparm $2
		oem_flasher_eeprom="$2"
		;;
	--oem-flasher-job)
		checkparm $2
		oem_flasher_job="$2"
		;;
	--enable-systemd)
		echo "--enable-systemd: option is depreciated (enabled by default Jessie+)"
		;;
	--enable-cape-universal)
		enable_cape_universal="enable"
		;;
	--enable-uboot-cape-overlays)
		uboot_cape_overlays="enable"
		;;
	--enable-uboot-pru-rproc-44ti)
		uboot_pru_rproc_44ti="enable"
		;;
	--enable-uboot-pru-rproc-49ti)
		echo "[--enable-uboot-pru-rproc-49ti] is obsolete, use [--enable-uboot-pru-rproc-414ti]"
		exit 2
		;;
	--enable-uboot-pru-rproc-414ti)
		uboot_pru_rproc_414ti="enable"
		;;
	--efi)
		uboot_efi_mode="enable"
		;;
	--offline)
		offline=1
		;;
	--kernel)
		checkparm $2
		kernel_override="$2"
		;;
	--enable-cape)
		checkparm $2
		oobe_cape="$2"
		;;
	--enable-fat-partition)
		enable_fat_partition="enable"
		;;
	--enable-ssh)
		enable_openssh="enable"
		;;
	--force-device-tree)
		checkparm $2
		forced_dtb="$2"
		;;
	esac
	shift
done

if [ ! "${media}" ] ; then
	echo "ERROR: --mmc undefined"
	usage
fi

if [ "${error_invalid_dtb}" ] ; then
	echo "-----------------------------"
	echo "ERROR: --dtb undefined"
	echo "-----------------------------"
	usage
fi

if ! is_valid_rootfs_type ${ROOTFS_TYPE} ; then
	echo "ERROR: ${ROOTFS_TYPE} is not a valid root filesystem type"
	echo "Valid types: ${VALID_ROOTFS_TYPES}"
	exit
fi

unset BTRFS_FSTAB
if [ "x${ROOTFS_TYPE}" = "xbtrfs" ] ; then
	unset NEEDS_COMMAND
	check_for_command mkfs.btrfs btrfs-tools

	if [ "${NEEDS_COMMAND}" ] ; then
		echo ""
		echo "Your system is missing the btrfs dependency needed for this particular target."
		echo "Ubuntu/Debian: sudo apt-get install btrfs-tools"
		echo "Fedora: as root: yum install btrfs-progs"
		echo "Gentoo: emerge btrfs-progs"
		echo ""
		exit
	fi

	BTRFS_FSTAB=1

	if [ ! "x${conf_boot_fstype}" = "xfat" ] ; then
		conf_boot_fstype="btrfs"
	fi
fi

find_issue
detect_software

if [ "${spl_name}" ] || [ "${boot_name}" ] ; then
	if [ "${USE_LOCAL_BOOT}" ] ; then
		local_bootloader
	else
		dl_bootloader
	fi
fi

if [ ! "x${build_img_file}" = "xenable" ] ; then
	unmount_all_drive_partitions
fi
create_partitions
populate_boot
populate_rootfs

exit 0
#
