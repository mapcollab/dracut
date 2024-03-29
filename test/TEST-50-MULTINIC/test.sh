#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh
TEST_DESCRIPTION="root filesystem on NFS with multiple nics"

KVERSION=${KVERSION-$(uname -r)}

# Uncomment this to debug failures
#DEBUGFAIL="rd.shell"
#SERIAL="tcp:127.0.0.1:9999"

run_server() {
    # Start server first
    echo "MULTINIC TEST SETUP: Starting DHCP/NFS server"

    fsck -a "$TESTDIR"/server.ext3 || return 1
    $testdir/run-qemu \
        -hda "$TESTDIR"/server.ext3 \
        -m 512M -smp 2 \
        -display none \
        -net socket,listen=127.0.0.1:12350 \
        -net nic,macaddr=52:54:01:12:34:56,model=e1000 \
        ${SERIAL:+-serial "$SERIAL"} \
        -watchdog i6300esb -watchdog-action poweroff \
        -kernel /boot/vmlinuz-"$KVERSION" \
        -append "loglevel=7 root=/dev/sda rootfstype=ext3 rw console=ttyS0,115200n81 selinux=0" \
        -initrd "$TESTDIR"/initramfs.server \
        -pidfile "$TESTDIR"/server.pid -daemonize || return 1
    sudo chmod 644 -- "$TESTDIR"/server.pid || return 1

    # Cleanup the terminal if we have one
    tty -s && stty sane

    echo Sleeping 10 seconds to give the server a head start
    sleep 10
}

client_test() {
    local test_name="$1"
    local mac1="$2"
    local mac2="$3"
    local mac3="$4"
    local cmdline="$5"
    local check="$6"

    echo "CLIENT TEST START: $test_name"

    # Need this so kvm-qemu will boot (needs non-/dev/zero local disk)
    if ! dd if=/dev/zero of="$TESTDIR"/client.img bs=1M count=1; then
        echo "Unable to make client sda image" 1>&2
        return 1
    fi

    $testdir/run-qemu -hda "$TESTDIR"/client.img -m 512M -smp 2 -nographic \
        -net socket,connect=127.0.0.1:12350 \
        -net nic,macaddr=52:54:00:12:34:$mac1,model=e1000 \
        -net nic,macaddr=52:54:00:12:34:$mac2,model=e1000 \
        -net nic,macaddr=52:54:00:12:34:$mac3,model=e1000 \
        -watchdog i6300esb -watchdog-action poweroff \
        -kernel /boot/vmlinuz-"$KVERSION" \
        -append "$cmdline $DEBUGFAIL rd.retry=5 rw console=ttyS0,115200n81 selinux=0 init=/sbin/init rd.debug systemd.log_target=console loglevel=7" \
        -initrd "$TESTDIR"/initramfs.testing

    { read OK; read IFACES; } < "$TESTDIR"/client.img

    if [[ "$OK" != "OK" ]]; then
        echo "CLIENT TEST END: $test_name [FAILED - BAD EXIT]"
        return 1
    fi

    for i in $check; do
        if [[ " $IFACES " != *\ $i\ * ]]; then
            echo "$i not in '$IFACES'"
            echo "CLIENT TEST END: $test_name [FAILED - BAD IF]"
            return 1
        fi
    done

    for i in $IFACES; do
        if [[ " $check " != *\ $i\ * ]]; then
            echo "$i in '$IFACES', but should not be"
            echo "CLIENT TEST END: $test_name [FAILED - BAD IF]"
            return 1
        fi
    done

    echo "CLIENT TEST END: $test_name [OK]"
    return 0
}


test_run() {
    if ! run_server; then
        echo "Failed to start server" 1>&2
        return 1
    fi
    test_client || { kill_server; return 1; }
}

