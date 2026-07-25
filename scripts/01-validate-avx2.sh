#!/usr/bin/env bash
# =============================================================================
# 01-validate-avx2.sh
#
# RUN THIS: on the Proxmox VE host, via its SSH/console shell (as root).
# PURPOSE:  Prove that a VM with CPU type "host" actually exposes AVX2 to
#           the guest before we build the real dune-prod/dune-dev VMs.
#
# WHY THIS MATTERS: Funcom's self-host requirement is explicit: "A CPU that
# supports AVX2 instructions." Default/generic QEMU CPU models (e.g. "kvm64",
# "qemu64") deliberately mask newer instruction sets for cross-host migration
# compatibility. If you build both real VMs with the wrong CPU type, the
# Dune game server binaries may fail to start, or silently misbehave, and
# you won't find out until deep into the 7/30 stand-up. This script creates
# a small disposable VM, boots a minimal live environment, checks for AVX2,
# and then destroys the test VM. Takes about 5 minutes.
#
# USAGE: bash 01-validate-avx2.sh
# =============================================================================
set -euo pipefail

TEST_VMID=900
ISO_STORAGE="local"   # default Proxmox ISO storage, adjust if yours differs
ISO_NAME="test-avx2-check.iso"

echo "=== AVX2 Passthrough Validation ==="
echo
echo "This will create a temporary test VM (ID $TEST_VMID), boot a minimal"
echo "live Linux environment, check for AVX2 CPU flag support, then destroy"
echo "the test VM. No permanent changes are made to your Proxmox host."
echo

# --- Step 1: confirm the physical host itself actually has AVX2 ------------
echo "--- Checking host CPU for AVX2 support ---"
if grep -q avx2 /proc/cpuinfo; then
  echo "OK: Host CPU (Xeon Gold 6248) reports AVX2 support in /proc/cpuinfo."
else
  echo "FAIL: Host CPU does not report AVX2. This should not happen on a"
  echo "Cascade Lake Xeon Gold 6248 - check for a CPU/BIOS microcode issue"
  echo "before proceeding any further."
  exit 1
fi
echo

# --- Step 2: confirm host CPU type will be used, not a generic model -------
echo "--- Reminder ---"
echo "When you create the real VMs in script 02, the QEMU CPU type MUST be"
echo "set to 'host' (Proxmox UI: VM -> Hardware -> Processors -> Type: host,"
echo "or --cpu host on the qm command line). Do not use 'kvm64', 'qemu64',"
echo "or any specific non-host model name - these can mask AVX2 even though"
echo "the physical CPU supports it."
echo

# --- Step 3: quick automated check using a disposable VM --------------------
# We use a tiny existing rescue/live ISO if present, otherwise instruct the
# user to do a 60-second manual check instead of trying to auto-download an
# ISO (keeps this script offline-safe and fast).

if [ -f "/var/lib/vz/template/iso/${ISO_NAME}" ]; then
  echo "--- Found test ISO, creating disposable VM $TEST_VMID ---"
  qm create "$TEST_VMID" \
    --name "avx2-test" \
    --memory 1024 \
    --cores 2 \
    --cpu host \
    --net0 virtio,bridge=vmbr0 \
    --ide2 "${ISO_STORAGE}:iso/${ISO_NAME},media=cdrom" \
    --boot order=ide2 \
    --scsihw virtio-scsi-pci

  echo "Starting test VM..."
  qm start "$TEST_VMID"

  echo
  echo "ACTION REQUIRED: Open the Proxmox web UI, go to VM $TEST_VMID's"
  echo "Console tab, wait for the live environment to boot, and run:"
  echo
  echo "    cat /proc/cpuinfo | grep avx2"
  echo
  echo "You MUST see 'avx2' in the output. If you see nothing, the CPU type"
  echo "is not passing through correctly - STOP and troubleshoot before"
  echo "proceeding to script 02."
  echo
  read -r -p "Press Enter once you've confirmed avx2 is visible in the guest (or Ctrl+C to abort): "

  echo "Cleaning up test VM..."
  qm stop "$TEST_VMID" || true
  sleep 2
  qm destroy "$TEST_VMID"
  echo "Test VM removed."
else
  echo "--- No test ISO found at /var/lib/vz/template/iso/${ISO_NAME} ---"
  echo
  echo "MANUAL VALIDATION REQUIRED instead. Do this quick check:"
  echo
  echo "1. Download any minimal Linux live ISO (e.g. Alpine standard ISO,"
  echo "   ~200MB, from https://alpinelinux.org/downloads/) to this host:"
  echo "     wget -P /var/lib/vz/template/iso/ <alpine-iso-url>"
  echo
  echo "2. Re-run this script - it will detect the ISO and automate the rest."
  echo
  echo "   OR, do it fully manually via the Proxmox web UI:"
  echo "     a. Create VM ID $TEST_VMID, CPU type 'host', attach the ISO"
  echo "     b. Boot it, open the Console tab"
  echo "     c. Run: cat /proc/cpuinfo | grep avx2"
  echo "     d. Confirm output is non-empty"
  echo "     e. qm stop $TEST_VMID && qm destroy $TEST_VMID"
  echo
  exit 2
fi

echo
echo "=== AVX2 validation complete. Safe to proceed to 02-provision-vms.sh ==="
