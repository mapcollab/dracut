#!/bin/bash
TEST_DESCRIPTION="root filesystem on LVM PV on a isw dmraid"

KVERSION=${KVERSION-$(uname -r)}

# Uncomment this to debug failures
#DEBUGFAIL="rd.shell"
#DEBUGFAIL="$DEBUGFAIL udev.log-priority=debug"

client_run() {
    echo "CLIENT TEST START: $@"
    $testdir/run-qemu \
	-hda $TESTDIR/root.ext2 \
	-hdb $TESTDIR/disk1 \
	-hdc $TESTDIR/disk2 \
	-m 256M -nographic \
	-net none -kernel /boot/vmlinuz-$KVERSION \
	-append "$* root=LABEL=root rw debug rd.retry=20 rd.debug console=ttyS0,115200n81 selinux=0 rd.info $DEBUGFAIL" \
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
    read MD_UUID < $TESTDIR/mduuid
    client_run rd.auto rd.md.imsm=0 || return 1
    client_run rd.auto rd.md.uuid=$MD_UUID rd.dm=0 || return 1
    # This test succeeds, because the mirror parts are found without
    # assembling the mirror itsself, which is what we want
    client_run rd.auto rd.md.uuid=$MD_UUID rd.md=0 rd.md.imsm failme rd.device.timeout=40 && return 1
    client_run rd.auto rd.md.uuid=$MD_UUID rd.md=0 failme rd.device.timeout=40 && return 1
    # the following test hangs on newer md
    client_run rd.auto rd.md.uuid=$MD_UUID rd.dm=0 rd.md.imsm rd.md.conf=0 || return 1
   return 0
}

test_setup() {

    # Create the blank file to use as a root filesystem
    rm -f -- $TESTDIR/root.ext2
    rm -f -- $TESTDIR/disk1
    rm -f -- $TESTDIR/disk2
    dd if=/dev/null of=$TESTDIR/root.ext2 bs=1M seek=1
    dd if=/dev/null of=$TESTDIR/disk1 bs=1M seek=80
    dd if=/dev/null of=$TESTDIR/disk2 bs=1M seek=80

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
	inst_simple /etc/os-release
	inst "$basedir/modules.d/40network/dhclient-script.sh" "/sbin/dhclient-script"
	inst "$basedir/modules.d/40network/ifup.sh" "/sbin/ifup"
	inst_multiple grep
	inst ./test-init.sh /sbin/init
	find_binary plymouth >/dev/null && inst_multiple plymouth
	(cd "$initdir"; mkdir -p dev sys proc etc var/run tmp )
	cp -a /etc/ld.so.conf* $initdir/etc
	mkdir $initdir/run
	sudo ldconfig -r "$initdir"
    )

    # second, install the files needed to make the root filesystem
    (
	export initdir=$TESTDIR/overlay
	. $basedir/dracut-init.sh
	inst_multiple sfdisk mke2fs poweroff cp umount grep
	inst_hook initqueue 01 ./create-root.sh
	inst_simple ./99-idesymlinks.rules /etc/udev/rules.d/99-idesymlinks.rules
    )

    # create an initramfs that will create the target root filesystem.
    # We do it this way so that we do not risk trashing the host mdraid
    # devices, volume groups, encrypted partitions, etc.
    $basedir/dracut.sh -l -i $TESTDIR/overlay / \
	-m "lvm mdraid dmraid udev-rules base rootfs-block fs-lib kernel-modules" \
	-d "piix ide-gd_mod ata_piix ext2 sd_mod dm-multipath dm-crypt dm-round-robin faulty linear multipath raid0 raid10 raid1 raid456" \
	-f $TESTDIR/initramfs.makeroot $KVERSION || return 1
    rm -rf -- $TESTDIR/overlay
    # Invoke KVM and/or QEMU to actually create the target filesystem.
    $testdir/run-qemu \
	-hda $TESTDIR/root.ext2 \
	-hdb $TESTDIR/disk1 \
	-hdc $TESTDIR/disk2 \
	-m 256M -nographic -net none \
	-kernel "/boot/vmlinuz-$kernel" \
	-append "root=/dev/dracut/root rw rootfstype=ext2 quiet console=ttyS0,115200n81 selinux=0" \
	-initrd $TESTDIR/initramfs.makeroot  || return 1
    grep -F -m 1 -q dracut-root-block-created $TESTDIR/root.ext2 || return 1
    eval $(grep -F --binary-files=text -m 1 MD_UUID $TESTDIR/root.ext2)
    echo $MD_UUID > $TESTDIR/mduuid
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
	-d "piix ide-gd_mod ata_piix ext2 sd_mod" \
	-f $TESTDIR/initramfs.testing $KVERSION || return 1
}

test_cleanup() {
    return 0
}

. $testdir/test-functions
