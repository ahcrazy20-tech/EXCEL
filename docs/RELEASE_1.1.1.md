# SheetX 1.1.1 — sheet deletion and a usable Ask screen

**Version:** 1.1.1 (build 3), iOS 16+, unchanged bundle ID.

## Delete one sheet, not its siblings

The old sheet-row Delete action called `deleteWorkbook`, removing every sheet in that workbook. It now offers **Delete sheet**, with confirmation describing the scope.

- Files: swipe a sheet (full-swipe deletion is disabled), or long-press it → Delete sheet.
- Open sheet: **⋯ → Delete sheet**.
- Workbook header: **⋯ → Delete entire workbook**, a separate, explicitly labelled confirmation.
- Removes the selected sheet's local data, fill/search side tables, column metadata, reports, saved analyses and persisted layout. Other sheets remain intact.
- Removes the empty workbook entry when its final sheet is deleted.
- The imported original file is never edited or deleted. Deletion is permanent; export anything you need first.
- SQLite table drops and metadata deletion form one serialized transaction; an error rolls back the entire operation. No success state is published before commit.
- Deletion runs off the main thread and is blocked during import/another deletion. Late report saves cannot recreate orphan records.
- There is no automatic `VACUUM` after deletion. SQLite reuses freed pages for later imports; the on-disk database size may not immediately shrink.

## Ask: keep the controls separate from the content

The old result view put up to 100 rows × every column into a horizontal-only scroll view with a maximum height. That limited layout height without providing vertical scrolling or clipping, allowing large content to draw/hit-test outside its intended area.

- Ask opens full-screen from both a sheet and Saved Analyses.
- The question composer and Run/Cancel controls sit in a bottom safe-area inset, outside the result scroll view. Options and Close stay in the navigation bar.
- Running a question dismisses the keyboard; a Done keyboard button and interactive scroll dismissal are available.
- AI/offline selection and narration/privacy settings move to a separate Options sheet rather than crowding the question field.
- Results use a fixed, clipped and hit-test-bounded viewport with horizontal **and** vertical scrolling.
- Inline rendering pages through 12 rows and 6 columns at a time; Explore result uses 20 rows. Page controls cover the loaded result, not unqueried source rows. Existing truncation limits still apply and are labelled.
- Headers/cell previews have bounded dimensions and text lengths. Tap a cell to read/copy its full value.
- Long AI responses and SQL use short inline previews with a paginated full-text reader; Unicode text is preserved.
- Result export, saved-report generation, local query parsing and AI narration-context formatting run away from the UI thread.

## Validation

- Regression tests added for deleting one of multiple sheets, deleting the last sheet, metadata/side-table cleanup, rollback after a simulated failure, wrong-owner/corrupt metadata rejection, import transaction protection, whole-workbook deletion and layout cleanup.
- Presentation tests cover large/empty/shrinking results, last-page access, view-count bounds and Unicode text paging.
- A DEBUG-only in-memory UI fixture supplies a 500 × 200 result and a long bilingual response without any API call or user-data changes. The UI test checks Options, Run, result navigation and Close. The fixture is excluded from the Release IPA.
- Native XCTest/UI execution still requires Xcode or installing the expanded `ci/build-ipa.yml` workflow. The current GitHub connection cannot edit active workflow files; the existing workflow builds/packages the IPA only.

### Required device check

1. Import a workbook with at least two sheets. Cancel a delete confirmation first, then delete one sheet. Verify the sibling still opens, and its report remains.
2. Delete the last sheet and verify the empty workbook entry disappears. Confirm the original file remains in Files.
3. Ask a question producing many rows/columns. Navigate result pages, open a cell, open Options and dismiss the keyboard. Run/Cancel and Close must remain reachable.
4. Repeat with Arabic/RTL, English, portrait, landscape and large Dynamic Type. Read a long AI response, then run another question.
5. Confirm truncation labels and that Ask exports contain the loaded result, not the entire underlying sheet.
