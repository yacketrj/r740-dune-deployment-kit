# R740XD-01: Proxmox Install + VM Provisioning

You are an LLM coding agent running in your own session, ON THE PROXMOX
HOST (via SSH or the web console at `https://<r740-mgmt-ip>:8006`). Your
job in this session covers everything from Proxmox VE installation media
through both VM shells being created and bootstrapped — all ISO
acquisition, install steps, and configuration happen here, not in any
`tabr-tau/` prompt (see issue #59's session boundary: Tabr-Tau sessions
gather credentials/config only, R740xd sessions do all actual
install/configuration work). If asked to do dev-machine-only gathering
work in this session, redirect to the correct `tabr-tau/` prompt instead
of doing it here.

## Target Machine
The Dell R740 Proxmox host. Access via:
- Web UI: `https://<PROXMOX_MGMT_IP>:8006` (root / password set during install)
- SSH: `ssh root@<PROXMOX_MGMT_IP>` (after enabling during install)
- If Proxmox is not yet installed: iDRAC Virtual Console + Virtual Media
  (this exact hardware's iDRAC9 has been used for exactly this before —
  see `docs/05-dell-support-case-boot-failure.md`), or a physical USB
  installer if iDRAC access isn't available. Either way, this is R740xd
  work — do not attempt any of it from a `tabr-tau/` session.

## Before You Start, Confirm
- `tabr-tau/00-prerequisites.md` has been completed (values.env filled,
  Funcom tokens ready, bot secrets staged) — ask the user if you have no
  direct evidence, since this was run in a separate session
- R740 is racked, powered, network cabled to UCG-Max
- UCG-Max VLANs are configured per `docs/02-network-setup.md`
- Read `docs/01-proxmox-install.md` for the full step-by-step reference

## Determine Current State Before Acting
The R740 is powered on. Proxmox VE may or may not be installed yet —
Phase 0 below covers the case where it isn't; skip to Phase 1 if it is.
Confirm which situation you're in with `pveversion` over SSH or by
checking whether the web UI at `https://<r740-mgmt-ip>:8006` is
reachable — do not assume either state without checking.

## Phase 0: Acquire Install Media (if Proxmox VE is not yet installed)

### 0.1 Download the Proxmox VE ISO
This can be done from any machine with a browser, including the dev
machine, since it's just a download, not R740-side configuration:
```bash
wget -P /tmp/opencode/r740-isos/ \
  https://enterprise.proxmox.com/iso/proxmox-ve_8.2-1.iso
# Verify checksum matches the official page:
# https://www.proxmox.com/en/downloads
sha256sum /tmp/opencode/r740-isos/proxmox-ve_8.2-1.iso
```
Report the checksum and confirm it matches the published value before
proceeding — do not continue with an unverified ISO.

### 0.2 Boot From It
- **Physical USB**: `sudo dd if=/tmp/opencode/r740-isos/proxmox-ve_8.2-1.iso of=/dev/sdX bs=4M status=progress conv=fsync`
  (confirm `/dev/sdX` via `lsblk` first — this destroys all data on the
  target device; get explicit user confirmation of the device before
  running `dd`), then boot the R740 from it.
- **iDRAC Virtual Media** (no physical USB needed): iDRAC web UI →
  Virtual Console → Virtual Media → mount the ISO, then reboot the R740
  and select the virtual optical drive as the boot device. See
  `docs/05-dell-support-case-boot-failure.md` if this hardware's iDRAC
  gives you trouble mounting media — it's happened before on this exact
  server.

## Phase 1: Install Proxmox VE

### 1.1 BIOS Check (if not already done)
Ask the user to check, during POST (press F2 → System BIOS Settings →
Processor Settings), that:
- Virtualization Technology: Enabled
- VT-d: Enabled
- Logical Processor: Enabled
- Power Profile: Maximum Performance
- C-States: Disabled

You cannot do this yourself — it happens before any OS is reachable
over the network.

### 1.2 Run the Installer
Walk the user through the Proxmox VE installer (this is interactive and
console-only; you cannot drive it yourself remotely):
1. Select "Install Proxmox VE" from boot menu
2. Accept EULA
3. **Target disk**: Select the RAID1 mirror (should show ~1.92 TB)
4. Set country/timezone/keyboard
5. **Root password**: Generate and have the user save it to their
   password manager
6. **Network**: Set to the management VLAN IP per values.env
   - IP: `$PROXMOX_MGMT_IP/24`
   - Gateway: `192.168.30.1`
   - DNS: `1.1.1.1`
   - Hostname: `r740-pve`

### 1.3 Post-Install: Switch to No-Subscription Repository
After reboot, SSH into the Proxmox host as root and run:
```bash
# Replace enterprise repo with community (free)
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list
apt update && apt full-upgrade -y
```
Report the outcome — confirm `apt update` succeeds with no repo errors
before proceeding.

