#!/bin/bash
# ESP/kernel diagnostic dump for the immutable overlay.
# Run it at every checkpoint:
#   1. host, freshly booted @overlay-init (baseline)
#   2. inside `immutable shell <name>` BEFORE installing anything
#   3. inside `immutable shell <name>` AFTER installing the kernel
#   4. host, AFTER `immutable switch <name>`, BEFORE reboot
# Pass a label so each run is easy to tell apart:
#   bash esp-diag.sh "1-baseline-host"
#
# Every run prints to stdout AND appends to /tmp/esp-diag.log (and, when
# /pool is mounted, also to /pool/@data/esp-diag.log so it survives the
# overlay).

label="${1:-unlabelled}"
stamp=$(date +%F-%H%M%S)

section() {
    echo
    echo "=================================================================="
    echo "== $1"
    echo "=================================================================="
}

dump() {
    {
        echo
        echo "########## $label @ $stamp ##########"
        section "identity"
        hostname
        uname -r
        echo
        echo "-- mounts (/, /boot, /boot/efi) --"
        findmnt -no SOURCE,FSTYPE,OPTIONS / 2>/dev/null
        findmnt -no SOURCE,FSTYPE,OPTIONS /boot/efi 2>/dev/null
        echo
        echo "-- proc cmdline --"
        cat /proc/cmdline 2>/dev/null

        section "current /boot/efi (real ESP if block dev, else overlay copy)"
        echo "-- source --"
        findmnt -no SOURCE /boot/efi 2>/dev/null
        echo
        echo "-- loader/loader.conf --"
        cat /boot/efi/loader/loader.conf 2>/dev/null
        echo
        echo "-- loader/entries --"
        for f in /boot/efi/loader/entries/*.conf; do
            [ -e "$f" ] || continue
            echo "[$f]"
            cat "$f"
        done
        echo
        echo "-- EFI dirs --"
        for d in /boot/efi/EFI/*; do
            [ -e "$d" ] || continue
            echo "[$d]"
            ls -l --full-time "$d" 2>/dev/null
        done

        section "overlay root /boot (kernels + initrds + symlinks)"
        ls -l --full-time /boot/ 2>/dev/null | grep -Ei "vmlinuz|initrd" || ls -l --full-time /boot/ 2>/dev/null
        echo
        section "/lib/modules"
        ls -l /lib/modules/ 2>/dev/null

        section "/etc/fstab"
        cat /etc/fstab 2>/dev/null
        echo
        section "/etc/crypttab"
        cat /etc/crypttab 2>/dev/null

        section "kernelstub config"
        cat /etc/kernelstub/configuration 2>/dev/null | python3 -m json.tool 2>/dev/null || cat /etc/kernelstub/configuration 2>/dev/null

        section "boot-counter / rollback state (in /pool/@data)"
        for f in /pool/@data/boot-counter /pool/@data/boot-last-overlay /pool/@data/rollback-message; do
            [ -e "$f" ] && { echo "[$f]"; cat "$f"; }
        done

        if [ -d /pool ]; then
            section "/pool subvolumes"
            ls /pool/ 2>/dev/null
            echo
            echo "-- last ESP sync times per overlay copy --"
            for s in /pool/@overlay-*/boot/efi /pool/@base/boot/efi; do
                [ -d "$s" ] || continue
                echo "[$s]"
                ls -l --full-time "$s/EFI/"* 2>/dev/null
            done
        fi
        echo
        echo "########## END $label ##########"
    } | tee -a /tmp/esp-diag.log

    if [ -d /pool/@data ]; then
        cp -f /tmp/esp-diag.log /pool/@data/esp-diag.log 2>/dev/null
        echo "(also copied to /pool/@data/esp-diag.log)"
    fi
}

dump
