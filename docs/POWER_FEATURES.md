# Powerful next features for SheetX

> **1.4.0 status:** Sheet/workbook Trash and per-sheet restore/permanent deletion are implemented, retaining stored colors and saved work. [Release guide and verification](RELEASE_1.4.0.md). Full-workspace backup, cross-device restore and bulk Trash actions remain future work. Trash is not a backup.

> **1.3.0 status:** Linked KPI/bar/line/table dashboards now ship, with one saved configuration per sheet. [Release guide](RELEASE_1.3.0.md). Dashboard pivots, saved-analysis pinning, PDF export and multi-board layouts remain future work.

> **1.2.0 status:** Cross-sheet joins/strict lookups and reversible cleaning recipes are implemented. [Release guide, limits, and verified tests](RELEASE_1.2.0.md). The first dashboard release is now available in 1.3.0.

This is the original priority list. The status notes above distinguish delivered scope from **remaining proposals**; broad compatibility and extensions listed below are not all shipped. SheetX already has local import, filtering, pivots, basic charts, AI/offline questions, Saved Analyses and Data Overview. The best next investments should build on them, not repeat them.

| Priority | Feature | What it enables | Size / main dependency |
|---|---|---|---|
| 1 | **Cross-sheet joins and lookups** | Match sales to customers, combine inventory with prices, and reconcile records across files. Preview unmatched keys and many-to-many duplication before executing. | Large; typed join plans, indexes and output-size estimation |
| 2 | **Reversible data-cleaning recipes** | Trim/replace/split text, normalize Arabic/English numerals, parse dates, handle missing values and remove duplicates. Preview affected rows and undo each step. | Large; immutable source + derived tables + versioned transformations |
| 3 | **Linked dashboards** | KPI cards, charts, pivots and tables sharing filters. Tap a city or month and update every card; save/present the dashboard. | Large; bind cards to Saved Analyses rather than duplicating data |
| 4 | **Workspace backup (Trash/restore shipped in 1.4.0)** | Export a consistent full-workspace backup and restore after reinstalling or changing devices. This is separate from local Trash recovery. | Medium–large; snapshot/export policy and tested backup migrations |
| 5 | **Conditional formatting and visual rules** | Data bars, color scales, duplicate highlights, overdue dates and threshold alerts—saved per sheet. | Medium; viewport-only evaluation with explicit rule precedence |
| 6 | **AI analyst with evidence and follow-up questions** | Review the query plan before execution; ask “compare that with last month”; link each number to a result/query. Clarify ambiguous columns and units instead of guessing. | Large; structured conversation state, plan review, provenance and privacy controls |
| 7 | **Dataset comparison and reconciliation** | Compare two versions, detect added/removed/changed records, and produce an exceptions report keyed by selected columns. | Medium–large; join engine and explicit duplicate-key handling |
| 8 | **Calculated columns and formula assistance** | Add profit, margin, date buckets and business rules with a formula editor and AI suggestions. Preview errors and dependencies before applying. | Large; a typed expression engine and dependency model, not raw SQL concatenation |
| 9 | **Time-series analysis, forecasts and anomaly detection** | Month-over-month changes, rolling averages, seasonality and unusual transactions. Show uncertainty and backtesting; never present predictions as facts. | Large; robust numeric/date typing and validated statistics |
| 10 | **SQL workbench** | Syntax highlighting, column completion, parameters, saved snippets, query-plan inspection and result charts using the existing read-only execution boundary. | Medium; editor UI and controlled query diagnostics |
| 11 | **More analytical charts** | Scatter plots, histograms, box plots, stacked bars and real date axes with automatic chart suggestions and accessible palettes. | Medium; correct chart data types, sampling/aggregation and selection behavior |
| 12 | **Refreshable import pipelines** | Replace a monthly source file and rerun cleaning, joins, analyses and dashboards after reviewing schema changes. | Large; schema mapping, immutable source versions and job orchestration |
| 13 | **Two-dimensional grid virtualization and indexed search** | Smooth viewing of very wide sheets, bounded memory, keyboard/range selection and faster repeated substring searches. | Large; measured device benchmarks and runtime SQLite capability checks |
| 14 | **Report studio** | Branded PDF/HTML reports with chart layouts, selected findings, filters, source timestamps and explicit result limits. | Medium–large; document layout and export-fidelity tests |
| 15 | **Privacy workspace controls** | Per-column redaction, preview of exactly what AI will receive, optional local-only mode, biometric access and encrypted backups. | Large; threat model, key management and explicit fallback-provider consent |

## Recommended order

1. Finish device validation of **Trash/restore, Ask, colors, preparation and dashboards**. Native core/build verification does not replace device testing.
2. Add **full-workspace backup/restore** with consistent snapshots and migration tests; local Trash does not protect against uninstall/device loss.
3. Build **dataset reconciliation** and richer dashboard/reporting tools on the shipped join and cleaning engines.
4. Extend the AI analyst to operate on explicit plans and validated results; conditional formatting is a separate visual-workflow priority.

Do not attempt a complete Excel formula engine, real-time collaboration and lossless workbook editing in the same release. They are separate, high-cost compatibility projects. A strong local-first analysis workspace is a clearer and more achievable advantage.
