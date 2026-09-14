# SheetX 1.4.0 — Trash and Restore

**Version:** 1.4.0 / build 6 · iOS 16+ · same bundle ID and local workspace.

## Recover accidental deletions

- **My Sheets → sheet swipe/menu → Move sheet to Trash**, or use the same action in a sheet's **⋯** menu.
- A workbook's menu can move **all its active sheets** to Trash in one transaction. Sheets already in Trash keep their original deletion dates and recovery tokens.
- Open **My Sheets → Trash** (the toolbar trash icon). Each row shows its sheet, original workbook, row count, and deletion date. **Restore** returns that sheet to its original workbook with the same identity and ordering. Restoring the first sheet makes a hidden workbook visible again.
- Restore preserves imported data, stored cell/header fills, reports, saved analyses, dashboard configuration, preparation provenance and the sheet's saved column layout. It does not recreate colors that were never imported; the [1.3.0 color limitations](RELEASE_1.3.0.md#excel-colors) still apply.
- Trash is paged in groups of 50 sheets. Restore and permanent deletion are **per sheet**, including sheets moved as part of a workbook. There is no bulk restore or Empty Trash button in this release.
- **Settings → Storage → Move all sheets to Trash** now moves active sheets atomically instead of immediately destroying the workspace. Its confirmation explains that this does not free storage.

## Permanent deletion and storage

Inside Trash, the destructive trash action opens a second, explicitly irreversible confirmation. It removes only that sheet's data/fill/search tables, reports, saved analyses, dashboard, preparation record, and layout preferences. Other sheets and independently published derived outputs are not deleted. A workbook's metadata remains until its last physical sheet is permanently removed.

Each trip to Trash gets a new recovery token. A confirmation from an older trip cannot permanently delete a restored sheet or a later Trash entry. Restore, move-to-Trash and permanent data/metadata deletion are transactional; simulated failures are tested for rollback. Layout preferences live in UserDefaults, are retained on soft deletion, and are removed only after permanent database deletion succeeds. A process crash in that final cleanup interval could leave unused layout preferences, not delete another sheet's data.

**No automatic expiry.** Trashed sheets still use device storage. Permanent deletion makes SQLite pages reusable, but the database file may not shrink immediately; this update does not run a blocking VACUUM.

**Trash is not a backup.** Deleting/uninstalling the app also removes its Trash. This release does not include a full-workspace backup/export/restore system, cross-device recovery, secure erasure, or recovery of sheets permanently deleted by older versions. The original imported file outside SheetX is never deleted by these actions and is not copied into Trash.

## Analysis and preparation safety

- Trashed sources disappear from the active sheet, report and dashboard catalogs. New Ask/analysis/dashboard readers refuse them until restored. Late report/analysis/dashboard saves cannot overwrite their saved work.
- Preparation previews and publication both check active source identity; a source moved to Trash must be restored before a recipe can run or publish. An independent derived output remains usable after its source is permanently deleted, but rebuilding its original recipe requires the original source identity. Reimport creates a different identity and does not automatically repair old recipes.
- Already-running read-only analysis snapshots may finish; moving to Trash is not an immediate revocation/security boundary. New readers are blocked. The AI SQL authorizer remains restricted, and trusted setup statements are removed from its statement cache before authorization is installed.
- Storage mutations remain guarded while import, publishing or another deletion/restore is busy. Catalog changes follow successful commits; stale asynchronous refreshes cannot replace newer catalog state.
- Failed-import cleanup retains its internal hard-delete path; incomplete imports are not presented as recoverable user sheets.

## Validation

The native macOS Foundation/SQLite test gate includes **19 new Trash tests**, alongside the previous 82 cases. It covers retained colors and saved work, original workbook identity, sibling isolation, repeat/stale actions, read-only reader refusal, trusted-statement cache authorization, preparation validation, derived history, permanent cleanup, late metadata writes, rollback, corrupt identities, open-transaction protection, pre-Trash schema migration, persistence and bounded pagination.

### Verified release results — 2026-09-14

- [Build 34810212808](https://github.com/ahcrazy20-tech/EXCEL/actions/runs/34810212808), source commit `8cbccfc334969635c91b32c036f14f4c57b1256f`, Xcode 16.2.
- **101 native macOS-host XCTest cases passed, zero failures**, including all **19 Trash tests** and the previous 82 core cases. The final run explicitly passed pre-Trash schema migration, multi-workbook move-all, rollback and stale-confirmation regressions.
- **Unsigned iOS Release build, packaging and upload passed**; job duration **2m 6s**.
- [Download SheetX 1.4.0](https://github.com/ahcrazy20-tech/EXCEL/actions/runs/34810212808/artifacts/10335020635): `SheetX-unsigned-ipa`, **4,832,595 bytes**. Extract the ZIP and install `SheetX-unsigned.ipa` with TrollStore **over the existing app**. Do not delete SheetX first.
- Static Swift parsing (known baseline SettingsView parser limitation excluded), localization-key checks, version/plist/YAML alignment and shell/diff checks passed. The native Xcode build compiled SettingsView successfully.
- The 19 unit-test methods outside the native host subset and the iOS UI tests were not run. No simulator, touchscreen or physical-device verification is claimed. In particular, layout/VoiceOver/RTL behavior and installation over a real user's existing workspace still require device acceptance.

## Device acceptance checklist (not yet executed)

1. Export important data, then install over the existing SheetX with TrollStore. **Do not delete SheetX first.** Verify old sheets, colors, reports, saved analyses and dashboards remain.
2. On a workbook with two sheets, change column widths/hide a column; save an analysis, report and dashboard. Trash just that sheet. Confirm its sibling remains, its saved work is absent from active catalogs, and Trash shows the correct original workbook.
3. Restore it and verify values, header/cell colors, row order, column layout and saved work. Close/reopen the app while a sheet is still in Trash, then restore it.
4. Trash a whole workbook with one sibling already in Trash. Restore one sheet at a time. Confirm names/identities and previously trashed entry dates remain intact.
5. Trash a derived sheet, restore it, inspect preparation history and rebuild while its sources are active. Trash a source and confirm new analysis/preparation attempts are refused; restore it and retry.
6. Cancel a permanent-delete confirmation, then confirm on a disposable sheet. Verify sibling and independent derived data survive. Verify final deletion of a workbook's last physical sheet removes the empty workbook.
7. Test Settings' move-all confirmation and restoration. Check 51+ disposable sheets for pagination, refresh and final-page clamping.
8. Verify English/Arabic RTL, VoiceOver labels, portrait/landscape, small screens, large Dynamic Type, busy-state buttons and cancellation/error displays. Foundation host tests do not verify these UI behaviors.
