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

## Step 2: Assign Physical Ports

Under **Settings → Networks → Port Manager** (or per-port config on the
UCG-Fiber's switch ports):

- Pick one LAN port and tag it for VLAN 20 (Prod) — this is where the R740's
  first NIC port connects
- Pick another LAN port and tag it for VLAN 21 (Dev) — R740's second NIC port
- Pick another and tag it for VLAN 30 (Mgmt) — R740's third NIC port (or
  iDRAC's dedicated port, if your R740 has a separate iDRAC NIC — check
  the back of the chassis; if iDRAC has its own port, use that for VLAN 30
  instead of consuming a 4th data NIC port for it)
- Leave remaining ports on the default Trusted-LAN VLAN for your existing
  devices

This uses 3 of the R740's 4 onboard RJ45 ports (Prod, Dev, Mgmt), leaving
1 spare — fine for now, gives you headroom for a future LACP bond or a
second Mgmt path later if you want it.

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
