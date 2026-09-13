# SheetX: intelligent data workspace

**Planning date:** September 13, 2026
**Status:** long-term proposal, not a list of shipped features. The first implementation slice is now described in [release 1.1.0](RELEASE_1.1.0.md): Saved Analyses, Data Overview, and isolated/bounded Ask execution. Remaining stages below are future work.

## Product direction

Build the best **local-first, mobile spreadsheet analysis and presentation experience** before attempting to replace every part of Excel. The existing app imports and analyzes spreadsheet values; it is not yet a cell editor, formula recalculation engine or lossless workbook editor. Calling it a full Excel replacement today would overpromise.

The distinctive workflow should be:

> Open a large workbook → understand its quality → combine and prepare data → ask a question → inspect a reproducible answer → publish an interactive dashboard or report.

Arabic and English should be first-class throughout, not just translated menus. Reliability, correct numbers and understandable provenance matter more than the number of AI providers.

## Existing foundation and gaps

| Area | What the code already provides | Highest-impact gap |
|---|---|---|
| Import | Streaming XLSX / CSV, JSON, header detection, cell fills | Adversarial/large-file fixtures, type-conversion diagnostics, resumable jobs |
| Data engine | SQLite, statement cache, filters, statistics, aggregation, pivots | Cancellable query budgets, strict read-only SQL execution, separation of long analyses from interactive reads |
| Grid | Paged row data, per-sheet widths/visibility, lazy vertical rows | Horizontal virtualization, cell reuse, bounded deep-scroll layout, accessible pinned regions |
| Analysis | Local natural-language plans, AI plans, full reports | Saved/replayable workflows, safe cross-sheet joins, result provenance |
| Presentation | Bar/line/pie charts, pivot heatmap, export | Linked dashboards, proper numeric/date axes, scatter/histogram, chart accessibility |
| Persistence | Workspace metadata and an existing `meta_saved_queries` table | A user-facing saved-query/workflow library with schema/version tracking |
| AI | Multiple providers, fallback and optional local parsing | Explicit data-sharing controls, plan approval, operation-wide cancellation and verifiable answers |

## Stage 0 — Reliability and trust first

**Delivered in this patch:** asynchronous secure storage, cache-only Settings rendering, searchable model selection, cancellable discovery/tests, visible persistence errors, keyless custom-server support, schema-only planning, clearer AI data-sharing disclosure and regression-test wiring. See `AI_SETTINGS_FIX.md`; device verification is still required.

**Next release blockers:**

1. **Enforce read-only SQL at SQLite, not with text filtering.** `QueryEngine.runSQL` currently rejects a small keyword list and retrieves unbounded results. Use a dedicated read-only analysis connection, an authorizer restricting tables/functions, one-statement enforcement and `sqlite3_stmt_readonly`. Apply row/result-byte limits plus a progress-handler time/instruction budget. Validate AI column references and reject unsupported plans rather than silently dropping invalid filters.
2. **Own and cancel every analysis job.** Propagate cancellation from Ask, reports, pivots and exports into network requests and SQLite work. A cancelled query must not interrupt unrelated imports or grid reads. Use independent connections/job ownership before applying `sqlite3_interrupt`.
3. **Make errors actionable.** Distinguish no matching rows from a failed database read. Keep existing content during refresh. Expose stages, progress, Cancel and Retry for long jobs.
4. **Make privacy explicit.** Offer schema-only planning by default (now implemented), per-request preview/redaction of report/result context, opt-in to cell-value sharing, and visible fallback destinations. Never include keys or cell contents in diagnostics. Existing narration can contain cell values; do not claim otherwise.
5. **Establish device benchmarks.** Synthetic fixtures for 20K, 100K and 1M rows; narrow and 200-column sheets; Arabic text; mixed dates; empty/duplicate headers; malformed CSV/XLSX. Measure before changing the rendering engine.

**Gate:** existing keys survive upgrade; AI Settings works offline; no synchronous secure-storage or long database work on the UI thread; a cancelled job cannot replace a newer result; read-only SQL adversarial tests pass.

## Stage 1 — Instant understanding and a faster viewer

### Data Overview

A new Overview tab per sheet: row/column count, detected types, missing values, duplicate groups, numeric distributions, date coverage and a short list of suggested questions. Every card opens the exact underlying filter/query. Expensive profiles run in the background and cache by sheet version, column and filter fingerprint.

### Two-dimensional grid virtualization

Prototype a `UICollectionView`-backed viewport with reusable cells and virtualized columns, preserving the existing `SheetViewModel` paging interface. Keep row numbers and selected columns pinned; add range selection, copy, search highlighting, keyboard navigation and VoiceOver row/column descriptions. Benchmark the prototype against the current SwiftUI grid before replacing it.

### Search that stays responsive

Debounce typing, cancel superseded queries, preserve scroll position and show whether results are partial or complete. Add optional background search indexing only after checking the bundled/system SQLite tokenizer capabilities on iOS 16. Do not assume FTS5 trigram is available or that published desktop benchmarks apply to this phone. Keep a correct LIKE fallback and disclose index disk cost.

**Gate:** row/page memory stays bounded during a million-row deep scroll; hidden columns do not generate off-screen cells; search/paging cannot apply stale results.

## Stage 2 — Reusable data preparation and serious analysis

### Saved analysis recipes

Use `meta_saved_queries` as the starting point for named, parameterized analyses with a structured plan, source-sheet/version identifiers, filters, sort order, result limits and timestamps. Offer favorite questions, recent analyses and rerun-with-new-file mappings. Store plans locally, not provider-specific chat history as the source of truth.

