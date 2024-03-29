#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

check() {
    # If our prerequisites are not met, fail anyways.
    require_binaries mount.cifs || return 1

    [[ $hostonly ]] || [[ $mount_needs ]] && {
        for fs in ${host_fs_types[@]}; do
            [[ "$fs" == "cifs" ]] && return 0
        done
        return 255
    }

    return 0
}

depends() {
    # We depend on network modules being loaded
    echo network
}

installkernel() {
    instmods cifs ipv6
}

install() {
    local _i
    local _nsslibs
    inst_multiple -o mount.cifs
    inst_multiple /etc/services /etc/nsswitch.conf /etc/protocols

    inst_libdir_file 'libcap-ng.so*'

    _nsslibs=$(sed -e '/^#/d' -e 's/^.*://' -e 's/\[NOTFOUND=return\]//' /etc/nsswitch.conf \
        |  tr -s '[:space:]' '\n' | sort -u | tr -s '[:space:]' '|')
    _nsslibs=${_nsslibs#|}
    _nsslibs=${_nsslibs%|}

    inst_libdir_file -n "$_nsslibs" 'libnss_*.so*'

    inst_hook cmdline 90 "$moddir/parse-cifsroot.sh"
    inst "$moddir/cifsroot.sh" "/sbin/cifsroot"
    inst "$moddir/cifs-lib.sh" "/lib/cifs-lib.sh"
    dracut_need_initqueue
}
