# R740XD-01: Proxmox Install + VM Provisioning

This prompt runs in its own session, ON THE PROXMOX HOST (via SSH or the
web console at `https://<r740-mgmt-ip>:8006`). It covers everything from
Proxmox VE installation media through both VM shells being created and
bootstrapped — all ISO acquisition, install steps, and configuration
happen here, not in any `tabr-tau/` prompt (see issue #59's session
boundary: Tabr-Tau sessions gather credentials/config only, R740xd
sessions do all actual install/configuration work).

## Target Machine
The Dell R740 Proxmox host. Access via:
- Web UI: `https://<PROXMOX_MGMT_IP>:8006` (root / password set during install)
- SSH: `ssh root@<PROXMOX_MGMT_IP>` (after enabling during install)
- If Proxmox is not yet installed: iDRAC Virtual Console + Virtual Media
  (this exact hardware's iDRAC9 has been used for exactly this before —
  see `docs/05-dell-support-case-boot-failure.md`), or a physical USB
  installer if iDRAC access isn't available. Either way, this is R740xd
  work, not something to prepare on the dev machine beforehand.

## Pre-Requisites
- `tabr-tau/00-prerequisites.md` completed (values.env filled, Funcom
  tokens ready, bot secrets staged) — run in ITS OWN separate session
- R740 racked, powered, network cabled to UCG-Max
- UCG-Max VLANs configured per `docs/02-network-setup.md`
- Read `docs/01-proxmox-install.md` for the full step-by-step

## State Before Starting
The R740 is powered on. Proxmox VE may or may not be installed yet —
Phase 0 below covers the case where it isn't; skip to Phase 1 if it is
(confirm with `pveversion` over SSH or by checking whether the web UI at
`https://<r740-mgmt-ip>:8006` is reachable).

## Phase 0: Acquire Install Media (if Proxmox VE is not yet installed)

### 0.1 Download the Proxmox VE ISO
On any machine with a browser (this can be your dev machine, since it's
just a download, not R740-side configuration):
```bash
wget -P /tmp/opencode/r740-isos/ \
  https://enterprise.proxmox.com/iso/proxmox-ve_8.2-1.iso
# Verify checksum matches the official page:
# https://www.proxmox.com/en/downloads
sha256sum /tmp/opencode/r740-isos/proxmox-ve_8.2-1.iso
```

### 0.2 Boot From It
- **Physical USB**: `sudo dd if=/tmp/opencode/r740-isos/proxmox-ve_8.2-1.iso of=/dev/sdX bs=4M status=progress conv=fsync`
  (confirm `/dev/sdX` via `lsblk` first — this destroys all data on the
  target device), then boot the R740 from it.
- **iDRAC Virtual Media** (no physical USB needed): iDRAC web UI →
  Virtual Console → Virtual Media → mount the ISO, then reboot the R740
  and select the virtual optical drive as the boot device. See
  `docs/05-dell-support-case-boot-failure.md` if this hardware's iDRAC
  gives you trouble mounting media — it's happened before on this exact
  server.

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

### 1.4 Download and Upload the Ubuntu Server ISO
This is genuinely R740xd-side work now (not a Tabr-Tau step) — download
directly onto the Proxmox host itself, since it has its own internet
access and this avoids an unnecessary dev-machine hop entirely:
```bash
# Directly on the Proxmox host:
curl -sL "https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso" \
  -o /var/lib/vz/template/iso/ubuntu-26.04-live-server-amd64.iso
# Verify against the published checksum:
# https://releases.ubuntu.com/26.04/SHA256SUMS
sha256sum /var/lib/vz/template/iso/ubuntu-26.04-live-server-amd64.iso
```

Or via the Proxmox web UI: Datacenter → local → ISO Images → Upload.

### 1.5 Run AVX2 Validation
```bash
# On the Proxmox host, as root:
cd /root
# Transfer the r740-deployment repo or just this script
bash /path/to/scripts/01-validate-avx2.sh
```

**Note on running this non-interactively:** the script's own `read -p`
confirmation prompt assumes an interactive console session watching the
test VM boot. If running this from an automated/agent-driven session
instead, verify AVX2 passthrough directly via QEMU's own QMP API instead
of the console-based check:
```bash
# After the script creates and starts the disposable test VM (e.g. VMID 900):
python3 -c "
import socket, json
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect('/var/run/qemu-server/900.qmp')
def read_json():
    buf = b''
    while True:
        buf += sock.recv(65536)
        try: return json.loads(buf.decode())
        except json.JSONDecodeError: continue
def send(cmd):
    sock.sendall((json.dumps(cmd) + '\n').encode())
    return read_json()
read_json()  # greeting
send({'execute': 'qmp_capabilities'})
result = send({'execute': 'query-cpu-model-expansion', 'arguments': {'type': 'full', 'model': {'name': 'host'}}})
props = result.get('return', {}).get('model', {}).get('props', {})
print('avx2 exposed to guest:', props.get('avx2'))
"
# Expected: avx2 exposed to guest: True
```

**VERIFY**: The script reports "AVX2 validation complete" and the disposable
test VM shows AVX2 in `/proc/cpuinfo` inside the guest. If it fails, DO NOT
PROCEED — check CPU type is "host" in the VM config.

## Phase 2: Configure VM Networking

### 2.0 Configure VLAN-Aware Bridge (CRITICAL — skip at your peril)

**This is the most important networking step in the entire deployment.**
VMs use `tag=20` and `tag=21` which emit 802.1Q-tagged frames. The bridge
must be VLAN-aware or those tags are silently ignored.

