# Proxmox VE Installation Guide

## What You're Installing

Proxmox VE turns the R740 into a hypervisor: instead of running one OS
directly on the hardware, you run Proxmox itself as a thin base layer, and
then create Virtual Machines (VMs) on top of it. Each VM (dune-prod,
dune-dev) gets its own slice of CPU/RAM/disk and runs its own independent
copy of Ubuntu Server, completely isolated from the other.

**Cost: $0.** Download and use are free with no feature restrictions. You'll
be prompted about an optional paid support subscription during setup —
dismiss/skip it, it is not required.

## Step 1: Download the ISO

On any computer with a browser:

1. Go to https://www.proxmox.com/en/downloads
2. Download **"Proxmox VE 8.x ISO Installer"** (get the latest stable
   version listed — as of writing this is the 8.x series)
3. This is a ~1.3GB `.iso` file

## Step 2: Create a Bootable USB

You need an 8GB+ USB flash drive.

**On Windows**, use [Rufus](https://rufus.ie) (free):
1. Plug in the USB drive (WARNING: this erases everything on it)
2. Open Rufus, select the USB drive under "Device"
3. Click "SELECT" and choose the Proxmox ISO you downloaded
4. Leave partition scheme as default (GPT for UEFI systems, which the R740 is)
5. Click "START", accept the "write in ISO mode" prompt if asked
6. Wait for it to finish (~5-10 minutes)

**On Linux/Mac**, use `dd` from a terminal (replace `/dev/sdX` with your
actual USB device — find it with `lsblk` or `diskutil list`, and BE CAREFUL,
picking the wrong device will destroy data on it):
```bash
sudo dd if=proxmox-ve_8.x.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

## Step 3: BIOS Configuration on the R740 (before booting the USB)

Power on the R740, press **F2** during POST to enter the iDRAC/BIOS setup
menu.

Navigate to **System BIOS Settings > Processor Settings** and confirm/enable:

- **Virtualization Technology**: Enabled (this is Intel VT-x — required for
  any VM to run at all)
- **Virtualization Technology for Directed I/O (VT-d)**: Enabled (needed if
  you ever want to pass a physical device like a NIC directly into a VM;
  enable it now even if unused today)
- **Logical Processor**: Enabled (this is hyperthreading — leave on, you
  want all 80 logical threads available)
- **Power Profile**: **"Maximum Performance"** — NOT the default "OS Control"
  or "Balanced" profile. This matters specifically for this workload: the
  default profile favors power savings and slower turbo-clock ramp-up, but
  the Gold 6248's clock speed is your primary bottleneck for the
  single-thread-bound game server processes discussed earlier in this
  project. Do not skip this setting.
- **C-States**: Disabled (C-states are power-saving CPU sleep states; disabling
  them reduces turbo-ramp latency at the cost of slightly higher idle power
  draw — the right tradeoff for a server that needs to react quickly to
  bursty single-thread game-server load)

Save and exit BIOS (F10), then boot from the USB drive. If it doesn't boot
automatically, press **F11** during POST for the one-time boot menu and
select the USB device.

## Step 4: Proxmox Installer

1. Select **"Install Proxmox VE"** from the boot menu
2. Accept the EULA
3. **Target disk**: select the RAID1 mirror you configured on the H730P
   (see note below if you haven't set up the RAID array yet)
4. **Country/timezone/keyboard**: set to your actual locale
5. **Password/email**: set a strong root password, save it in your password
   manager — this is the master credential for the whole hypervisor
6. **Network configuration**: this is your Proxmox **management** interface,
   which should land on VLAN 30 (Management) per the network design. If your
   switch/UCG-Max isn't VLAN-configured yet at this point, just use a
   temporary IP on your regular LAN for now — you can move it to the
   management VLAN after `02-network-setup.md` is done.
7. Confirm and let it install (~10 minutes), then reboot.

### If you haven't configured the H730P RAID array yet

Before installing Proxmox, you need the two 1.92TB SSDs mirrored:
1. During POST, press **Ctrl+R** (or F2 → Device Settings → PERC H730P
   Configuration Utility, depending on firmware version) to enter the RAID
   controller setup
2. Create a new **Virtual Disk**, RAID level **RAID 1**, using both 1.92TB
   SSDs
3. Save and exit — this virtual disk is what Proxmox will see as a single
   ~1.92TB drive during installation

## Step 5: First Login

After reboot, from any browser on your network (not the R740 itself), go to:
```
https://<r740-management-ip>:8006
```
Accept the self-signed certificate warning (expected on first setup — you
can replace this with a real cert later if you want, not required). Log in
as `root` with the password you set.

You'll see a popup about "No valid subscription" — this is Proxmox nagging
you about the optional paid support tier. Click OK/dismiss. This does not
limit any functionality; you're on the free, fully-featured Community
repository.

## Step 6: Switch to the No-Subscription Repository (recommended, still free)

By default Proxmox points at the "enterprise" update repo, which requires a
paid subscription key to actually pull updates. Switch to the free
"no-subscription" repo so you can still get updates:

Via the web UI: **Datacenter → <your node> → Updates → Repositories** →
disable the `pve-enterprise` repo, add the `pve-no-subscription` repo.

Or via SSH/console:
```bash
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list
apt update && apt full-upgrade -y
```

You're now ready for `scripts/01-validate-avx2.sh`.
