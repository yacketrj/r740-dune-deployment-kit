# UCG-Fiber Network Configuration Guide

This covers the UniFi OS setup on the UCG-Fiber: 4 VLANs, firewall rules,
and port forwards. All of this is done through the UniFi web UI (or the
UniFi mobile app) — there is no CLI scripting for this device in this kit,
since Ubiquiti doesn't expose a stable local API/CLI for this scope of config
without extra tooling. Follow this as a manual checklist.

## Initial Setup

1. Connect the UCG-Fiber's WAN port to your ONT/fiber handoff.
2. Connect a laptop to one of its LAN ports (or use the UniFi mobile app over
   Bluetooth for first-time setup).
3. Follow the guided setup wizard: create/log into your Ubiquiti account,
   name the site, let it detect the WAN connection.
4. Confirm you're getting your real public IP on the WAN interface (Settings
   → Internet → WAN) — should match what `curl -s https://api.ipify.org`
   reports from a device behind it.

## Step 1: Create the 4 VLANs

Go to **Settings → Networks → Create New Network** for each of the
following. For each network, set "Network Purpose" to a **Corporate/Standard**
network (not Guest — Guest networks have extra client-isolation restrictions
you don't need here, and add complexity to inter-VM communication if you
ever want it).

| Name | VLAN ID | Subnet | Purpose |
|---|---|---|---|
| Trusted-LAN | 10 | 192.168.10.0/24 | Your existing devices, PC, phones |
| Prod | 20 | 192.168.20.0/24 | dune-prod VM |
| Dev | 21 | 192.168.21.0/24 | dune-dev VM |
| Mgmt | 30 | 192.168.30.0/24 | Proxmox host, iDRAC |

Note: if your existing LAN devices are already on a different subnet
(e.g., the `192.168.68.0/22` seen on the current gaming PC), you can either
renumber everything to match this table, or keep your existing Trusted-LAN
subnet as-is and just add VLANs 20/21/30 as the new ones — the exact Trusted
subnet doesn't matter, what matters is that Prod/Dev/Mgmt are separate
VLANs from it and from each other.

## Step 2: Proxmox Bridge Configuration (DO THIS FIRST)

Before cabling, configure the Proxmox bridge as **VLAN-aware** so VM
network interfaces with `tag=` actually receive the correct VLAN:

```bash
# On the Proxmox host, edit /etc/network/interfaces
# Add bridge-vlan-aware yes to vmbr0:
auto vmbr0
iface vmbr0 inet manual
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10 20 21 30
# After editing, apply:
ifreload -a
```

**Without this setting, VLAN tags on VM network interfaces are silently
ignored and both VMs fall onto the same untagged broadcast domain —
breaking the entire inter-VLAN security model with no visible symptom.**

## Step 3: Assign the UCG-Fiber Port as a Trunk

Use a single LAN port on the UCG-Fiber configured as a **trunk port**
carrying all four VLANs tagged:

- Pick one UCG-Fiber LAN port and set it to carry VLANs 10, 20, 21, 30
  tagged (802.1Q trunk)
- Connect the R740's vmbr0 physical port (eno1 or equivalent) to this
  UCG-Fiber trunk port
- The remaining three R740 NIC ports are free for future LACP bonding,
  a dedicated management path, or a failover link

**Important:** This is a trunk-port topology — one cable, multiple tagged
VLANs. Do NOT configure three separate access ports. The VM NIC config
uses `tag=20` and `tag=21` which emit 802.1Q-tagged frames. An access
port would drop them.

## Step 3: Firewall Rules — Inter-VLAN Isolation

By default, UniFi allows all VLANs to talk to each other freely. You want
to lock this down. Go to **Settings → Firewall & Security → Create New
Rule** and add these, in this order (rules are evaluated top-down, first
match wins):

1. **Allow: Trusted-LAN → Mgmt** (so you can reach the Proxmox web UI and
   iDRAC from your normal devices)
2. **Allow: Trusted-LAN → Prod, Trusted-LAN → Dev** (so you can reach the
   consoles via VPN/local access — see Step 5)
3. **Block: Dev → Prod** (Dev should never be able to reach Prod directly —
   this is the blast-radius containment discussed earlier)
4. **Block: Prod → Dev** (same, other direction)
5. **Block: Prod → Mgmt, Dev → Mgmt** (neither battlegroup VM should be able
   to reach the Proxmox hypervisor or iDRAC — if a VM is ever compromised,
   this stops it from pivoting to the hypervisor layer)
6. **Allow: established/related** (standard stateful return-traffic rule —
   UniFi usually has this by default, confirm it exists)
7. **Default deny** for everything else not explicitly allowed above

## Step 4: WAN Port Forwards (Prod ONLY)

Go to **Settings → Firewall & Security → Port Forwarding → Create New
Port Forward**. Add these three rules, all pointing at **dune-prod's VM IP**
(e.g., `192.168.20.10` — pick and note down a static IP for it):

| Name | WAN Port(s) | Forward IP | Forward Port(s) | Protocol |
|---|---|---|---|---|
| Dune Game Traffic | 7777-7810 | 192.168.20.10 | 7777-7810 | UDP |
| Dune RMQ Game | 31982 | 192.168.20.10 | 31982 | TCP |
| Dune RMQ HTTP | 31983 | 192.168.20.10 | 31983 | TCP |

**Do NOT create a port forward for 8088 (admin console) on either VM.**
This is intentional — the admin console is reached via VPN only (Step 5),
never directly from the internet. This directly closes the CRIT-01-class
exposure identified earlier in this project (the live gaming-PC setup
currently has `console.darkdante.org` pointed at the console over a
Cloudflare Tunnel with no additional access gate — don't reproduce that
here without at least Cloudflare Access in front of it, see
`04-post-standup-hardening.md`).

**Dev gets no port forwards at all** — per the original Phase 0 decision,
Dev is LAN/VPN-only, no public testers.

## Step 5: VPN Access for Remote Admin

Go to **Settings → VPN → Teleport** (Ubiquiti's zero-config WireGuard VPN)
or **Settings → VPN → WireGuard** (manual config) and set up a VPN profile
for yourself. Install the WiFi Man or UniFi app on your phone/laptop, enable
Teleport, and confirm you can connect from outside your LAN (e.g., phone on
cellular data) and reach `192.168.20.10:8088` or `192.168.21.10:8088`
through the tunnel.

This is how you'll reach both consoles remotely without ever exposing them
directly to the WAN.

## Step 6: Verify Throughput Before Moving On

From a device on the Trusted-LAN VLAN, run a speed test (fast.com or
speedtest.net) and confirm you're seeing close to your full 2Gbps — this
validates the UCG-Fiber isn't bottlenecking your fiber line, which was the
whole reason you replaced the Deco mesh unit for this role.

Once VLANs, firewall rules, and port forwards are in place and verified,
move to `scripts/01-validate-avx2.sh` on the Proxmox side.
