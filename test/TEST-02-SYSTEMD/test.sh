#!/bin/bash
TEST_DESCRIPTION="root filesystem on a ext3 filesystem"

KVERSION="${KVERSION-$(uname -r)}"

# Uncomment this to debug failures
#DEBUGFAIL="rd.shell loglevel=77 systemd.log_level=debug systemd.log_target=console"
#DEBUGFAIL="rd.shell rd.break=initqueue"
test_run() {
    dd if=/dev/zero of=$TESTDIR/marker.disk bs=1M count=80
    $testdir/run-qemu \
	-hda $TESTDIR/root.ext3 \
	-hdb $TESTDIR/marker.disk \
	-m 256M -smp 2 -nographic \
	-net none -kernel /boot/vmlinuz-$KVERSION \
	-append "root=LABEL=dracut rw loglevel=77 rd.retry=3 rd.info console=ttyS0,115200n81 selinux=0 init=/sbin/init $DEBUGFAIL" \
	-initrd $TESTDIR/initramfs.testing
    grep -F -m 1 -q dracut-root-block-success $TESTDIR/marker.disk || return 1
}

test_setup() {
    rm -f -- $TESTDIR/root.ext3
    rm -f -- $TESTDIR/marker.disk
    # Create the blank file to use as a root filesystem
    dd if=/dev/null of=$TESTDIR/root.ext3 bs=1M seek=80

    kernel=$KVERSION
    # Create what will eventually be our root filesystem onto an overlay
    (
	export initdir=$TESTDIR/overlay/source
	mkdir -p $initdir
	. $basedir/dracut-init.sh
	inst_multiple sh df free ls shutdown poweroff stty cat ps ln ip route \
	    mount dmesg ifconfig dhclient mkdir cp ping dhclient \
	    umount strace less setsid
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
	inst_multiple sfdisk mkfs.ext3 poweroff cp umount
	inst_hook initqueue 01 ./create-root.sh
        inst_hook initqueue/finished 01 ./finished-false.sh
	inst_simple ./99-idesymlinks.rules /etc/udev/rules.d/99-idesymlinks.rules
    )

    # create an initramfs that will create the target root filesystem.
    # We do it this way so that we do not risk trashing the host mdraid
    # devices, volume groups, encrypted partitions, etc.
    $basedir/dracut.sh -l -i $TESTDIR/overlay / \
	-m "udev-rules base rootfs-block fs-lib kernel-modules" \
	-d "piix ide-gd_mod ata_piix ext3 sd_mod" \
        --nomdadmconf \
	-f $TESTDIR/initramfs.makeroot $KVERSION || return 1
    rm -rf -- $TESTDIR/overlay
    # Invoke KVM and/or QEMU to actually create the target filesystem.

    $testdir/run-qemu \
	-hda $TESTDIR/root.ext3 \
	-m 256M -smp 2 -nographic -net none \
	-kernel "/boot/vmlinuz-$kernel" \
	-append "root=/dev/fakeroot rw rootfstype=ext3 quiet console=ttyS0,115200n81 selinux=0" \
	-initrd $TESTDIR/initramfs.makeroot  || return 1
    grep -F -m 1 -q dracut-root-block-created $TESTDIR/root.ext3 || return 1


    (
	export initdir=$TESTDIR/overlay
	. $basedir/dracut-init.sh
	inst_multiple poweroff shutdown
	inst_hook emergency 000 ./hard-off.sh
	inst_simple ./99-idesymlinks.rules /etc/udev/rules.d/99-idesymlinks.rules
    )
    sudo $basedir/dracut.sh -l -i $TESTDIR/overlay / \
	-a "debug systemd" \
	-o "network plymouth" \
	-d "piix ide-gd_mod ata_piix ext3 sd_mod" \
	-f $TESTDIR/initramfs.testing $KVERSION || return 1

#	-o "plymouth network md dmraid multipath fips caps crypt btrfs resume dmsquash-live dm"
}

test_cleanup() {
    return 0
}

. $testdir/test-functions
