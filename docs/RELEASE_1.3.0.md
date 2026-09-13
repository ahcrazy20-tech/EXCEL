# SheetX 1.3.0 — linked dashboards and visible Excel fills

**Version:** 1.3.0 / build 5, iOS 16+, same bundle ID and existing workspace.

## Dashboards

Open the new **Dashboards** tab and choose a sheet, or open a sheet → **⋯ → Dashboards**.

- One saved dashboard per sheet, including derived sheets from joins/cleaning.
- Up to **12 editable/reorderable cards**: KPI, bar chart, ordered line chart, and bounded source-row table.
- KPI calculations: row count, sum, average, minimum, maximum, distinct count. Numeric calculations include stored numbers only; invalid text is ignored, never treated as zero. Convert numeric text with Clean data first. No numeric result is shown as a dash, not a fabricated zero.
- Every card shares search/filters and one consistent source snapshot. The initial draft can use the open grid's filters/search; an existing saved dashboard restores its saved filters instead.
- Tap a bar/point or **Select group / inspect values** to apply an additional exact, type-aware group filter to **every** card. This filter is ANDed outside the ordinary filter group, even when that group uses Match any. NULL, empty text, numeric keys and textual IDs remain distinct. Clear the group filter to return.
- Bar charts show the highest 12 groups. Lines show the first 24 groups ordered by source value. Lines are equally spaced categories, not continuous-time plots; missing dates are not inserted, and null numeric points are omitted. ISO dates give chronological text order.
- Tables show the first 50 matching rows using the same clipped/paginated table as Ask. Truncation is explicit. KPIs and matching-row counts cover all matching rows, not the chart/table sample.
- Presentation mode hides card editing menus. Refresh/Cancel, Save and Close stay outside scrolling content.
- Save persists layout, calculations and filters—not stale calculated results. Reopening recomputes locally. Closing dirty drafts prompts before discarding; reset changes only the draft until saved.
- No AI, API key or network calls. One isolated read-only connection and shared **15-second** budget across all cards, **4 MiB** combined result-value budget, **128 source columns**, at most **16 filters**, and bounded values. Cancelling/failing a refresh does not expose partial or stale cards.
- Saved source schema/row count mismatches are refused. Deleting a sheet removes its own dashboard metadata, not dashboards belonging to other sheets.
- This release provides linked KPI/chart/table dashboards. Dashboard pivots, multiple boards per sheet, saved-analysis pinning, PDF dashboard export and multi-source cards are not included; join data into a derived sheet first.

## Excel colors

Several independent faults have been corrected:

1. **Theme XML prefixes:** standard `a:clrScheme` / `a:srgbClr` elements were not recognized. Theme/style/worksheet parsers now handle namespace prefixes. Standard Office theme fallback is available when no complete theme is present.
2. **Invisible alpha:** some XLSX generators write `00RRGGBB`; spreadsheet fills are now treated as opaque, including already-stored fill payloads when decoded for display.
3. **Indexed palette:** corrected the legacy 64-entry palette and primary-color positions.
4. **Tints:** apply tint to HLS luminance rather than independently tinting RGB channels.
5. **White fills and dark mode:** explicit white is preserved. Bright fills use black text instead of theme-dependent primary text; dark fills use white.
6. **Colored headers:** the detected header's fill is stored separately at side-table rowid 0 and displayed on column headers. Data rowids remain unchanged; report-title rows above the header are not displayed.
7. **Inherited direct styles:** row/column fills apply to used cells, with explicit cell styles taking precedence. Sparse cells within a used row can inherit fills.
8. **Blank-row leakage:** skipped blank styled rows cannot color the next data row.
9. **Live toggle:** **Show colors** is now in the sheet menu as well as Settings; changing it refreshes loaded row/header fills immediately.
10. Color-spool read/write failures and malformed worksheet XML are reported instead of silently treated as successful color import.

### Important: existing imports

- Enable **Settings → Cell colors → Import Excel cell colors** before importing. Enable **Show colors inside the grid** to display them.
- If the previous import omitted colors, parsed an incorrect palette, or discarded white/header fills, **import the original XLSX again**. The original file is not retained inside SheetX after import, so the app cannot reconstruct missing styles from values alone. Reimport creates a new workbook; it does not overwrite the existing one. Check the new copy before deleting an old one.
- Existing stored fills encoded with alpha zero can become visible without reimport; previously missing data cannot.
- Supported: **solid background fills**, direct cell/row/column styles, RGB, indexed and theme colors, theme tints, detected header backgrounds.
- **Not reproduced:** conditional formatting, table-style banding, gradients/pattern hatching, font colors, merged-cell layouts, completely blank styled rows, or formatting beyond a row's imported width. CSV/JSON have no Excel formatting. Preparation-derived sheets remain values-only.
- If your workbook uses unsupported formatting or still looks different, share a small representative `.xlsx` so its actual style rules can be inspected. No user workbook was attached for this upgrade.

## Validation

The existing native macOS host test gate now also compiles the unchanged Foundation XML/color parsers, color storage, and dashboard engine. It needs no third-party packages for these tests. Tests exercise namespace themes, opaque fills, indexed/tinted/white colors, inheritance, blank-row isolation, header/data mapping, filtered row alignment, linked filters, numeric handling, limits, persistence, rollback, schema errors, cancellation and source deletion.

Native test/build results are pending the release build. Static checks do not substitute for simulator/device testing.

### Device acceptance checklist

1. Install over SheetX without deleting the app; verify existing data remains. Export important data before updating.
2. Turn color import/display on, import the original XLSX into a new workbook, and compare its direct fills/header with Excel. Check light and dark modes and the live display toggle. Sort/filter and confirm colors stay attached to the correct source row.
3. Build a dashboard with KPI, bar, line and table cards. Apply shared filters and drill into a chart group; verify all cards agree. Clear the selection, reorder/edit cards, save, close and reopen.
4. Cancel a refresh, then refresh again. Check that no stale or partial cards remain. Delete a source and confirm its dashboard disappears without affecting others.
5. Check English/Arabic RTL, portrait/landscape, small-screen and large Dynamic Type layouts, keyboard dismissal, chart taps and the accessible group-selection list. iOS UI/device verification must be done separately from the core test gate.
