# SheetX 1.2.0 — joins and reversible data cleaning

**Version:** 1.2.0, build 4. iOS 16+. Same bundle ID and existing workspace; no reimport needed.

## Start here

Open a sheet → **⋯ → Clean data** or **Join / lookup**.

1. Configure the ordered cleaning steps, or choose the right-hand sheet, key columns, match mode, and columns to bring across.
2. Press **Run preview**. This computes the full result locally, showing exact row/impact counts and bounded samples.
3. Review warnings. A join with repeated right keys requires acknowledgement; invalid conversions require approval to keep their original values.
4. Give the output a name and press **Save new sheet**. A new independent workbook/sheet appears in **My Sheets**, labelled **Derived**.
5. On the output, choose **⋯ → Preparation history → Edit recipe & rebuild a new copy** to revise the saved recipe. Every rebuild produces another output, never overwrites an old one.

### Joins and lookups

- Cross-sheet and cross-workbook joins, including self-joins. All left columns are retained; select which right columns to include.
- **Left:** keep every left row. **Inner:** keep matches only. **Strict lookup:** keep every left row, but refuse any duplicated nonblank right key. Lookup never arbitrarily chooses the first match.
- **Exact** is the default: binary/case-sensitive text, numeric integer/real equality, no text-to-number coercion. Text `001`, text `1`, and numeric `1` are distinct keys.
- **Normalized text** is opt-in: cast to SQLite text, Unicode whitespace trim, lowercase, Arabic/Persian digit normalization, and canonical Unicode composition. This is not fuzzy matching, Arabic-letter normalization, or a numeric parser; numeric text formatting can still differ.
- NULL, empty, and whitespace-only keys **never match**, including in normalized mode.
- Diagnostics count matched/unmatched source rows, blank keys, duplicate key groups, and projected output rows. Counts refer to full sources, not samples. Duplicate groups count groups, not extra rows.
- Multiplicity is calculated before materializing a join. Over-limit expansions and nonunique lookup keys block saving. Right columns get source-qualified, deconflicted names. Output order is left source row, then right source row.

### Reversible cleaning

Ordered recipes support:

- Unicode trim, lower/uppercase, Arabic/Persian digits → ASCII digits.
- Case-sensitive literal replacement (not regex), text cells only.
- Blank text → NULL, fill missing values with **literal text**, or drop rows missing a selected column.
- Strict explicit-format numeric conversion: dot/comma/Arabic decimal and grouping separators; validates thousands grouping instead of blindly removing commas. Exact Int64 integers, finite decimal/scientific numbers with at most 15 significant digits. Numeric overflow/underflow is rejected. No currency/percent or guessed separator formats. Leading zeros are removed only when explicitly converting to number.
- Strict Gregorian date conversion: `yyyy-MM-dd`, `dd/MM/yyyy`, or `MM/dd/yyyy` input; ISO `yyyy-MM-dd` output. UTC/POSIX calendar, exact round-trip validation. No Excel serial dates, time-of-day, Hijri conversion, or date guessing.
- Whole-row deduplication retains the first occurrence using SQLite grouping semantics (numeric integer/real equivalents group together; text remains distinct).

Each step reports changed cells, removed rows, and invalid conversions. Invalid number/date conversions keep the original value and mark mixed output columns as text. Missing inputs convert to NULL. Rejected-value samples are capped at 10 per step and 30 displayed in total.

**Undo/redo is recipe editing**, not editing the imported cells. Add, edit, remove, and reorder steps; undo or redo those edits before rerunning the preview. Saved recipes survive app restart; unsaved drafts do not survive closing. Derived sheets remain usable after deleting sources, but rebuilding requires the original source IDs, row counts, and column schemas.

## Data safety and practical limits

