#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

# fixme: assume user is root

check() {
    [[ $mount_needs ]] && return 1

    # If our prerequisites are not met, fail.
    require_binaries ssh scp  || return 1

    if [[ $sshkey ]]; then
        [ ! -f $sshkey ] && {
            derror "ssh key: $sshkey is not found!"
            return 1
        }
    fi

    return 255
}

depends() {
    # We depend on network modules being loaded
    echo network
}

inst_sshenv()
{
    if [ -d /root/.ssh ]; then
        inst_dir /root/.ssh
        chmod 700 ${initdir}/root/.ssh
    fi

    # Copy over ssh key and knowhosts if needed
    [[ $sshkey ]] && {
        inst_simple $sshkey
        [[ -f /root/.ssh/known_hosts ]] && inst_simple /root/.ssh/known_hosts
        [[ -f /etc/ssh/ssh_known_hosts ]] && inst_simple /etc/ssh/ssh_known_hosts
    }

    # Copy over root and system-wide ssh configs.
    [[ -f /root/.ssh/config ]] && inst_simple /root/.ssh/config
    if [[ -f /etc/ssh/ssh_config ]]; then
        inst_simple /etc/ssh/ssh_config
        sed -i -e 's/\(^[[:space:]]*\)ProxyCommand/\1# ProxyCommand/' ${initdir}/etc/ssh/ssh_config
        while read key val; do
            [[ $key != "GlobalKnownHostsFile" ]] && continue
            inst_simple "$val"
            break
        done < /etc/ssh/ssh_config
    fi

    return 0
}

install() {
    inst_multiple ssh scp
    inst_sshenv
}

