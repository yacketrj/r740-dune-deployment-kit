# UCG-Max Network Configuration Guide

**Device correction (2026-08-11):** this guide previously referred to a
"UCG-Fiber" throughout. The actual hardware in this deployment is a
**UCG-Max** (UCG-Max-NS) — a different Ubiquiti product with different
ports and throughput. Confirmed via Ubiquiti's own tech-specs page
(techspecs.ui.com/unifi/cloud-gateways/ucg-max): 5x 2.5GbE RJ45 ports
total, 1 default WAN port (up to 4 can be configured as WAN if ever
needed), 2.3 Gbps IDS/IPS throughput. If you have an actual UCG-Fiber
instead, the steps below are still broadly correct (same UniFi Network
application, same UI concepts) but re-check your device's real port
count and WAN handoff type (Fiber's default WAN is SFP+/fiber, not
2.5GbE RJ45) before following Step 3's port math.

This covers the UniFi OS setup on the UCG-Max: 4 VLANs, firewall
policies, and port forwards. All of this is done through the UniFi web
UI (or the UniFi mobile app) — there is no CLI scripting for this device
in this kit, since Ubiquiti doesn't expose a stable local API/CLI for
this scope of config without extra tooling. Follow this as a manual
checklist.

**This is a live, in-use home network** (AP mesh, all household devices)
per this project's Strict Requirement 7 — the steps below are
deliberately ordered to avoid touching anything already working
(existing internet access, existing Wi-Fi/mesh) until the very last,
lowest-risk step. Read through once before starting so you know where
the safe stopping points are if you need to pause partway through.

**Status on this deployment (2026-08-12):** Steps 1, 3, and 4 are
complete and independently verified.

Step 1: Prod, Dev, and Mgmt networks exist on the live gateway
(confirmed via the UniFi Integration API); the existing
Default/Trusted-LAN network was confirmed already correctly configured
and was left untouched.

Step 3: port 3 on the UCG-Max (identified via a live port-state change
when the R740's data NIC was connected) was configured as a trunk via
the UniFi web UI and verified via the legacy internal API —
`forward: customize`, `tagged_vlan_mgmt: custom`,
`native_networkconf_id: ""` (no native/untagged network, as intended).
Port 2 (iDRAC) was independently confirmed unchanged (`forward: all`,
no `tagged_vlan_mgmt` field) to rule out any accidental cross-port
effect. Port 3's physical link remained UP throughout at the same
speed, confirming the VLAN change didn't disrupt the physical link
layer.

Step 4: this gateway was running UniFi Network 10.5.67 but had **not**
yet migrated to zone-based firewalling (confirmed via the Integration
API returning `"Zone Based Firewall is not configured"` on the
firewall/zones and firewall/policies endpoints, despite the app
version being well past the 9.0.108 release that introduced it) — the
one-click **Security → Traffic & Firewall Rules → Upgrade** migration
was run first via the web UI. Three custom zones were then created via
the API (Prod-Zone, Dev-Zone, Mgmt-Zone), each containing exactly its
corresponding network, moving them out of the built-in Internal zone
which now correctly contains only the Default/Trusted-LAN network. All
7 directional policies from the table below were created and verified
present with the correct source zone, destination zone, and action via
a follow-up GET request (not just trusted from the POST response) —
paginate past the default 25-result page limit if checking manually,
since the migration itself auto-generates ~20 built-in per-zone
policies that push custom ones past the first page.

Step 5 (deferred until Prod VM exists): discovered two pre-existing
WAN port forwards (originally named `DA-UDP` 7777-7810/UDP and
`DA-TCP` 31982/TCP) already configured, pointing at `192.168.68.92`.
**Confirmed by the operator: `192.168.68.92` is the actual, currently
active game server** — not a stale leftover. A third forward was
briefly added pointing at the future Prod VLAN IP (`192.168.20.10`,
port 31983/TCP), but this was premature since nothing is listening
there yet (Proxmox/the Prod VM don't exist yet) — the operator
correctly removed it and instead consolidated all three required ports
(7777-7810/UDP, 31982/TCP, 31983/TCP) onto the two existing rules,
renamed to `DA-Game Server` and `DA-RMQ` respectively, both still
correctly pointing at `192.168.68.92` where the game server actually
runs today. 31983 was confirmed required (not internal-only) per the
upstream Core project's own setup script (`runtime/scripts/init.sh`'s
"Public hosting reminder" explicitly lists TCP 31983 alongside 31982
and the UDP game range) and its server-gateway container
(`runtime/scripts/start-server-gateway.sh`), which advertises this
port bound to the public `SERVER_IP` directly to Funcom's live
services.

**The actual cutover — repointing these forwards from `192.168.68.92`
to the new Prod VLAN IP — must happen as a deliberate, coordinated step
during the real migration window**, not before: only do this once the
new dune-prod VM exists, is running the game server, and a live
cutover has been planned (ideally with no active players, or an
announced maintenance window) — repointing a live game server's
forwards while players are connected would disconnect them mid-session
with no warning. Steps 6 onward not yet started.

## Initial Setup

1. Connect the UCG-Max's WAN port (the 2.5GbE RJ45 port labeled/default
   as WAN) to your ONT/modem handoff.