- Local, offline, deterministic preparation. No AI/network calls and no changes to AI SQL authorization.
- Sources are attached **read-only** to a private staging database. A consistent read snapshot spans preparation. The main database queue is not held during this work.
- Save uses a separate write connection and a single transaction: validate source identities/schemas/counts, create new tables/catalog entries, copy values, and persist recipe/provenance, then commit. Publication failure rolls back DDL, data, and metadata together. The library changes only after commit.
- No NUMERIC affinity in derived tables: text IDs, leading zeros, and SQLite storage types are preserved unless the recipe explicitly converts them. Publication compacts rowids for grid paging.
- Existing imported/derived values are immutable within the app; validation relies on that invariant plus source identity/schema/count checks, not a full content hash.
- **Values only, entire sheet:** current grid filters/sorts, formatting, fill colors, formulas, and indexes are not copied. Formula results already imported as values remain values.
- Maximum **1,000,000 rows per source/output**, **128 columns per source/output**, **20 cleaning steps**, **120 seconds per prepare/save**. Parameters up to 1,000 characters; output names up to 120.
- Each sample is **30 rows / 4 MiB**; previews use the same clipped/paginated table and full-cell reader as Ask. Counts cover the full result; a sample is not an export of all rows.
- SQLite value/row length limit: **1 MiB** on preparation connections. The staging database page limit is **512 MiB**; temporary sorting, journals, and final outputs can require additional disk space. This is not a total disk quota. Disk/SQLite errors refuse publication, not silent truncation.
- Cancel and Save/Preview controls remain outside scrolling previews. Cancellation is cooperative through SQLite progress callbacks and step checks. A tap after commit does not undo the committed output or falsely report rollback.
- Deleting a source does not cascade into dependent derived sheets. Deleting an output removes only its own saved preparation history. Existing safe individual-sheet deletion and Ask layout fixes remain.

## Validation

- New preparation tests cover join cardinality/duplicates/blanks/unmatched rows, exact versus normalized keys, lookup rejection, expansion limits, strict conversions, undo/redo, immutable sources, leading zeros/NUL text, rowid compaction, history/rebuild, source deletion/schema changes, transactional rollback, cancellation/timeouts, read-only attachments, AI isolation, and bounded previews.
- `bash ci/test-core.sh` builds the **unchanged Foundation/SQLite production sources** in a temporary Swift package and runs the core XCTest suites on a macOS host. Only localization is adapted for the host. It is also a pre-build test gate in `project.yml`; the existing GitHub build workflow can execute these tests without a simulator or workflow-file edits.
- iOS-specific preferences/UI tests are not part of the host suite. A successful host test run is not a simulator or physical-device test.
- Executing the previously unrun overview tests exposed an existing unqualified `COUNT(*)`/SQLite-authorizer mismatch. Internal reads now qualify `main` explicitly; the strict AI authorizer is unchanged. Migration also checks column existence rather than intentionally swallowing a duplicate-column error on every open.
- **Verified 2026-09-13:** [build 34763388043](https://github.com/ahcrazy20-tech/EXCEL/actions/runs/34763388043), source commit `631361ccf18d827b75ab0eca24c90bb2292c5e2c`, Xcode 16.2 on macOS 14.8.9.
- **57 native host XCTest cases passed, zero failures**, including **26 preparation cases**, 10 analysis safety, 3 overview, 5 result presentation, 6 storage/deletion, and 7 saved-analysis cases.
- **Unsigned iOS Release compilation, packaging, and artifact upload passed.** Build job duration: 2m 6s. [Download the 1.2.0 artifact](https://github.com/ahcrazy20-tech/EXCEL/actions/runs/34763388043/artifacts/10319907304) (`SheetX-unsigned-ipa`, 4,584,834 bytes).
- Static Swift syntax checks (excluding the known baseline SettingsView parser limitation), bilingual localization-key checks, version/plist/YAML checks, and `git diff --check` also passed.
- The project defines 76 unit-test methods in total; the 19 outside this host subset and the iOS UI tests were **not run**. No simulator or physical-device verification is claimed.

### Install

Download the artifact ZIP, extract `SheetX-unsigned.ipa`, and install it with TrollStore **over the existing app**. Do not delete SheetX first, because deletion removes its local workspace. Export important data as a precaution before updating.

### Device acceptance checklist

1. Install over the existing app, without deleting it. Confirm old workbooks, reports, and saved analyses remain.
2. Join two sheets with duplicate keys, unmatched keys, blank keys, and Arabic/Persian-digit IDs. Check exact/normalized differences and the lookup block.
3. Preview a clean recipe; edit, move, undo, redo, and remove steps. Confirm invalid values/counts and approval requirements.
4. Save and open the new sheet. Inspect leading-zero IDs; export/query the full output rather than assuming the sample is complete.
5. Close/reopen the app, reopen preparation history, remove a cleaning step and rebuild. Verify both outputs and the original remain distinct.
6. Delete a source; verify its derived output still opens and rebuild fails clearly. Delete one sheet of an imported workbook; siblings remain.
7. Run and cancel a large preparation, then use Ask. Check portrait/landscape, English/Arabic RTL, small-screen devices, keyboard visibility, and large Dynamic Type. Controls must remain reachable.