test_client() {
    # Mac Numbering Scheme
    # ...:00-02 receive IP adresses all others don't
    # ...:02 receives a dhcp root-path

    # Require three interfaces with dhcp root-path
    # PXE Style BOOTIF=
    client_test "MULTINIC root=nfs BOOTIF=" \
        00 01 02 \
        "root=nfs:192.168.50.1:/nfs/client BOOTIF=52-54-00-12-34-00" \
        "ens3" || return 1

    client_test "MULTINIC root=nfs BOOTIF= ip=ens4:dhcp" \
        00 01 02 \
        "root=nfs:192.168.50.1:/nfs/client BOOTIF=52-54-00-12-34-00 ip=ens4:dhcp" \
        "ens3 ens4" || return 1

    # PXE Style BOOTIF= with dhcp root-path
    client_test "MULTINIC root=dhcp BOOTIF=" \
        00 01 02 \
        "root=dhcp BOOTIF=52-54-00-12-34-02" \
        "ens5" || return 1

    # Multinic case, where only one nic works
    client_test "MULTINIC root=nfs ip=dhcp" \
        FF 00 FE \
        "root=nfs:192.168.50.1:/nfs/client ip=dhcp" \
        "ens4" || return 1

    # Require two interfaces
    client_test "MULTINIC root=nfs ip=ens4:dhcp ip=ens5:dhcp bootdev=ens4" \
        00 01 02 \
        "root=nfs:192.168.50.1:/nfs/client ip=ens4:dhcp ip=ens5:dhcp bootdev=ens4" \
        "ens4 ens5" || return 1

    # Require three interfaces with dhcp root-path
    client_test "MULTINIC root=dhcp ip=ens3:dhcp ip=ens4:dhcp ip=ens5:dhcp bootdev=ens5" \
        00 01 02 \
        "root=dhcp ip=ens3:dhcp ip=ens4:dhcp ip=ens5:dhcp bootdev=ens5" \
        "ens3 ens4 ens5" || return 1

    # bonding test
    client_test "MULTINIC root=dhcp rd.neednet=1 bond=bond0:ens3,ens4 ip=bond0:dhcp ip=ens5:dhcp bootdev=ens5" \
        00 01 02 \
        "root=dhcp rd.neednet=1 bond=bond0:ens3,ens4 ip=bond0:dhcp ip=ens5:dhcp bootdev=ens5" \
        "bond0 ens5" || return 1

    # multiple bonding test
    client_test "MULTINIC root=dhcp rd.neednet=1 bond=bond0:ens3 bond=bond1:ens4 ip=bond0:dhcp ip=ens5:dhcp bootdev=ens5" \
        00 01 02 \
        "root=dhcp rd.neednet=1 bond=bond0:ens3 bond=bond1:ens4 ip=bond0:dhcp ip=bond1:dhcp ip=ens5:dhcp bootdev=ens5" \
        "bond0 bond1 ens5" || return 1

    kill_server
    return 0
}