2. Connect a laptop to one of its LAN ports (or use the UniFi mobile app
   over Bluetooth for first-time setup).
3. Follow the guided setup wizard: create/log into your Ubiquiti account,
   name the site, let it detect the WAN connection.
4. Confirm you're getting your real public IP on the WAN interface (Settings
   → Internet → WAN) — should match what `curl -s https://api.ipify.org`
   reports from a device behind it.

**If this UCG-Max is already your live gateway** (as is the case here —
it already has an AP mesh and household devices behind it), Initial
Setup is already done. Skip straight to Step 1.

## Step 1: Create 3 New VLANs (Trusted-LAN Likely Already Exists)

**Check first whether "Trusted-LAN" already exists before creating
anything.** Every UniFi gateway ships with a built-in **"Default"**
network (`Settings → Networks`), pre-configured as VLAN 1, that serves
as the out-of-box LAN — if this gateway has ever been set up at all
(true here — it already has a mesh and household devices behind it),
this Default network almost certainly **is** your Trusted-LAN already,
serving whatever subnet your existing devices are already using (e.g.
`192.168.68.0/24`). Confirmed directly against a live UCG-Max via its
Integration API during this project: the existing "Default" network
was already VLAN 1 at `192.168.68.0/24`, already serving every existing
device including iDRAC — no separate "Trusted-LAN" network needed to
be created at all.

**Do not delete, rename, or renumber the existing Default network** to
force it to match the VLAN ID "10" used as a placeholder below —
renumbering an existing network modifies something every current
device depends on (forces a DHCP-lease renewal across the household)
for purely cosmetic benefit. Just use Default/VLAN 1 (or whatever your
actual existing gateway assigned) as "Trusted-LAN" in Step 4's firewall
zone policies — the specific VLAN ID doesn't matter, only that it's
distinct from Prod/Dev/Mgmt below, which it already is.

**Create only these 3 new networks.** Go to **Settings → Networks →
Create New Network** for each. For each network, set "Network Purpose"
to a **Corporate/Standard** network (not Guest — Guest networks have
extra client-isolation restrictions you don't need here, and add
complexity to inter-VM communication if you ever want it).

| Name | VLAN ID | Subnet | Purpose |
|---|---|---|---|
| *(existing) Default* | *(whatever it already is, e.g. 1)* | *(your existing subnet, e.g.* `192.168.68.0/24`*)* | Your existing devices, PC, phones, AP mesh — **do not recreate, already exists** |
| Prod | 20 | 192.168.20.0/24 | dune-prod VM |
| Dev | 21 | 192.168.21.0/24 | dune-dev VM |
| Mgmt | 30 | 192.168.30.0/24 | Proxmox host, iDRAC |

**This is unrelated to ongoing connectivity issues, if you have any.**
If devices are dropping or reconnecting unpredictably independent of
this migration, that's a separate problem (the most common cause in a
mixed mesh+UniFi setup is the mesh still running its own DHCP server
alongside the UCG-Max's — confirm the mesh is in bridge/access-point
mode, not router mode, before assuming subnetting is the issue).
Keeping the existing subnet here only avoids a migration-induced
reconnect event; it does not fix or mask an unrelated stability
problem.

**Do this first, before touching any physical ports or cabling.** Creating
these networks in the UniFi UI does not disrupt any existing traffic —
it only becomes disruptive once you start reassigning ports in Step 3,
so there's no risk yet at this stage.

**If your AP mesh is third-party** (eero, Google Nest WiFi, TP-Link Deco,
etc. — not UniFi access points), keep your existing Trusted-LAN subnet
exactly as-is and do not touch the mesh's existing port or cable at any
point in this guide. Most consumer mesh systems cannot accept an
802.1Q VLAN trunk and expect a plain untagged connection; the new
VLANs (Prod/Dev/Mgmt) are added alongside your existing network, not
by modifying it.

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

