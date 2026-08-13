#!/usr/bin/env bash
# =============================================================================
# 02-provision-vms.sh
#
# RUN THIS: on the Proxmox VE host, via its SSH/console shell (as root).
# PURPOSE:  Create the dune-prod and dune-dev VM shells with the correct
#           CPU type, memory, vCPU pinning, and network bridge assignment.
#           This does NOT install an OS - after this script, you attach the
#           Ubuntu Server 26.04 ISO and install the OS interactively through
#           the Proxmox console (no way to script an OS install reliably
#           here, and you shouldn't want to - you want to see it happen).
#
# PREREQ:   - 01-validate-avx2.sh has passed
#           - VLANs 20 (Prod) and 21 (Dev) exist on your network/bridge
#             config (see docs/02-network-setup.md)
#           - Ubuntu Server 26.04 LTS ISO uploaded to Proxmox local storage
#             (Datacenter -> local storage -> ISO Images -> Upload)
#
# SIZING RATIONALE (2026-08-07 revision — 2x Sietch @40p + 4x DD + dynamics):
#   dune-prod: 152 GB RAM, 40 vCPU, pinned to ALL of NUMA node 0's logical
#              CPUs (40 logical CPUs = all 20 physical cores' worth of
#              hyperthreads on this socket -- see the NODE0_CPUS detection
#              block below for why this is detected at runtime rather than
#              hardcoded as a numeric range)
#              Always-on baseline: 2 Sietch @16GB (32) + 4 DD @16GB (64) +
#              Overmap 3GB + Arrakeen+Harko always-on 6GB + support+bot 6GB = 111 GB
#              Dynamic peak: ~30 GB (10 concurrent dungeons/overlands @ 3 GB)
#              CPU peak: ~52 vCPU (2 Sietch @40p loaded + 4 DD + 10 dynamic maps)
#              Headroom: 11 GB / CPU oversubscription safe (Proxmox scheduler)
#   dune-dev:  50 GB RAM, 20 vCPU, pinned to a 20-CPU subset of NUMA node 1's
#              logical CPUs (detected at runtime, same reasoning as above)
#              1 Sietch @16GB + 1 DD peak @16GB + Overmap 3GB + support 5GB
#              + dynamic peak 10GB = 50 GB (tight but dev-only, no SLA)
#
# NUMA CORRECTION (2026-08-13): the CPU pinning in this script previously
# assumed socket 0 = a contiguous logical CPU range (e.g. "0-19") and
# socket 1 = the next contiguous range (e.g. "20-39" or "20-29"). This is
# WRONG on hosts where the kernel numbers logical CPUs interleaved across
# sockets (socket 0 = all even IDs, socket 1 = all odd IDs) rather than in
# two contiguous blocks -- confirmed via a live host's real `lscpu -p`
# output, not assumed from "N cores/socket" arithmetic. A contiguous-range
# affinity on an interleaved host silently mixes both sockets roughly
# 50/50, achieving none of the single-socket isolation this sizing's NUMA
# latency reasoning depends on. This script now detects each NUMA node's
# real CPU list at runtime via `lscpu -p=CPU,NODE` instead of hardcoding a
# range -- do not revert to a hardcoded range without re-verifying against
# this exact host's actual topology first.
#
# USAGE: bash 02-provision-vms.sh
# =============================================================================
set -euo pipefail

# --- Adjust these if your environment differs ------------------------------
STORAGE="local-lvm"          # where VM disks live; check `pvesm status` if unsure
ISO_STORAGE="local"
UBUNTU_ISO="ubuntu-26.04-live-server-amd64.iso"   # must already be uploaded

PROD_VMID=101
PROD_NAME="dune-prod"
PROD_BRIDGE="vmbr0"          # bridge carrying VLAN 20 - adjust to your bridge name
PROD_VLAN=20
PROD_MEM=155648              # 152 GB in MiB (2 Sietch @ 16 GB + 4 DD @ 16 GB + Overmap 3 GB + hubs 6 GB + support 5 GB + dynamic peak 30 GB + 11 GB buffer)
PROD_CORES=40
PROD_DISK_GB=300

DEV_VMID=102
DEV_NAME="dune-dev"
DEV_BRIDGE="vmbr0"           # bridge carrying VLAN 21 - adjust to your bridge name
DEV_VLAN=21
DEV_MEM=51200                # 50 GB in MiB (1 Sietch @ 16 GB + DD peak 16 GB + Overmap 3 GB + support 5 GB + dynamic 10 GB)
DEV_CORES=20
DEV_DISK_GB=300

echo "=== Provisioning dune-prod (VMID $PROD_VMID) ==="

if ! [ -f "/var/lib/vz/template/iso/${UBUNTU_ISO}" ] 2>/dev/null; then
  echo "WARNING: Ubuntu ISO not found at expected path. Confirm it's uploaded"
  echo "under Datacenter -> local storage -> ISO Images before continuing,"
  echo "or adjust ISO_STORAGE/UBUNTU_ISO variables in this script."
  echo
fi