test_setup() {
     # Make server root
    dd if=/dev/null of="$TESTDIR"/server.ext3 bs=1M seek=60
    mke2fs -j -F -- "$TESTDIR"/server.ext3
    mkdir -- "$TESTDIR"/mnt
    sudo mount -o loop -- "$TESTDIR"/server.ext3 "$TESTDIR"/mnt

    (
        export initdir="$TESTDIR"/mnt
        . "$basedir"/dracut-init.sh

        (
            cd "$initdir";
            mkdir -p -- dev sys proc run etc var/run tmp var/lib/{dhcpd,rpcbind}
            mkdir -p -- var/lib/nfs/{v4recovery,rpc_pipefs}
            chmod 777 -- var/lib/rpcbind var/lib/nfs
        )

        for _f in modules.builtin.bin modules.builtin; do
            [[ $srcmods/$_f ]] && break
        done || {
            dfatal "No modules.builtin.bin and modules.builtin found!"
            return 1
        }

        for _f in modules.builtin.bin modules.builtin modules.order; do
            [[ $srcmods/$_f ]] && inst_simple "$srcmods/$_f" "/lib/modules/$kernel/$_f"
        done

        inst_multiple sh ls shutdown poweroff stty cat ps ln ip \
            dmesg mkdir cp ping exportfs \
            modprobe rpc.nfsd rpc.mountd showmount tcpdump \
            /etc/services sleep mount chmod
        for _terminfodir in /lib/terminfo /etc/terminfo /usr/share/terminfo; do
            [ -f "${_terminfodir}"/l/linux ] && break
        done
        inst_multiple -o "${_terminfodir}"/l/linux
        type -P portmap >/dev/null && inst_multiple portmap
        type -P rpcbind >/dev/null && inst_multiple rpcbind
        [ -f /etc/netconfig ] && inst_multiple /etc/netconfig
        type -P dhcpd >/dev/null && inst_multiple dhcpd
        [ -x /usr/sbin/dhcpd3 ] && inst /usr/sbin/dhcpd3 /usr/sbin/dhcpd
        instmods nfsd sunrpc ipv6 lockd af_packet
        inst_simple /etc/os-release
        inst ./server-init.sh /sbin/init
        inst ./hosts /etc/hosts
        inst ./exports /etc/exports
        inst ./dhcpd.conf /etc/dhcpd.conf
        inst_multiple /etc/nsswitch.conf /etc/rpc /etc/protocols

        inst_multiple rpc.idmapd /etc/idmapd.conf

        inst_libdir_file 'libnfsidmap_nsswitch.so*'
        inst_libdir_file 'libnfsidmap/*.so*'
        inst_libdir_file 'libnfsidmap*.so*'

        _nsslibs=$(sed -e '/^#/d' -e 's/^.*://' -e 's/\[NOTFOUND=return\]//' /etc/nsswitch.conf \
            |  tr -s '[:space:]' '\n' | sort -u | tr -s '[:space:]' '|')
        _nsslibs=${_nsslibs#|}
        _nsslibs=${_nsslibs%|}

        inst_libdir_file -n "$_nsslibs" 'libnss_*.so*'

        inst /etc/nsswitch.conf /etc/nsswitch.conf
        inst /etc/passwd /etc/passwd
        inst /etc/group /etc/group

        cp -a -- /etc/ld.so.conf* "$initdir"/etc
        sudo ldconfig -r "$initdir"
        dracut_kernel_post
    )

    # Make client root inside server root
    (
        export initdir="$TESTDIR"/mnt/nfs/client
        . "$basedir"/dracut-init.sh
        inst_multiple sh shutdown poweroff stty cat ps ln ip \
            mount dmesg mkdir cp ping grep ls
        for _terminfodir in /lib/terminfo /etc/terminfo /usr/share/terminfo; do
            [[ -f ${_terminfodir}/l/linux ]] && break
        done
        inst_multiple -o "${_terminfodir}"/l/linux
        inst_simple /etc/os-release
        inst ./client-init.sh /sbin/init
        (
            cd "$initdir"
            mkdir -p -- dev sys proc etc run
            mkdir -p -- var/lib/nfs/rpc_pipefs
        )
        inst /etc/nsswitch.conf /etc/nsswitch.conf
        inst /etc/passwd /etc/passwd
        inst /etc/group /etc/group

        inst_multiple rpc.idmapd /etc/idmapd.conf
        inst_libdir_file 'libnfsidmap_nsswitch.so*'
        inst_libdir_file 'libnfsidmap/*.so*'
        inst_libdir_file 'libnfsidmap*.so*'

        _nsslibs=$(sed -e '/^#/d' -e 's/^.*://' -e 's/\[NOTFOUND=return\]//' -- /etc/nsswitch.conf \
            |  tr -s '[:space:]' '\n' | sort -u | tr -s '[:space:]' '|')
        _nsslibs=${_nsslibs#|}
        _nsslibs=${_nsslibs%|}

        inst_libdir_file -n "$_nsslibs" 'libnss_*.so*'

        cp -a -- /etc/ld.so.conf* "$initdir"/etc
        sudo ldconfig -r "$initdir"
    )

    sudo umount "$TESTDIR"/mnt
    rm -fr -- "$TESTDIR"/mnt

    # Make an overlay with needed tools for the test harness
    (
        export initdir="$TESTDIR"/overlay
        . "$basedir"/dracut-init.sh
        inst_multiple poweroff shutdown
        inst_hook emergency 000 ./hard-off.sh
        inst_simple ./99-idesymlinks.rules /etc/udev/rules.d/99-idesymlinks.rules
    )

    # Make server's dracut image
    $basedir/dracut.sh -l -i "$TESTDIR"/overlay / \
        -m "udev-rules base rootfs-block fs-lib debug kernel-modules watchdog" \
        -d "af_packet piix ide-gd_mod ata_piix ext3 sd_mod nfsv2 nfsv3 nfsv4 nfs_acl nfs_layout_nfsv41_files nfsd e1000 i6300esb ib700wdt" \
        -f "$TESTDIR"/initramfs.server "$KVERSION" || return 1

    # Make client's dracut image
    $basedir/dracut.sh -l -i "$TESTDIR"/overlay / \
        -o "plymouth" \
        -a "debug" \
        -d "af_packet piix sd_mod sr_mod ata_piix ide-gd_mod e1000 nfsv2 nfsv3 nfsv4 nfs_acl nfs_layout_nfsv41_files sunrpc i6300esb ib700wdt" \
        -f "$TESTDIR"/initramfs.testing "$KVERSION" || return 1
}

kill_server() {
    if [[ -s "$TESTDIR"/server.pid ]]; then
        sudo kill -TERM -- $(cat "$TESTDIR"/server.pid)
        rm -f -- "$TESTDIR"/server.pid
    fi
}

test_cleanup() {
    kill_server
}

. "$testdir"/test-functions
