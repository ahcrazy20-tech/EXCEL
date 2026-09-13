# SheetX 1.1.0 — analysis workspace update

## Included

### AI Settings stability

Background Keychain access, searchable model selection, cancellable discovery/connection checks, visible credential errors and keyless custom-server support. Existing Keychain identifiers and stored provider settings are preserved.

### Data Overview

Open a sheet → **⋯ → Data Overview**.

- Exact count of rows matching the current search/filters.
- Missing values, distinct non-empty values and completeness.
- Average/minimum/maximum of stored numeric values. Non-empty text in numeric columns is counted separately, not silently converted to zero.
- Profiles use up to the **first 10,000 matching rows**, in source order, and explicitly say when they are sampled. The exact row count is independent of that sample.
- Show missing values in the grid. This action explicitly replaces existing search/filters and searches the entire sheet.
- Local-only computation, progress, cancel and refresh. No AI request or raw-row materialization is needed.

### Saved Analyses

Run a question or SELECT query in **Ask → Save analysis**. Find it under **⋯ → Saved Analyses**.

- Saves the executable plan, filters, grouping, sorting and source schema, not merely a question to reinterpret later.
- Review and run again locally without an AI key. Editing the question starts a new analysis.
- Rename/delete; persisted in the existing per-sheet `meta_saved_queries` table.
- Source ID, table, row count and column signature checks reject incompatible recipes.
- Unreadable saved entries remain visible and deletable. The latest 200 entries are displayed; source deletion removes its analyses.

### Safer analysis execution

Ask and Data Overview use an isolated, read-only SQLite connection per job. Cancelling one does not interrupt the shared import/grid connection.

- SQLite authorizer restricts reads to the selected sheet and approved functions; denies writes, schema access, other sheets, attachments, PRAGMAs and extensions.
- One SQL statement per execution, checked by SQLite parsing rather than keyword matching.
- A 15-second job budget, SQLite progress-handler cancellation, SQL/column/value-size limits and a 4 MiB result-data budget.
- Raw SQL previews cap at 500 rows; structured aggregations at 5,000 groups; row previews at 500 rows. Truncation is displayed. Exports from Ask contain the loaded result, not the full underlying file.
- The temporary SQL alias `data` exposes `rowid` and imported columns `c0`, `c1`, etc. String literals are never rewritten to substitute a table name.
- Database step errors now throw rather than returning partial rows as if successful.
- Invalid AI column references and malformed plans fail instead of silently dropping filters.
- Duplicate-group analyses respect their saved filters.
- Ungrouped median is actually computed as median. Grouped median is explicitly rejected until implemented rather than mislabeled as average.
- Ask shows local execution time and source name, supports cancellation and suppresses stale replies.
- AI result narration in Ask is opt-in: enable **AI narrative (share result excerpts)**. Planning sends the question/schema without row samples.

## Compatibility and boundaries

- iOS 16+, existing iPhone/iPad targets. App version **1.1.0**, build **2**.
- Existing workbook, report and credential storage paths remain unchanged. No destructive migration is introduced.
- Saved plans are tied to the current imported source; remapping them to a different workbook is not yet implemented.
- This release does not add cell editing, formula recalculation, cross-sheet joins, linked dashboards or lossless XLSX editing. Those remain roadmap items.
- The new cancellation/budget boundary covers Ask and Data Overview. Existing standalone report, chart, pivot and export jobs are not all migrated yet.
- SQL's allowlist intentionally excludes unreviewed functions. SQLite function availability still depends on the iOS runtime.
- The time budget checks SQLite VM progress, not a hard process deadline. Result-byte accounting bounds returned data, not all SQLite temporary sort/group allocations; VM and input limits provide additional safeguards.
- Overview is a first-N profile, not a statistically random sample. Do not generalize its quality percentages as exact for rows outside the sample.

## Regression coverage

Tests cover secure settings; provider/model parsing and transport; SQL isolation; multiple statements; dangerous functions; result-size limits; SQLite step errors; timeout/cancellation; saved-plan persistence and replay; schema mismatch; invalid AI plans; duplicate filtering; median semantics; and exact/filtered/sampled/empty overviews.

The active GitHub Actions workflow generates the Xcode project, builds the unsigned device application and packages `SheetX-unsigned.ipa`. The expanded `ci/build-ipa.yml` template additionally runs unit/UI tests; installing that workflow requires GitHub workflow-edit permission, which the current connection does not have. Tests can also run manually with the Xcode scheme. Consult the specific build run's status before installing. A physical iOS 16.4 / TrollStore upgrade test is still required to confirm on-device Keychain behavior, the original freeze report and large-file performance.