## Step 3: Assign the R740's Existing Port as a Trunk

**If the R740 is already physically cabled to the UCG-Max** (as is the
case here), you are not running new cabling in this step — you're
changing that one existing port's profile from whatever it currently
is (likely a plain, untagged LAN port) to a tagged 802.1Q trunk. The
cable itself doesn't move.

**This is the first step in this guide that touches something already
live.** It only affects the single port the R740 is connected to — your
AP mesh's port, and every other device's port, are untouched by this
step. If something goes wrong, the blast radius is limited to the R740
losing network connectivity, not your whole household.

In the UniFi Network app, go to **Devices → [your UCG-Max] → Ports**,
find the port the R740 is connected to, and set its **Port Profile**
(sometimes labeled **Native Network / Tagged Networks** depending on
UniFi Network version) to:

- **Native/Untagged Network**: leave unset, or set to none — this port
  should carry no untagged traffic
- **Tagged Networks**: select all four — the existing Default/Trusted-LAN
  network (whatever VLAN ID it already has, e.g. 1), Prod (20),
  Dev (21), Mgmt (30)

This makes the port an 802.1Q trunk carrying all four VLANs tagged.
Do NOT split this into three separate access ports even if you have
spare ports available — the VM NIC config on the Proxmox side uses
`tag=20` and `tag=21`, which emit 802.1Q-tagged frames; a plain access
port silently drops them, and the failure looks like "the VM has no
network" with no obvious cause.

**Verify immediately after applying:** confirm the R740/Proxmox host
still has network connectivity (ping it from another device, or check
the physical link light). If it drops, revert the port profile change
and re-check the VLAN IDs before retrying — this is expected to be a
one-command-away fix, not something to troubleshoot for hours.

## Step 4: Firewall Policies — Inter-VLAN Isolation

**UniFi Network 9.0+ uses zone-based firewalling**, not a flat ordered
list of Allow/Block rules. If your UniFi Network app still shows the
older rule-list UI, migrate first: **Security → Traffic & Firewall
Rules → Upgrade** (Ubiquiti's own migration tool — takes seconds, no
downtime, and produces functionally identical rules before you add
anything new). If you already see **Security → Zones** or a **Zone
Matrix**, you're already on the new model — skip the migration step.

By default, every new network you created in Step 1 is placed in the
built-in **Internal** zone, and Internal→Internal traffic is
**Allow All** — this is exactly why Prod/Dev/Mgmt can currently reach
each other and your Trusted-LAN devices freely, and why this step
exists.

**Recommended approach:** create three custom zones (e.g. `Prod-Zone`,
`Dev-Zone`, `Mgmt-Zone`) and move the Prod, Dev, and Mgmt networks into
them respectively (a network can only belong to one zone at a time,
set when editing the network or in the Firewall/Zones section). Leave
Trusted-LAN in the default **Internal** zone. Then, in the **Zone
Matrix** (**Settings → Zones** or **Settings → Policy Table**,
depending on your UniFi Network version), configure:

1. **Internal → Mgmt-Zone: Allow** (so you can reach the Proxmox web UI
   and iDRAC from your normal devices)
2. **Internal → Prod-Zone: Allow, Internal → Dev-Zone: Allow** (so you
   can reach the consoles via VPN/local access — see Step 6)
3. **Dev-Zone → Prod-Zone: Block** (Dev should never reach Prod
   directly — this is the blast-radius containment discussed earlier)
4. **Prod-Zone → Dev-Zone: Block** (same, other direction)
5. **Prod-Zone → Mgmt-Zone: Block, Dev-Zone → Mgmt-Zone: Block**
   (neither battlegroup VM should be able to reach the Proxmox
   hypervisor or iDRAC — if a VM is ever compromised, this stops it
   from pivoting to the hypervisor layer)
6. Leave every zone pair not listed above at its **default** value —
   do not manually add a blanket "default deny" policy on top of the
   zone matrix; the built-in per-zone defaults (e.g. External→Internal
   already defaults to block-except-return-traffic) already provide
   this, and adding a conflicting custom rule can produce confusing,
   hard-to-debug interactions with the built-in policies.

