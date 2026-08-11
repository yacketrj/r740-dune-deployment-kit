#!/usr/bin/env bash
# =============================================================================
# 02-provision-vms.sh
#
# RUN THIS: on the Proxmox VE host, via its SSH/console shell (as root).
# PURPOSE:  Create the dune-prod and dune-dev VM shells with the correct
#           CPU type, memory, vCPU pinning, and network bridge assignment.
#           This does NOT install an OS - after this script, you attach the
#           Ubuntu Server 24.04 ISO and install the OS interactively through
#           the Proxmox console (no way to script an OS install reliably
#           here, and you shouldn't want to - you want to see it happen).
#
# PREREQ:   - 01-validate-avx2.sh has passed
#           - VLANs 20 (Prod) and 21 (Dev) exist on your network/bridge
#             config (see docs/02-network-setup.md)
#           - Ubuntu Server 24.04 LTS ISO uploaded to Proxmox local storage
#             (Datacenter -> local storage -> ISO Images -> Upload)
#
# SIZING RATIONALE (2026-08-07 revision — 2x Sietch @40p + 4x DD + dynamics):
#   dune-prod: 152 GB RAM, 40 vCPU, pinned to physical socket 0 (all 20 cores)
#              Always-on baseline: 2 Sietch @16GB (32) + 4 DD @16GB (64) +
#              Overmap 3GB + Arrakeen+Harko always-on 6GB + support+bot 6GB = 111 GB
#              Dynamic peak: ~30 GB (10 concurrent dungeons/overlands @ 3 GB)
#              CPU peak: ~52 vCPU (2 Sietch @40p loaded + 4 DD + 10 dynamic maps)
#              Headroom: 11 GB / CPU oversubscription safe (Proxmox scheduler)
#   dune-dev:  50 GB RAM, 20 vCPU, pinned to physical socket 1 (cores 20-29)
#              1 Sietch @16GB + 1 DD peak @16GB + Overmap 3GB + support 5GB
#              + dynamic peak 10GB = 50 GB (tight but dev-only, no SLA)
#
# USAGE: bash 02-provision-vms.sh
# =============================================================================
set -euo pipefail

# --- Adjust these if your environment differs ------------------------------
STORAGE="local-lvm"          # where VM disks live; check `pvesm status` if unsure
ISO_STORAGE="local"
UBUNTU_ISO="ubuntu-24.04-live-server-amd64.iso"   # must already be uploaded

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

# Pin to physical socket 0's cores. Adjust the core range to match your
# actual topology - confirm with `lscpu | grep -E "Socket|Core"` on the host
# first. This example assumes socket 0 = physical cores 0-19 (Gold 6248 has
# 20 cores/socket), doubled for hyperthreads by the kernel's own scheduling
# (we pin at the core level, not the thread level, and let Proxmox/KVM manage
# thread affinity within that set).
echo "Pinning dune-prod to physical socket 0 (all 20 cores, 40 threads)..."
qm set "$PROD_VMID" --affinity 0-19
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

echo "Pinning dune-dev to physical socket 1 (half: cores 20-29, 20 threads)..."
echo "NOTE: if your R740 reports fewer than 40 total physical cores visible"
echo "here (e.g. NUMA node boundaries differ from this assumption), check"
echo "'lscpu | grep -E \"Socket|NUMA\"' and adjust the affinity range below"
echo "manually before/after this script runs."
qm set "$DEV_VMID" --affinity 20-29

echo
echo "=== Both VM shells created ==="
echo
echo "NEXT STEPS (manual, via Proxmox web UI):"
echo "1. Open the web UI, select VM $PROD_VMID ($PROD_NAME), click Console"
echo "2. Start the VM, install Ubuntu Server 24.04 LTS interactively"
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
