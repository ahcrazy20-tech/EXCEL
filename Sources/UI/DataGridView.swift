import SwiftUI

struct DataGridView: View {
    @ObservedObject var vm: SheetViewModel
    @EnvironmentObject var settings: AppSettings
    @Binding var scrollTarget: Int?
    var onSelectRow: ([DBValue]) -> Void
    var onHeaderTap: (ColumnInfo) -> Void

    private var rowHeight: CGFloat { CGFloat(settings.rowHeight) }
    private var fontSize: CGFloat { CGFloat(settings.fontSize) }
    private var defaultWidth: CGFloat { CGFloat(settings.columnWidth) }
    private let indexWidth: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    headerRow
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 0) {
                                ForEach(0..<vm.totalRows, id: \.self) { index in
                                    rowView(index)
                                        .id(index)
                                        .onAppear { vm.prefetch(around: index) }
                                }
                            }
                            .id(vm.totalRows)
                        }
                        .frame(height: max(120, geo.size.height - rowHeight - 1))
                        .onChange(of: scrollTarget) { target in
                            guard let target, target >= 0, target < vm.totalRows else { return }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                            scrollTarget = nil
                        }
                    }
                }
                .frame(minWidth: geo.size.width, alignment: .leading)
            }
            .overlay(alignment: .center) {
                if vm.totalRows == 0 && !vm.isLoading {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                        Text("sheet.noResults".loc).foregroundStyle(.secondary)
                        if vm.query.isActive {
                            Button("sheet.clear".loc) { vm.clearAll() }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.system(size: fontSize - 1, weight: .semibold))
                .frame(width: indexWidth, height: rowHeight)
                .background(Color.accentColor.opacity(0.14))
                .overlay(Rectangle().frame(width: 0.5).foregroundStyle(Color(uiColor: .separator)), alignment: .trailing)

            ForEach(vm.visibleColumns) { col in
                Button {
                    settings.haptic()
                    onHeaderTap(col)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: col.kind.symbol)
                            .font(.system(size: fontSize - 3))
                            .foregroundStyle(.secondary)
                        Text(col.name)
                            .font(.system(size: fontSize, weight: .semibold))
                            .lineLimit(1)
                        if let sort = vm.query.sorts.first(where: { $0.columnIndex == col.index }) {
                            Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                                .font(.system(size: fontSize - 3))
                                .foregroundStyle(.tint)
                        }
                        if vm.query.filters.contains(where: { $0.columnIndex == col.index }) {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .font(.system(size: fontSize - 3))
                                .foregroundStyle(.orange)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: vm.width(for: col, default: defaultWidth), height: rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.accentColor.opacity(0.10))
                .overlay(Rectangle().frame(width: 0.5).foregroundStyle(Color(uiColor: .separator)), alignment: .trailing)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ index: Int) -> some View {
        let values = vm.row(at: index)
        let fills = vm.fills(page: index / vm.pageSize, offset: index % vm.pageSize)
        HStack(spacing: 0) {
            Text("\(index + 1)")
                .font(.system(size: fontSize - 2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: indexWidth, height: rowHeight)
                .background(Color.secondary.opacity(0.06))
                .overlay(Rectangle().frame(width: 0.5).foregroundStyle(Color(uiColor: .separator)), alignment: .trailing)

            if let values {
                ForEach(vm.visibleColumns) { col in
                    cell(values: values, col: col, fills: fills)
                }
            } else {
                ForEach(vm.visibleColumns) { col in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.08))
                        .frame(width: vm.width(for: col, default: defaultWidth) - 10, height: rowHeight * 0.42)
                        .clipShape(Capsule())
                        .frame(width: vm.width(for: col, default: defaultWidth), height: rowHeight)
                }
            }
        }
        .background(index % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color(uiColor: .separator)), alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture {
            if let values {
                settings.haptic()
                onSelectRow(values)
            }
        }
    }

    private func cell(values: [DBValue], col: ColumnInfo, fills: [Int: UInt32]?) -> some View {
        // values[0] is the rowid
        let value = col.index + 1 < values.count ? values[col.index + 1] : DBValue.null
        let numeric = col.kind == .number
        let fillColor = fills?[col.index].map { Color(argb: $0) }
        let textColor: Color = {
            guard let fillColor else { return .primary }
            return fillColor.luminance < 0.55 ? .white : .primary
        }()
        return Text(display(value, kind: col.kind))
            .font(.system(size: fontSize, design: numeric ? .monospaced : .default))
            .foregroundStyle(value.isEmptyText
                             ? (fillColor != nil ? textColor.opacity(0.55) : Color.secondary.opacity(0.5))
                             : textColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(width: vm.width(for: col, default: defaultWidth), height: rowHeight,
                   alignment: numeric ? .trailing : .leading)
            .background(fillColor ?? Color.clear)
            .overlay(Rectangle().frame(width: 0.5).foregroundStyle(Color(uiColor: .separator).opacity(0.6)), alignment: .trailing)
    }

    private func display(_ v: DBValue, kind: ColumnKind) -> String {
        switch v {
        case .double(let d): return ReportBuilder.formatNumber(d)
        case .int(let i): return kind == .number ? ReportBuilder.formatInt(Int(i)) : String(i)
        case .text(let s): return s
        case .null: return ""
        }
    }
}