**Do not blindly copy a bridge-port name or VLAN list from an example —
confirm both against this specific host first:**
```bash
# Confirm your actual data-NIC interface name (varies by host/NIC driver;
# do NOT assume "eno1" -- this deployment's actual R740 uses "nic0", a
# different name entirely, confirmed via `ip link show` before editing):
ip link show
cat /etc/network/interfaces   # see which interface vmbr0 already uses as bridge-ports

# Confirm your actual configured VLANs via the UCG-Max (or the UniFi
# Network Integration API) rather than assuming a fixed list -- this
# deployment only has 20 (Prod), 21 (Dev), 30 (Mgmt) configured, NOT a
# VLAN 10, despite an earlier draft of this doc assuming one existed.
```

Edit `/etc/network/interfaces` **in place** (add these three lines to the
existing `vmbr0` stanza — do not blindly append a second, duplicate
`vmbr0` block with `cat >>`, which creates a conflicting second
definition):
```
	bridge-vlan-aware yes
	bridge-vids 20 21 30
```
using your host's actual `bridge-ports` value and actual VLAN list from
the check above, then apply:
```bash
ifreload -a
```

**Verified working on this exact deployment (2026-08-14), applied live
with zero connectivity loss** — the management IP/gateway stayed on the
untagged native VLAN throughout; only the new VLANs needed adding:
```
auto vmbr0
iface vmbr0 inet static
	address 192.168.68.127/24
	gateway 192.168.68.1
	bridge-ports nic0
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 20 21 30
```

**VERIFY:** `bridge vlan show` should list your actual VLANs (20, 21, 30
on this deployment) on both the bridge-port interface and `vmbr0`,
alongside VLAN 1 (or whatever your native/untagged VLAN is) still marked
`PVID Egress Untagged`. If the new VLANs are missing, the bridge is NOT
VLAN-aware and inter-VM isolation does not exist — STOP and fix before
continuing. If your management connection drops after `ifreload -a`,
your backed-up copy of `/etc/network/interfaces` should be restored via
the Proxmox console (not SSH, which will be down) — always back up the
file before editing it, and consider a scheduled revert-and-reload
safety net (e.g. a `sleep N && cp backup /etc/network/interfaces &&
ifreload -a` backgrounded process) if working from a remote/agent-driven
session with no console fallback readily available.

**Cabling:** Use ONE UCG-Max LAN port configured as a trunk (tagged for
your actual VLAN list). Connect one R740 NIC to it. The remaining NICs
are spare.

## Phase 3: Create VMs

### 3.1 Run Provisioning Script
Transfer `scripts/02-provision-vms.sh` to the Proxmox host and run it:
```bash
bash /path/to/scripts/02-provision-vms.sh
```

If you don't have the script accessible, run the equivalent commands.
**Do not hardcode a contiguous affinity range like `0-19`/`20-29` for the
NUMA pinning below** — on hosts where the kernel numbers logical CPUs
interleaved across sockets (this exact class of 2-socket Xeon hardware
does exactly this: socket 0 = all even logical CPU IDs, socket 1 = all
odd IDs, NOT two contiguous blocks), a contiguous range silently mixes
both sockets roughly 50/50, achieving none of the single-socket isolation
this sizing depends on. Detect the real per-node CPU list first:
```bash
NODE0_CPUS="$(lscpu -p=CPU,NODE 2>/dev/null | grep -v '^#' | awk -F, '$2==0 {print $1}' | paste -sd, -)"
NODE1_CPUS="$(lscpu -p=CPU,NODE 2>/dev/null | grep -v '^#' | awk -F, '$2==1 {print $1}' | paste -sd, -)"
echo "Node 0: $NODE0_CPUS"
echo "Node 1: $NODE1_CPUS"
```

```bash
# dune-prod (VMID 101) — 40 vCPU, 152 GB RAM, socket 0 (ALL of node 0's CPUs)
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
  --ide2 local:iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom \
  --boot order=scsi0 \
  --ostype l26 \
  --agent enabled=1
qm set 101 --affinity "$NODE0_CPUS"

# dune-dev (VMID 102) — 20 vCPU, 50 GB RAM, socket 1 (first 20 of node 1's CPUs)
DEV_NODE1_SUBSET="$(printf '%s' "$NODE1_CPUS" | tr ',' '\n' | head -n 20 | paste -sd, -)"

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
  --ide2 local:iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom \
  --boot order=scsi0 \
  --ostype l26 \
  --agent enabled=1
qm set 102 --affinity "$DEV_NODE1_SUBSET"

# Enable auto-start on boot, with ordering
qm set 101 --onboot 1 --startup order=1
qm set 102 --onboot 1 --startup order=2
```

**Or just run `scripts/02-provision-vms.sh` directly** — it already
handles this NUMA detection automatically and is the preferred path;
the manual commands above are only a fallback for when the script isn't
accessible.

**Verified on this exact deployment (2026-08-14):** both VM shells were
created successfully using the script (not the manual fallback), with
`dune-prod` correctly pinned to all 40 of node 0's logical CPUs and
`dune-dev` to the first 20 of node 1's — confirmed via `qm config
101`/`qm config 102` showing the real detected CPU lists, not a guessed
range.

### 2.2 Install Ubuntu Server on Each VM

For EACH VM (do dune-prod first, then dune-dev):

1. In Proxmox web UI: select VM → Console → Start
2. Follow Ubuntu Server 26.04 installer:
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
- [ ] dune-prod VM (VMID 101): 40 vCPU / 152 GB RAM, Ubuntu 26.04
- [ ] dune-dev VM (VMID 102): 20 vCPU / 50 GB RAM, Ubuntu 26.04
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