**Double-check both directions for every rule.** Per Ubiquiti's own
documentation, blocking Zone A → Zone B does not automatically block
Zone B → Zone A — you must configure both directions explicitly, which
is why rules 3/4 and the two halves of rule 5 are listed as separate
entries above.

**Do not block traffic to the built-in Gateway zone** for any of your
new zones — this handles DHCP/DNS/management traffic for the UCG-Max
itself, and blocking it can break basic network function in
hard-to-diagnose ways.

## Step 5: WAN Port Forwards (Prod ONLY)

**This step is a cutover, not an additive setup step — do it last, and
only when dune-prod is actually ready to take over.** If this gateway
already has an active game server running on the old flat Trusted-LAN
(true for this deployment: forwards already exist pointing at a
currently-live game server), do NOT create a second, parallel set of
forwards pointing at the new Prod VLAN IP ahead of time — nothing is
listening there until the new dune-prod VM exists and is actually
running the game server, so an early forward is dead weight at best,
and repointing the *existing* forwards early would disconnect real
players with no warning.

**All three ports are required, including 31983** — this is not an
internal-only port that can be skipped. Confirmed via the upstream
Core project's own setup wizard (`runtime/scripts/init.sh`'s "Public
hosting reminder" lists TCP 31983 alongside 31982 and the UDP game
range) and its server-gateway container, which advertises this port
bound to the public server IP directly to Funcom's live services as
part of the standard player-connection path.

**When dune-prod is actually ready** (game server running, tested,
ready to take live traffic), do the cutover as a single deliberate
step, ideally during a maintenance window with players warned in
advance or with none currently connected: update the *existing*
forward rules' target IP from the old device to `192.168.20.10` (pick
and note down a static IP for dune-prod's VM). Editing the existing
rules in place (rather than deleting and recreating) preserves
whatever WAN-side dependent config (DNS, monitoring, firewall logging
history) already references those rule IDs.

Go to **Settings → Firewall & Security → Port Forwarding**, and update
(or, on a fresh setup with no pre-existing rules, create) these three
rules to point at **dune-prod's VM IP**:

| Name | WAN Port(s) | Forward IP | Forward Port(s) | Protocol |
|---|---|---|---|---|
| Dune Game Traffic | 7777-7810 | 192.168.20.10 | 7777-7810 | UDP |
| Dune RMQ Game | 31982 | 192.168.20.10 | 31982 | TCP |
| Dune RMQ HTTP | 31983 | 192.168.20.10 | 31983 | TCP |

**Do NOT create a port forward for 8088 (admin console) on either VM.**
This is intentional — the admin console is reached via VPN only (Step 6),
never directly from the internet. This directly closes the CRIT-01-class
exposure identified earlier in this project (the live gaming-PC setup
currently has its console tunnel hostname pointed at the console over a
Cloudflare Tunnel with no additional access gate — don't reproduce that
here without at least Cloudflare Access in front of it, see
`04-post-standup-hardening.md`).

**Dev gets no port forwards at all** — per the original Phase 0 decision,
Dev is LAN/VPN-only, no public testers.

## Step 6: VPN Access for Remote Admin

Go to **Settings → VPN → Teleport** (Ubiquiti's zero-config WireGuard VPN)
or **Settings → VPN → WireGuard** (manual config) and set up a VPN profile
for yourself. Install the WiFi Man or UniFi app on your phone/laptop, enable
Teleport, and confirm you can connect from outside your LAN (e.g., phone on
cellular data) and reach `192.168.20.10:8088` or `192.168.21.10:8088`
through the tunnel.

This is how you'll reach both consoles remotely without ever exposing them
directly to the WAN.

## Step 7: Verify Throughput and Existing Devices Before Moving On

1. From a device on the Trusted-LAN VLAN, run a speed test (fast.com or
   speedtest.net) and confirm you're seeing close to your full ISP
   throughput — this validates the UCG-Max isn't bottlenecking your
   connection.
2. **Confirm your AP mesh and all household devices still have working
   internet/Wi-Fi.** Since the mesh's port was never touched in this
   guide, this should already be the case — but verify explicitly
   rather than assume, given everything else on this network was live
   throughout this change.
3. Confirm the R740/Proxmox host still has connectivity after the
   Step 3 trunk-port change (re-check if you skipped the inline
   verification in that step).

Once VLANs, firewall policies, port forwards, and the trunk port are in
place and verified — and your existing devices/mesh are confirmed
unaffected — move to `scripts/01-validate-avx2.sh` on the Proxmox side.
