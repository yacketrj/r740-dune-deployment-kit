# Evidence: prod (VM 101) restore drill PASSED, 2026-10-06

Backup strategy requirement: a restore of the production image must be tested before the schedule goes live.

- **Image:** `vm101-20261001-120000.vma.zst.age` (the weekly image of dune-prod, 300 GiB disk, 54.2% sparse), decrypted with the operator's age key and restored to scratch VM 990.
- **Result:** PASS, exit code 0, at 2026-10-06T08:55:18Z. The scratch guest booted on an isolated no-uplink bridge (MAC kept: `BK_DRILL_KEEP_MAC=1`), sent 27 packets and read 747 MiB from its disk. **Boot-only proof: no command was run inside the guest** and the database inside the image was not restored by this drill.
- **Restore time:** 5,935 s (about 99 min). Total run about 100 min, started 00:15 PDT, well inside the 04:20-05:20 blackout rule.
- **Impact on prod:** the game stayed READY before and after; the safety guard (I/O pressure, memory pressure, disk busy, pool, game state) raised nothing. sda during the drill, 1,202 samples at 5 s: write mean 51.0 MB/s, peak 74.5 MB/s; read mean 0.5, peak 60.5 MB/s; peak w_await 8.6 ms; peak util 28%. The configured write cap is 40 MiB/s (41.9 MB/s); observed writes exceeded it, which did not hurt the game but means the cap is not a hard limit.
- **Cleanup:** scratch guest and volume removed; `qm list` shows only 101, 102, 103; thin pool 18.36% before and after.
- **Settings:** bwlimit 40960 KiB/s, NUMA node 1, affinity 1,3,5,7, cpuunits 10, restore timeout 220 min, guard on.
- **Earlier failures (2026-10-02/03, guest 101):** boot stage 0 packets (consistent with the MAC-matched netplan; the date `BK_DRILL_KEEP_MAC=1` was added to the operator's config was not recorded), and one stop by the guard because the game was not READY.

Audit/evidence log line (`/var/lib/r740-backup/evidence.log`):

```
2026-10-06T08:55:18Z	drill-vm	PASS	guest=101 image=vm101-20261001-120000.vma.zst.age scratch=990 check=BK_DRILL_VM_CHECK_101 mode=boot-only guard=1 bwlimit_kib=40960 node=1 affinity=1,3,5,7 cpuunits=10 timeout_min=220
```

Drill log (progress lines omitted):

```
2026-10-06T07:15:51Z guard: watching PID 2582877 every 10s; will stop it after 3 bad samples in a row (I/O pressure > 20%, memory pressure > 10%, disk > 95% busy, pool > 85% full, game not READY)
restore vma archive: vma extract -v -r /var/tmp/vzdumptmp2583102.fifo - /var/tmp/vzdumptmp2583102
CFG: size: 838 name: qemu-server.conf
DEV: dev_id=1 size: 322122547200 devname: drive-scsi0
CTIME: Thu Oct  1 05:30:21 2026
rate limit for storage local-lvm: 40960 KiB/s
new volume ID is 'local-lvm:vm-990-disk-0'
map 'drive-scsi0' to '/dev/pve/vm-990-disk-0' (write zeros = 0)
total bytes read 322122547200, sparse bytes 174583549952 (54.2%)
space reduction due to 4K zero blocks 1.39%
rescan volumes...
2026-10-06T08:55:18Z boot-only check: the restored guest is running, sent 27 packets on its isolated network and read 747 MiB from its disk (no in-guest command was run)
2026-10-06T08:55:18Z dead-man ping skipped (no URL file configured)
2026-10-06T08:55:18Z VM drill PASSED: vm101-20261001-120000.vma.zst.age restored to scratch 990, booted isolated (boot-only: sent packets, no in-guest command); destroying the scratch guest
```
