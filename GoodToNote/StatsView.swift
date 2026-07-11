//
//  StatsView.swift
//  GoodToNote
//
//  GN-017 — 统计 tab. Replaces StatsPlaceholderView. Range selector (本月/上月/今年/全部/自定义)
//  + category multi-select filter → drives a 支出趋势 line chart (daily for single-month ranges,
//  monthly for year/all/wide-custom, zero-filled) and a 分类占比 donut + ranked list.
//
//  Data 口径铁律 (全仓一致, see LedgerView): sums use Transaction.sgdAmount; EXCLUDE
//  isPending drafts (@Query predicate); this tab counts EXPENSE ONLY (type == .expense,
//  filtered in-memory); needsFxRate txns still count. Aggregation is pure (StatsAggregator);
//  this view only projects @Query rows into ExpenseSnapshot and feeds Swift Charts.
//

import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    @Environment(\.modelContext) private var modelContext   // GN-024: 读当前本位币
    // 沿用 LedgerView:排除 isPending 草稿;只在内存里再筛 type == .expense。
    @Query(filter: #Predicate<Transaction> { !$0.isPending },
           sort: \Transaction.date) private var allTxns: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var range: StatsRange = .thisMonth
    @State private var selectedCategoryIDs: Set<UUID> = []   // 空=全部
    @State private var showFilter = false
    @State private var showCustomRange = false
    @State private var customStart: Date = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var customEnd: Date = Date()

    private var cal: Calendar { .current }

    // MARK: derived

    /// 全部支出(已排除 pending)的快照,未经范围/分类过滤——用于求最早日期 & .all 起点。
    private var allExpenseSnapshots: [ExpenseSnapshot] {
        allTxns.filter { $0.type == .expense }.map(snapshot(of:))
    }

    private var earliest: Date? { allExpenseSnapshots.map(\.date).min() }

    private var resolvedRange: (start: Date, end: Date) {
        range.resolve(now: Date(), earliest: earliest, calendar: cal)
    }

    private var bucket: TimeBucket {
        StatsAggregator.bucket(for: range, now: Date(), earliest: earliest, calendar: cal)
    }

    /// 当前范围 + 分类 filter 下的支出快照。
    private var snapshots: [ExpenseSnapshot] {
        let r = resolvedRange
        return allTxns.compactMap { t -> ExpenseSnapshot? in
            guard t.type == .expense else { return nil }
            guard t.date >= r.start && t.date < r.end else { return nil }
            if !selectedCategoryIDs.isEmpty {
                guard let cid = t.category?.id, selectedCategoryIDs.contains(cid) else { return nil }
            }
            return snapshot(of: t)
        }
    }

    private var trend: [TrendPoint] {
        let r = resolvedRange
        return StatsAggregator.trend(snapshots, bucket: bucket, start: r.start, end: r.end, calendar: cal)
    }

    private var slices: [CategorySlice] { StatsAggregator.breakdown(snapshots) }

    private var grandTotal: Decimal { slices.reduce(0) { $0 + $1.total } }

    private func snapshot(of t: Transaction) -> ExpenseSnapshot {
        ExpenseSnapshot(
            date: t.date,
            sgdAmount: t.sgdAmount,
            categoryID: t.category?.id,
            categoryName: t.category?.name ?? String(localized: "未分类"),
            categoryIcon: t.category?.icon ?? "❓"
        )
    }

    // MARK: body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controlRow
                    if slices.isEmpty {
                        ContentUnavailableView("该范围暂无支出", systemImage: "chart.pie",
                            description: Text("换个时间范围或先记几笔。"))
                            .padding(.top, 40)
                    } else {
                        trendCard
                        donutCard
                        rankCard
                    }
                }
                .padding()
            }
            .navigationTitle("统计")
            .sheet(isPresented: $showFilter) {
                CategoryFilterSheet(categories: categories, selectedCategoryIDs: $selectedCategoryIDs)
            }
            .sheet(isPresented: $showCustomRange) { customRangeSheet }
        }
    }

    // MARK: control row (range menu + filter button)

    private var controlRow: some View {
        HStack {
            Menu {
                rangeButton(.thisMonth)
                rangeButton(.lastMonth)
                rangeButton(.thisYear)
                rangeButton(.all)
                Button {
                    // 默认自定义起止 = 当前已解析范围。
                    let r = resolvedRange
                    customStart = r.start
                    customEnd = cal.date(byAdding: .day, value: -1, to: r.end) ?? r.start
                    showCustomRange = true
                } label: {
                    Label("自定义", systemImage: "calendar")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(range.label).font(.headline)
                    Image(systemName: "chevron.down").font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
            }
            if case .custom(let s, let e) = range {
                Text("\(shortDate(s)) – \(shortDate(cal.date(byAdding: .day, value: -1, to: e) ?? e))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showFilter = true } label: {
                Image(systemName: selectedCategoryIDs.isEmpty
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
                    .font(.title3)
            }
        }
    }

    private func rangeButton(_ r: StatsRange) -> some View {
        Button { range = r } label: {
            if range.id == r.id { Label(r.label, systemImage: "checkmark") }
            else { Text(r.label) }
        }
    }

    // MARK: trend line chart

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("支出趋势").font(.headline)
            Chart(trend) { point in
                LineMark(
                    x: .value("日期", point.bucketStart),
                    y: .value("支出", doubleValue(point.total))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor)
                AreaMark(
                    x: .value("日期", point.bucketStart),
                    y: .value("支出", doubleValue(point.total))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor.opacity(0.12))
            }
            .chartXAxis {
                if bucket == .daily {
                    AxisMarks(values: .stride(by: .day, count: 5)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                } else {
                    AxisMarks(values: .stride(by: .month, count: 1)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.narrow))
                    }
                }
            }
            .frame(height: 200)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: donut + center total

    private var donutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分类占比").font(.headline)
            Chart(slices) { slice in
                SectorMark(
                    angle: .value("金额", doubleValue(slice.total)),
                    innerRadius: .ratio(0.62),
                    angularInset: 1
                )
                .cornerRadius(3)
                .foregroundStyle(by: .value("分类", "\(slice.icon) \(slice.name)"))
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
            .chartBackground { _ in
                VStack(spacing: 2) {
                    Text("支出").font(.caption).foregroundStyle(.secondary)
                    Text(sgd(grandTotal)).font(.headline)
                }
            }
            .frame(height: 240)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: ranked list

    private var rankCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分类排行").font(.headline)
            ForEach(slices) { slice in
                HStack {
                    Text(slice.icon)
                    Text(slice.name)
                    Spacer()
                    Text(sgd(slice.total))
                    Text(slice.fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 4)
                if slice.id != slices.last?.id { Divider() }
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: sheets

    private var customRangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker("开始", selection: $customStart, displayedComponents: .date)
                DatePicker("结束", selection: $customEnd, displayedComponents: .date)
            }
            .navigationTitle("自定义范围")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showCustomRange = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        range = .custom(start: customStart, end: customEnd)
                        showCustomRange = false
                    }
                }
            }
        }
    }

    // MARK: helpers

    private func doubleValue(_ d: Decimal) -> Double { (d as NSDecimalNumber).doubleValue }

    private func sgd(_ v: Decimal) -> String {
        formatBase(v, code: AppSettings.current(in: modelContext).baseCurrencyCode)
    }

    private func shortDate(_ d: Date) -> String {
        d.formatted(.dateTime.month().day())
    }
}