# --- Determine this host's REAL per-NUMA-node CPU list ----------------------
# Do NOT assume socket 0 = a contiguous low range of logical CPU IDs and
# socket 1 = a contiguous high range. Linux's default logical CPU numbering
# on a 2-socket system is commonly INTERLEAVED (socket 0 = all even IDs,
# socket 1 = all odd IDs), not two contiguous blocks -- confirmed on this
# exact class of hardware via `lscpu`. Pinning to a contiguous numeric range
# like "0-19" on an interleaved layout silently mixes both sockets roughly
# 50/50, achieving NONE of the single-socket isolation the surrounding
# comments/sizing math assume -- this was caught and fixed here specifically
# because it was verified against a live host's real `lscpu` output, not
# assumed from "20 cores/socket" arithmetic alone.
NODE0_CPUS="$(lscpu -p=CPU,NODE 2>/dev/null | grep -v '^#' | awk -F, '$2==0 {print $1}' | paste -sd, -)"
NODE1_CPUS="$(lscpu -p=CPU,NODE 2>/dev/null | grep -v '^#' | awk -F, '$2==1 {print $1}' | paste -sd, -)"

if [ -z "$NODE0_CPUS" ] || [ -z "$NODE1_CPUS" ]; then
  echo "ERROR: could not determine per-NUMA-node CPU lists via 'lscpu -p=CPU,NODE'."
  echo "This host may not be a 2-socket system, or lscpu's -p output format"
  echo "differs from what this script expects. Run 'lscpu -e' manually, confirm"
  echo "the real socket/node CPU assignment, and hardcode NODE0_CPUS/NODE1_CPUS"
  echo "above before proceeding -- do NOT guess a contiguous range."
  exit 1
fi

echo "Detected NUMA node 0 CPUs: $NODE0_CPUS"
echo "Detected NUMA node 1 CPUs: $NODE1_CPUS"
echo

qm create "$PROD_VMID" \
  --name "$PROD_NAME" \
  --memory "$PROD_MEM" \
  --balloon 0 \
  --cores "$PROD_CORES" \
  --sockets 1 \
  --cpu host \
  --numa 1 \
  --net0 "virtio,bridge=${PROD_BRIDGE},tag=${PROD_VLAN}" \
  --scsihw virtio-scsi-pci \
  --scsi0 "${STORAGE}:${PROD_DISK_GB}" \
  --ide2 "${ISO_STORAGE}:iso/${UBUNTU_ISO},media=cdrom" \
  --boot order=scsi0 \
  --ostype l26 \
  --agent enabled=1

echo "dune-prod VM shell created."
echo

# Pin to ALL of NUMA node 0's logical CPUs (detected above, not assumed --
# see the NODE0_CPUS/NODE1_CPUS detection block for why a hardcoded
# contiguous range like "0-19" is wrong on hosts with interleaved CPU
# numbering across sockets).
echo "Pinning dune-prod to NUMA node 0 ($PROD_CORES vCPUs -> all of: $NODE0_CPUS)..."
qm set "$PROD_VMID" --affinity "$NODE0_CPUS"
echo

echo "=== Provisioning dune-dev (VMID $DEV_VMID) ==="

qm create "$DEV_VMID" \
  --name "$DEV_NAME" \
  --memory "$DEV_MEM" \
  --balloon 0 \
  --cores "$DEV_CORES" \
  --sockets 1 \
  --cpu host \
  --numa 1 \
  --net0 "virtio,bridge=${DEV_BRIDGE},tag=${DEV_VLAN}" \
  --scsihw virtio-scsi-pci \
  --scsi0 "${STORAGE}:${DEV_DISK_GB}" \
  --ide2 "${ISO_STORAGE}:iso/${UBUNTU_ISO},media=cdrom" \
  --boot order=scsi0 \
  --ostype l26 \
  --agent enabled=1

echo "dune-dev VM shell created."
echo

# Dev only needs DEV_CORES of node 1's CPUs (not all of them, since node 1
# has 40 logical CPUs available but Dev is sized for 20 vCPUs) -- take the
# first DEV_CORES entries from the real detected node1 list, not a guessed
# contiguous range.
DEV_NODE1_SUBSET="$(printf '%s' "$NODE1_CPUS" | tr ',' '\n' | head -n "$DEV_CORES" | paste -sd, -)"

if [ -z "$DEV_NODE1_SUBSET" ]; then
  echo "ERROR: could not select $DEV_CORES CPUs from node 1's detected list"
  echo "($NODE1_CPUS). Node 1 may have fewer CPUs than DEV_CORES requires --"
  echo "check 'lscpu -e' and adjust DEV_CORES or investigate before proceeding."
  exit 1
fi

echo "Pinning dune-dev to NUMA node 1 ($DEV_CORES of ${NODE1_CPUS//,/, } -> using: $DEV_NODE1_SUBSET)..."
qm set "$DEV_VMID" --affinity "$DEV_NODE1_SUBSET"

echo
echo "=== Both VM shells created ==="
echo
echo "NEXT STEPS (manual, via Proxmox web UI):"
echo "1. Open the web UI, select VM $PROD_VMID ($PROD_NAME), click Console"
echo "2. Start the VM, install Ubuntu Server 26.04 LTS interactively"
echo "   - Set hostname: dune-prod"
echo "   - Set a static IP on the VLAN 20 subnet (e.g. 192.168.20.10/24,"
echo "     gateway 192.168.20.1) - this is the IP your router forwards to"
echo "   - Enable OpenSSH server during install"
echo "3. Repeat for VM $DEV_VMID ($DEV_NAME) on VLAN 21"
echo "   - Set hostname: dune-dev"
echo "   - Static IP e.g. 192.168.21.10/24, gateway 192.168.21.1"
echo "4. After both installs finish and you can SSH into each, run"
echo "   03-vm-guest-bootstrap.sh INSIDE each VM (not on the Proxmox host)."
echo
echo "Verify sizing/pinning any time with:"
echo "  qm config $PROD_VMID"
echo "  qm config $DEV_VMID"
