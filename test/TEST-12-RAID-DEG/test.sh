#!/bin/bash
TEST_DESCRIPTION="root filesystem on an encrypted LVM PV on a degraded RAID-5"

KVERSION=${KVERSION-$(uname -r)}

# Uncomment this to debug failures
#DEBUGFAIL="rd.shell rd.break rd.debug"
#DEBUGFAIL="rd.shell rd.break=pre-mount udev.log-priority=debug"
#DEBUGFAIL="rd.shell rd.udev.log-priority=debug loglevel=70 systemd.log_target=kmsg"
#DEBUGFAIL="rd.shell loglevel=70 systemd.log_target=kmsg"

client_run() {
    echo "CLIENT TEST START: $@"
    cp --sparse=always --reflink=auto $TESTDIR/disk2.img $TESTDIR/disk2.img.new
    cp --sparse=always --reflink=auto $TESTDIR/disk3.img $TESTDIR/disk3.img.new

    $testdir/run-qemu \
	-hda $TESTDIR/root.ext2 -m 256M -nographic  -smp 2 \
	-hdc $TESTDIR/disk2.img.new \
	-hdd $TESTDIR/disk3.img.new \
	-net none -kernel /boot/vmlinuz-$KVERSION \
	-append "$* root=LABEL=root rw rd.retry=20 rd.info console=ttyS0,115200n81 selinux=0 rd.debug $DEBUGFAIL " \
	-initrd $TESTDIR/initramfs.testing
    if ! grep -F -m 1 -q dracut-root-block-success $TESTDIR/root.ext2; then
	echo "CLIENT TEST END: $@ [FAIL]"
	return 1;
    fi

    sed -i -e 's#dracut-root-block-success#dracut-root-block-xxxxxxx#' $TESTDIR/root.ext2
    echo "CLIENT TEST END: $@ [OK]"
    return 0
}

test_run() {
    eval $(grep -F --binary-files=text -m 1 MD_UUID $TESTDIR/root.ext2)
    echo "MD_UUID=$MD_UUID"
    read LUKS_UUID < $TESTDIR/luksuuid

    client_run rd.device.timeout=60 failme && return 1
    client_run rd.device.timeout=60 rd.auto || return 1


    client_run rd.device.timeout=60 rd.luks.uuid=$LUKS_UUID rd.md.uuid=$MD_UUID rd.md.conf=0 rd.lvm.vg=dracut || return 1

    client_run rd.device.timeout=60 rd.luks.uuid=$LUKS_UUID rd.md.uuid=failme rd.md.conf=0 rd.lvm.vg=dracut failme && return 1

    client_run rd.device.timeout=60 rd.luks.uuid=$LUKS_UUID rd.md.uuid=$MD_UUID rd.lvm=0 failme && return 1
    client_run rd.device.timeout=60 rd.luks.uuid=$LUKS_UUID rd.md.uuid=$MD_UUID rd.lvm=0 rd.auto=1 failme && return 1
    client_run rd.device.timeout=60 rd.luks.uuid=$LUKS_UUID rd.md.uuid=$MD_UUID rd.lvm.vg=failme failme && return 1
    client_run rd.luks.uuid=$LUKS_UUID rd.md.uuid=$MD_UUID rd.lvm.vg=dracut || return 1
    client_run rd.device.timeout=60 rd.luks.uuid=$LUKS_UUID rd.md.uuid=$MD_UUID rd.lvm.lv=dracut/failme failme && return 1
    client_run rd.luks.uuid=$LUKS_UUID rd.md.uuid=$MD_UUID rd.lvm.lv=dracut/root || return 1

    return 0
}

