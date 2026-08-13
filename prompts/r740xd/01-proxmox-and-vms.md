# R740XD-01: Proxmox Install + VM Provisioning

This prompt runs ON THE PROXMOX HOST (via SSH or the web console at
`https://<r740-mgmt-ip>:8006`) after booting from the Proxmox USB.
It installs Proxmox VE, creates the two VMs, and installs Ubuntu Server
24.04 on each.

## Target Machine
The Dell R740 Proxmox host, freshly booted from the Proxmox VE installer
USB. Access via:
- Web UI: `https://<PROXMOX_MGMT_IP>:8006` (root / password set during install)
- SSH: `ssh root@<PROXMOX_MGMT_IP>` (after enabling during install)

## Pre-Requisites
- `tabr-tau/00-prerequisites.md` completed (ISOs downloaded, values.env filled)
- R740 racked, powered, network cabled to UCG-Max
- UCG-Max VLANs configured per `docs/02-network-setup.md`
- Read `docs/01-proxmox-install.md` for the full step-by-step

## State Before Starting
The R740 is powered on. You are at the Proxmox VE installer screen.

## Phase 1: Install Proxmox VE

### 1.1 BIOS Check (if not already done)
During POST, press F2 → System BIOS Settings → Processor Settings:
- Virtualization Technology: Enabled
- VT-d: Enabled
- Logical Processor: Enabled
- Power Profile: Maximum Performance
- C-States: Disabled

### 1.2 Run the Installer
Follow the Proxmox VE installer:
1. Select "Install Proxmox VE" from boot menu
2. Accept EULA
3. **Target disk**: Select the RAID1 mirror (should show ~1.92 TB)
4. Set country/timezone/keyboard
5. **Root password**: Generate and save to password manager
6. **Network**: Set to your management VLAN IP per values.env
   - IP: `$PROXMOX_MGMT_IP/24`
   - Gateway: `192.168.30.1`
   - DNS: `1.1.1.1`
   - Hostname: `r740-pve`

### 1.3 Post-Install: Switch to No-Subscription Repository
After reboot, SSH into the Proxmox host as root:
```bash
# Replace enterprise repo with community (free)
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list
apt update && apt full-upgrade -y
```

### 1.4 Upload ISO Files
Via the Proxmox web UI: Datacenter → local → ISO Images → Upload
Upload both ISOs (Proxmox + Ubuntu Server 24.04) if not already present.

Or via SCP from your dev machine:
```bash
# From dev machine:
scp /tmp/opencode/r740-isos/ubuntu-24.04.1-live-server-amd64.iso \
  root@<PROXMOX_MGMT_IP>:/var/lib/vz/template/iso/
```

### 1.5 Run AVX2 Validation
```bash
# On the Proxmox host, as root:
cd /root
# Transfer the r740-deployment repo or just this script
bash /path/to/scripts/01-validate-avx2.sh
```

**VERIFY**: The script reports "AVX2 validation complete" and the disposable
test VM shows AVX2 in `/proc/cpuinfo` inside the guest. If it fails, DO NOT
PROCEED — check CPU type is "host" in the VM config.

## Phase 2: Configure VM Networking

### 2.0 Configure VLAN-Aware Bridge (CRITICAL — skip at your peril)

**This is the most important networking step in the entire deployment.**
VMs use `tag=20` and `tag=21` which emit 802.1Q-tagged frames. The bridge
must be VLAN-aware or those tags are silently ignored.

On the Proxmox host, as root:
```bash
# Edit /etc/network/interfaces and add bridge-vlan-aware + vids:
cat >> /etc/network/interfaces << 'BRIDGECFG'

# VLAN-aware bridge configuration (added by R740 deployment kit)
auto vmbr0
iface vmbr0 inet manual
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10 20 21 30
BRIDGECFG

ifreload -a
```

**VERIFY:** `bridge vlan show` should list VLANs 10, 20, 21, 30 on vmbr0.
If empty, the bridge is NOT VLAN-aware and inter-VM isolation does not
exist — STOP and fix before continuing.

**Cabling:** Use ONE UCG-Max LAN port configured as a trunk (tagged for
VLANs 10/20/21/30). Connect one R740 NIC to it. The three remaining NICs
are spare.

## Phase 3: Create VMs

### 3.1 Run Provisioning Script
Transfer `scripts/02-provision-vms.sh` to the Proxmox host and run it:
```bash
bash /path/to/scripts/02-provision-vms.sh
```