### Reversible preparation steps

Trim whitespace; normalize Arabic/English numerals; parse locale-aware numbers and dates; split/merge columns; replace values; handle blanks; remove duplicates; derive columns. Each step has a preview, affected-row count and undo/reorder support. Keep imported data immutable and materialize derived tables transactionally. Invalid conversions must be visible, not silently become zero.

### Cross-sheet joins / lookup

A visual join builder with key selection, data-type checks, duplicate-key warnings, unmatched-row previews and estimated output size. Start with left/inner joins and lookup semantics, then append/union. Warn about many-to-many row multiplication before execution. Index join keys as needed with bounded background jobs.

### Analytical depth

Weighted averages, distinct counts, percentiles, period-over-period comparisons, running totals and grouped date buckets. Support explicit number/currency/date formatting and rounding policies. Specify NULL semantics, decimal precision and timezone/date interpretation; validate with small hand-checkable fixtures.

**Gate:** a recipe reproduces the same result on a versioned source; source data survives undo and crashes; join totals match fixtures; every transformation reports rejected values.

## Stage 3 — A world-class data presentation experience

Create a Dashboard document made of KPI, chart, table, narrative and filter cards, each bound to a saved analysis rather than duplicated data.

- Linked filters and cross-highlighting across charts, pivots and tables.
- Time-series charts with real date axes, scatter plots with numeric axes, histograms, grouped/stacked bars and accessible heatmaps. Do not substitute row positions for time or silently convert missing values to zero.
- Templates: sales performance, finance overview, inventory, customer retention and data-quality audit.
- Useful defaults: readable units, totals, legends, category caps with an “Other” bucket, empty-state guidance and colorblind-safe palettes.
- iPad canvas / iPhone focused view; full Arabic RTL and Dynamic Type support.
- Export a reproducible report with filters, source version, generated time, exact/sample/truncation labels and chart source tables. Maintain current CSV/HTML/PDF sharing; add interactive HTML only with escaping and privacy review.

**Gate:** selecting a chart segment produces the same filtered numbers everywhere; exports disclose limits and match the displayed result; dashboards remain usable with VoiceOver and larger text.

## Stage 4 — A trustworthy analyst, not just a chatbot

Use an explicit execution path:

`question → proposed structured plan → safety/type validation → user review when needed → local execution → result/provenance → optional narration`

- Show which columns, filters, joins and calculations answer the question before expensive or ambiguous actions.
- Ask clarification for ambiguous dates, units, metrics or join keys; do not manufacture confidence percentages.
- Keep numeric calculations local. AI explains validated result tables; it does not invent the figures.
- Attach provenance to every answer: query/recipe, parameters, source version, filter scope, execution time, exact vs sampled, truncation and actual provider/model.
- Support follow-up questions by modifying a versioned plan, not by sending the workbook again.
- Route by task capability, context budget, privacy mode and user cost preference. Fallback should be explicit, cancellable and not unexpectedly switch to a paid provider or another data destination.
- Treat cell text as untrusted data, never executable instructions. AI has no unrestricted SQL, file-writing or network tools.

**Gate:** every reported number can be traced to a local result; malformed plans cannot broaden access; cancellation stops fallback; cell-value sharing requires the chosen privacy mode.

## Separate workstream — Spreadsheet editing compatibility

Do not quietly add editing on top of the current viewer. Lossless editing requires workbook fidelity tests for formulas/cached values, styles, merged cells, dates, named ranges, multiple sheets and unsupported features. Begin with an explicit derived-table editor with transactional undo. Evaluate a dedicated formula engine and licensing before promising Excel-compatible recalculation or round-trip XLSX preservation. Legacy `.xls` import is another scoped compatibility project, not “just a file extension”.

## Proposed architecture boundaries

- **Workspace store:** source identity/versioning, metadata migrations, saved recipes and dashboard documents.
- **Query service:** background connections, read-only sandbox, typed parameters, budgets, cancellation, result metadata and bounded caches.
- **Job coordinator:** one owner per task; progress/state machines; generation IDs so old results cannot replace current UI state.
- **Presentation:** viewport-driven grid and small dashboard card view models; no synchronous database/Keychain work in `body`.
- **AI service:** provider transport plus a typed planning/validation layer, consent/redaction and observable request lifecycle. Credentials remain in Keychain with an in-memory cache.

## Proposed performance goals (not measured claims)

Measure on the target iPhone 11 Pro Max with representative fixtures, both cold and warm caches. Record device/iOS version and data shape with every result.

| Scenario | Initial target |
|---|---|
| Open Settings / model browser | Visible response within 100 ms at p95; no main-thread I/O |
| Scroll an already-loaded grid viewport | Aim for 60 fps; profile frame stalls above 16.7 ms |
| Display a cached page | Under 100 ms at p95 |
| Simple indexed filter on 1M narrow rows | Under 500 ms at p95; otherwise immediate progress/cancel UI |
| Cancellation feedback | UI responds within 100 ms; underlying work stops at its next bounded checkpoint |
| Memory during deep scrolling | A plateau tied to the viewport/page cache, not the number of rows visited |

Do not adopt arbitrary “millions of rows instantly” or “100× faster” claims without device measurements. If targets fail, ship a measured limitation and prioritize the bottleneck.

## Recommended next implementation slice

After the AI Settings fix passes device verification, build **safe, cancellable query execution + Saved Analyses + Data Overview** as the next coherent release. It improves daily usefulness, supplies the provenance foundation for AI, and provides reusable queries for dashboards. Then benchmark the grid prototype and implement joins before expanding the AI surface area.
