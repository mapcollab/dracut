#!/bin/bash
TEST_DESCRIPTION="root filesystem on multiple device btrfs"

KVERSION=${KVERSION-$(uname -r)}

# Uncomment this to debug failures
#DEBUGFAIL="rd.shell"
test_run() {
    DISKIMAGE=$TESTDIR/TEST-15-BTRFSRAID-root.img
    $testdir/run-qemu \
	-hda $DISKIMAGE \
	-m 256M  -smp 2 -nographic \
	-net none -kernel /boot/vmlinuz-$KVERSION \
	-append "root=LABEL=root rw rd.retry=3 rd.info console=ttyS0,115200n81 selinux=0 $DEBUGFAIL" \
	-initrd $TESTDIR/initramfs.testing
    dd if=$DISKIMAGE bs=512 count=2 | grep -F -m 1 -q dracut-root-block-success $DISKIMAGE || return 1
}

test_setup() {
    # Create the blank file to use as a root filesystem
    DISKIMAGE=$TESTDIR/TEST-15-BTRFSRAID-root.img
    rm -f -- $DISKIMAGE
    dd if=/dev/null of=$DISKIMAGE bs=1M seek=1024

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
	inst ./test-init.sh /sbin/init
	inst_simple /etc/os-release
	find_binary plymouth >/dev/null && inst_multiple plymouth
	(cd "$initdir"; mkdir -p dev sys proc etc var/run tmp )
	cp -a /etc/ld.so.conf* $initdir/etc
	sudo ldconfig -r "$initdir"
    )

    # second, install the files needed to make the root filesystem
    (
	export initdir=$TESTDIR/overlay
	. $basedir/dracut-init.sh
	inst_multiple sfdisk mkfs.btrfs poweroff cp umount
	inst_hook initqueue 01 ./create-root.sh
        inst_hook initqueue/finished 01 ./finished-false.sh
	inst_simple ./99-idesymlinks.rules /etc/udev/rules.d/99-idesymlinks.rules
    )

    # create an initramfs that will create the target root filesystem.
    # We do it this way so that we do not risk trashing the host mdraid
    # devices, volume groups, encrypted partitions, etc.
    $basedir/dracut.sh -l -i $TESTDIR/overlay / \
	-m "btrfs udev-rules base rootfs-block fs-lib kernel-modules" \
	-d "piix ide-gd_mod ata_piix btrfs sd_mod" \
        --nomdadmconf \
	-f $TESTDIR/initramfs.makeroot $KVERSION || return 1

    rm -rf -- $TESTDIR/overlay

    # Invoke KVM and/or QEMU to actually create the target filesystem.
    $testdir/run-qemu \
	-hda $DISKIMAGE \
	-m 256M  -smp 2 -nographic -net none \
	-kernel "/boot/vmlinuz-$kernel" \
	-append "root=/dev/fakeroot rw quiet console=ttyS0,115200n81 selinux=0" \
	-initrd $TESTDIR/initramfs.makeroot  || return 1

    dd if=$DISKIMAGE bs=512 count=2 | grep -F -m 1 -q dracut-root-block-created || return 1

   (
        export initdir=$TESTDIR/overlay
	. $basedir/dracut-init.sh
	inst_multiple poweroff shutdown
	inst_hook emergency 000 ./hard-off.sh
	inst_simple ./99-idesymlinks.rules /etc/udev/rules.d/99-idesymlinks.rules
    )
    sudo $basedir/dracut.sh -l -i $TESTDIR/overlay / \
	-o "plymouth network" \
	-a "debug" \
	-d "piix ide-gd_mod ata_piix btrfs sd_mod" \
	-f $TESTDIR/initramfs.testing $KVERSION || return 1
}

test_cleanup() {
    return 0
}

. $testdir/test-functions