### 1.4 Download and Upload the Ubuntu Server ISO
This is R740xd-side work, not a Tabr-Tau step — download directly onto
the Proxmox host itself, since it has its own internet access and this
avoids an unnecessary dev-machine hop entirely:
```bash
# Directly on the Proxmox host:
curl -sL "https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso" \
  -o /var/lib/vz/template/iso/ubuntu-26.04-live-server-amd64.iso
# Verify against the published checksum:
# https://releases.ubuntu.com/26.04/SHA256SUMS
sha256sum /var/lib/vz/template/iso/ubuntu-26.04-live-server-amd64.iso
```
Report the checksum comparison result before proceeding — do not use an
unverified ISO for VM installs.

Alternative: via the Proxmox web UI: Datacenter → local → ISO Images → Upload.

### 1.5 Run AVX2 Validation
Run:
```bash
# On the Proxmox host, as root:
cd /root
# Transfer the r740-deployment repo or just this script
bash /path/to/scripts/01-validate-avx2.sh
```

**Note for you as an agent driving this non-interactively:** the
script's own `read -p` confirmation prompt assumes an interactive
console session watching the test VM boot. Since you're running this
from an automated/agent-driven session, verify AVX2 passthrough directly
via QEMU's own QMP API instead of the console-based check:
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

Confirm the script reports "AVX2 validation complete" and that the
disposable test VM shows AVX2 in `/proc/cpuinfo` inside the guest, and
report this back to the user. **If either check fails, stop — do not
proceed to VM creation.** Check that CPU type is "host" in the VM config
and fix before continuing.

## Phase 2: Configure VM Networking

### 2.0 Configure VLAN-Aware Bridge (CRITICAL — do not skip)

**This is the most important networking step in the entire deployment.**
VMs use `tag=20` and `tag=21` which emit 802.1Q-tagged frames. The bridge
must be VLAN-aware or those tags are silently ignored.

**Do not copy a bridge-port name or VLAN list from an example below
without confirming both against this specific host first:**
```bash
# Confirm the actual data-NIC interface name (varies by host/NIC driver;
# do NOT assume "eno1" -- this deployment's actual R740 uses "nic0", a
# different name entirely, confirmed via `ip link show` before editing):
ip link show
cat /etc/network/interfaces   # see which interface vmbr0 already uses as bridge-ports

# Confirm the actual configured VLANs via the UCG-Max (or the UniFi
# Network Integration API) rather than assuming a fixed list -- this
# deployment only has 20 (Prod), 21 (Dev), 30 (Mgmt) configured, NOT a
# VLAN 10, despite an earlier draft of this doc assuming one existed.
```

Edit `/etc/network/interfaces` **in place** (add these two lines to the
existing `vmbr0` stanza — do not append a second, duplicate `vmbr0`
block with `cat >>`, which creates a conflicting second definition):
```
	bridge-vlan-aware yes
	bridge-vids 20 21 30
```
using the host's actual `bridge-ports` value and actual VLAN list from
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

Before editing, back up `/etc/network/interfaces` and consider a
scheduled revert-and-reload safety net (e.g. a `sleep N && cp backup
/etc/network/interfaces && ifreload -a` backgrounded process), since
you're likely operating from a remote/agent-driven session with no
console fallback readily available if the management connection drops.

After applying, run `bridge vlan show` and confirm it lists the actual
VLANs (20, 21, 30 on this deployment) on both the bridge-port interface
and `vmbr0`, alongside VLAN 1 (or whatever the native/untagged VLAN is)
still marked `PVID Egress Untagged`. **If the new VLANs are missing, the
bridge is NOT VLAN-aware and inter-VM isolation does not exist — stop and
fix before continuing; do not proceed to Phase 3.** If the management
connection drops after `ifreload -a`, tell the user the backed-up copy of
`/etc/network/interfaces` needs to be restored via the Proxmox console
(not SSH, which will be down).

**Cabling:** confirm with the user that one UCG-Max LAN port is
configured as a trunk (tagged for the actual VLAN list) and one R740 NIC
is connected to it. The remaining NICs are spare.

## Phase 3: Create VMs

### 3.1 Run Provisioning Script
Transfer `scripts/02-provision-vms.sh` to the Proxmox host and run it:
```bash
bash /path/to/scripts/02-provision-vms.sh
```
This is the preferred path — it already handles NUMA detection
automatically. Only fall back to the manual commands below if the script
is genuinely inaccessible.

**Do not hardcode a contiguous affinity range like `0-19`/`20-29` for
NUMA pinning if you do fall back to manual commands** — on hosts where
the kernel numbers logical CPUs interleaved across sockets (this exact
class of 2-socket Xeon hardware does exactly this: socket 0 = all even
logical CPU IDs, socket 1 = all odd IDs, NOT two contiguous blocks), a
contiguous range silently mixes both sockets roughly 50/50, achieving
none of the single-socket isolation this sizing depends on. Detect the
real per-node CPU list first:
```bash
NODE0_CPUS="$(lscpu -p=CPU,NODE 2>/dev/null | grep -v '^#' | awk -F, '$2==0 {print $1}' | paste -sd, -)"
NODE1_CPUS="$(lscpu -p=CPU,NODE 2>/dev/null | grep -v '^#' | awk -F, '$2==1 {print $1}' | paste -sd, -)"
echo "Node 0: $NODE0_CPUS"
echo "Node 1: $NODE1_CPUS"
```

