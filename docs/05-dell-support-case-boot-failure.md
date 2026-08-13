# Dell ProSupport Case: PowerEdge R740xd — Persistent "No bootable devices" / UEFI boot failure across all boot media

**Status as of 2026-08-13: Operationally resolved. Dell's formal RCA report
has not yet been received.** Proxmox VE is confirmed installed and running
on this exact host (`pveversion`: `pve-manager/9.2.2`, service tag `DMYV0S2`
still matches) as of this update. Resolution occurred via a live Dell
ProSupport AnyDesk remote session -- **do not treat any specific root cause
below as confirmed** until Dell's written report arrives; this section will
be updated again once it does.

**Operator's working theory, pending Dell's written confirmation:** a missed
step in properly mounting the installer ISO via iDRAC Virtual Media -- i.e.
the extensive troubleshooting documented below (sections 1-10) may have been
chasing a real symptom with an operational, not hardware, root cause. This
is explicitly a working theory, not a verified finding -- everything in
"What This Rules Out" below was independently confirmed at the time via the
Redfish API and remains accurate as a record of what was tested; it does not
necessarily mean those causes are still believed to be ruled out if the
actual root cause turns out to be procedural rather than hardware-level.

The original 2026-08-12 case writeup below is preserved as-is (not rewritten
retroactively) since it's the actual case history submitted for support and
has genuine value as a troubleshooting reference for anyone hitting a
similar "No bootable devices" symptom on iDRAC9/R740-class hardware --
several of the negative results (ISO-agnostic failure, USB-vs-Virtual-Media
parity, firmware-update-independent) remain useful data points regardless of
the final root cause.

---

**Original status as of 2026-08-12 (preserved for history):** Unresolved.
Every reasonable software/firmware/config avenue has been exhausted and
independently verified via the iDRAC Redfish API and Virtual Console. This
document is the case writeup intended for submission to Dell ProSupport, and
is checked into this repo (not `/tmp` or any other non-persistent location)
so it survives reboots and remains available for follow-up.

## System Identification

| Field | Value |
|---|---|
| Model | PowerEdge R740xd |
| Service Tag | DMYV0S2 |
| Serial Number | CNFCP0088V01DR |
| BIOS Version | 2.27.0 |
| iDRAC Firmware | 7.00.00.184 |
| Access Method | Remote (iDRAC9, Redfish API + Virtual Console) — no physical/VGA console access available |

## Summary

