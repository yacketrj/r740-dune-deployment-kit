# 07 - Live state and performance tuning (2026-11-20)

**Status:** Current as of 2026-11-20 (Pacific). This file records what the
live R740 looks like now and the tuning done during the 2026-11-19/20
rubberbanding investigation. `00-START-HERE.md` and
`scripts/02-provision-vms.sh` describe the original plan and sizing; where
they disagree with this file, this file matches the live host. The full
evidence and findings are in `Project-Arrakis/meta`
`archive/sessions/2026-11-19-rubberbanding-investigation.md` (tracking:
`meta`#99, fork issue 1352).

## 1. What is deployed now (verified against the live host)

| Item | Live value |
|---|---|
| Hardware | Dell R740, 2x Xeon Gold 6248 (20c/40t each, 2.5 GHz base, 3.9 GHz turbo), 256 GB DDR4-2400 as 8x32 GB (4 DIMMs per socket, 4 of 6 channels used) |
| dune-prod (VM 101) | 60 vCPUs (2 sockets x 30 cores), 192 GB, `balloon: 0`, two vNUMA nodes: node 0 = vCPUs 0-39 with 112 GB bound to host node 0, node 1 = vCPUs 40-59 with 80 GB bound to host node 1; CPU affinity = host node 0 even threads plus node 1 odd threads 41-79 |
| dune-dev (VM 102) | 8 vCPUs, 26 GB, affinity on host odd threads 1-39 (node 1), `vga: std` (changed 2026-11-20), `e1000e` NIC |
| Memory per socket | 128 GB. The prod VM's 192 GB therefore cannot fit on one socket, so a single-socket prod layout needs a memory cut. The operator decided **not** to reduce prod memory (ceilings of 3 Sietches, 3 Deep Deserts and dynamic maps exceed 112 GB) |
| Guest | Ubuntu 26.04, game engine single-thread bound per map, `kernel.numa_balancing=1` |

Why the original "40 vCPU on socket 0, 152 GB" plan was superseded: see
the dune-prod rebuild notes in `Project-Arrakis/meta`'s README (2026-09-28)
and `01`/`02` historical headers.

## 2. BIOS profile (applied 2026-11-20 ~10:20 PT)

Finding: the live host was on `SysProfile = PerfPerWattOptimizedDapc`
(C-states and C1E on, dynamic uncore, Dell-controlled power/performance),
not the "Maximum Performance" profile this kit specified. Busy cores peaked
about 3.2-3.3 GHz against a 3.9 GHz turbo. The game's main thread per map is
single-threaded, so per-core speed is the limit.

Change: `SysProfile = PerfOptimized`. Setting this profile sets the related
attributes. Applied result, read back from iDRAC after the reboot:

| Attribute | Before | After |
|---|---|---|
| `SysProfile` | `PerfPerWattOptimizedDapc` | `PerfOptimized` |
| `ProcCStates` | Enabled | Disabled |
| `ProcC1E` | Enabled | Disabled |
| `UncoreFrequency` | `DynamicUFS` | `MaxUFS` |
| `ProcPwrPerf` | `SysDbpm` | `MaxPerf` |
| `EnergyPerformanceBias` | `BalancedPerformance` | `MaxPower` (max performance) |
| `PcieAspmL1` | Enabled | Disabled |
| `CpuInterconnectBusLinkPower` | (default) | Disabled |

Turbo and Hyper-Threading are unchanged (enabled). Idle power rose from about
246 W to about 275 W; fans ran at about 6000 RPM right after boot with CPUs
at 45-47 C (inlet 20 C), recheck after settling.

How it was applied (Redfish, staged for the next reset, no immediate reboot):
read the current attributes (`GET .../Bios`) and save them for rollback;
confirm `PerfOptimized` is allowed in `.../Bios/BiosRegistry`; then
`PATCH .../Bios/Settings` with `{"Attributes":{"SysProfile":"PerfOptimized"},
"@Redfish.SettingsApplyTime":{"ApplyTime":"OnReset"}}`; the job then runs at
the next host reboot. Authenticate with the iDRAC credential from your
password manager; never put it in this repo.

Rollback: set `SysProfile` back to `PerfPerWattOptimizedDapc` the same way
and reboot once more.

Measurement (pending, needs players back): events per day and longest burst
against the 2026-11-18/19 baseline (about 1.2 Atrium events per hour), and
busy-core clocks (success looks like about 3.8-3.9 GHz). If clocks do not
rise, the profile was not the limit and the next step is hardware.

**Open security item:** iDRAC is still on its factory-default admin password
and sits on the main LAN (audit finding F20). Change it as its own change.

## 3. Game containers pinned to NUMA node 0 (guest side)

Finding: game processes had 30-90% of their memory on the far NUMA node
before pinning (remote access about 2.1x slower). The VM keeps its 192 GB
across both sockets, so the fix is inside the guest: pin every map-server
container to guest node 0 CPUs (`0-39`) and let automatic NUMA balancing
move pages to node 0.

Persistence: `docker update --cpuset-cpus` is lost when a container is
recreated (the daily 05:00 restart, dynamic map starts). The pin is
therefore a service on the prod guest, kept in this repo at
`scripts/guest/`:

- `dune-game-pin.sh` - pins every `dune-server-*` container except the
  gateway to cpuset `0-39` (override with `DUNE_PIN_CPUSET`) when it runs and
  again on every container start event.
- `dune-game-pin.service` - systemd unit, `After=docker.service`,
  `Restart=always`.

Install (on the prod guest, as root):

```bash
install -m 755 scripts/guest/dune-game-pin.sh /usr/local/sbin/dune-game-pin.sh
install -m 644 scripts/guest/dune-game-pin.service /etc/systemd/system/dune-game-pin.service
systemctl daemon-reload && systemctl enable --now dune-game-pin
```

Verify: `docker inspect -f '{{.HostConfig.CpusetCpus}}' <map container>`
prints `0-39`; a newly started `dune-server-*` container is pinned within a
second (tested with a throwaway container). `dune doctor` warns about
container cpusets; that warning is expected here.

Undo: `systemctl disable --now dune-game-pin`, then
`docker update --cpuset-cpus 0-59 <container>` for each container.

The dune-dev VM is not pinned this way (different CPU layout).

## 4. Display adapter: QXL removed (prod)

Finding: on 2026-11-20 a `qm shutdown` of dune-prod hung. The guest's `qxl`
display driver wedged during shutdown (`qxl_fence_wait` stuck, then
`[TTM] Buffer eviction failed` repeating roughly 290,000 times), so the guest
never powered off and Proxmox reported "VM quit/powerdown failed". The
previous boot showed the same driver errors. dune-dev showed the same failure on its earlier stop.

Changes on dune-prod:

- Proxmox: `qm set 101 --vga std` (was `qxl`), takes effect at the next full
  stop/start. Undo: `qm set 101 --revert`, or set `--vga qxl`.
- Guest: `/etc/modprobe.d/blacklist-qxl.conf` containing `blacklist qxl` and
  `install qxl /bin/false`, then `update-initramfs -u`. After boot the guest
  uses the `bochs` framebuffer driver. Undo: delete the file and run
  `update-initramfs -u`.
- `vga: none` was considered and not used: the guest has no serial login
  configured (`serial-getty@ttyS0` disabled), so `none` would leave no
  console if networking or sshd failed.

dune-dev got the same change on 2026-11-20: `qm set 102 --vga std`, the same
`blacklist-qxl.conf` plus `update-initramfs -u`, and a full stop/start. Its
`qm shutdown` completed gracefully (no force-stop), the guest uses the `bochs`
framebuffer and `qxl` is not loaded; the game was READY afterwards.

When stopping a VM for a host reboot: run `dune stop` first, then
`qm shutdown <id> --timeout 120`, and `qm stop <id>` only if it has not
powered off after about two minutes (the game is already stopped cleanly).

## 5. Left unchanged on purpose / open

- **Prod memory stays 192 GB** (operator decision). Do not stage a smaller
  size.
- **VM NIC is the emulated `e1000e`** (not virtio). Impact unmeasured. A
  change can rename the guest interface, so do it as its own window with a
  console fallback.
- **Memory balance:** 4 DIMMs per socket on 4 of 6 channels. Adding 2 DIMMs
  per socket (or moving 2 from socket 1 to socket 0) is a separate hardware
  decision.
- **CPU swap:** the Gold 6244 (8c, 3.6/4.4 GHz) is confirmed R740-compatible by
  Dell; the 6250, 6256 and 6246 are unconfirmed for the R740. Not priced.
- **ksmtuned stays stopped and disabled** on the host (`/sys/kernel/mm/ksm/run`
  must read 0, never set `run=2`); it caused a 63 s all-maps freeze on
  2026-11-11.