Manual fallback commands, using the detected lists above:
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

**Known bug (issue #61, not yet fixed in the script as of 2026-08-14):**
`--boot order=scsi0` never includes `ide2` (the installer ISO) in boot
order, so the VM shows "no boot media" on first boot. Work around this by
running, immediately after creation and before first boot:
```bash
qm set 101 --boot 'order=ide2;scsi0'
qm set 102 --boot 'order=ide2;scsi0'
```
Reset back to `order=scsi0` on each VM after its OS install completes, so
subsequent boots don't try the CD-ROM first.

After creating both VMs, run `qm config 101` and `qm config 102` and
confirm the CPU affinity lists match the real detected per-node CPU
lists from above, not a guessed contiguous range — report this
confirmation back to the user.

### 3.2 Install Ubuntu Server on Each VM

For EACH VM (do dune-prod first, then dune-dev), this is interactive
console work — walk the user through it, or if you have console access
yourself, drive it directly:

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
     - Password: generate + have the user store it in their password
       manager
   - **SSH**: Enable "Install OpenSSH server"
   - **Snaps**: Skip (no snaps needed)

**Known issue not yet tracked as a GitHub issue as of 2026-08-14:** the
Ubuntu installer's netplan config
(`/etc/netplan/00-installer-config.yaml`) has been observed to write
`match:`/`set-name:` for the network interface but NOT write the
`addresses:` entry for the static IP entered during install, despite the
installer prompting for it. Before rebooting out of the installer, check
`ip addr show` matches the intended static IP; if it doesn't, fix the
netplan file and run `netplan apply` before proceeding, rather than
discovering the VM is unreachable after reboot.

### 3.3 Verify SSH Access
From wherever you're running this session, confirm you can reach both
VMs:
```bash
ssh dune@192.168.20.10 "hostname && free -h | head -2 && nproc"
# Expected: dune-prod, 152 GB RAM, 40 CPUs

ssh dune@192.168.21.10 "hostname && free -h | head -2 && nproc"
# Expected: dune-dev, 50 GB RAM, 20 CPUs
```
Report the actual output and compare it explicitly against the expected
values above — do not assume it matches without checking.

If you can't reach the VMs, use the Proxmox console instead, or confirm
your access path is on the Trusted-LAN VLAN (per `docs/02-network-setup.md`)
and that the firewall allows Trusted-LAN → Prod / Trusted-LAN → Dev per
that doc's Step 3.

## Phase 4: Bootstrap Both VMs

### 4.1 Transfer Bootstrap Script
```bash
scp ~/r740-deployment/scripts/03-vm-guest-bootstrap.sh dune@192.168.20.10:~/
scp ~/r740-deployment/scripts/03-vm-guest-bootstrap.sh dune@192.168.21.10:~/
```

### 4.2 Run Bootstrap on Both VMs
```bash
# On dune-prod:
ssh dune@192.168.20.10 "bash ~/03-vm-guest-bootstrap.sh"

# On dune-dev:
ssh dune@192.168.21.10 "bash ~/03-vm-guest-bootstrap.sh"
```

This installs Docker, Docker Compose plugin, and clones the
`dune-awakening-selfhost-docker` repo from the latest GitHub release
tarball.

**Verify on each VM** by running:
```bash
docker --version          # Docker version 26+
docker compose version    # Compose plugin present
ls ~/dune-awakening-selfhost-docker/runtime/scripts/dune  # CLI exists
grep avx2 /proc/cpuinfo   # AVX2 visible in guest
```
Report each check's actual result explicitly — do not report this phase
complete until all four checks pass on both VMs.

## What to Report Back When This Prompt Is Done
Confirm and report each of the following explicitly, not just "looks
done":
- Proxmox VE installed on the R740
- No-subscription repo configured
- AVX2 validated inside a test VM
- dune-prod VM (VMID 101): 40 vCPU / 152 GB RAM, Ubuntu 26.04
- dune-dev VM (VMID 102): 20 vCPU / 50 GB RAM, Ubuntu 26.04
- Both VMs have Docker + Docker Compose plugin installed
- `dune-awakening-selfhost-docker` cloned on both VMs
- SSH access confirmed to both VMs as `dune@<IP>`

## When This Prompt Is Done
Tell the user to proceed to `r740xd/02-game-servers.md` to initialize
both battlegroups.

## Rollback
At this stage, nothing on the gaming PC has been touched. To abort, run:
1. `qm stop 101 && qm destroy 101` on the Proxmox host
2. `qm stop 102 && qm destroy 102` on the Proxmox host
3. All ISO files and the Proxmox install itself remain intact
</content>