test_setup() {
    # Create the blank file to use as a root filesystem
    rm -f -- $TESTDIR/root.ext2
    dd if=/dev/null of=$TESTDIR/root.ext2 bs=1M seek=40
    dd if=/dev/null of=$TESTDIR/disk1.img bs=1M seek=20
    dd if=/dev/null of=$TESTDIR/disk2.img bs=1M seek=20
    dd if=/dev/null of=$TESTDIR/disk3.img bs=1M seek=20

    kernel=$KVERSION
    # Create what will eventually be our root filesystem onto an overlay
    (
	export initdir=$TESTDIR/overlay/source
	. $basedir/dracut-init.sh
	inst_multiple sh df free ls shutdown poweroff stty cat ps ln ip route \
	    mount dmesg ifconfig dhclient mkdir cp ping dhclient
        for _terminfodir in /lib/terminfo /etc/terminfo /usr/share/terminfo; do
	    [ -f ${_terminfodir}/l/linux ] && break
	done
	inst_multiple -o ${_terminfodir}/l/linux
	inst "$basedir/modules.d/40network/dhclient-script.sh" "/sbin/dhclient-script"
	inst "$basedir/modules.d/40network/ifup.sh" "/sbin/ifup"
	inst_multiple grep
        inst_simple /etc/os-release
	inst ./test-init.sh /sbin/init
	find_binary plymouth >/dev/null && inst_multiple plymouth
	(cd "$initdir"; mkdir -p dev sys proc etc var/run tmp )
	cp -a /etc/ld.so.conf* $initdir/etc
	sudo ldconfig -r "$initdir"
    )

    # second, install the files needed to make the root filesystem
    (
	export initdir=$TESTDIR/overlay
	. $basedir/dracut-init.sh
	inst_multiple sfdisk mke2fs poweroff cp umount dd grep
	inst_hook initqueue 01 ./create-root.sh
        inst_hook initqueue/finished 01 ./finished-false.sh
 	inst_simple ./99-idesymlinks.rules /etc/udev/rules.d/99-idesymlinks.rules
   )

    # create an initramfs that will create the target root filesystem.
    # We do it this way so that we do not risk trashing the host mdraid
    # devices, volume groups, encrypted partitions, etc.
    $basedir/dracut.sh -l -i $TESTDIR/overlay / \
	-m "crypt lvm mdraid udev-rules base rootfs-block fs-lib kernel-modules" \
	-d "piix ide-gd_mod ata_piix ext2 sd_mod" \
	-f $TESTDIR/initramfs.makeroot $KVERSION || return 1
    rm -rf -- $TESTDIR/overlay
    # Invoke KVM and/or QEMU to actually create the target filesystem.
    $testdir/run-qemu \
	-hda $TESTDIR/root.ext2 \
	-hdb $TESTDIR/disk1.img \
	-hdc $TESTDIR/disk2.img \
	-hdd $TESTDIR/disk3.img \
	-m 256M -smp 2 -nographic -net none \
	-kernel "/boot/vmlinuz-$kernel" \
	-append "root=/dev/fakeroot rw rootfstype=ext2 quiet console=ttyS0,115200n81 selinux=0" \
	-initrd $TESTDIR/initramfs.makeroot  || return 1

    grep -F -m 1 -q dracut-root-block-created $TESTDIR/root.ext2 || return 1
    eval $(grep -F --binary-files=text -m 1 MD_UUID $TESTDIR/root.ext2)
    eval $(grep -F -a -m 1 ID_FS_UUID $TESTDIR/root.ext2)
    echo $ID_FS_UUID > $TESTDIR/luksuuid

    (
	export initdir=$TESTDIR/overlay
	. $basedir/dracut-init.sh
	inst_multiple poweroff shutdown
	inst_hook emergency 000 ./hard-off.sh
	inst_simple ./99-idesymlinks.rules /etc/udev/rules.d/99-idesymlinks.rules
	inst ./cryptroot-ask.sh /sbin/cryptroot-ask
        mkdir -p $initdir/etc
        echo "ARRAY /dev/md0 level=raid5 num-devices=3 UUID=$MD_UUID" > $initdir/etc/mdadm.conf
        echo "luks-$ID_FS_UUID UUID=$ID_FS_UUID /etc/key" > $initdir/etc/crypttab
        echo -n test > $initdir/etc/key
    )

    sudo $basedir/dracut.sh -l -i $TESTDIR/overlay / \
	-o "plymouth network" \
	-a "debug" \
	-d "piix ide-gd_mod ata_piix ext2 sd_mod" \
	-f $TESTDIR/initramfs.testing $KVERSION || return 1
}

test_cleanup() {
    return 0
}

. $testdir/test-functions
