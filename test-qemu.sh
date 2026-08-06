#!/bin/bash
set -euo pipefail

# Host-side QEMU harness for Immutable Pop!_OS.
#
#   ./test-qemu.sh install <iso>        boot the ISO to run the installer
#   ./test-qemu.sh run                  boot the installed system off disk
#   ./test-qemu.sh clean                delete the test VM disk and UEFI vars
#
# The installed guest is a throwaway test VM at $VM_DIR (default
# /home/system76/vms/immutable-test). Install with the Erase/Clean-Install
# option (the only path that provisions the immutable layout), then use
# `./test-qemu.sh run` and `test-immutable.sh` inside the guest.

VM_DIR="${VM_DIR:-/home/system76/vms/immutable-test}"
VM_DISK="$VM_DIR/disk.qcow2"
VM_VARS="$VM_DIR/vars_4M.fd"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_TMPL="/usr/share/OVMF/OVMF_VARS_4M.fd"
ISO=""
MEM="${MEM:-8192}"
SMP="${SMP:-4}"

QEMU_FLAGS=(
    -enable-kvm
    -machine q35,accel=kvm
    -cpu host
    -smp "$SMP"
    -m "$MEM"
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$VM_VARS"
    -drive file="$VM_DISK",format=qcow2,if=virtio
    -netdev user,id=net0
    -device virtio-net-pci,netdev=net0
    -display gtk
)

case "${1:-run}" in
    install)
        [ $# -ge 2 ] || { echo "usage: $0 install <iso>" >&2; exit 1; }
        ISO="$(realpath "$2")"
        [ -f "$ISO" ] || { echo "ISO not found: $ISO" >&2; exit 1; }
        [ -d "$VM_DIR" ] || mkdir -p "$VM_DIR"
        [ -f "$VM_DISK" ] || qemu-img create -f qcow2 "$VM_DISK" 60G
        [ -f "$VM_VARS" ] || cp "$OVMF_VARS_TMPL" "$VM_VARS"
        echo "==> Booting installer from $ISO"
        echo "    Install with Erase (Clean Install) to exercise immutable provisioning."
        qemu-system-x86_64 "${QEMU_FLAGS[@]}" \
            -drive file="$ISO",media=cdrom,readonly=on \
            -boot order=d
        ;;
    run)
        [ -f "$VM_DISK" ] || { echo "No installed disk yet; run 'install' first." >&2; exit 1; }
        echo "==> Booting installed system"
        qemu-system-x86_64 "${QEMU_FLAGS[@]}" \
            -boot order=c
        ;;
    clean)
        echo "==> Removing $VM_DIR"
        rm -rf "$VM_DIR"
        ;;
    *)
        echo "usage: $0 {install <iso>|run|clean}" >&2
        exit 1
        ;;
esac