This system cannot boot from **any** UEFI boot media — USB flash drive, iDRAC
Virtual Media (CD/DVD), or any OS installer ISO tested — despite the media
being correctly detected, named, and enabled as a valid UEFI boot option. The
firmware ultimately reports **"No bootable devices"** (or, prior to the most
recent BIOS factory reset, "Boot failed: please ensure a compatible bootable
media is available" / generic USB device naming) after cycling through the
full boot order.

This is a fresh, out-of-service deployment attempt — the system has never had
an OS successfully installed. This is not a regression from a previously
working state; it has never successfully booted an installer.

## Environment

- R740xd is intended to run Proxmox VE as a hypervisor for a home game-server
  virtualization project (see `docs/01-proxmox-install.md` in this repo).
- No OS has ever been successfully installed on this system.
- RAID1 virtual disk exists and reports healthy: `Disk.Virtual.0:RAID.Slot.6-1`,
  Name `DA-Disks`, RAIDType RAID1, ~1.92TB, Status Health=OK/State=Enabled (via
  PERC H730P, RAID.Slot.6-1). This virtual disk has never had a filesystem or
  bootloader written to it — it is empty/fresh.
- Remote access only: iDRAC9 Enterprise, accessed via web UI, Virtual Console,
  and the Redfish API. No physical monitor/keyboard access is available at
  this time.

## Timeline and Troubleshooting Steps Taken (in order)

### 1. Initial attempts — physical USB media

- Created a bootable USB using Rufus in **DD (raw) image mode** (not
  ISO/file-copy mode — confirmed this is the correct mode for this ISO type;
  Rufus itself flagged the Proxmox ISO as "ISOHybrid, not compatible with
  ISO/file-copy mode" and auto-enforced DD mode).
- **Result:** `Boot failed: please ensure a compatible bootable media is
  available`. F11 one-time boot menu showed the device generically as
  "Generic USB" rather than a named device.
- Verified ISO integrity via SHA256 checksum against the official published
  value on proxmox.com before writing — checksum matched exactly. ISO used:
  **Proxmox VE 9.2-1**
  (`4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c`).
- Confirmed USB connected to a rear-panel USB port (not front panel).

### 2. Ruled out USB-transport-specific and BIOS-setting causes

- Confirmed via System Setup (prior to any reset): Boot Mode = UEFI, Secure
  Boot = Disabled, UEFI Boot Sequence included the USB device and was
  checked/enabled.
- Confirmed "Generic USB Boot" BIOS option was Enabled (this is a legitimate
  compatibility fallback for USB enumeration, not a misconfiguration — left
  enabled per its intended purpose).

### 3. Ruled out physical-USB-specific causes — switched to iDRAC Virtual Media

- Mounted the identical, checksum-verified Proxmox VE 9.2-1 ISO via iDRAC
  Virtual Media (Virtual Optical Drive), bypassing USB entirely.
- **Result:** Identical failure — "Boot failed," generic device naming.
- This ruled out USB controller/enumeration-specific causes, since Virtual
  Media uses a completely different code path (emulated virtual CD, not USB
  mass storage in the traditional sense on this platform).

### 4. Full Dell firmware update campaign

- Performed a complete Dell firmware update across all available components
  (BIOS, iDRAC, NIC, PERC, backplane, etc. — 8 components updated per Dell's
  own update tooling).
- Confirmed post-update firmware versions via Redfish
  `UpdateService/FirmwareInventory`:
  - BIOS: 2.27.0 (confirmed by operator this was already the latest available
    version — no newer BIOS existed to install)
  - iDRAC: 7.00.00.184
  - RAID.Slot.6-1: 25.5.9.0001
  - RAID.Backplane.Firmware.1: 2.52
  - NIC.Integrated.1 (all 4 ports): 23.61.3
  - CPLD: 1.1.4
- **Retried boot after full firmware update — identical failure.** This rules
  out a known/patched firmware bug as the cause, since the latest available
  firmware for every updatable component was already installed.

### 5. Ruled out ISO-specific / Proxmox-specific causes

- Downloaded and tested **Ubuntu 26.04** installer ISO via the identical iDRAC
  Virtual Media path.
- **Result:** Identical failure. This rules out any Proxmox-ISO-specific
  incompatibility (e.g., a GRUB2/shim build issue specific to Proxmox's
  installer) — the failure is media/transport/OS-agnostic.

### 6. BIOS factory-defaults reset via Redfish

Given no physical console access was available and the iDRAC HTML5 Virtual
Console's F-key passthrough (F9/F10/F12) was **completely unresponsive**
(confirmed: arrow keys, Enter registered correctly in Virtual Console;
F9/F10/F12 registered nothing, tested via both physical keyboard focus and
the Virtual Console's on-screen macro/keyboard panel) — the factory-defaults
reset was instead performed via the **iDRAC Redfish API** directly:

```
POST /redfish/v1/Systems/System.Embedded.1/Bios/Actions/Bios.ResetBios
Body: {"ResetType": "default"}
```
→ 200 OK, `BIOSRTDRequested` flag set TRUE, confirmed to require a subsequent
restart.

Followed by:
```
POST /redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset
Body: {"ResetType": "GracefulRestart"}
```

- System entered System Setup automatically post-reset (expected Dell
  behavior after a BIOS RTD).
- A subsequent `ForceRestart` was required to actually progress past the
  Setup screen (system appeared to hang at Setup indefinitely on the first
  `GracefulRestart` alone — unclear if this is expected or itself anomalous).
- Post-reset, confirmed via Redfish that defaults were correctly applied:
  `BootMode: Uefi`, `SecureBoot: Disabled`, `ProcVirtualization: Enabled`.
- **Boot options were correctly re-enumerated post-reset**, including a
  properly and specifically named USB device: `Boot0003: "Disk connected to
  back USB 1: USB Flash Disk"`, UEFI device path
  `PciRoot(0x0)/Pci(0x14,0x0)/USB(0xA,0x0)`, `BootOptionEnabled: True`.
- **Retried boot with the freshly-reset BIOS and the same Proxmox USB stick —
  identical failure**, now cycling through the full boot order and hanging
  specifically at the PXE boot option before cycling again (continuous loop
  observed for 10+ minutes on Virtual Console).

### 7. Encountered and resolved an unrelated iDRAC job-queue deadlock

During the above, one BIOS-Settings PATCH via Redfish (an initial, malformed
attempt using an invalid `BootSourceOverrideTarget: "UefiBootNext"` value)
left a **stuck configuration job** (`Configure: BIOS.Setup.1-1`) in a
permanent `Scheduling` state with message `"Lifecycle Controller in use.
This job will start when Lifecycle Controller is available."` This job could
not be deleted via the standard Redfish `DELETE` job endpoint (`500 - Unable
to complete the operation because the provider is not ready`), even after a
full host `ForceOff`. **Restarting iDRAC itself** (`POST
/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset`,
`GracefulRestart`) was required to clear this stuck job — the job then
transitioned to `Failed` and was successfully deleted afterward. Flagging
this separately in case it's a known iDRAC 7.00.00.184 issue worth Dell's
awareness, independent of the primary boot problem.

### 8. Disabled PXE to rule out a boot-order-timeout confound

- PXE (`PxeDev1EnDis`) had been re-enabled by the factory-defaults reset
  (expected Dell default behavior).
- Disabled via Redfish with an explicit `@Redfish.SettingsApplyTime:
  {"ApplyTime": "OnReset"}` to correctly create a real BIOS config job (first
  attempt without this parameter returned `200 OK` but created no actual
  config job — silently did not apply on a plain OS-level graceful restart; a
  genuine config job, visible as `JobState: Scheduled` → `Running` →
  `Completed`, was required for the change to actually take effect).
- Confirmed post-reboot via Redfish: `PxeDev1EnDis: Disabled`, and boot
  options collection now correctly shows only 3 entries (PXE entry removed):
  Virtual Floppy Drive, Virtual Optical Drive, and the USB Flash Disk
  (`Boot0003`, still correctly enabled and named).

### 9. Most direct evidence — firmware confirms no bootable device found

With PXE removed as a variable, the system proceeds through the full
(reduced) boot order and reports, verified directly via Redfish:

```
BootProgress: {"LastState": "OEM", "OemLastState": "No bootable devices."}
```

This is reported **despite** `Boot0003` (the USB Flash Disk) being present,
correctly named, and `BootOptionEnabled: True` at the time of this failure.
This is the clearest evidence yet that the system enumerates the media
correctly at the firmware/boot-option level but fails to actually
locate/execute a valid boot loader on it — on **every** media type and
transport tested.

### 10. Failure confirmed to persist across an iDRAC restart; iDRAC also crashed spontaneously (2026-08-12)

While continuing to monitor the boot-cycle failure via Virtual Console,
**iDRAC itself became unresponsive and restarted on its own**, with no
explicit reset command issued at that moment. This was first observed as the
Redfish API returning `HTTP 500` (`"Unable to complete the operation because
the provider is not ready"`) on a routine status-check call, then
transitioning to a fully unreachable state (connection refused/timeout —
`curl` exit with no HTTP response at all) for approximately 3 minutes before
the Redfish API became reachable again.

Once iDRAC recovered, **the host's boot-cycle failure was confirmed
unchanged** — Virtual Console showed the identical continuous behavior
(cycling through all remaining boot options, finding none bootable) both
immediately before and immediately after the unplanned iDRAC restart. This is
a useful negative-result data point: it rules out "the current iDRAC
session/state itself" as a contributing cause, since a completely fresh
iDRAC instance (post-restart) reproduces the identical host-side symptom
against the same, unchanged BIOS/boot configuration.

Separately, **this spontaneous iDRAC restart is itself worth flagging to
Dell** as a secondary reliability observation on iDRAC firmware 7.00.00.184,
independent of the primary boot-device issue — this is the second iDRAC-side
instability observed during this investigation (the first being the stuck
configuration-job deadlock in step 7, which also required an iDRAC restart to
clear). Two independent iDRAC-availability issues in a single troubleshooting
session, on the same firmware version, may be worth Dell checking against
known issues for `7.00.00.184`.

## What This Rules Out (high confidence, independently verified at each step)

- ❌ Bad/corrupt ISO — 2 different OS ISOs (Proxmox VE 9.2-1, Ubuntu 26.04),
  Proxmox ISO checksum independently verified against the official published
  value.
- ❌ USB drive/write-mode issue — identical failure via iDRAC Virtual Media
  (no USB stick involved at all).
- ❌ Outdated/buggy firmware — identical failure after a complete firmware
  update across all 8 updatable components to their latest available
  versions.
- ❌ Stale/corrupted BIOS settings or NVRAM boot-order corruption — identical
  failure after a complete factory-defaults BIOS reset via Redfish,
  independently confirmed applied (BootMode/SecureBoot/ProcVirtualization all
  read back as expected defaults).
- ❌ PXE-related boot-order timeout masking a working USB path — identical
  failure ("No bootable devices") after PXE was fully disabled and removed
  from the boot options collection.
- ❌ Boot Mode / Secure Boot / UEFI Boot Sequence misconfiguration — confirmed
  correct both before and after the factory reset.
- ❌ Wrong USB port — confirmed rear-panel port used throughout.
- ❌ Current iDRAC session/state contributing to the failure — identical
  failure confirmed immediately before and after an unplanned iDRAC restart
  (step 10).

## What Has Not Been Ruled Out / Requested from Dell

- A genuine hardware fault in the UEFI boot-execution subsystem
  (motherboard-level USB/UEFI boot chipset interaction, or a fault specific to
  how this system validates a GPT/ESP boot structure before execution).
- Whether `Boot0003`'s correct enumeration/naming but subsequent "No bootable
  devices" result during actual boot attempt is a known symptom Dell has
  documented for this platform/BIOS version, with or without a
  firmware/hardware remediation path.
- Whether on-site/remote diagnostics (e.g., ePSA/Dell diagnostics boot, which
  is itself listed as a boot option candidate —
  `Diagnostics.Embedded.1:LC.Embedded.1`, firmware 4301A73 currently
  installed) can further isolate this, given the same "no bootable devices"
  symptom might also apply to Dell's own diagnostic boot media — this has not
  yet been tested and may be a useful next diagnostic step Dell support can
  guide.
- Whether this specific Service Tag has any open recall, known erratum, or
  hardware advisory related to boot-device enumeration or UEFI execution on
  this BIOS branch.
- Whether iDRAC firmware 7.00.00.184 has any known stability issues matching
  the two independent instability events observed in this session (stuck
  configuration job requiring an iDRAC restart to clear; a separate, later
  spontaneous/unprompted iDRAC restart) — requesting Dell confirm whether an
  iDRAC firmware issue could also be contributing to or masking diagnosis of
  the primary boot problem.

## Access Constraints for Remote Support

- No physical monitor/keyboard/VGA adapter available on-site currently — all
  diagnosis must occur via iDRAC (Virtual Console, Redfish API, or SSH
  racadm if Dell support prefers that interface).
- iDRAC Virtual Console F-key passthrough (F9/F10/F12) has been
  unreliable/non-functional during this investigation — plan diagnostic
  steps assuming F-keys may need to be issued via Redfish/racadm rather than
  interactively, or confirm a working alternative input method during the
  support session.

## Resolution (2026-08-13)

Resolved via a live Dell ProSupport remote session conducted over AnyDesk.
Proxmox VE 9.2.2 is now confirmed installed and running on this host.

**Root cause: not yet confirmed by Dell in writing.** The operator's working
theory is a missed step in the virtual-media ISO-mount procedure (see status
banner at the top of this document) rather than a genuine hardware fault —
but this is not yet independently verified against a written Dell RCA.

**Action items once Dell's written report arrives:**
- [ ] Update this section with Dell's confirmed root cause (do not leave the
  working theory above standing in as fact once the real answer is known —
  see this project's Strict Requirement 12: documentation must reflect
  verified reality, not assumption).
- [ ] If the root cause turns out to be a genuine hardware defect (not a
  procedural miss), re-open a tracking issue and evaluate whether the fix
  applied during the AnyDesk session is durable or whether the underlying
  fault could recur.
- [ ] If the root cause is confirmed as a virtual-media mounting step this
  document's own troubleshooting (sections 1-10 above) missed, consider
  adding a corrected quick-reference to `docs/01-proxmox-install.md`'s
  Virtual Media instructions so a future re-install (e.g. after a disk
  failure) doesn't require re-discovering the same fix.
