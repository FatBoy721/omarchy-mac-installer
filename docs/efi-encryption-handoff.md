# EFI encryption handoff

The installer records the encryption checkbox and selected release lane in `omarchy/install.conf` on the Omarchy EFI partition after the engine finishes the macOS stage. Without that file, first boot defaults to encryption enabled. Failure to save the file produces “The encryption choice wasn’t saved, so Omarchy will encrypt its disk at first boot.”

## Failure observed on the M3 Pro

Installer 2.3.11, whose source is tagged at `c5979c1`, completed the macOS stage on an M3 Pro (`apple,j514s`) running macOS 27.0 (26A428) on 2026-11-01. The execution journal ended with `outcome=awaiting_recovery` at 05:50:04 local time. At 05:50:06, the subsequent EFI unmount failed with status `0x10` (`EBUSY`) and Disk Management dissenter code `49168`. The EFI volume remained mounted and its `omarchy` directory contained no `install.conf`. A later read-only `lsof` check found Spotlight's `mds` and `mds_stores` holding files on that volume. This identifies a busy-volume failure; the later process snapshot makes Spotlight the likely blocker, rather than proving which process held each vnode at the exact failure time.

The same code remains on `main` at `982094e`. `DiskutilInstallConfESPOperator.mount` first tries to unmount every already-mounted ESP so it can remount at a private path. That normal unmount throws before `InstallConfESPMountWriter` reaches the atomic write. The helper maps this pre-write failure to `.notRecorded`, which the app renders as the warning above. The existing test `testBusyExistingMountIsNeverForcedOrWrittenThrough` explicitly required this outcome.

![Installer 2.3.11 showing the encryption-choice warning on the M3 Pro](images/efi-encryption-warning-2026-11-01.png)

Commit `df9de0e` introduced the pre-write unmount to fix a different failure: macOS can report a successful mount command while leaving the volume at its existing mount path. Writing blindly to the requested private directory can then appear successful without reaching EFI. Removing device or mount verification would reintroduce that bug.

## Corrected behavior

The helper locates the EFI partition inside the completed installation plan's exact store and extent. If it is already mounted and writable, the helper opens that mount root and verifies the opened filesystem's source device, mount root and read-only flag, together with the named directory's device and inode. A newly mounted volume must still appear at the requested private path and pass the same checks.

Mount-root verification canonicalizes the path with `realpath(3)` before comparing it with the kernel's mount path. Foundation's URL normalization can remove `/private`, while the kernel reports `/private/var/...` for a mount requested under `/var/...`; comparing those different forms rejects a valid private mount. The FAT-image integration tests cover both an existing mount and repeated fresh private mounts with the production verifier, without replacing it with a test double.

The helper keeps the verified root descriptor open while creating and opening the `omarchy` directory. Descriptor-relative operations reject symlinks and traversal onto another filesystem. A unique temporary file is written and synchronized before an atomic rename, then a bounded regular-file readback checks the exact document. Mount-path replacement cannot redirect these operations into another directory.

Every file and directory descriptor closes before the normal unmount attempt. If EFI is still busy, the helper reports the existing `.unconfirmed(encrypt:)` outcome after saving the document. The saved opt-out message therefore remains available for `encrypt=0`. Mount-directory cleanup uses only `rmdir`; it never recursively deletes a mounted filesystem's contents. No force unmount is used.

## Validation boundary

The busy-mount regression must fail on the unmodified source and pass with this fix. Focused Swift coverage also checks wrong mounts, read-only mounts, atomic replacement, post-write unmount failure for both encryption choices, temporary-file cleanup, symlink rejection, pinned-directory behavior after path replacement and descriptor closure before unmount.

These checks exercise temporary directories and mocked disk operations. They do not qualify a new installation, change an installed EFI partition, register a helper, sign an app or publish a release. A physical installation remains a separate check against a packaged candidate.

Local checks on 2026-11-01: the added busy-mount regression failed on the unmodified `982094e` source with `mountFailed`. The corrected source passed 47 focused tests and strict package-wide Swift formatting on the M5 with macOS 26.6.2 (25G83), Xcode 27.2 (27B52), Swift 6.4.2 and checksum-pinned XcodeBuildMCP 2.7.0. The portable `bash test/all` suite passed on Linux. A separate read-only executable compiled from the production mount-verifier source accepted the M3's existing macOS 27 FSKit EFI mount and rejected both another device and a subdirectory of that mount; it did not write or unmount anything.

The complete Swift package passed 807 debug tests and 793 release tests, with zero failures and one skip in each configuration. Independent read-only review found no actionable issues. The tested `InstallConfESP.swift` SHA-256 is `583e0f7156aa884f4464f636d2e8e018c2093d0424ce93f800794a228384c1d5`. App assembly, signing and a new physical installation were not performed for this source-only fix.
