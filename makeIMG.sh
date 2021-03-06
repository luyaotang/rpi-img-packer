#!/bin/bash

IMG=raspberrypi.img
TAR=raspberrypi.tar.gz
SRC_ROOT=/mnt/root-ro
SRC_BOOT=/boot
SRC_DEV=/dev/mmcblk0
DST=/mnt/USB
# Add 200MB in image for safety.
ADD_SPACE=204800

if [ $UID -ne 0 ]; then
	echo "Superuser privileges are required to run this script."
	echo "e.g. \"sudo $0\""
	exit 1
fi

cd "$(dirname "${BASH_SOURCE-$0}")"
SCRIPT_DIR=`pwd`

if [ `df | grep 'root-ro' | wc -l` -eq 0 ]; then
	echo "Installing needed packages..."
	apt-get install -y dosfstools parted kpartx rsync
	echo "Cleaning apt & raspberrypi.* ..."
	apt-get clean && apt-get autoclean
else
	if [ `dpkg -l | grep "dosfstools" | wc -l` -lt 1 ] || [ `dpkg -l | grep "parted" | wc -l` -lt 1 ] || [ `dpkg -l | grep "kpartx" | wc -l` -lt 1 ] || [ `dpkg -l | grep "rsync" | wc -l` -lt 1 ]; then
		echo "Info: You need install dosfstools parted kpartx rsync first"
		echo "e.g. \"sudo apt-get install dosfstools parted kpartx rsync\""
		exit 1
	fi
fi

cd $DST
rm $IMG $TAR

df=`df -P | awk '$6=="'$SRC_ROOT'"{print $3}'`
dr=`df -P | awk '$6=="'$SRC_BOOT'"{print $2}'`
df=`echo $df $dr $ADD_SPACE | awk '{print int(($1+$2+$3)/1024+1)*1024}'`  # add 200MB

echo "Making image size=${df}KB"
dd if=/dev/zero of=$IMG bs=1K count=$df
parted $IMG --script -- mklabel msdos
start=`fdisk -l $SRC_DEV | awk '$1=="'$SRC_DEV'p1"{print $2}'`
start=`echo $start's'`
end=`fdisk -l $SRC_DEV | awk '$1=="'$SRC_DEV'p1"{print $3}'`
if [ $end -lt 262143 ]; then
	echo -e "The boot partition is less than 128MB, would you like to expand it? (Y/N)\c"
	read A
	if [[ $A == Y* ]] || [[ $A == y* ]]; then
		end=262143
	fi
fi
end2=$[end+1]
end=`echo $end's'`
end2=`echo $end2's'`

echo "Making file systems"
parted $IMG --script -- mkpart primary fat32 $start $end
parted $IMG --script -- mkpart primary ext4 $end2 -1

loopdevice=`losetup -f --show $IMG`
device=`kpartx -va $loopdevice | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
device="/dev/mapper/${device}"
partBoot="${device}p1"
partRoot="${device}p2"
sleep 5
mkfs.vfat -F 32 $partBoot
mkfs.ext4 $partRoot

# make the same PTUUID
PT_UUID=`blkid $SRC_DEV | awk '{print $2}' | awk -F'"' '{print $2}'`
fdisk "${loopdevice}" << EOF > /dev/null 2>&1
p
x
i
0x${PT_UUID}
r
p
w
EOF

echo -e "Continue to copy files? (Y/N)\c"
read A
if [[ $A == Y* ]] || [[ $A == y* ]]; then
	rm -rf /media/B
	rm -rf /media/R
	mkdir /media/B
	mkdir /media/R
	mount -t vfat $partBoot /media/B
	mount -t ext4 $partRoot /media/R
	cp -rfp $SRC_BOOT/* /media/B/
	cd /media/R
	rsync -aP --exclude="$IMG" --exclude=".cache" --exclude=/backup/* --exclude=/var/cache/* --exclude=/media/* --exclude=/run/* --exclude=/sys/* --exclude=/boot/* --exclude=/proc/* --exclude=/tmp/* --exclude=/var/swap --exclude=/var/lib/dhcpcd5/* --exclude=/var/lib/dhcp/* --exclude=/root/mnt/log.ipv* $SRC_ROOT/ ./ > /dev/null
	touch /media/R/var/lib/dhcp/dhclient.leases
	cd
	
	#在这里开始修改文件
	echo -e "Use the resizing script with root-ro? (Y/N)\c"
	read A
	if [[ $A == Y* ]] || [[ $A == y* ]]; then
		echo "Making auto-resizing script"
		str=`cat /media/B/cmdline.txt`
		str="disable-root-ro=true quiet init=/usr/lib/raspi-config/init_resize_ro.sh $str"
		echo "$str" > /media/B/cmdline.txt
		cp "${SCRIPT_DIR}/init_resize_ro.sh" /media/R/usr/lib/raspi-config/init_resize_ro.sh
		chmod +x /media/R/usr/lib/raspi-config/init_resize_ro.sh
	fi
	
	#其他文件修改需要在这之前做
	echo -e "Umount now? (Y/N)\c"
	read B
	if [[ $B == Y* ]] || [[ $B == y* ]]; then
		umount -fl /media/B
		umount -fl /media/R

		kpartx -d $loopdevice
		losetup -d $loopdevice

		echo -e "Compress now? (Y/N)\c"
		read C
		if [[ $C == Y* ]] || [[ $C == y* ]]; then
			tar zcvf $TAR $IMG
		fi
	fi
else
	kpartx -d $loopdevice
	losetup -d $loopdevice
fi