If you don't have the script accessible, run the equivalent commands:
```bash
# dune-prod (VMID 101) — 40 vCPU, 152 GB RAM, socket 0
qm create 101 \
  --name dune-prod \
  --memory 155648 \
  --balloon 0 \
  --cores 40 \
  --sockets 1 \
  --cpu host \
  --numa 1 \
  --net0 virtio,bridge=vmbr0,tag=20 \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:300 \
  --ide2 local:iso/ubuntu-24.04.1-live-server-amd64.iso,media=cdrom \
  --boot order=scsi0 \
  --ostype l26 \
  --agent enabled=1
qm set 101 --affinity 0-19

# dune-dev (VMID 102) — 20 vCPU, 50 GB RAM, socket 1 (cores 20-29)
qm create 102 \
  --name dune-dev \
  --memory 51200 \
  --balloon 0 \
  --cores 20 \
  --sockets 1 \
  --cpu host \
  --numa 1 \
  --net0 virtio,bridge=vmbr0,tag=21 \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:300 \
  --ide2 local:iso/ubuntu-24.04.1-live-server-amd64.iso,media=cdrom \
  --boot order=scsi0 \
  --ostype l26 \
  --agent enabled=1
qm set 102 --affinity 20-29

# Enable auto-start on boot, with ordering
qm set 101 --onboot 1 --startup order=1
qm set 102 --onboot 1 --startup order=2
```

### 2.2 Install Ubuntu Server on Each VM

For EACH VM (do dune-prod first, then dune-dev):

1. In Proxmox web UI: select VM → Console → Start
2. Follow Ubuntu Server 24.04 installer:
   - **Language**: English
   - **Keyboard**: US
   - **Network**: Manual IPv4
     - dune-prod: `192.168.20.10/24`, gateway `192.168.20.1`, DNS `1.1.1.1`
     - dune-dev: `192.168.21.10/24`, gateway `192.168.21.1`, DNS `1.1.1.1`
   - **Storage**: Use entire disk (300 GB), no LVM
   - **Profile**:
     - Name: `dune` (for both VMs — same username)
     - Hostname: `dune-prod` / `dune-dev`
     - Password: generate + store in password manager
   - **SSH**: Enable "Install OpenSSH server"
   - **Snaps**: Skip (no snaps needed)

### 2.3 Verify SSH Access
From your dev machine, confirm you can reach both VMs (via VPN or Trusted-LAN):
```bash
ssh dune@192.168.20.10 "hostname && free -h | head -2 && nproc"
# Expected: dune-prod, 152 GB RAM, 40 CPUs

ssh dune@192.168.21.10 "hostname && free -h | head -2 && nproc"
# Expected: dune-dev, 50 GB RAM, 20 CPUs
```

If you can't reach the VMs from your dev machine, use the Proxmox console
or ensure your dev machine is on the Trusted-LAN VLAN (192.168.10.0/24)
and the firewall allows Trusted-LAN → Prod / Trusted-LAN → Dev per
`docs/02-network-setup.md` Step 3.

## Phase 3: Bootstrap Both VMs

### 3.1 Transfer Bootstrap Script
From your dev machine:
```bash
scp ~/r740-deployment/scripts/03-vm-guest-bootstrap.sh dune@192.168.20.10:~/
scp ~/r740-deployment/scripts/03-vm-guest-bootstrap.sh dune@192.168.21.10:~/
```

### 3.2 Run Bootstrap on Both VMs
```bash
# On dune-prod:
ssh dune@192.168.20.10 "bash ~/03-vm-guest-bootstrap.sh"

# On dune-dev:
ssh dune@192.168.21.10 "bash ~/03-vm-guest-bootstrap.sh"
```

This installs Docker, Docker Compose plugin, and clones the
`dune-awakening-selfhost-docker` repo from the latest GitHub release tarball.

**VERIFY on each VM:**
```bash
docker --version          # Docker version 26+
docker compose version    # Compose plugin present
ls ~/dune-awakening-selfhost-docker/runtime/scripts/dune  # CLI exists
grep avx2 /proc/cpuinfo   # AVX2 visible in guest
```

## State After Completion
- [ ] Proxmox VE installed on the R740
- [ ] No-subscription repo configured
- [ ] AVX2 validated inside a test VM
- [ ] dune-prod VM (VMID 101): 40 vCPU / 152 GB RAM, Ubuntu 24.04
- [ ] dune-dev VM (VMID 102): 20 vCPU / 50 GB RAM, Ubuntu 24.04
- [ ] Both VMs have Docker + Docker Compose plugin installed
- [ ] `dune-awakening-selfhost-docker` cloned on both VMs
- [ ] You can SSH into both VMs as `dune@<IP>`

## Next Prompt
Proceed to `r740xd/02-game-servers.md` to initialize both battlegroups.

## Rollback
At this stage, nothing on the gaming PC has been touched. To abort:
1. `qm stop 101 && qm destroy 101` on the Proxmox host
2. `qm stop 102 && qm destroy 102` on the Proxmox host
3. All ISO files and the Proxmox install itself remain intact
